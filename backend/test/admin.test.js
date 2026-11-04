process.env.TEST_DB_NAME = process.env.TEST_DB_NAME || 'admin';
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { setupTestApp, createTestLicense, adminLogin, authedClient, activateKey, INSTALL_A, HWID_A } from './helpers.js';

let t;
before(async () => { t = await setupTestApp(); });
after(async () => { await t.close(); });

test('logowanie admina: zle haslo -> 401, dobre -> cookie + csrf', async () => {
  const bad = await t.client('/api/v1/admin/login', {
    method: 'POST', body: JSON.stringify({ username: 'root', password: 'zle-haslo-12345' }),
  });
  assert.equal(bad.status, 401);
  const { createAdmin } = await import('../src/services/adminService.js');
  await createAdmin({ username: 'root', password: 'super-secret-password-123', role: 'superadmin' });
  const ok = await adminLogin(t.client, t.query);
  assert.equal(ok.ok, true);
  assert.ok(ok.cookieHeader.includes('d01i_admin_session'));
  assert.ok(ok.csrfToken);
});

test('dostęp do API admin bez sesji -> 401', async () => {
  const r = await t.client('/api/v1/admin/ops/stats');
  assert.equal(r.status, 401);
});

test('dostęp do API admin bez tokena CSRF przy POST -> 403', async () => {
  const { cookieHeader } = await adminLogin(t.client, t.query);
  const noCsrf = (p, opts = {}) =>
    t.client(p, { ...opts, headers: { 'Content-Type': 'application/json', Cookie: cookieHeader, ...(opts.headers || {}) } });
  const r = await noCsrf('/api/v1/admin/licenses', { method: 'POST', body: JSON.stringify({ type: 'DEMO' }) });
  assert.equal(r.status, 403);
  assert.equal((await r.json()).error, 'CSRF_FAILED');
});

test('CRUD licencji przez panel: utworzenie zwraca klucz tylko raz, lista, revoke, reset', async () => {
  const { cookieHeader, csrfToken } = await adminLogin(t.client, t.query);
  const api = authedClient(t.client, cookieHeader, csrfToken);

  const created = await api('/api/v1/admin/licenses', { method: 'POST', body: JSON.stringify({ type: 'PREMIUM_90D', max_devices: 2 }) });
  assert.equal(created.status, 201);
  const cj = await created.json();
  assert.match(cj.key, /^D01I-[A-HJ-NP-Z2-9]{4}(-[A-HJ-NP-Z2-9]{4}){3}$/);
  const licId = cj.license.id;

  // pelny klucz NIE jest w bazie - tylko hash
  const inDb = await t.query(`SELECT key_hash FROM licenses WHERE id=$1`, [licId]);
  assert.ok(inDb.rows[0].key_hash.length === 64);
  assert.ok(!JSON.stringify(inDb.rows).includes(cj.key));

  const list = await api('/api/v1/admin/licenses');
  const lj = await list.json();
  assert.ok(lj.licenses.some((l) => l.id === licId));

  // aktywacja klienta tym kluczem
  const act = await activateKey(t.client, cj.key, INSTALL_A, HWID_A);
  assert.equal(act.status, 200);

  // revoke
  const rev = await api(`/api/v1/admin/licenses/${licId}/revoke`, { method: 'POST', body: JSON.stringify({ reason: 'test' }) });
  assert.equal(rev.status, 200);
  const v = await t.client('/api/v1/license/validate', { method: 'POST', body: JSON.stringify({ token: act.body.token }) });
  assert.equal(v.status, 401, 'po revoke sesja klienta jest uniewazniona');

  // reset urzadzen
  const rs = await api(`/api/v1/admin/licenses/${licId}/reset-devices`, { method: 'POST' });
  assert.equal(rs.status, 200);
});

test('przedluzanie licencji i historia aktywacji', async () => {
  const { cookieHeader, csrfToken } = await adminLogin(t.client, t.query);
  const api = authedClient(t.client, cookieHeader, csrfToken);
  const lic = await createTestLicense(t.query, { type: 'PREMIUM_30D' });
  await activateKey(t.client, lic.key, INSTALL_A, HWID_A);

  const ext = await api(`/api/v1/admin/licenses/${lic.id}/extend`, { method: 'POST', body: JSON.stringify({ days: 10 }) });
  assert.equal(ext.status, 200);

  const hist = await api(`/api/v1/admin/licenses/${lic.id}/history`);
  const hj = await hist.json();
  assert.ok(hj.history.some((h) => h.action === 'ACTIVATE'));
});

