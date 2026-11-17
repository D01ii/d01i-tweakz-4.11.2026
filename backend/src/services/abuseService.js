import { query, withTransaction } from '../db/pool.js';
import { config } from '../config/index.js';
import { logAudit } from './auditService.js';
import { sendDiscordAlert } from './discordService.js';

/**
 * Wykrywanie naduzyc: zapis zdarzen, progowe alerty, czasowe blokady IP.
 * Blokady sa zawsze czasowe (chyba ze admin recznie przedluzy) i odwracalne.
 */
export async function recordAbuse({ kind, severity = 'low', ipHash = null, keyHash = null, installId = null, meta = null }) {
  await query(
    `INSERT INTO abuse_events (kind, severity, ip_hash, key_hash, install_id, meta)
     VALUES ($1,$2,$3,$4,$5,$6)`,
    [kind, severity, ipHash, keyHash, installId, meta ? JSON.stringify(meta) : null]
  );
  await logAudit({
    actorType: 'system',
    action: `abuse.${kind}`,
    severity: severity === 'critical' || severity === 'high' ? 'warning' : 'info',
    ipHash,
    meta: { severity, ...(meta || {}) },
  });

  // Progowe alerty + czasowa blokada przy powaznym nadużyciu.
  // Pojedyncze zdarzenie "high" tylko alarmuje; blokada pojawia sie przy "critical"
  // albo przy powtorzeniu tego samego rodzaju zdarzenia (>=3 w oknie) - zeby pojedynczy
  // blad klienta nie blokowal od razu calej sieci.
  if (severity === 'high' || severity === 'critical') {
    await sendDiscordAlert({
      title: `Wykryto nadużycie: ${kind}`,
      severity,
      fields: { severity, ip: ipHash ? ipHash.slice(0, 12) + '…' : null, install_id: installId },
    });
    if (ipHash) {
      let shouldBlock = severity === 'critical';
      if (!shouldBlock) {
        const n = await countRecentAbuse(ipHash, kind, config.abuse.windowMinutes);
        shouldBlock = n >= 3;
      }
      if (shouldBlock) {
        await applyTempBlock(ipHash, `auto:${kind}`, config.abuse.tempBlockMinutes);
      }
    }
  }
}

/** Sprawdza czy dany (zahashowany) IP jest aktualnie zablokowany. */
export async function isBlocked(ipHash) {
  if (!ipHash) return false;
  const r = await query(
    `SELECT reason, until FROM ip_blocks
     WHERE ip_hash = $1 AND NOT lifted AND until > now() ORDER BY until DESC LIMIT 1`,
    [ipHash]
  );
  return r.rows[0] || null;
}

export async function applyTempBlock(ipHash, reason, minutes) {
  const until = new Date(Date.now() + minutes * 60_000);
  await query(
    `INSERT INTO ip_blocks (ip_hash, reason, until) VALUES ($1,$2,$3)
     ON CONFLICT (ip_hash) DO UPDATE SET reason = EXCLUDED.reason, until = EXCLUDED.until,
       blocked_at = now(), lifted = FALSE`,
    [ipHash, reason, until]
  );
  await logAudit({ actorType: 'system', action: 'ip.temp_block', target: ipHash.slice(0, 12) + '…', severity: 'warning', meta: { reason, minutes } });
}

export async function liftBlock(ipHash, adminId) {
  await query(`UPDATE ip_blocks SET lifted = TRUE WHERE ip_hash = $1`, [ipHash]);
  await logAudit({ actorType: 'admin', actorId: adminId, action: 'ip.unblock', target: ipHash.slice(0, 12) + '…', severity: 'info' });
}

export async function listBlocks() {
  const r = await query(`SELECT ip_hash, reason, blocked_at, until, lifted FROM ip_blocks ORDER BY blocked_at DESC LIMIT 200`);
  return r.rows;
}

export async function listAbuseEvents({ limit = 100, offset = 0, kind = null } = {}) {
  const where = kind ? 'WHERE kind = $1' : '';
  const params = kind ? [kind, limit, offset] : [limit, offset];
  const r = await query(
    `SELECT id, kind, severity, ip_hash, key_hash, install_id, meta, at, resolved
     FROM abuse_events ${where} ORDER BY at DESC LIMIT $${kind ? 2 : 1} OFFSET $${kind ? 3 : 2}`,
    params
  );
  return r.rows;
}

/**
 * Liczy nieudane aktywacje (bledny klucz) dla danego IP w ostatnim oknie.
 * Sama liczba nieudanych prob NIE jest dowodem wlamania - sluzy tylko do alertu/blokady.
 */
export async function countRecentAbuse(ipHash, kind, windowMinutes = config.abuse.windowMinutes) {
  const r = await query(
    `SELECT COUNT(*)::int AS n FROM abuse_events
     WHERE ip_hash = $1 AND kind = $2 AND at > now() - ($3 || ' minutes')::interval`,
    [ipHash, kind, String(windowMinutes)]
  );
  return r.rows[0].n;
}

export async function maybeEscalateFailedKeys(ipHash) {
  const n = await countRecentAbuse(ipHash, 'FAILED_KEY');
  if (n >= config.abuse.failedKeyThreshold) {
    await recordAbuse({
      kind: 'FAILED_KEY_BURST',
      severity: 'critical',
      ipHash,
      meta: { count: n, windowMinutes: config.abuse.windowMinutes },
    });
    return true;
  }
  return false;
}

export { withTransaction };
