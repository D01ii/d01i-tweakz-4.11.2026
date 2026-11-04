import { query, withTransaction } from '../db/pool.js';
import { config } from '../config/index.js';
import { keyHash, licenseDurationDays } from '../utils/licenseKey.js';
import { pepperedHash, randomUuid } from '../utils/crypto.js';
import { issueSession, verifySessionToken, refreshSession, revokeAllSessions } from './tokenService.js';
import { logAudit, logAuditTx } from './auditService.js';
import { recordAbuse, maybeEscalateFailedKeys } from './abuseService.js';

function publicLicense(row) {
  return {
    id: row.id,
    type: row.type,
    status: row.status,
    max_devices: row.max_devices,
    expires_at: row.expires_at,
    created_at: row.created_at,
  };
}

/**
 * AKTYWACJA - cala logika w transakcji PostgreSQL z SELECT ... FOR UPDATE,
 * co eliminuje race condition przy rownoleglych aktywacjach (limit 2 urzadzenia).
 */
export async function activate({ key, installId, hwid, label = null, ipHash = null, userAgent = null }) {
  if (!key || typeof key !== 'string') return { ok: false, code: 'KEY_REQUIRED' };
  if (!installId || typeof installId !== 'string' || installId.length > 128) return { ok: false, code: 'INSTALL_ID_INVALID' };
  if (!hwid || typeof hwid !== 'string' || hwid.length > 512) return { ok: false, code: 'HWID_INVALID' };

  const kh = keyHash(key);
  const hwidHash = pepperedHash(hwid);
  const instId = installId.trim();

  return withTransaction(async (client) => {
    const licR = await client.query(`SELECT * FROM licenses WHERE key_hash = $1 FOR UPDATE`, [kh]);
    if (licR.rows.length === 0) {
      await recordAbuse({ kind: 'FAILED_KEY', severity: 'low', ipHash, keyHash: kh, installId: instId, meta: { stage: 'unknown_key' } });
      await maybeEscalateFailedKeys(ipHash);
      await logAudit({ actorType: 'client', action: 'license.activate.failed', ipHash, severity: 'info', meta: { reason: 'unknown_key', key_prefix: key.slice(0, 9) } });
      return { ok: false, code: 'KEY_INVALID' };
    }
    const lic = licR.rows[0];
    if (lic.status !== 'ACTIVE') {
      await recordAbuse({ kind: 'REVOKED_KEY_USE', severity: 'medium', ipHash, keyHash: kh, meta: { license_id: lic.id } });
      return { ok: false, code: 'LICENSE_REVOKED' };
    }
    if (lic.expires_at && new Date(lic.expires_at) <= new Date()) {
      return { ok: false, code: 'LICENSE_EXPIRED' };
    }

    // Istniejace urzadzenie (re-aktywacja) lub nowe.
    let devR = await client.query(
      `SELECT * FROM devices WHERE license_id = $1 AND install_id = $2 FOR UPDATE`,
      [lic.id, instId]
    );
    let device;
    if (devR.rows.length) {
      device = devR.rows[0];
      // B2: HWID istniejacego urzadzenia NIE może być cicho podmieniony.
      // Zmiana sprzetu wymaga resetu urzadzenia przez admina (reset czyści hwid_hash).
      if (device.hwid_hash && device.hwid_hash !== hwidHash) {
        await recordAbuse({
          kind: 'DEVICE_HWID_MISMATCH',
          severity: 'high',
          ipHash,
          keyHash: kh,
          installId: instId,
          meta: { license_id: lic.id, device_id: device.id, active: device.active },
        });
        await logAuditTx(client, {
          actorType: 'client', action: 'license.activate.hwid_mismatch', target: lic.id,
          ipHash, severity: 'warning', meta: { device_id: device.id, install_id: instId },
        });
        return { ok: false, code: 'HWID_MISMATCH' };
      }
      if (!device.active) {
        // Reaktywacja: hwid_hash NULL (po resecie admina) -> wiażemy nowy HWID (kontrolowanie).
        await client.query(
          `UPDATE devices SET active = TRUE, deactivated_at = NULL, hwid_hash = COALESCE(hwid_hash, $2), last_seen_at = now() WHERE id = $1`,
          [device.id, hwidHash]
        );
        device.active = true;
        await client.query(
          `INSERT INTO activation_history (license_id, device_id, action, ip_hash, user_agent, meta)
           VALUES ($1,$2,'REACTIVATE',$3,$4,$5)`,
          [lic.id, device.id, ipHash, userAgent, JSON.stringify({ hwid_rebound: device.hwid_hash === null })]
        );
        await logAuditTx(client, {
          actorType: 'client', action: 'license.reactivate.ok', target: lic.id,
          ipHash, severity: 'info', meta: { device_id: device.id, hwid_rebound: device.hwid_hash === null },
        });
      } else {
        await client.query(`UPDATE devices SET last_seen_at = now() WHERE id = $1`, [device.id]);
      }
    } else {
      const activeCount = await client.query(
        `SELECT COUNT(*)::int AS n FROM devices WHERE license_id = $1 AND active = TRUE`,
        [lic.id]
      );
      if (activeCount.rows[0].n >= lic.max_devices) {
        await recordAbuse({ kind: 'DEVICE_LIMIT_HIT', severity: 'medium', ipHash, keyHash: kh, installId: instId, meta: { license_id: lic.id, active: activeCount.rows[0].n, max: lic.max_devices } });
      await client.query(
        `INSERT INTO activation_history (license_id, action, ip_hash, user_agent, meta)
         VALUES ($1,'ACTIVATE',$2,$3,$4)`,
          [lic.id, ipHash, userAgent, JSON.stringify({ result: 'device_limit', install_id: instId })]
        );
        await logAuditTx(client, {
          actorType: 'client', action: 'license.activate.device_limit', target: lic.id,
          ipHash, severity: 'info', meta: { install_id: instId, max: lic.max_devices },
        });
        return { ok: false, code: 'DEVICE_LIMIT_REACHED', maxDevices: lic.max_devices };
      }
      const newId = randomUuid();
      try {
        await client.query(
          `INSERT INTO devices (id, license_id, install_id, hwid_hash, label) VALUES ($1,$2,$3,$4,$5)`,
          [newId, lic.id, instId, hwidHash, label]
        );
      } catch (err) {
        // Runda 3, Problem 1: UNIQUE(license_id, install_id) to ostatnia linia obrony.
        // Jesli mimo blokady licencji FOR UPDATE doszlo do naruszenia unikalnosci
        // (np. w przyszlosci bez blokady), nie zwracamy 500 - traktujemy jak istniejace urzadzenie.
        if (err.code === '23505') {
          const again = await client.query(
            `SELECT * FROM devices WHERE license_id = $1 AND install_id = $2 FOR UPDATE`,
            [lic.id, instId]
          );
          if (again.rows.length) {
            device = again.rows[0];
            if (device.hwid_hash && device.hwid_hash !== hwidHash) {
              await recordAbuse({ kind: 'DEVICE_HWID_MISMATCH', severity: 'high', ipHash, keyHash: kh, installId: instId, meta: { license_id: lic.id, device_id: device.id, race: true } });
              return { ok: false, code: 'HWID_MISMATCH' };
            }
            if (!device.active) {
              await client.query(
                `UPDATE devices SET active = TRUE, deactivated_at = NULL, hwid_hash = COALESCE(hwid_hash, $2), last_seen_at = now() WHERE id = $1`,
                [device.id, hwidHash]
              );
              device.active = true;
            }
            await client.query(
              `INSERT INTO activation_history (license_id, device_id, action, ip_hash, user_agent, meta)
               VALUES ($1,$2,'REACTIVATE',$3,$4,$5)`,
              [lic.id, device.id, ipHash, userAgent, JSON.stringify({ result: 'race_existing_device' })]
            );
          } else {
            throw err;
          }
        } else {
          throw err;
        }
      }
      if (!device) {
        device = { id: newId, active: true };
        await client.query(
          `INSERT INTO activation_history (license_id, device_id, action, ip_hash, user_agent, meta)
           VALUES ($1,$2,'ACTIVATE',$3,$4,$5)`,
          [lic.id, device.id, ipHash, userAgent, JSON.stringify({ result: 'ok' })]
        );
        // Runda 3, Problem 1: ponowna kontrola limitu PO insertcie (defense in depth).
        const afterCount = await client.query(
          `SELECT COUNT(*)::int AS n FROM devices WHERE license_id = $1 AND active = TRUE`,
          [lic.id]
        );
        if (afterCount.rows[0].n > lic.max_devices) {
          await recordAbuse({ kind: 'DEVICE_LIMIT_EXCEEDED', severity: 'critical', ipHash, keyHash: kh, installId: instId, meta: { license_id: lic.id, active: afterCount.rows[0].n, max: lic.max_devices } });
          throw new Error(`device limit exceeded after insert (${afterCount.rows[0].n} > ${lic.max_devices})`);
        }
      }
    }

    await client.query(`UPDATE devices SET last_seen_at = now() WHERE id = $1`, [device.id]);
    // Wszystkie poprzednie sesje tego urzadzenia zostaja uniewaznione (jedna aktywna sesja na urzadzenie).
    await client.query(
      `UPDATE license_sessions SET revoked = TRUE, revoked_at = now(), revoke_reason = 'superseded_by_activation'
       WHERE device_id = $1 AND NOT revoked`,
      [device.id]
    );
    await logAuditTx(client, { actorType: 'client', action: 'license.activate.ok', target: lic.id, ipHash, severity: 'info', meta: { device_id: device.id, type: lic.type } });

    // Sesje wydajemy poza blokujacym lockiem? Nie - wydajemy w tej samej transakcji, zeby byla atomowa.
    const jti = randomUuid();
    const now = new Date();
    const exp = new Date(now.getTime() + config.security.tokenTtlSeconds * 1000);
    await client.query(
      `INSERT INTO license_sessions (jti, license_id, device_id, issued_at, expires_at) VALUES ($1,$2,$3,$4,$5)`,
      [jti, lic.id, device.id, now, exp]
    );
    const { signToken } = await import('../utils/crypto.js');
    const token = signToken({
      jti,
      lic: lic.id,
      dev: device.id,
      iat: Math.floor(now.getTime() / 1000),
      exp: Math.floor(exp.getTime() / 1000),
      typ: 'access',
    });
    return {
      ok: true,
      token,
      token_expires_at: exp.toISOString(),
      device_id: device.id,
      license: publicLicense(lic),
    };
  });
}

