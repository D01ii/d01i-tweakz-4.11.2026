// R8: konfiguracja - jeden obiekt db (bez nadpisywania), fail-closed sekretow w produkcji.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');

function loadConfig(env) {
  const out = execFileSync(process.execPath, ['-e', `import('./src/config/index.js').then(m => console.log(JSON.stringify({
    db: m.config.db, mfaRequired: m.config.admin.mfaRequired, hasPepper: !!m.config.secrets.licenseKeyPepper
  })))`], { cwd: root, env: { ...process.env, ...env }, encoding: 'utf8' });
  return JSON.parse(out.trim());
}

test('R8: config.db zawiera pelna konfiguracje puli ORAZ migrationsUrl (brak nadpisania klucza)', async () => {
  process.env.SECURITY_PEPPER = process.env.SECURITY_PEPPER || 'test-pepper';
  process.env.SECRET_ENC_KEY = process.env.SECRET_ENC_KEY || 'a'.repeat(64);
  process.env.ALLOW_EPHEMERAL_KEYS = 'true';
  const { config } = await import('../src/config/index.js');
  assert.equal(typeof config.db.max, 'number');
  assert.equal(typeof config.db.idleTimeoutMillis, 'number');
  assert.equal(typeof config.db.connectionTimeoutMillis, 'number');
  assert.ok('migrationsUrl' in config.db, 'brak migrationsUrl w config.db');
});

test('R8: produkcja fail-closed - MFA wymagane bez jawnego ADMIN_REQUIRE_MFA=false', () => {
  const c = loadConfig({ NODE_ENV: 'production', SECURITY_PEPPER: 'x', SECRET_ENC_KEY: 'a'.repeat(64), LICENSE_KEY_PEPPER: 'y', ED25519_PRIVATE_KEY_PATH: '/dev/null', ED25519_PUBLIC_KEY_PATH: '/dev/null', ALLOW_EPHEMERAL_KEYS: 'true' });
  assert.equal(c.mfaRequired, true, 'produkcja bez ADMIN_REQUIRE_MFA musi wymagac MFA');
  const c2 = loadConfig({ NODE_ENV: 'production', ADMIN_REQUIRE_MFA: 'false', SECURITY_PEPPER: 'x', SECRET_ENC_KEY: 'a'.repeat(64), LICENSE_KEY_PEPPER: 'y', ALLOW_EPHEMERAL_KEYS: 'true' });
  assert.equal(c2.mfaRequired, false, 'jawny ADMIN_REQUIRE_MFA=false wyłącza MFA');
});

test('R8: produkcja wymaga osobnego LICENSE_KEY_PEPPER (bez fallbacku do SECURITY_PEPPER)', () => {
  assert.throws(() => loadConfig({
    NODE_ENV: 'production', SECURITY_PEPPER: 'x', SECRET_ENC_KEY: 'a'.repeat(64),
    ALLOW_EPHEMERAL_KEYS: 'true',
  }), /LICENSE_KEY_PEPPER/);
  const ok = loadConfig({
    NODE_ENV: 'production', SECURITY_PEPPER: 'x', SECRET_ENC_KEY: 'a'.repeat(64),
    LICENSE_KEY_PEPPER: 'y', ALLOW_EPHEMERAL_KEYS: 'true',
  });
  assert.equal(ok.hasPepper, true);
});
