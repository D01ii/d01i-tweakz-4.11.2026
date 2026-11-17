import { query } from '../db/pool.js';
import { logAudit } from './auditService.js';

/** Ustawienia systemowe przechowywane w tabeli settings (klucz -> JSON). */
export async function getSetting(key) {
  const r = await query(`SELECT value, updated_at FROM settings WHERE key = $1`, [key]);
  return r.rows[0] || null;
}

export async function setSetting(key, value, updatedBy) {
  await query(
    `INSERT INTO settings (key, value, updated_by) VALUES ($1,$2,$3)
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by`,
    [key, JSON.stringify(value), updatedBy]
  );
  await logAudit({ actorType: 'admin', actorId: updatedBy, action: 'settings.update', target: key, severity: 'info' });
}

export async function listSettings() {
  const r = await query(`SELECT key, value, updated_at FROM settings ORDER BY key`);
  return r.rows;
}
