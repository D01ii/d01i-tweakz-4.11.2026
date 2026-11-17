import { config } from '../config/index.js';
import { verifyAdminSession, logoutAdmin } from '../services/adminService.js';
import { logAudit } from '../services/auditService.js';
import { httpError } from './common.js';

/**
 * Wymaga waznej sesji admina (cookie HttpOnly) + poprawnego tokena CSRF
 * (double submit: cookie + naglowek) dla metod zmieniajacych stan.
 */
export async function requireAdmin(req, res, next) {
  const sessionToken = req.cookies?.[config.admin.cookieName];
  const csrfCookie = req.cookies?.[config.admin.csrfCookieName];
  const csrfHeader = req.headers['x-csrf-token'];

  const session = await verifyAdminSession(sessionToken, req.method !== 'GET' && req.method !== 'HEAD' ? csrfHeader : null);
  if (!session) {
    const reason = sessionToken ? 'session_invalid' : 'no_session';
    return next(httpError(401, 'UNAUTHORIZED', 'Wymagane uwierzytelnienie administratora.'));
  }
  if (session.csrfMismatch) {
    await logAudit({ actorType: 'system', action: 'admin.csrf.mismatch', actorId: session.adminId, ipHash: req.ipHash, severity: 'warning' });
    return next(httpError(403, 'CSRF_FAILED', 'Nieprawidlowy token CSRF.'));
  }
  if (req.method !== 'GET' && req.method !== 'HEAD' && csrfCookie !== csrfHeader) {
    return next(httpError(403, 'CSRF_FAILED', 'Brak zgodnego tokena CSRF.'));
  }
  req.admin = session;
  next();
}

export function requireRole(role) {
  return (req, res, next) => {
    if (req.admin?.role !== role && req.admin?.role !== 'superadmin') {
      return next(httpError(403, 'FORBIDDEN', 'Brak wymaganej roli.'));
    }
    next();
  };
}

export async function csrfTokenEndpoint(req, res) {
  // Token CSRF jest powiazany z sesja; wystawiamy aktualny z rekordu sesji.
  const sessionToken = req.cookies?.[config.admin.cookieName];
  const { query } = await import('../db/pool.js');
  const { sha256Hex } = await import('../utils/crypto.js');
  const r = await query('SELECT csrf_token FROM admin_sessions WHERE token_hash = $1 AND NOT revoked AND expires_at > now()', [sha256Hex(sessionToken || '')]);
  res.json({ csrfToken: r.rows[0]?.csrf_token || null });
}

export { logoutAdmin };