test('audit log rejestruje akcje admina', async () => {
  const { cookieHeader, csrfToken } = await adminLogin(t.client, t.query);
  const api = authedClient(t.client, cookieHeader, csrfToken);
  await api('/api/v1/admin/licenses', { method: 'POST', body: JSON.stringify({ type: 'DEMO' }) });
  const audit = await api('/api/v1/admin/ops/audit?limit=50');
  const aj = await audit.json();
  assert.ok(aj.logs.some((l) => l.action === 'license.create'));
  assert.ok(aj.logs.some((l) => l.action === 'admin.login.ok'));
});

test('blokada po brute-force logowania (konto blokowane czasowo)', async () => {
  const { createAdmin } = await import('../src/services/adminService.js');
  await createAdmin({ username: 'victim', password: 'super-secret-password-123' });
  for (let i = 0; i < 5; i++) {
    await t.client('/api/v1/admin/login', { method: 'POST', body: JSON.stringify({ username: 'victim', password: 'zle-zle-zle-zle' }) });
  }
  const r = await t.client('/api/v1/admin/login', { method: 'POST', body: JSON.stringify({ username: 'victim', password: 'super-secret-password-123' }) });
  assert.equal(r.status, 423);
  assert.equal((await r.json()).error, 'ACCOUNT_LOCKED');
});

test('MFA: setup + enable TOTP, logowanie wymaga kodu', async () => {
  const { createAdmin, setupTotp, enableTotp, loginAdmin } = await import('../src/services/adminService.js');
  await createAdmin({ username: 'mfaadmin', password: 'super-secret-password-123' });
  const id = (await t.query(`SELECT id FROM admins WHERE username='mfaadmin'`)).rows[0].id;
  const { secret } = await setupTotp(id);
  const { authenticator } = await import('otplib');
  const code = authenticator.generate(secret);
  await enableTotp(id, code);
  const r = await loginAdmin({ username: 'mfaadmin', password: 'super-secret-password-123' });
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'TOTP_REQUIRED');
  const r2 = await loginAdmin({ username: 'mfaadmin', password: 'super-secret-password-123', totp: authenticator.generate(secret) });
  assert.equal(r2.ok, true);
});

test('wylogowanie uniewaznia sesje', async () => {
  const { cookieHeader, csrfToken } = await adminLogin(t.client, t.query);
  const api = authedClient(t.client, cookieHeader, csrfToken);
  await api('/api/v1/admin/logout', { method: 'POST' });
  const r = await api('/api/v1/admin/me');
  assert.equal(r.status, 401);
});

test('ustawienia webhooka: zapis i maskowanie URL', async () => {
  const { cookieHeader, csrfToken } = await adminLogin(t.client, t.query);
  const api = authedClient(t.client, cookieHeader, csrfToken);
  const set = await api('/api/v1/admin/ops/settings/webhook', {
    method: 'POST', body: JSON.stringify({ enabled: true, url: 'https://discord.com/api/webhooks/123/abc' }),
  });
  assert.equal(set.status, 200);
  const get = await api('/api/v1/admin/ops/settings/webhook');
  const gj = await get.json();
  assert.equal(gj.webhook.enabled, true);
  assert.equal(gj.webhook.configured, true);
  // pelny URL nie wraca do klienta
  const all = await api('/api/v1/admin/ops/settings');
  const aj = await all.json();
  assert.ok(!JSON.stringify(aj).includes('abc'));
});

test('limit urzadzen > 2 jest odrzucany przez API (B3 - regula produktu)', async () => {
  const { cookieHeader, csrfToken } = await adminLogin(t.client, t.query);
  const api = authedClient(t.client, cookieHeader, csrfToken);
  const r = await api('/api/v1/admin/licenses', { method: 'POST', body: JSON.stringify({ type: 'PREMIUM_30D', max_devices: 5 }) });
  assert.equal(r.status, 400);
  assert.equal((await r.json()).error, 'VALIDATION_ERROR');
  const ok = await api('/api/v1/admin/licenses', { method: 'POST', body: JSON.stringify({ type: 'PREMIUM_30D', max_devices: 2 }) });
  assert.equal(ok.status, 201);
});

