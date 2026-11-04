import { query } from '../db/pool.js';
import { encryptSecret, decryptSecret, isEncrypted } from '../utils/secretCrypto.js';
import { logAudit } from './auditService.js';

/**
 * Migracja legacy jawnych sekretow do formatu enc:v1: (AES-256-GCM).
 * Idempotentna: szyfruje tylko wartosci bez prefiksu enc:v1:, weryfikuje odszyfrowanie
 * przed zapisem, nie loguje sekretow, bezpiecznie wznawialna po przerwaniu.
 *
 * Jezeli w bazie istnieja juz zaszyfrowane rekordy, a klucz SECRET_ENC_KEY jest
 * niedostepny/nieprawidlowy - proces MUSI sie zatrzymac (config rzuca blad przy starcie),
 * bo nowy klucz uniemozliwilby odczyt starych sekretow.
 */
export async function migrateLegacySecrets({ log = console.log } = {}) {
  // admins.totp_secret (plaintext legacy)
  const admins = await query(`SELECT id, totp_secret FROM admins WHERE totp_secret IS NOT NULL AND totp_secret NOT LIKE 'enc:v1:%'`);
  for (const row of admins.rows) {
    const enc = encryptSecret(row.totp_secret);
    decryptSecret(enc); // weryfikacja przed zapisem
    await query(`UPDATE admins SET totp_secret = $2 WHERE id = $1`, [row.id, enc]);
    log(`[secrets] zaszyfrowano legacy totp_secret admina ${row.id}`);
  }

  // settings.discord_webhook.url (plaintext legacy)
  const wh = await query(`SELECT value FROM settings WHERE key = 'discord_webhook'`);
  if (wh.rows.length && wh.rows[0].value?.url && !isEncrypted(wh.rows[0].value.url)) {
    const v = wh.rows[0].value;
    const enc = encryptSecret(v.url);
    decryptSecret(enc);
    await query(`UPDATE settings SET value = $1::jsonb, updated_at = now() WHERE key = 'discord_webhook'`, [JSON.stringify({ ...v, url: enc })]);
    log('[secrets] zaszyfrowano legacy webhook url');
  }

  if (admins.rows.length) {
    await logAudit({ actorType: 'system', action: 'secrets.migrate_legacy', severity: 'warning', meta: { count: admins.rows.length } });
  }
  return { adminSecrets: admins.rows.length };
}

/**
 * R4: weryfikacja SECRET_ENC_KEY wzledem WSZYSTKICH istniejacych zaszyfrowanych sekretow.
 * Polega na rzeczywistym odszyfrowaniu AES-256-GCM (nie na formacie klucza).
 * Nie loguje plaintextu. Rzuca blad, jesli ktoregokolwiek rekordu nie da sie odszyfrowac.
 * Uruchamiana po migracjach schematu, PRZED startem HTTP.
 */
export async function verifySecretKeyIntegrity() {
  const admins = await query(`SELECT id, totp_secret FROM admins WHERE totp_secret LIKE 'enc:v1:%'`);
  for (const row of admins.rows) {
    try {
      decryptSecret(row.totp_secret);
    } catch {
      throw new Error(`SECRET_ENC_KEY nie odszyfrowuje istniejacego totp_secret (admin ${row.id}). Przywroc oryginalny klucz - NIE uruchamiam serwera.`);
    }
  }
  const wh = await query(`SELECT value FROM settings WHERE key='discord_webhook' AND value::text LIKE '%enc:v1:%'`);
  for (const row of wh.rows) {
    try {
      if (row.value?.url) decryptSecret(row.value.url);
    } catch {
      throw new Error('SECRET_ENC_KEY nie odszyfrowuje istniejacego webhook URL. Przywroc oryginalny klucz - NIE uruchamiam serwera.');
    }
  }
  return { verified: admins.rows.length + wh.rows.length };
}