export async function validate(token, ctx = {}) {
  const res = await verifySessionToken(token, ctx);
  if (!res.ok) return res;
  const lic = await query(`SELECT id, type, status, max_devices, expires_at FROM licenses WHERE id = $1`, [res.payload.lic]);
  return { ok: true, valid: true, license: publicLicense(lic.rows[0]), device_id: res.payload.dev };
}

export async function refresh(token, ctx = {}) {
  const res = await refreshSession(token, ctx);
  if (!res.ok) return res;
  return { ok: true, token: res.token, token_expires_at: res.expiresAt ? res.expiresAt.toISOString() : undefined, replayed: !!res.replayed };
}

export async function deactivate({ token = null, key = null, installId = null, ipHash = null }) {
  let licenseId, deviceId;
  if (token) {
    const v = await verifySessionToken(token, { ipHash });
    if (!v.ok) return v;
    licenseId = v.payload.lic;
    deviceId = v.payload.dev;
  } else if (key && installId) {
    const lic = await query(`SELECT id FROM licenses WHERE key_hash = $1`, [keyHash(key)]);
    if (!lic.rows.length) return { ok: false, reason: 'KEY_INVALID' };
    licenseId = lic.rows[0].id;
    const dev = await query(`SELECT id FROM devices WHERE license_id = $1 AND install_id = $2`, [licenseId, installId.trim()]);
    if (!dev.rows.length) return { ok: false, reason: 'DEVICE_NOT_FOUND' };
    deviceId = dev.rows[0].id;
  } else {
    return { ok: false, reason: 'TOKEN_OR_KEY_REQUIRED' };
  }
  await withTransaction(async (client) => {
    await client.query(`UPDATE devices SET active = FALSE, deactivated_at = now() WHERE id = $1`, [deviceId]);
    await client.query(
      `UPDATE license_sessions SET revoked = TRUE, revoked_at = now(), revoke_reason = 'device_deactivated'
       WHERE device_id = $1 AND NOT revoked`,
      [deviceId]
    );
    await client.query(
      `INSERT INTO activation_history (license_id, device_id, action, ip_hash) VALUES ($1,$2,'DEACTIVATE',$3)`,
      [licenseId, deviceId, ipHash]
    );
    await logAuditTx(client, { actorType: 'client', action: 'license.deactivate.ok', target: licenseId, ipHash, severity: 'info', meta: { device_id: deviceId } });
  });
  return { ok: true };
}

