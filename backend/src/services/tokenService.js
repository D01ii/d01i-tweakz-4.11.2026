import { query, withTransaction } from '../db/pool.js';
import { config } from '../config/index.js';
import { signToken, verifyToken, randomUuid } from '../utils/crypto.js';
import { logAudit } from './auditService.js';
import { recordAbuse } from './abuseService.js';

const TTL = () => config.security.tokenTtlSeconds;

/**
 * Sesje licencyjne: token = Ed25519-signed, krotki (<=120s), z jti trzymanym w bazie.
 * Serwer jest jedynym zrodlem prawdy - klient nie moze sam wygenerowac uprawnien.
 */
export async function issueSession({ licenseId, deviceId }) {
  const jti = randomUuid();
  const now = new Date();
  const exp = new Date(now.getTime() + TTL() * 1000);
  await query(
    `INSERT INTO license_sessions (jti, license_id, device_id, issued_at, expires_at)
     VALUES ($1,$2,$3,$4,$5)`,
    [jti, licenseId, deviceId, now, exp]
  );
  const token = signToken({ jti, lic: licenseId, dev: deviceId, iat: Math.floor(now.getTime() / 1000), exp: Math.floor(exp.getTime() / 1000), typ: 'access' });
  return { token, jti, expiresAt: exp };
}

/**
 * Weryfikacja tokena: podpis -> struktura -> termin -> sesja w bazie (nie uniewazniona, nie wygasla).
 * Zwraca { ok, payload?, reason? }.
 */
export async function verifySessionToken(token, { ipHash = null } = {}) {
  const payload = verifyToken(token);
  if (!payload) {
    await recordAbuse({ kind: 'TOKEN_TAMPER', severity: 'high', ipHash, meta: { stage: 'signature' } });
    return { ok: false, reason: 'INVALID_SIGNATURE' };
  }
  const now = Math.floor(Date.now() / 1000);
  if (payload.exp <= now) {
    return { ok: false, reason: 'TOKEN_EXPIRED', payload };
  }
  const r = await query(
    `SELECT s.revoked, s.expires_at, s.license_id, l.status AS license_status, l.expires_at AS license_expires_at, d.active AS device_active
     FROM license_sessions s
     JOIN licenses l ON l.id = s.license_id
     JOIN devices d ON d.id = s.device_id
     WHERE s.jti = $1`,
    [payload.jti]
  );
  if (r.rows.length === 0) {
    await recordAbuse({ kind: 'TOKEN_UNKNOWN_SESSION', severity: 'high', ipHash, meta: { jti: payload.jti } });
    return { ok: false, reason: 'SESSION_UNKNOWN', payload };
  }
  const row = r.rows[0];
  if (row.revoked) return { ok: false, reason: 'SESSION_REVOKED', payload };
  if (row.license_status !== 'ACTIVE') return { ok: false, reason: 'LICENSE_REVOKED', payload };
  if (row.license_expires_at && new Date(row.license_expires_at) <= new Date()) return { ok: false, reason: 'LICENSE_EXPIRED', payload };
  if (!row.device_active) return { ok: false, reason: 'DEVICE_DEACTIVATED', payload };
  return { ok: true, payload, row };
}

/**
 * Odświeżanie tokena z rotacja. Odporne na utratę odpowiedzi:
 * jesli stary token zostal juz zastapiony, a nastepca jest mlodszy niz
 * REFRESH_REPLAY_WINDOW_SECONDS, zwracamy ten sam nowy token (idempotentne powtorzenie).
 */
