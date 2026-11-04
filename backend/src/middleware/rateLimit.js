import rateLimit from 'express-rate-limit';
import { config } from '../config/index.js';

const keyByIp = (req) => req.rawIp || req.ip || 'unknown';

function makeLimiter(max, message) {
  return rateLimit({
    windowMs: config.rateLimit.windowMs,
    max,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    keyGenerator: keyByIp,
    skip: () => false,
    handler: (req, res) =>
      res.status(429).json({ error: 'RATE_LIMITED', message, retry_after_seconds: Math.ceil(config.rateLimit.windowMs / 1000) }),
  });
}

export const activateLimiter = makeLimiter(config.rateLimit.activateMax, 'Zbyt wiele prob aktywacji. Sprobuj ponownie pozniej.');
export const validateLimiter = makeLimiter(config.rateLimit.validateMax, 'Zbyt wiele prob walidacji.');
export const loginLimiter = makeLimiter(config.rateLimit.loginMax, 'Zbyt wiele nieudanych prob logowania. Konto/IP moze zostac czasowo zablokowane.');
export const adminApiLimiter = makeLimiter(config.rateLimit.adminApiMax, 'Zbyt wiele zadan do API administracyjnego.');
