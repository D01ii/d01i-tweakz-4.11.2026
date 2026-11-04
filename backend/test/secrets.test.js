process.env.TEST_DB_NAME = process.env.TEST_DB_NAME || 'secrets';
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';

let t;
before(async () => {
  const h = await import('./helpers.js');
  t = await h.setupTestApp();
});
after(async () => { await t.close(); });

test('migracja legacy sekretow: plaintext -> enc:v1:, idempotentna, dane zachowane', async () => {
  const { migrateLegacySecrets } = await import('../src/services/secretMigrationService.js');
  const { encryptSecret, decryptSecret } = await import('../src/utils/secretCrypto.js');
  const { authenticator } = await import('otplib');

  // legacy plaintext: admin z TOTP + webhook z jawnym URL
  const legacySecret = authenticator.generateSecret();
  await t.query(
    `INSERT INTO admins (username, password_hash, totp_secret, totp_enabled) VALUES ('legacy', 'x', $1, TRUE)`,
    [legacySecret]
  );
  await t.query(
    `INSERT INTO settings (key, value) VALUES ('discord_webhook', $1::jsonb)`,
    [JSON.stringify({ enabled: true, url: 'https://discord.com/api/webhooks/111/legacysecret' }) + '' ]
  );

  const r1 = await migrateLegacySecrets({ log: () => {} });
  assert.equal(r1.adminSecrets, 1);

  const row = await t.query(`SELECT totp_secret FROM admins WHERE username='legacy'`);
  assert.ok(row.rows[0].totp_secret.startsWith('enc:v1:'), 'totp_secret zaszyfrowany');
  assert.ok(!row.rows[0].totp_secret.includes(legacySecret), 'brak plaintextu w bazie');
  assert.equal(decryptSecret(row.rows[0].totp_secret), legacySecret, 'odszyfrowanie zwraca oryginal');
  assert.ok(authenticator.check(authenticator.generate(legacySecret), legacySecret), 'TOTP dziala po migracji');

  const wh = await t.query(`SELECT value FROM settings WHERE key='discord_webhook'`);
  assert.ok(String(wh.rows[0].value.url).startsWith('enc:v1:'), 'webhook url zaszyfrowany');
  assert.equal(decryptSecret(wh.rows[0].value.url), 'https://discord.com/api/webhooks/111/legacysecret');

  // idempotentnosc: drugie uruchomienie nic nie zmienia
  const r2 = await migrateLegacySecrets({ log: () => {} });
  assert.equal(r2.adminSecrets, 0, 'brak legacy do zaszyfrowania przy rerun');
  const row2 = await t.query(`SELECT totp_secret FROM admins WHERE username='legacy'`);
  assert.equal(row2.rows[0].totp_secret, row.rows[0].totp_secret, 'ponowna migracja nie podwaja szyfrowania');
});

test('uszkodzony ciphertext jest wykrywany (decrypt rzuca blad)', async () => {
  const { decryptSecret } = await import('../src/utils/secretCrypto.js');
  assert.throws(() => decryptSecret('enc:v1:AAAAAAAAAAAAAAAA:AAAAAAAAAAAAAAAAAAAAAA==:AAAAAAAA'), /authenticate|Unsupported/i);
});

test('nieprawidlowy SECRET_ENC_KEY (zla dlugosc) odmawia startu konfiguracji', async () => {
  const { execFileSync } = await import('node:child_process');
  let err = null;
  try {
    execFileSync(process.execPath, ['-e', "process.env.SECURITY_PEPPER='x';process.env.SECRET_ENC_KEY=' za krotki';process.env.ALLOW_EPHEMERAL_KEYS='true';import('./src/config/index.js')"], {
      cwd: new URL('..', import.meta.url).pathname,
      env: { ...process.env },
      encoding: 'utf8', timeout: 30000, stdio: 'pipe',
    });
  } catch (e) { err = e; }
  assert.ok(err, 'krotki klucz musi odmowic startu');
  assert.match(String(err.stderr || err.message), /SECRET_ENC_KEY/);
});
