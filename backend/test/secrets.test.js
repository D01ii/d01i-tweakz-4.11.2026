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

test('R4: verifySecretKeyIntegrity - poprawny klucz przechodzi, zly (ale poprawny format) odpada', async () => {
  const { verifySecretKeyIntegrity } = await import('../src/services/secretMigrationService.js');
  const { encryptSecret } = await import('../src/utils/secretCrypto.js');
  // rekord zaszyfrowany Biezacym kluczem testowym ('a'*64) - weryfikacja przechodzi
  await t.query(
    `INSERT INTO admins (username, password_hash, totp_secret, totp_enabled) VALUES ('encok', 'x', $1, TRUE)`,
    [encryptSecret('sekret-z-biezacym-kluczem')]
  );
  const ok = await verifySecretKeyIntegrity();
  assert.ok(ok.verified >= 1);

  // rekord zaszyfrowany INNYM kluczem (ale poprawnym formatem) -> weryfikacja musi sie nie powiesc
  const wrongKey = 'b'.repeat(64);
  const { createCipheriv, randomBytes } = await import('node:crypto');
  const iv = randomBytes(12);
  const c = createCipheriv('aes-256-gcm', Buffer.from(wrongKey, 'hex'), iv);
  const ct = Buffer.concat([c.update('inny-sekret', 'utf8'), c.final()]);
  const foreign = `enc:v1:${iv.toString('base64')}:${c.getAuthTag().toString('base64')}:${ct.toString('base64')}`;
  await t.query(
    `INSERT INTO admins (username, password_hash, totp_secret, totp_enabled) VALUES ('encforeign', 'x', $1, TRUE)`,
    [foreign]
  );
  await assert.rejects(() => verifySecretKeyIntegrity(), /SECRET_ENC_KEY nie odszyfrowuje/);
  // dane NIE zostaly zmodyfikowane przez nieudana weryfikacje
  const row = await t.query(`SELECT totp_secret FROM admins WHERE username='encforeign'`);
  assert.equal(row.rows[0].totp_secret, foreign);
});

test('R4: SECRET_ENC_KEY 64-znakowy HEX przechodzi walidacje backendu (jak klucz z instalatora)', async () => {
  const { execFileSync } = await import('node:child_process');
  // symulacja wartosci z New-SecureRandomHex 32 (32 bajty -> 64 znaki HEX)
  const key64 = '0123456789abcdef'.repeat(4);
  execFileSync(process.execPath, ['-e', `process.env.SECURITY_PEPPER='x';process.env.SECRET_ENC_KEY='${key64}';process.env.ALLOW_EPHEMERAL_KEYS='true';import('./src/config/index.js').then(()=>console.log('CONFIG_OK'))`], {
    cwd: new URL('..', import.meta.url).pathname,
    env: { ...process.env }, encoding: 'utf8', timeout: 30000,
  });
});

test('R4: instalator Windows generuje SECRET_ENC_KEY jako 32 bajty (statyczna kontrola pliku)', async () => {
  const fs = await import('node:fs');
  const ps1 = fs.readFileSync(new URL('../../deploy/windows/Install-Windows.ps1', import.meta.url), 'utf8');
  assert.ok(!ps1.includes('New-SecureRandomString'), 'brak starej funkcji New-SecureRandomString');
  assert.match(ps1, /\$encKey = New-SecureRandomHex 32/, 'SECRET_ENC_KEY = 32 bajty = 64 znaki HEX');
  assert.match(ps1, /function New-SecureRandomHex\(\[int\]\$ByteCount/, 'parametr funkcji to liczba bajtow');
});