export async function status(token, ctx = {}) {
  const v = await verifySessionToken(token, ctx);
  if (!v.ok) return v;
  const r = await query(
    `SELECT l.id, l.type, l.status, l.max_devices, l.expires_at, l.key_prefix,
            d.id AS device_id, d.active AS device_active,
            (SELECT COUNT(*)::int FROM devices d2 WHERE d2.license_id = l.id AND d2.active) AS active_devices
     FROM licenses l JOIN devices d ON d.id = $2 WHERE l.id = $1`,
    [v.payload.lic, v.payload.dev]
  );
  if (!r.rows.length) return { ok: false, reason: 'NOT_FOUND' };
  const row = r.rows[0];
  return {
    ok: true,
    license: publicLicense(row),
    key_prefix: row.key_prefix,
    device_id: row.device_id,
    active_devices: row.active_devices,
  };
}

export async function listDevices(token, ctx = {}) {
  const v = await verifySessionToken(token, ctx);
  if (!v.ok) return v;
  const r = await query(
    `SELECT id, install_id, label, active, first_seen_at, last_seen_at, deactivated_at
     FROM devices WHERE license_id = $1 ORDER BY first_seen_at`,
    [v.payload.lic]
  );
  // install_id wysylamy tylko zahashowany klientowi? Klient zna swoj install_id; dla innych urzadzen pokazujemy skrot.
  return {
    ok: true,
    devices: r.rows.map((d) => ({
      id: d.id,
      label: d.label,
      active: d.active,
      mine: d.id === v.payload.dev,
      install_id: d.id === v.payload.dev ? d.install_id : d.install_id.slice(0, 8) + '…',
      first_seen_at: d.first_seen_at,
      last_seen_at: d.last_seen_at,
      deactivated_at: d.deactivated_at,
    })),
  };
}

export { revokeAllSessions, licenseDurationDays };