test('sekret TOTP i URL webhooka sa szyfrowane w bazie (B4)', async () => {
  const { createAdmin, setupTotp } = await import('../src/services/adminService.js');
  await createAdmin({ username: 'encadmin', password: 'super-secret-password-123' });
  const id = (await t.query(`SELECT id FROM admins WHERE username='encadmin'`)).rows[0].id;
  const { secret } = await setupTotp(id);
  const row = await t.query(`SELECT totp_secret FROM admins WHERE id=$1`, [id]);
  assert.ok(row.rows[0].totp_secret.startsWith('enc:v1:'), 'sekret TOTP zaszyfrowany');
  assert.ok(!row.rows[0].totp_secret.includes(secret), 'plaintext sekretu nie ma w bazie');

  const { cookieHeader, csrfToken } = await adminLogin(t.client, t.query);
  const api = authedClient(t.client, cookieHeader, csrfToken);
  await api('/api/v1/admin/ops/settings/webhook', { method: 'POST', body: JSON.stringify({ enabled: true, url: 'https://discord.com/api/webhooks/999/secret' }) });
  const wh = await t.query(`SELECT value FROM settings WHERE key='discord_webhook'`);
  assert.ok(String(wh.rows[0].value.url).startsWith('enc:v1:'), 'URL webhooka zaszyfrowany');
  assert.ok(!JSON.stringify(wh.rows[0].value).includes('secret'), 'plaintext URL nie jest w bazie');
});

test('recovery code dziala jednorazowo (B5)', async () => {
  const { createAdmin, setupTotp, enableTotp, loginAdmin } = await import('../src/services/adminService.js');
  const { authenticator } = await import('otplib');
  await createAdmin({ username: 'recoveryadmin', password: 'super-secret-password-123' });
  const id = (await t.query(`SELECT id FROM admins WHERE username='recoveryadmin'`)).rows[0].id;
  const { secret } = await setupTotp(id);
  const { recoveryCodes } = await enableTotp(id, authenticator.generate(secret));
  const code = recoveryCodes[0];
  const r1 = await loginAdmin({ username: 'recoveryadmin', password: 'super-secret-password-123', recoveryCode: code });
  assert.equal(r1.ok, true, 'pierwsze użycie recovery code OK');
  const r2 = await loginAdmin({ username: 'recoveryadmin', password: 'super-secret-password-123', recoveryCode: code });
  assert.equal(r2.ok, false, 'drugie użycie tego samego recovery code odrzucone');
  assert.equal(r2.reason, 'MFA_INVALID');
  // zły kod TOTP -> MFA_INVALID (a nie mylące TOTP_REQUIRED)
  const r3 = await loginAdmin({ username: 'recoveryadmin', password: 'super-secret-password-123', totp: '000000' });
  assert.equal(r3.ok, false);
  assert.equal(r3.reason, 'MFA_INVALID');
});

test('wylaczenie MFA wymaga hasla + TOTP/kodu odzyskiwania (D2)', async () => {
  const { createAdmin, setupTotp, enableTotp, disableTotp } = await import('../src/services/adminService.js');
  const { authenticator } = await import('otplib');
  await createAdmin({ username: 'mfadisable', password: 'super-secret-password-123' });
  const id = (await t.query(`SELECT id FROM admins WHERE username='mfadisable'`)).rows[0].id;
  const { secret } = await setupTotp(id);
  await enableTotp(id, authenticator.generate(secret));
  await assert.rejects(() => disableTotp(id, { password: 'super-secret-password-123' }), /TOTP|odzyskiwania/);
  await assert.rejects(() => disableTotp(id, { password: 'zle-haslo-12345', totp: authenticator.generate(secret) }), /haslo/i);
  await disableTotp(id, { password: 'super-secret-password-123', totp: authenticator.generate(secret) });
  const row = await t.query(`SELECT totp_enabled FROM admins WHERE id=$1`, [id]);
  assert.equal(row.rows[0].totp_enabled, false);
});

