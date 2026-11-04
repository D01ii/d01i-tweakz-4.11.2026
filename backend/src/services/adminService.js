import argon2 from 'argon2';
import { authenticator } from 'otplib';
import { query, withTransaction } from '../db/pool.js';
import { config } from '../config/index.js';
import { sha256Hex, randomToken, randomUuid, pepperedHash } from '../utils/crypto.js';
import { logAudit } from './auditService.js';
import { encryptSecret, decryptSecret } from '../utils/secretCrypto.js';

authenticator.options = { step: 30, window: 1 };

export async function hashPassword(pw) {
  // W testach mozna obnizyc koszt przez ARGON2_MEMORY_COST (szybciej), produkcja: 64 MB / 3 iteracje.
  const memoryCost = Number.parseInt(process.env.ARGON2_MEMORY_COST || '65536', 10);
  const timeCost = Number.parseInt(process.env.ARGON2_TIME_COST || '3', 10);
  return argon2.hash(pw, { type: argon2.argon2id, memoryCost, timeCost, parallelism: 2 });
}

export async function verifyPassword(hash, pw) {
  try {
    return await argon2.verify(hash, pw);
  } catch {
    return false;
  }
}

export async function createAdmin({ username, password, role = 'admin', actorId = null }) {
  if (!/^[a-zA-Z0-9_.-]{3,32}$/.test(username)) throw new Error('Nieprawidlowa nazwa administratora (3-32 znakow: litery, cyfry, _ . -)');
  if (typeof password !== 'string' || password.length < 12) throw new Error('Haslo musi miec min. 12 znakow');
  const hash = await hashPassword(password);
  const r = await query(
    `INSERT INTO admins (username, password_hash, role) VALUES ($1,$2,$3)
     ON CONFLICT (username) DO NOTHING RETURNING id`,
    [username.toLowerCase(), hash, role]
  );
  if (!r.rows.length) throw new Error('Administrator o tej nazwie juz istnieje');
  await logAudit({ actorType: actorId ? 'admin' : 'system', actorId, action: 'admin.create', target: username, severity: 'warning' });
  return r.rows[0].id;
}

/** Bootstrap pierwszego admina tylko gdy tabela jest pusta i ADMIN_BOOTSTRAP_ENABLED=true. */
export async function bootstrapAdminIfNeeded() {
  if (!config.admin.bootstrapEnabled) return false;
  const count = await query('SELECT COUNT(*)::int AS n FROM admins');
  if (count.rows[0].n > 0) return false;
  if (!config.admin.bootstrapPassword || config.admin.bootstrapPassword.length < 12) {
    console.warn('[bootstrap] ADMIN_BOOTSTRAP_ENABLED=true ale haslo jest puste/krótkie - pomijam.');
    return false;
  }
  await createAdmin({ username: config.admin.bootstrapUsername, password: config.admin.bootstrapPassword, role: 'superadmin' });
  console.log(`[bootstrap] utworzono pierwszego administratora: ${config.admin.bootstrapUsername}`);
  return true;
}

const MAX_FAILED = 5;
const LOCK_MINUTES = 15;

/**
 * Logowanie admina z ochrona przed brute-force (licznik + blokada czasowa w bazie)
 * oraz opcjonalnym TOTP (MFA). Zwraca { sessionToken, csrfToken } lub { totpRequired }.
 */
