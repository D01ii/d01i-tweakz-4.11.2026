import { Router } from 'express';
import { z } from 'zod';
import { query, withTransaction } from '../../db/pool.js';
import { generateLicenseKey, keyHash, keyPrefix, isValidKeyFormat, LICENSE_TYPES, licenseDurationDays } from '../../utils/licenseKey.js';
import { requireAdmin } from '../../middleware/adminAuth.js';
import { adminApiLimiter } from '../../middleware/rateLimit.js';
import { httpError } from '../../middleware/common.js';
import { logAudit, logAuditTx } from '../../services/auditService.js';
import { sendDiscordAlert } from '../../services/discordService.js';

const router = Router();

const createSchema = z.object({
  type: z.enum(LICENSE_TYPES),
  max_devices: z.number().int().min(1).max(2).default(2),
  notes: z.string().max(500).optional(),
  expires_at: z.string().datetime().optional(), // opcjonalnie inna data niz domyslna dla typu
});

router.post('/', requireAdmin, adminApiLimiter, async (req, res, next) => {
  try {
    const parsed = createSchema.safeParse(req.body);
    if (!parsed.success) throw httpError(400, 'VALIDATION_ERROR', parsed.error.issues.map((i) => i.message).join('; '));
    const { type, max_devices, notes } = parsed.data;

    // Pelny klucz wyswietlamy tylko raz - w bazie zostaje tylko hash.
    const fullKey = generateLicenseKey();
    let expiresAt = parsed.data.expires_at ? new Date(parsed.data.expires_at) : null;
    if (!expiresAt) {
      const days = licenseDurationDays(type);
      if (days !== null) expiresAt = new Date(Date.now() + days * 86400_000);
    }
    const r = await query(
      `INSERT INTO licenses (key_hash, key_prefix, type, max_devices, expires_at, created_by, notes)
       VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING id, type, status, max_devices, expires_at, created_at`,
      [keyHash(fullKey), keyPrefix(fullKey), type, max_devices, expiresAt, req.admin.adminId, notes || null]
    );
    await logAudit({ actorType: 'admin', actorId: req.admin.adminId, action: 'license.create', target: r.rows[0].id, severity: 'warning', meta: { type, key_prefix: keyPrefix(fullKey) } });
    await sendDiscordAlert({ title: 'Utworzono nowa licencje', severity: 'medium', fields: { typ: type, prefix: keyPrefix(fullKey), devices: max_devices } });
    res.status(201).json({ ok: true, license: r.rows[0], key: fullKey, warning: 'Pelny klucz jest wyswietlany tylko raz. Zapisz go - nie mozna go odczytac z bazy.' });
  } catch (e) { next(e); }
});

