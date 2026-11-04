// Pomocnicy testow integracyjnych: osobna baza, migracje, aplikacja na losowym porcie.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { generateKeyPairSync } from 'node:crypto';

// Baza per plik testowy (node --test uruchamia pliki rownolegle), ustawiana przez TEST_DB_NAME.
export function testDbUrl() {
  if (process.env.TEST_DATABASE_URL) return process.env.TEST_DATABASE_URL;
  const name = process.env.TEST_DB_NAME ? `d01i_test_${process.env.TEST_DB_NAME}` : 'd01i_test';
  return `postgresql://postgres@/${name}?host=/tmp/d01i-pgdata`;
}

export function testEnv(overrides = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'd01i-keys-'));
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const privPath = path.join(dir, 'priv.pem');
  const pubPath = path.join(dir, 'pub.pem');
  fs.writeFileSync(privPath, privateKey.export({ type: 'pkcs8', format: 'pem' }));
  fs.writeFileSync(pubPath, publicKey.export({ type: 'spki', format: 'pem' }));
  return {
    NODE_ENV: 'test',
    DATABASE_URL: testDbUrl(),
    SECURITY_PEPPER: 'test-pepper',
    ED25519_PRIVATE_KEY_PATH: privPath,
    ED25519_PUBLIC_KEY_PATH: pubPath,
    PORT: '0',
    ADMIN_BOOTSTRAP_ENABLED: 'false',
    RATE_LIMIT_WINDOW_MS: '60000',
    RATE_LIMIT_ACTIVATE_MAX: '1000',
    RATE_LIMIT_VALIDATE_MAX: '100000',
    RATE_LIMIT_LOGIN_MAX: '1000',
    RATE_LIMIT_ADMIN_API_MAX: '100000',
    ABUSE_FAILED_KEY_THRESHOLD: '5',
    DISCORD_WEBHOOK_ENABLED: 'false',
    ...overrides,
  };
}

export async function setupTestApp(envOverrides = {}) {
  for (const [k, v] of Object.entries(testEnv(envOverrides))) process.env[k] = v;
  const { createApp } = await import('../src/app.js');
  const { migrate } = await import('../src/db/migrate.js');
  const { query, closePool } = await import('../src/db/pool.js');

  // Czysta baza przed kazdym zestawem testow
  await query(`DROP SCHEMA public CASCADE; CREATE SCHEMA public;`);
  await migrate({ log: () => {} });

  const app = createApp();
  const server = await new Promise((resolve) => {
    const s = app.listen(0, '127.0.0.1', () => resolve(s));
  });
  const base = `http://127.0.0.1:${server.address().port}`;
  const client = (p, opts = {}) =>
    fetch(base + p, {
      ...opts,
      headers: { 'Content-Type': 'application/json', ...(opts.headers || {}) },
    });
  return { app, server, base, client, query, close: async () => { server.close(); await closePool(); } };
}

export async function createTestLicense(query, { type = 'PREMIUM_30D', maxDevices = 2 } = {}) {
  const { generateLicenseKey, keyHash, keyPrefix, licenseDurationDays } = await import('../src/utils/licenseKey.js');
  const key = generateLicenseKey();
  const days = licenseDurationDays(type);
  const expires = days ? new Date(Date.now() + days * 86400_000) : null;
  const r = await query(
    `INSERT INTO licenses (key_hash, key_prefix, type, max_devices, expires_at) VALUES ($1,$2,$3,$4,$5) RETURNING id`,
    [keyHash(key), keyPrefix(key), type, maxDevices, expires]
  );
  return { key, id: r.rows[0].id };
}

export async function adminLogin(client, query, { username = 'root', password = 'super-secret-password-123' } = {}) {
  const { createAdmin } = await import('../src/services/adminService.js');
  try {
    await createAdmin({ username, password, role: 'superadmin' });
  } catch (e) {
    if (!/juz istnieje/.test(e.message)) throw e; // idempotentne dla powtornych wywolan w testach
  }
  const res = await client('/api/v1/admin/login', {
    method: 'POST',
    body: JSON.stringify({ username, password }),
  });
  const cookies = res.headers.get('set-cookie');
  const data = await res.json();
  const cookieHeader = cookies.split(',').map((c) => c.split(';')[0]).join('; ');
  return { ...data, cookieHeader };
}

export function authedClient(client, cookieHeader, csrfToken) {
  return (p, opts = {}) =>
    client(p, {
      ...opts,
      headers: {
        'Content-Type': 'application/json',
        Cookie: cookieHeader,
        ...(opts.method && opts.method !== 'GET' ? { 'X-CSRF-Token': csrfToken } : {}),
        ...(opts.headers || {}),
      },
    });
}

export const INSTALL_A = '11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
export const INSTALL_B = '22222222-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
export const INSTALL_C = '33333333-cccc-4ccc-8ccc-cccccccccccc';
export const HWID_A = 'hwid-machine-A-1234';
export const HWID_B = 'hwid-machine-B-5678';

export async function activateKey(client, key, installId, hwid) {
  const res = await client('/api/v1/license/activate', {
    method: 'POST',
    body: JSON.stringify({ key, install_id: installId, hwid, label: 'test' }),
  });
  return { status: res.status, body: await res.json() };
}