export async function loginAdmin({ username, password, totp = null, recoveryCode = null, ipHash = null, userAgent = null }) {
  const u = (username || '').toLowerCase().trim();
  const r = await query(`SELECT * FROM admins WHERE username = $1`, [u]);
  if (!r.rows.length) {
    await logAudit({ actorType: 'system', action: 'admin.login.failed', ipHash, severity: 'info', meta: { reason: 'unknown_user' } });
    return { ok: false, reason: 'INVALID_CREDENTIALS' };
  }
  const admin = r.rows[0];
  if (!admin.is_active) return { ok: false, reason: 'ACCOUNT_DISABLED' };
  if (admin.locked_until && new Date(admin.locked_until) > new Date()) {
    return { ok: false, reason: 'ACCOUNT_LOCKED', lockedUntil: admin.locked_until };
  }
  const ok = await verifyPassword(admin.password_hash, password || '');
  if (!ok) {
    const failed = admin.failed_logins + 1;
    const locked = failed >= MAX_FAILED ? new Date(Date.now() + LOCK_MINUTES * 60_000) : null;
    await query(`UPDATE admins SET failed_logins = $2, locked_until = $3 WHERE id = $1`, [admin.id, failed, locked]);
    await logAudit({ actorType: 'system', action: 'admin.login.failed', actorId: admin.id, ipHash, severity: failed >= MAX_FAILED ? 'warning' : 'info', meta: { reason: 'bad_password', failed } });
    if (locked) return { ok: false, reason: 'ACCOUNT_LOCKED', lockedUntil: locked };
    return { ok: false, reason: 'INVALID_CREDENTIALS' };
  }
  if (admin.totp_enabled) {
    // B4: sekret TOTP jest szyfrowany w bazie (AES-256-GCM), odszyfrowujemy tylko do weryfikacji.
    const totpSecret = decryptSecret(admin.totp_secret);
    let mfaOk = false;
    if (totp && totpSecret && authenticator.check(totp, totpSecret)) mfaOk = true;
    if (!mfaOk && recoveryCode) {
      const codeHash = sha256Hex(recoveryCode.trim().toUpperCase());
      if (Array.isArray(admin.recovery_codes) && admin.recovery_codes.includes(codeHash)) {
        mfaOk = true;
        await query(
          `UPDATE admins SET recovery_codes = array_remove(recovery_codes, $2) WHERE id = $1`,
          [admin.id, codeHash]
        );
        await logAudit({ actorType: 'admin', actorId: admin.id, action: 'admin.mfa.recovery_used', ipHash, severity: 'warning' });
      }
    }
    if (!mfaOk) {
      await logAudit({ actorType: 'system', action: 'admin.login.failed', actorId: admin.id, ipHash, severity: 'warning', meta: { reason: totp || recoveryCode ? 'bad_mfa' : 'mfa_required' } });
      // B5: rozróżniamy 'brak kodu MFA' od 'zły kod MFA' (inny komunikat, to samo 401).
      return { ok: false, reason: totp || recoveryCode ? 'MFA_INVALID' : 'TOTP_REQUIRED' };
    }
  }
  await query(`UPDATE admins SET failed_logins = 0, locked_until = NULL, last_login_at = now() WHERE id = $1`, [admin.id]);
  const sessionToken = randomToken(48);
  const csrfToken = randomToken(24);
  const expires = new Date(Date.now() + config.security.adminSessionTtlHours * 3600_000);
  const sid = randomUuid();
  await query(
    `INSERT INTO admin_sessions (id, admin_id, token_hash, csrf_token, ip_hash, user_agent, expires_at)
     VALUES ($1,$2,$3,$4,$5,$6,$7)`,
    [sid, admin.id, sha256Hex(sessionToken), csrfToken, ipHash, userAgent ? userAgent.slice(0, 300) : null, expires]
  );
  await logAudit({ actorType: 'admin', actorId: admin.id, action: 'admin.login.ok', ipHash, severity: 'info' });
  return { ok: true, sessionToken, csrfToken, sessionId: sid, expiresAt: expires };
}

export async function verifyAdminSession(sessionToken, csrfToken) {
  if (!sessionToken) return null;
  const r = await query(
    `SELECT s.id AS session_id, s.csrf_token, s.expires_at, s.revoked, a.id AS admin_id, a.username, a.role, a.is_active
     FROM admin_sessions s JOIN admins a ON a.id = s.admin_id
     WHERE s.token_hash = $1`,
    [sha256Hex(sessionToken)]
  );
  if (!r.rows.length) return null;
  const row = r.rows[0];
  if (row.revoked || !row.is_active || new Date(row.expires_at) <= new Date()) return null;
  if (csrfToken && row.csrf_token !== csrfToken) return { csrfMismatch: true };
  return { sessionId: row.session_id, adminId: row.admin_id, username: row.username, role: row.role };
}

