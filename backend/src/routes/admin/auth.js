import { Router } from 'express';
import { z } from 'zod';
import { config } from '../../config/index.js';
import { loginAdmin, logoutAdmin, setupTotp, enableTotp, disableTotp, listAdmins, createAdmin, setAdminActive } from '../../services/adminService.js';
import { requireAdmin, requireRole } from '../../middleware/adminAuth.js';
import { loginLimiter, adminApiLimiter } from '../../middleware/rateLimit.js';
import { httpError } from '../../middleware/common.js';
import { logAudit } from '../../services/auditService.js';

const router = Router();

const loginSchema = z.object({
  username: z.string().min(3).max(32),
  password: z.string().min(1).max(256),
  totp: z.string().length(6).optional(),
  recovery_code: z.string().max(32).optional(),
});
const adminCreateSchema = z.object({
  username: z.string().min(3).max(32),
  password: z.string().min(12).max(256),
  role: z.enum(['admin', 'superadmin']).default('admin'),
});

function setSessionCookies(res, { sessionToken, csrfToken, expiresAt }) {
  const opts = {
    httpOnly: true,
    secure: config.isProduction,
    sameSite: 'strict',
    path: '/',
    expires: expiresAt,
  };
  res.cookie(config.admin.cookieName, sessionToken, opts);
  res.cookie(config.admin.csrfCookieName, csrfToken, { ...opts, httpOnly: false }); // double-submit: JS musi odczytac cookie
}

router.post('/login', loginLimiter, async (req, res, next) => {
  try {
    const parsed = loginSchema.safeParse(req.body);
    if (!parsed.success) throw httpError(400, 'VALIDATION_ERROR', 'Nieprawidlowe dane logowania.');
    const r = await loginAdmin({ ...parsed.data, ipHash: req.ipHash, userAgent: req.headers['user-agent'] });
    if (!r.ok) {
      const status = r.reason === 'ACCOUNT_LOCKED' ? 423 : 401;
      return res.status(status).json({ error: r.reason, locked_until: r.lockedUntil });
    }
    setSessionCookies(res, r);
    await logAudit({ actorType: 'admin', actorId: null, action: 'admin.cookie.issued', ipHash: req.ipHash });
    res.json({ ok: true, username: req.body.username, csrfToken: r.csrfToken, expires_at: r.expiresAt });
  } catch (e) { next(e); }
});

router.post('/logout', requireAdmin, async (req, res, next) => {
  try {
    await logoutAdmin(req.cookies?.[config.admin.cookieName]);
    await logAudit({ actorType: 'admin', actorId: req.admin.adminId, action: 'admin.logout', ipHash: req.ipHash });
    res.clearCookie(config.admin.cookieName, { path: '/' });
    res.clearCookie(config.admin.csrfCookieName, { path: '/' });
    res.json({ ok: true });
  } catch (e) { next(e); }
});

router.get('/me', requireAdmin, (req, res) => {
  res.json({ ok: true, username: req.admin.username, role: req.admin.role });
});

router.get('/csrf', requireAdmin, async (req, res, next) => {
  try {
    const { query } = await import('../../db/pool.js');
    const { sha256Hex } = await import('../../utils/crypto.js');
    const r = await query('SELECT csrf_token FROM admin_sessions WHERE token_hash = $1 AND NOT revoked AND expires_at > now()', [sha256Hex(req.cookies?.[config.admin.cookieName] || '')]);
    res.json({ csrfToken: r.rows[0]?.csrf_token || null });
  } catch (e) { next(e); }
});

// ------------------------------ MFA ------------------------------
router.post('/mfa/setup', requireAdmin, adminApiLimiter, async (req, res, next) => {
  try {
    const r = await setupTotp(req.admin.adminId);
    res.json({ ok: true, secret: r.secret, otpauth: r.otpauth });
  } catch (e) { next(e); }
});

router.post('/mfa/enable', requireAdmin, adminApiLimiter, async (req, res, next) => {
  try {
    const code = String(req.body?.code || '');
    if (!/^\d{6}$/.test(code)) throw httpError(400, 'VALIDATION_ERROR', 'Kod TOTP musi miec 6 cyfr.');
    const r = await enableTotp(req.admin.adminId, code);
    res.json({ ok: true, recovery_codes: r.recoveryCodes });
  } catch (e) { next(e.status ? e : httpError(400, 'MFA_ERROR', e.message)); }
});

router.post('/mfa/disable', requireAdmin, adminApiLimiter, async (req, res, next) => {
  try {
    await disableTotp(req.admin.adminId, {
      password: String(req.body?.password || ''),
      totp: req.body?.totp ? String(req.body.totp) : null,
      recoveryCode: req.body?.recovery_code ? String(req.body.recovery_code) : null,
    });
    res.json({ ok: true });
  } catch (e) { next(e.status ? e : httpError(400, 'MFA_ERROR', e.message)); }
});

// ------------------------------ zarzadzanie adminami (superadmin) ------------------------------
router.get('/admins', requireAdmin, requireRole('superadmin'), async (req, res, next) => {
  try { res.json({ ok: true, admins: await listAdmins() }); } catch (e) { next(e); }
});

router.post('/admins', requireAdmin, requireRole('superadmin'), adminApiLimiter, async (req, res, next) => {
  try {
    const parsed = adminCreateSchema.safeParse(req.body);
    if (!parsed.success) throw httpError(400, 'VALIDATION_ERROR', 'Nieprawidlowe dane administratora.');
    const id = await createAdmin({ ...parsed.data, actorId: req.admin.adminId });
    res.status(201).json({ ok: true, id });
  } catch (e) { next(e.status ? e : httpError(400, 'ADMIN_ERROR', e.message)); }
});

router.post('/admins/:id/disable', requireAdmin, requireRole('superadmin'), adminApiLimiter, async (req, res, next) => {
  try {
    if (req.params.id === req.admin.adminId) throw httpError(400, 'SELF_DISABLE', 'Nie mozesz wylaczyc wlasnego konta.');
    await setAdminActive(req.params.id, false, req.admin.adminId);
    res.json({ ok: true });
  } catch (e) { next(e); }
});

router.post('/admins/:id/enable', requireAdmin, requireRole('superadmin'), adminApiLimiter, async (req, res, next) => {
  try {
    await setAdminActive(req.params.id, true, req.admin.adminId);
    res.json({ ok: true });
  } catch (e) { next(e); }
});

export default router;
