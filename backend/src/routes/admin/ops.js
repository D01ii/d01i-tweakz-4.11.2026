import { Router } from 'express';
import { z } from 'zod';
import { requireAdmin, requireRole } from '../../middleware/adminAuth.js';
import { adminApiLimiter } from '../../middleware/rateLimit.js';
import { httpError } from '../../middleware/common.js';
import { listAudit } from '../../services/auditService.js';
import { listAbuseEvents, listBlocks, liftBlock } from '../../services/abuseService.js';
import { getSetting, setSetting, listSettings } from '../../services/settingsService.js';
import { query, healthCheck } from '../../db/pool.js';
import { encryptSecret } from '../../utils/secretCrypto.js';

const router = Router();

router.get('/health', async (req, res) => {
  let db = false;
  try { db = await healthCheck(); } catch { db = false; }
  res.status(db ? 200 : 503).json({ ok: db, db, time: new Date().toISOString() });
});

router.get('/stats', requireAdmin, async (req, res, next) => {
  try {
    const q = async (sql) => (await query(sql)).rows[0];
    const stats = {
      licenses_total: (await q('SELECT COUNT(*)::int AS n FROM licenses')).n,
      licenses_active: (await q(`SELECT COUNT(*)::int AS n FROM licenses WHERE status='ACTIVE'`)).n,
      licenses_revoked: (await q(`SELECT COUNT(*)::int AS n FROM licenses WHERE status='REVOKED'`)).n,
      devices_active: (await q('SELECT COUNT(*)::int AS n FROM devices WHERE active')).n,
      sessions_active: (await q(`SELECT COUNT(*)::int AS n FROM license_sessions WHERE NOT revoked AND expires_at > now()`)).n,
      activations_24h: (await q(`SELECT COUNT(*)::int AS n FROM activation_history WHERE at > now() - interval '24 hours'`)).n,
      abuse_open: (await q(`SELECT COUNT(*)::int AS n FROM abuse_events WHERE NOT resolved AND at > now() - interval '24 hours'`)).n,
      admins: (await q('SELECT COUNT(*)::int AS n FROM admins WHERE is_active')).n,
    };
    res.json({ ok: true, stats });
  } catch (e) { next(e); }
});

router.get('/audit', requireAdmin, async (req, res, next) => {
  try {
    const limit = Math.min(500, parseInt(req.query.limit || '100', 10));
    const action = typeof req.query.action === 'string' ? req.query.action : null;
    res.json({ ok: true, logs: await listAudit({ limit, action }) });
  } catch (e) { next(e); }
});

router.get('/abuse', requireAdmin, async (req, res, next) => {
  try {
    const limit = Math.min(500, parseInt(req.query.limit || '100', 10));
    const kind = typeof req.query.kind === 'string' ? req.query.kind : null;
    res.json({ ok: true, events: await listAbuseEvents({ limit, kind }) });
  } catch (e) { next(e); }
});

router.get('/blocks', requireAdmin, async (req, res, next) => {
  try { res.json({ ok: true, blocks: await listBlocks() }); } catch (e) { next(e); }
});

router.post('/blocks/:ipHash/unblock', requireAdmin, requireRole('superadmin'), adminApiLimiter, async (req, res, next) => {
  try {
    await liftBlock(req.params.ipHash, req.admin.adminId);
    res.json({ ok: true });
  } catch (e) { next(e); }
});

// ------------------------------ webhook Discord ------------------------------
const webhookSchema = z.object({
  enabled: z.boolean(),
  url: z.string().url().max(300).optional().or(z.literal('')),
});

router.get('/settings/webhook', requireAdmin, async (req, res, next) => {
  try {
    const s = await getSetting('discord_webhook');
    // Nigdy nie zwracamy pelnego URL webhooka do klienta - tylko czy jest ustawiony.
    res.json({ ok: true, webhook: s ? { enabled: !!s.value?.enabled, configured: !!s.value?.url } : { enabled: false, configured: false } });
  } catch (e) { next(e); }
});

router.post('/settings/webhook', requireAdmin, requireRole('superadmin'), adminApiLimiter, async (req, res, next) => {
  try {
    const parsed = webhookSchema.safeParse(req.body);
    if (!parsed.success) throw httpError(400, 'VALIDATION_ERROR', 'Nieprawidlowa konfiguracja webhooka.');
    if (parsed.data.enabled && !parsed.data.url) throw httpError(400, 'VALIDATION_ERROR', 'Włączony webhook wymaga adresu URL.');
    // B4: URL webhooka zapisujemy zaszyfrowany (AES-256-GCM); klucz jest poza baza (env).
    await setSetting('discord_webhook', { ...parsed.data, url: parsed.data.url ? encryptSecret(parsed.data.url) : parsed.data.url }, req.admin.adminId);
    res.json({ ok: true });
  } catch (e) { next(e); }
});

router.get('/settings', requireAdmin, async (req, res, next) => {
  try {
    const rows = await listSettings();
    // maskowanie sekretow
    const masked = rows.map((r) =>
      r.key === 'discord_webhook' ? { ...r, value: { ...r.value, url: r.value?.url ? '***' : r.value?.url } } : r
    );
    res.json({ ok: true, settings: masked });
  } catch (e) { next(e); }
});

export default router;