test('zwykly admin nie moze listowac administratorow (B6 - 403)', async () => {
  const { createAdmin } = await import('../src/services/adminService.js');
  await createAdmin({ username: 'plainadmin', password: 'super-secret-password-123', role: 'admin' });
  const res = await t.client('/api/v1/admin/login', { method: 'POST', body: JSON.stringify({ username: 'plainadmin', password: 'super-secret-password-123' }) });
  const cookies = res.headers.get('set-cookie');
  const { csrfToken } = await res.json();
  const cookieHeader = cookies.split(',').map((c) => c.split(';')[0]).join('; ');
  const r = await t.client('/api/v1/admin/admins', { headers: { Cookie: cookieHeader } });
  assert.equal(r.status, 403);
  // ale statystyki i wlasne konto sa dostepne
  const stats = await t.client('/api/v1/admin/ops/stats', { headers: { Cookie: cookieHeader } });
  assert.equal(stats.status, 200);
});

test('recovery code przy rownoleglych probach logowania zuzywa sie ATOMOWO - tylko jedno OK', async () => {
  const { createAdmin, setupTotp, enableTotp, loginAdmin } = await import('../src/services/adminService.js');
  const { authenticator } = await import('otplib');
  await createAdmin({ username: 'raceadmin', password: 'super-secret-password-123' });
  const id = (await t.query(`SELECT id FROM admins WHERE username='raceadmin'`)).rows[0].id;
  const { secret } = await setupTotp(id);
  const { recoveryCodes } = await enableTotp(id, authenticator.generate(secret));
  const code = recoveryCodes[0];
  const results = await Promise.all(
    Array.from({ length: 8 }, () => loginAdmin({ username: 'raceadmin', password: 'super-secret-password-123', recoveryCode: code }))
  );
  const okCount = results.filter((r) => r.ok).length;
  assert.equal(okCount, 1, `dokładnie jedno uwierzytelnienie, otrzymano: ${okCount}`);
  // kod juz zuzyty - kolejna proba odrzucona
  const after = await loginAdmin({ username: 'raceadmin', password: 'super-secret-password-123', recoveryCode: code });
  assert.equal(after.ok, false);
});

test('R3-P3: uniewazniona/wygasla/wylaczona sesja admina nie przechodzi autoryzacji', async () => {
  const { cookieHeader, csrfToken } = await adminLogin(t.client, t.query, { username: 'sessadmin', password: 'super-secret-password-123' });
  const api = authedClient(t.client, cookieHeader, csrfToken);
  assert.equal((await api('/api/v1/admin/me')).status, 200, 'sesja aktywna dziala');

  // 1) sesja uniewazniona bezposrednio w bazie (np. logout admina / disable)
  const { sha256Hex } = await import('../src/utils/crypto.js');
  const tokenHash = sha256Hex(cookieHeader.match(/d01i_admin_session=([^;]+)/)[1]);
  await t.query(`UPDATE admin_sessions SET revoked=TRUE WHERE token_hash=$1`, [tokenHash]);
  assert.equal((await api('/api/v1/admin/me')).status, 401, 'revoked -> 401');

  // 2) sesja wygasla
  const login2 = await adminLogin(t.client, t.query, { username: 'sessadmin2', password: 'super-secret-password-123' });
  const api2 = authedClient(t.client, login2.cookieHeader, login2.csrfToken);
  const th2 = sha256Hex(login2.cookieHeader.match(/d01i_admin_session=([^;]+)/)[1]);
  await t.query(`UPDATE admin_sessions SET expires_at = now() - interval '1 hour' WHERE token_hash=$1`, [th2]);
  assert.equal((await api2('/api/v1/admin/me')).status, 401, 'expired -> 401');

  // 3) konto admina wylaczone przez superadmina -> wszystkie sesje 401
  const login3 = await adminLogin(t.client, t.query, { username: 'sessadmin3', password: 'super-secret-password-123' });
  const api3 = authedClient(t.client, login3.cookieHeader, login3.csrfToken);
  const admin3 = (await t.query(`SELECT id FROM admins WHERE username='sessadmin3'`)).rows[0].id;
  const { setAdminActive } = await import('../src/services/adminService.js');
  await setAdminActive(admin3, false, null);
  assert.equal((await api3('/api/v1/admin/me')).status, 401, 'konto wylaczone -> 401');
});
