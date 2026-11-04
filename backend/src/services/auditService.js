import { query } from '../db/pool.js';

/**
 * Centralny audit log. Wszystkie wazne operacje (licencje, admin, bezpieczenstwo)
 * musza przechodzic przez logAudit.
 */
export async function logAudit({ actorType = 'system', actorId = null, action, target = null, ipHash = null, severity = 'info', meta = null }) {
  try {
    await query(
      `INSERT INTO audit_logs (actor_type, actor_id, action, target, ip_hash, severity, meta)
       VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [actorType, actorId, action, target, ipHash, severity, meta ? JSON.stringify(meta) : null]
    );
  } catch (err) {
    // Audit log nie moze przerwac operacji, ale blad musi byc widoczny.
    console.error('[audit] nie udalo sie zapisac wpisu:', err.message);
  }
}

export async function listAudit({ limit = 100, offset = 0, action = null } = {}) {
  const where = action ? 'WHERE action = $1' : '';
  const params = action ? [action, limit, offset] : [limit, offset];
  const sql = `SELECT id, actor_type, actor_id, action, target, severity, meta, at
               FROM audit_logs ${where}
               ORDER BY at DESC LIMIT $${action ? 2 : 1} OFFSET $${action ? 3 : 2}`;
  const r = await query(sql, params);
  return r.rows;
}