router.get('/', requireAdmin, async (req, res, next) => {
  try {
    const search = typeof req.query.search === 'string' ? req.query.search.trim().slice(0, 64) : '';
    const page = Math.max(1, parseInt(req.query.page || '1', 10));
    const perPage = Math.min(100, Math.max(10, parseInt(req.query.per_page || '25', 10)));
    const where = search
      ? `WHERE key_prefix ILIKE $1 OR type::text ILIKE $1 OR status ILIKE $1`
      : '';
    const params = search ? [`%${search}%`] : [];
    const total = await query(`SELECT COUNT(*)::int AS n FROM licenses ${where}`, params);
    const r = await query(
      `SELECT l.id, l.key_prefix, l.type, l.status, l.max_devices, l.expires_at, l.created_at, l.revoked_at, l.notes,
              (SELECT COUNT(*)::int FROM devices d WHERE d.license_id = l.id AND d.active) AS active_devices
       FROM licenses l ${where} ORDER BY l.created_at DESC LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
      [...params, perPage, (page - 1) * perPage]
    );
    res.json({ ok: true, licenses: r.rows, total: total.rows[0].n, page, per_page: perPage });
  } catch (e) { next(e); }
});

router.get('/:id', requireAdmin, async (req, res, next) => {
  try {
    const lic = await query(`SELECT * FROM licenses WHERE id = $1`, [req.params.id]);
    if (!lic.rows.length) throw httpError(404, 'NOT_FOUND', 'Nie znaleziono licencji.');
    const devices = await query(
      `SELECT id, install_id, label, active, first_seen_at, last_seen_at, deactivated_at FROM devices WHERE license_id = $1 ORDER BY first_seen_at`,
      [req.params.id]
    );
    const history = await query(
      `SELECT id, action, at, ip_hash, user_agent, meta FROM activation_history WHERE license_id = $1 ORDER BY at DESC LIMIT 100`,
      [req.params.id]
    );
    res.json({ ok: true, license: lic.rows[0], devices: devices.rows, history: history.rows });
  } catch (e) { next(e); }
});

router.post('/:id/revoke', requireAdmin, adminApiLimiter, async (req, res, next) => {
  try {
    const reason = String(req.body?.reason || '').slice(0, 300) || 'brak';
    // B7: revoke + uniewaznienie sesji + audit w JEDNEJ transakcji.
    const revoked = await withTransaction(async (client) => {
      const r = await client.query(
        `UPDATE licenses SET status = 'REVOKED', revoked_at = now(), revoke_reason = $2 WHERE id = $1 AND status = 'ACTIVE' RETURNING id`,
        [req.params.id, reason]
      );
      if (!r.rows.length) return false;
      await client.query(
        `UPDATE license_sessions SET revoked = TRUE, revoked_at = now(), revoke_reason = 'license_revoked_by_admin'
         WHERE license_id = $1 AND NOT revoked`,
        [req.params.id]
      );
      await logAuditTx(client, { actorType: 'admin', actorId: req.admin.adminId, action: 'license.revoke', target: req.params.id, severity: 'critical', meta: { reason } });
      return true;
    });
    if (!revoked) throw httpError(404, 'NOT_FOUND', 'Licencja nie istnieje lub jest juz uniewazniona.');
    await sendDiscordAlert({ title: 'Uniewazniono licencje', severity: 'high', fields: { licencja: req.params.id.slice(0, 8) + '…', powod: reason } });
    res.json({ ok: true });
  } catch (e) { next(e); }
});

router.post('/:id/extend', requireAdmin, adminApiLimiter, async (req, res, next) => {
  try {
    const days = z.number().int().min(1).max(36500).parse(req.body?.days);
    const r = await query(
      `UPDATE licenses SET expires_at = COALESCE(expires_at, now()) + ($2 || ' days')::interval WHERE id = $1 RETURNING id, expires_at`,
      [req.params.id, String(days)]
    );
    if (!r.rows.length) throw httpError(404, 'NOT_FOUND', 'Nie znaleziono licencji.');
    await logAudit({ actorType: 'admin', actorId: req.admin.adminId, action: 'license.extend', target: req.params.id, meta: { days } });
    res.json({ ok: true, expires_at: r.rows[0].expires_at });
  } catch (e) { next(e.status ? e : httpError(400, 'VALIDATION_ERROR', e.message)); }
});

router.post('/:id/reset-devices', requireAdmin, adminApiLimiter, async (req, res, next) => {
  try {
    await withTransaction(async (client) => {
      const lic = await client.query(`SELECT id FROM licenses WHERE id = $1 FOR UPDATE`, [req.params.id]);
      if (!lic.rows.length) throw httpError(404, 'NOT_FOUND', 'Nie znaleziono licencji.');
      // B2: reset czyści też hwid_hash - kolejna aktywacja wiąże HWID od nowa (kontrolowanie).
      await client.query(`UPDATE devices SET active = FALSE, deactivated_at = now(), hwid_hash = NULL WHERE license_id = $1`, [req.params.id]);
      await client.query(
        `UPDATE license_sessions SET revoked = TRUE, revoked_at = now(), revoke_reason = 'devices_reset_by_admin' WHERE license_id = $1 AND NOT revoked`,
        [req.params.id]
      );
      await logAuditTx(client, { actorType: 'admin', actorId: req.admin.adminId, action: 'license.reset_devices', target: req.params.id, severity: 'warning' });
    });
    res.json({ ok: true });
  } catch (e) { next(e); }
});

router.post('/:id/devices/:deviceId/deactivate', requireAdmin, adminApiLimiter, async (req, res, next) => {
  try {
    const r = await query(
      `UPDATE devices SET active = FALSE, deactivated_at = now() WHERE id = $1 AND license_id = $2 RETURNING id`,
      [req.params.deviceId, req.params.id]
    );
    if (!r.rows.length) throw httpError(404, 'NOT_FOUND', 'Urzadzenie nie nalezy do tej licencji.');
    await query(
      `UPDATE license_sessions SET revoked = TRUE, revoked_at = now(), revoke_reason = 'device_deactivated_by_admin' WHERE device_id = $1 AND NOT revoked`,
      [req.params.deviceId]
    );
    await logAudit({ actorType: 'admin', actorId: req.admin.adminId, action: 'device.deactivate', target: req.params.deviceId, severity: 'info' });
    res.json({ ok: true });
  } catch (e) { next(e); }
});

router.get('/:id/history', requireAdmin, async (req, res, next) => {
  try {
    const r = await query(
      `SELECT id, action, at, ip_hash, user_agent, meta FROM activation_history WHERE license_id = $1 ORDER BY at DESC LIMIT 500`,
      [req.params.id]
    );
    res.json({ ok: true, history: r.rows });
  } catch (e) { next(e); }
});

export default router;
