import { pepperedHash } from '../utils/crypto.js';
import { config } from '../config/index.js';
import { isBlocked } from '../services/abuseService.js';

/** Hashuje IP klienta (z uwzglednieniem X-Forwarded-For tylko gdy zaufany proxy). */
export function ipHashMiddleware(req, res, next) {
  const fwd = req.headers['x-forwarded-for'];
  const raw = config.isProduction && fwd ? String(fwd).split(',')[0].trim() : req.socket.remoteAddress;
  req.rawIp = raw || '';
  req.ipHash = raw ? pepperedHash(raw) : null;
  next();
}

/** Odrzuca zablokowane IP z czytelna odpowiedzia (blokady sa zawsze czasowe). */
export async function blockCheckMiddleware(req, res, next) {
  if (!req.ipHash) return next();
  const block = await isBlocked(req.ipHash);
  if (block) {
    return res.status(429).json({
      error: 'IP_TEMPORARILY_BLOCKED',
      message: 'Zbyt wiele podejrzanych żądań. Blokada wygasa automatycznie.',
      until: block.until,
    });
  }
  next();
}

/** Standardowa odpowiedz bledu. */
export function errorHandler(err, req, res, next) {
  if (res.headersSent) return next(err);
  const status = err.status || err.statusCode || 500;
  if (status >= 500) {
    console.error(`[error] ${req.method} ${req.originalUrl}:`, err);
  }
  res.status(status).json({
    error: err.expose ? err.code || 'ERROR' : status >= 500 ? 'INTERNAL_ERROR' : err.code || 'ERROR',
    message: err.expose || status < 500 ? err.message : 'Wystapil blad wewnetrzny serwera.',
  });
}

export function httpError(status, code, message) {
  const e = new Error(message);
  e.status = status;
  e.code = code;
  e.expose = true;
  return e;
}

/** 404 dla nieznanych tras API. */
export function notFound(req, res) {
  res.status(404).json({ error: 'NOT_FOUND', message: 'Nie znaleziono zasobu.' });
}
