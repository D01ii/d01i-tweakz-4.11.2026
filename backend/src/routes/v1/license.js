import { Router } from 'express';
import { z } from 'zod';
import { activate, validate, refresh, deactivate, status, listDevices } from '../../services/licenseService.js';
import { activateLimiter, validateLimiter } from '../../middleware/rateLimit.js';
import { httpError } from '../../middleware/common.js';

const router = Router();

const activateSchema = z.object({
  key: z.string().min(10).max(64),
  install_id: z.string().min(8).max(128),
  hwid: z.string().min(8).max(512),
  label: z.string().max(64).optional(),
});
const tokenSchema = z.object({ token: z.string().min(20).max(2048) });
const deactivateSchema = z.object({
  token: z.string().min(20).max(2048).optional(),
  key: z.string().min(10).max(64).optional(),
  install_id: z.string().min(8).max(128).optional(),
});

const validateBody = (schema) => (req, res, next) => {
  const parsed = schema.safeParse(req.body || {});
  if (!parsed.success) {
    return next(httpError(400, 'VALIDATION_ERROR', parsed.error.issues.map((i) => `${i.path.join('.')}: ${i.message}`).join('; ')));
  }
  req.body = parsed.data;
  next();
};

const ctx = (req) => ({ ipHash: req.ipHash, userAgent: req.headers['user-agent'] });

router.post('/activate', activateLimiter, validateBody(activateSchema), async (req, res, next) => {
  try {
    const r = await activate({
      key: req.body.key,
      installId: req.body.install_id,
      hwid: req.body.hwid,
      label: req.body.label,
      ...ctx(req),
    });
    if (!r.ok) {
      const map = {
        KEY_INVALID: [401, 'Klucz licencyjny jest nieprawidlowy.'],
        LICENSE_REVOKED: [403, 'Licencja zostala uniewazniona.'],
        LICENSE_EXPIRED: [403, 'Licencja wygasla.'],
        DEVICE_LIMIT_REACHED: [409, `Osiagnieto limit aktywnych urzadzen (${r.maxDevices}). Dezaktywuj jedno z nich.`],
        KEY_REQUIRED: [400, 'Brak klucza.'],
        INSTALL_ID_INVALID: [400, 'Nieprawidlowy identyfikator instalacji.'],
        HWID_INVALID: [400, 'Nieprawidlowy identyfikator sprzetu.'],
      };
      const [s, m] = map[r.code] || [400, 'Aktywacja nieudana.'];
      return res.status(s).json({ error: r.code, message: m });
    }
    res.status(200).json(r);
  } catch (e) { next(e); }
});

router.post('/validate', validateLimiter, validateBody(tokenSchema), async (req, res, next) => {
  try {
    const r = await validate(req.body.token, ctx(req));
    if (!r.ok) return res.status(401).json({ valid: false, error: r.reason });
    res.json({ valid: true, license: r.license, device_id: r.device_id });
  } catch (e) { next(e); }
});

router.post('/refresh', validateLimiter, validateBody(tokenSchema), async (req, res, next) => {
  try {
    const r = await refresh(req.body.token, ctx(req));
    if (!r.ok) return res.status(401).json({ ok: false, error: r.reason });
    res.json(r);
  } catch (e) { next(e); }
});

router.post('/deactivate', activateLimiter, validateBody(deactivateSchema), async (req, res, next) => {
  try {
    const r = await deactivate({ ...req.body, ipHash: req.ipHash });
    if (!r.ok) return res.status(400).json({ ok: false, error: r.reason });
    res.json({ ok: true });
  } catch (e) { next(e); }
});

router.post('/status', validateLimiter, validateBody(tokenSchema), async (req, res, next) => {
  try {
    const r = await status(req.body.token, ctx(req));
    if (!r.ok) return res.status(401).json({ ok: false, error: r.reason });
    res.json(r);
  } catch (e) { next(e); }
});

router.post('/devices', validateLimiter, validateBody(tokenSchema), async (req, res, next) => {
  try {
    const r = await listDevices(req.body.token, ctx(req));
    if (!r.ok) return res.status(401).json({ ok: false, error: r.reason });
    res.json(r);
  } catch (e) { next(e); }
});

export default router;