export async function refreshSession(token, { ipHash = null } = {}) {
  const payload = verifyToken(token);
  if (!payload) {
    await recordAbuse({ kind: 'TOKEN_TAMPER', severity: 'high', ipHash, meta: { stage: 'refresh-signature' } });
    return { ok: false, reason: 'INVALID_SIGNATURE' };
  }
  const now = Math.floor(Date.now() / 1000);
  if (payload.exp <= now) return { ok: false, reason: 'TOKEN_EXPIRED' };

  return withTransaction(async (client) => {
    const r = await client.query(
      `SELECT s.jti, s.replaced_by, s.revoked, s.license_id, s.device_id,
              l.status AS license_status, l.expires_at AS license_expires_at, d.active AS device_active
       FROM license_sessions s
       JOIN licenses l ON l.id = s.license_id
       JOIN devices d ON d.id = s.device_id
       WHERE s.jti = $1 FOR UPDATE`,
      [payload.jti]
    );
    if (r.rows.length === 0) return { ok: false, reason: 'SESSION_UNKNOWN' };
    const cur = r.rows[0];
    if (cur.revoked) return { ok: false, reason: 'SESSION_REVOKED' };
    if (cur.license_status !== 'ACTIVE') return { ok: false, reason: 'LICENSE_REVOKED' };
    if (cur.license_expires_at && new Date(cur.license_expires_at) <= new Date()) return { ok: false, reason: 'LICENSE_EXPIRED' };
    if (!cur.device_active) return { ok: false, reason: 'DEVICE_DEACTIVATED' };

    // Idempotentne powtorzenie po utracie odpowiedzi:
    if (cur.replaced_by) {
      const rep = await client.query(
        `SELECT jti, issued_at, revoked FROM license_sessions WHERE jti = $1`,
        [cur.replaced_by]
      );
      if (rep.rows.length && !rep.rows[0].revoked) {
        const age = (Date.now() - new Date(rep.rows[0].issued_at).getTime()) / 1000;
        if (age <= config.security.refreshReplayWindowSeconds) {
          const p2 = { jti: rep.rows[0].jti, lic: cur.license_id, dev: cur.device_id, iat: Math.floor(new Date(rep.rows[0].issued_at).getTime() / 1000) };
          // exp nastepcy juz minelo? jesli tak, wydaj nowy normalnie.
          const exp2 = Math.floor(new Date((await client.query('SELECT expires_at FROM license_sessions WHERE jti=$1', [cur.replaced_by])).rows[0].expires_at).getTime() / 1000);
          if (exp2 > now) {
            return {
              ok: true,
              replayed: true,
              token: signToken({ ...p2, exp: exp2, typ: 'access' }),
              jti: p2.jti,
            };
          }
        }
      }
    }

    const jti = randomUuid();
    const nowD = new Date();
    const exp = new Date(nowD.getTime() + TTL() * 1000);
    await client.query(
      `INSERT INTO license_sessions (jti, license_id, device_id, issued_at, expires_at) VALUES ($1,$2,$3,$4,$5)`,
      [jti, cur.license_id, cur.device_id, nowD, exp]
    );
    await client.query(`UPDATE license_sessions SET replaced_by = $1 WHERE jti = $2`, [jti, cur.jti]);
    const token2 = signToken({
      jti,
      lic: cur.license_id,
      dev: cur.device_id,
      iat: Math.floor(nowD.getTime() / 1000),
      exp: Math.floor(exp.getTime() / 1000),
      typ: 'access',
    });
    return { ok: true, replayed: false, token: token2, jti, expiresAt: exp };
  });
}

/** Natychmiastowe uniewaznienie wszystkich sesji licencji (np. po revoke). */
export async function revokeAllSessions(licenseId, reason = 'license_revoked') {
  await query(
    `UPDATE license_sessions SET revoked = TRUE, revoked_at = now(), revoke_reason = $2
     WHERE license_id = $1 AND NOT revoked`,
    [licenseId, reason]
  );
  await logAudit({ actorType: 'system', action: 'sessions.revoke_all', target: licenseId, severity: 'warning', meta: { reason } });
}

export async function revokeSession(jti, reason) {
  await query(`UPDATE license_sessions SET revoked = TRUE, revoked_at = now(), revoke_reason = $2 WHERE jti = $1`, [jti, reason]);
}
