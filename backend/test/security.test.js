process.env.TEST_DB_NAME = process.env.TEST_DB_NAME || 'security';
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { setupTestApp, createTestLicense, activateKey, INSTALL_A, HWID_A } from './helpers.js';

let t;
before(async () => { t = await setupTestApp(); });
after(async () => { await t.close(); });

test('token wygasa po TTL (symulacja przez stary iat/exp w podpisanym tokenie)', async () => {
  const { signToken } = await import('../src/utils/crypto.js');
  const lic = await createTestLicense(t.query);
  // ręcznie wystawiona sesja z przeszła data wygaszenia
  await t.query(
    `INSERT INTO devices (license_id, install_id, hwid_hash) VALUES ($1,$2,$3) RETURNING id`,
    [lic.id, INSTALL_A, 'hash']
  );
  const dev = (await t.query(`SELECT id FROM devices WHERE license_id=$1`, [lic.id])).rows[0].id;
  const jti = '00000000-0000-4000-8000-000000000001';
  const past = Math.floor(Date.now() / 1000) - 300;
  await t.query(
    `INSERT INTO license_sessions (jti, license_id, device_id, issued_at, expires_at) VALUES ($1,$2,$3, to_timestamp($4), to_timestamp($5))`,
    [jti, lic.id, dev, past, past + 120]
  );
  const token = signToken({ jti, lic: lic.id, dev, iat: past, exp: past + 120, typ: 'access' });
  const v = await t.client('/api/v1/license/validate', { method: 'POST', body: JSON.stringify({ token }) });
  assert.equal(v.status, 401);
  assert.equal((await v.json()).error, 'TOKEN_EXPIRED');
});

test('token z nieznana sesja (ale poprawnym podpisem) -> SESSION_UNKNOWN + alert', async () => {
  const { signToken } = await import('../src/utils/crypto.js');
  const lic = await createTestLicense(t.query);
  const now = Math.floor(Date.now() / 1000);
  const token = signToken({ jti: '00000000-0000-4000-8000-00000000dead', lic: lic.id, dev: 'x', iat: now, exp: now + 120, typ: 'access' });
  const v = await t.client('/api/v1/license/validate', { method: 'POST', body: JSON.stringify({ token }) });
  assert.equal((await v.json()).error, 'SESSION_UNKNOWN');
  const ev = await t.query(`SELECT kind FROM abuse_events WHERE kind='TOKEN_UNKNOWN_SESSION'`);
  assert.ok(ev.rows.length > 0);
});

test('burst blednych kluczy wywoluje alert FAILED_KEY_BURST i czasowa blokade IP', async () => {
  // threshold w test env = 5
  for (let i = 0; i < 6; i++) {
    await activateKey(t.client, 'D01I-AAAA-BBBB-CCCC-' + String(i).padStart(4, 'A'), INSTALL_A, HWID_A);
  }
  const ev = await t.query(`SELECT kind, severity FROM abuse_events WHERE kind='FAILED_KEY_BURST' ORDER BY at DESC LIMIT 1`);
  assert.equal(ev.rows[0]?.kind, 'FAILED_KEY_BURST');
  const blocks = await t.query(`SELECT ip_hash FROM ip_blocks WHERE NOT lifted AND until > now()`);
  assert.ok(blocks.rows.length > 0, 'IP powinien byc czasowo zablokowany');
  // kolejne zadanie z tego IP -> 429
  const r = await t.client('/api/v1/admin/ops/health');
  assert.equal(r.status, 429);
  // sprzatanie: cofamy blokade, zeby kolejne testy mogly dzialac
  const { liftBlock } = await import('../src/services/abuseService.js');
  const bl = await t.query(`SELECT ip_hash FROM ip_blocks WHERE NOT lifted`);
  for (const row of bl.rows) await liftBlock(row.ip_hash, null);
});

test('rate limiting aktywacji (niski limit, osobny proces)', async () => {
  const { execFileSync } = await import('node:child_process');
  const out = execFileSync(process.execPath, ['test/ratelimit-child.mjs'], {
    cwd: new URL('..', import.meta.url).pathname,
    env: { ...process.env, ARGON2_MEMORY_COST: '19456', ARGON2_TIME_COST: '2' },
    encoding: 'utf8',
    timeout: 60000,
  });
  const m = out.match(/CODES=([\d,]+)/);
  assert.ok(m, `brak wyniku z procesu dziecka: ${out}`);
  const codes = m[1].split(',').map(Number);
  assert.ok(codes.includes(429), `oczekiwano 429, otrzymano: ${codes}`);
});

test('XSS/CSP: naglowki bezpieczenstwa sa ustawione', async () => {
  const r = await t.client('/');
  assert.ok(r.headers.get('content-security-policy')?.includes("default-src 'self'"));
  assert.equal(r.headers.get('x-frame-options'), 'DENY');
  assert.equal(r.headers.get('x-powered-by'), null);
});

test('SQL injection w wyszukiwarce licencji (endpoint admina) nie wykonuje kodu', async () => {
  const { adminLogin, authedClient } = await import('./helpers.js');
  const { cookieHeader, csrfToken } = await adminLogin(t.client, t.query);
  const api = authedClient(t.client, cookieHeader, csrfToken);
  const payload = "'; DROP TABLE licenses; --";
  const r = await api(`/api/v1/admin/licenses?search=${encodeURIComponent(payload)}`);
  assert.equal(r.status, 200);
  const stillThere = await t.query(`SELECT COUNT(*)::int AS n FROM licenses`);
  assert.ok(stillThere.rows[0].n >= 0, 'tabela licenses nadal istnieje');
});

test('nieznana trasa API -> 404 JSON', async () => {
  const r = await t.client('/api/v1/nie-istnieje');
  assert.equal(r.status, 404);
  assert.equal((await r.json()).error, 'NOT_FOUND');
});

test('replay rotowanego tokena tylko w oknie idempotencji (B1, osobny proces)', async () => {
  const { execFileSync } = await import('node:child_process');
  const out = execFileSync(process.execPath, ['test/refresh-window-child.mjs'], {
    cwd: new URL('..', import.meta.url).pathname,
    env: { ...process.env, ARGON2_MEMORY_COST: '19456' },
    encoding: 'utf8',
    timeout: 60000,
  });
  assert.match(out, /FIRST=200/);
  assert.match(out, /REPLAY_IN_WINDOW=200 same=true/);
  assert.match(out, /REPLAY_AFTER_WINDOW=401 error=TOKEN_ROTATED/);
});

test('konfiguracja: TOKEN_TTL_SECONDS poza zakresem 30-120 odmawia startu (D1)', async () => {
  const { execFileSync } = await import('node:child_process');
  let err = null;
  try {
    execFileSync(process.execPath, ['-e', "process.env.DATABASE_URL='postgresql://postgres@/d01i_test_security?host=/tmp/d01i-pgdata';process.env.SECURITY_PEPPER='x';process.env.SECRET_ENC_KEY='a'.repeat(64);process.env.ALLOW_EPHEMERAL_KEYS='true';process.env.TOKEN_TTL_SECONDS='9999';import('./src/config/index.js')"], {
      cwd: new URL('..', import.meta.url).pathname,
      env: { ...process.env },
      encoding: 'utf8',
      timeout: 30000,
      stdio: 'pipe',
    });
  } catch (e) { err = e; }
  assert.ok(err, 'start z TTL=9999 musi sie nie powiesc');
  assert.match(String(err.stderr || err.message), /TOKEN_TTL_SECONDS/);
});