export async function logoutAdmin(sessionToken) {
  if (!sessionToken) return;
  await query(`UPDATE admin_sessions SET revoked = TRUE, revoked_at = now() WHERE token_hash = $1`, [sha256Hex(sessionToken)]);
}

// ------------------------------ MFA (TOTP) ------------------------------

export async function setupTotp(adminId) {
  const secret = authenticator.generateSecret();
  await query(`UPDATE admins SET totp_secret = $2, totp_enabled = FALSE WHERE id = $1`, [adminId, encryptSecret(secret)]);
  const otpauth = authenticator.keyuri(adminId, 'D01i Tweakz', secret);
  return { secret, otpauth };
}

export async function enableTotp(adminId, code) {
  const r = await query(`SELECT totp_secret FROM admins WHERE id = $1`, [adminId]);
  if (!r.rows.length || !r.rows[0].totp_secret) throw new Error('Najpierw wygeneruj sekret TOTP');
  if (!authenticator.check(code, decryptSecret(r.rows[0].totp_secret))) throw new Error('Nieprawidlowy kod TOTP');
  const recovery = Array.from({ length: 10 }, () => randomToken(8).toUpperCase());
  await query(
    `UPDATE admins SET totp_enabled = TRUE, recovery_codes = $2 WHERE id = $1`,
    [adminId, recovery.map((c) => sha256Hex(c))]
  );
  await logAudit({ actorType: 'admin', actorId: adminId, action: 'admin.mfa.enabled', severity: 'warning' });
  return { recoveryCodes: recovery }; // wyswietlane tylko raz
}

export async function disableTotp(adminId, { password, totp = null, recoveryCode = null }) {
  const r = await query(`SELECT password_hash, totp_secret, recovery_codes, totp_enabled FROM admins WHERE id = $1`, [adminId]);
  if (!r.rows.length || !(await verifyPassword(r.rows[0].password_hash, password || ''))) {
    throw new Error('Nieprawidlowe haslo');
  }
  // D2: wylaczenie MFA wymaga hasła ORAZ aktualnego kodu TOTP lub jednorazowego kodu odzyskiwania.
  if (r.rows[0].totp_enabled) {
    let second = false;
    if (totp && r.rows[0].totp_secret && authenticator.check(totp, decryptSecret(r.rows[0].totp_secret))) second = true;
    if (!second && recoveryCode) {
      const codeHash = sha256Hex(recoveryCode.trim().toUpperCase());
      if (Array.isArray(r.rows[0].recovery_codes) && r.rows[0].recovery_codes.includes(codeHash)) {
        second = true;
        await query(`UPDATE admins SET recovery_codes = array_remove(recovery_codes, $2) WHERE id = $1`, [adminId, codeHash]);
      }
    }
    if (!second) throw new Error('Wymagany aktualny kod TOTP lub kod odzyskiwania');
  }
  await query(`UPDATE admins SET totp_enabled = FALSE, totp_secret = NULL, recovery_codes = NULL WHERE id = $1`, [adminId]);
  await logAudit({ actorType: 'admin', actorId: adminId, action: 'admin.mfa.disabled', severity: 'warning' });
}

export async function listAdmins() {
  const r = await query(`SELECT id, username, role, is_active, totp_enabled, failed_logins, locked_until, last_login_at, created_at FROM admins ORDER BY created_at`);
  return r.rows;
}

export async function setAdminActive(adminId, active, actorId) {
  await query(`UPDATE admins SET is_active = $2 WHERE id = $1`, [adminId, active]);
  await query(`UPDATE admin_sessions SET revoked = TRUE, revoked_at = now() WHERE admin_id = $1 AND NOT revoked`, [adminId]);
  await logAudit({ actorType: 'admin', actorId, action: active ? 'admin.enable' : 'admin.disable', target: adminId, severity: 'warning' });
}

export { pepperedHash };
