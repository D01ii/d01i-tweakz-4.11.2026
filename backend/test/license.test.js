process.env.TEST_DB_NAME = process.env.TEST_DB_NAME || 'license';
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import {
  setupTestApp, createTestLicense, adminLogin, activateKey,
  INSTALL_A, INSTALL_B, INSTALL_C, HWID_A, HWID_B,
} from './helpers.js';

let t;
before(async () => { t = await setupTestApp(); });
after(async () => { await t.close(); });

test('poprawna aktywacja zwraca podpisany token i dane licencji', async () => {
  const lic = await createTestLicense(t.query, { type: 'PREMIUM_30D' });
  const r = await activateKey(t.client, lic.key, INSTALL_A, HWID_A);
  assert.equal(r.status, 200);
  assert.ok(r.body.token);
  assert.equal(r.body.license.type, 'PREMIUM_30D');
  assert.ok(r.body.device_id);
});

test('niepoprawny klucz -> 401 KEY_INVALID', async () => {
  const r = await activateKey(t.client, 'D01I-AAAA-BBBB-CCCC-DDDD', INSTALL_A, HWID_A);
  assert.equal(r.status, 401);
  assert.equal(r.body.error, 'KEY_INVALID');
});

test('walidacja tokena dziala, refresh rotuje token i UNIEWAŻNIA stary (B1)', async () => {
  const lic = await createTestLicense(t.query);
  const act = await activateKey(t.client, lic.key, INSTALL_A, HWID_A);
  const token = act.body.token;

  const v = await t.client('/api/v1/license/validate', { method: 'POST', body: JSON.stringify({ token }) });
  assert.equal(v.status, 200);
  const vj = await v.json();
  assert.equal(vj.valid, true);
  assert.equal(vj.license.type, 'PREMIUM_30D');

  const rf = await t.client('/api/v1/license/refresh', { method: 'POST', body: JSON.stringify({ token }) });
  assert.equal(rf.status, 200);
  const rj = await rf.json();
  assert.ok(rj.token && rj.token !== token);

  // B1: stary token po rotacji NIE może być użyty do walidacji (revoked natychmiast)
  const vOld = await t.client('/api/v1/license/validate', { method: 'POST', body: JSON.stringify({ token }) });
  assert.equal(vOld.status, 401);
  assert.equal((await vOld.json()).error, 'SESSION_REVOKED');

  // idempotentny replay: powtorzony refresh w oknie zwraca TEN SAM nowy token
  const rf2 = await t.client('/api/v1/license/refresh', { method: 'POST', body: JSON.stringify({ token }) });
  assert.equal(rf2.status, 200);
  const rj2 = await rf2.json();
  assert.equal(rj2.token, rj.token, 'powtorzony refresh po utracie odpowiedzi zwraca ten sam token (idempotentnosc)');

  // nowy token działa
  const v2 = await t.client('/api/v1/license/validate', { method: 'POST', body: JSON.stringify({ token: rj.token }) });
  assert.equal((await v2.json()).valid, true);
});

test('rownolegle odswiezenia jednego tokena tworza dokladnie jeden nastepce (B1)', async () => {
  const lic = await createTestLicense(t.query);
  const act = await activateKey(t.client, lic.key, INSTALL_A, HWID_A);
  const token = act.body.token;
  const results = await Promise.all(
    Array.from({ length: 6 }, () => t.client('/api/v1/license/refresh', { method: 'POST', body: JSON.stringify({ token }) }))
  );
  const bodies = await Promise.all(results.map((r) => r.json()));
  assert.ok(results.every((r) => r.status === 200));
  const tokens = new Set(bodies.map((b) => b.token));
  assert.equal(tokens.size, 1, 'wszystkie równoczesne odswiezenia musza dostac ten sam token');
  const active = await t.query(
    `SELECT COUNT(*)::int AS n FROM license_sessions WHERE device_id = $1 AND NOT revoked`,
    [act.body.device_id]
  );
  assert.equal(active.rows[0].n, 1, 'dokladnie jedna aktywna sesja na urzadzenie');
});

test('zmiana HWID przy tym samym install_id jest odrzucana (B2)', async () => {
  const lic = await createTestLicense(t.query);
  const a = await activateKey(t.client, lic.key, INSTALL_A, HWID_A);
  assert.equal(a.status, 200);
  // "sklonowany" install_id z innym HWID -> odmowa
  const evil = await activateKey(t.client, lic.key, INSTALL_A, 'hwid-attacker-clone-99');
  assert.equal(evil.status, 409);
  assert.equal(evil.body.error, 'HWID_MISMATCH');
  const ev = await t.query(`SELECT kind FROM abuse_events WHERE kind='DEVICE_HWID_MISMATCH' ORDER BY at DESC LIMIT 1`);
  assert.equal(ev.rows[0].kind, 'DEVICE_HWID_MISMATCH');
  // oryginalny HWID nadal dziala
  const ok = await activateKey(t.client, lic.key, INSTALL_A, HWID_A);
  assert.equal(ok.status, 200);
});

test('po resecie urzadzen przez admina mozna ponownie zwiazac HWID (B2)', async () => {
  const { adminLogin, authedClient } = await import('./helpers.js');
  const { cookieHeader, csrfToken } = await adminLogin(t.client, t.query);
  const api = authedClient(t.client, cookieHeader, csrfToken);
  const lic = await createTestLicense(t.query);
  await activateKey(t.client, lic.key, INSTALL_A, HWID_A);
  // admin resetuje urzadzenia
  const rs = await api(`/api/v1/admin/licenses/${lic.id}/reset-devices`, { method: 'POST' });
  assert.equal(rs.status, 200);
  // hwid_hash wyczyszczony
  const d = await t.query(`SELECT hwid_hash FROM devices WHERE license_id=$1`, [lic.id]);
  assert.equal(d.rows[0].hwid_hash, null);
  // ponowna aktywacja z nowym HWID przechodzi (kontrolowane ponowne zwiazanie)
  const re = await activateKey(t.client, lic.key, INSTALL_A, 'hwid-new-hardware-01');
  assert.equal(re.status, 200);
});

test('limit urzadzen: 2 aktywne OK, trzecie odrzucone (409)', async () => {
  const lic = await createTestLicense(t.query, { maxDevices: 2 });
  const a = await activateKey(t.client, lic.key, INSTALL_A, HWID_A);
  const b = await activateKey(t.client, lic.key, INSTALL_B, HWID_B);
  assert.equal(a.status, 200);
  assert.equal(b.status, 200);
  const c = await activateKey(t.client, lic.key, INSTALL_C, 'hwid-machine-C-9999');
  assert.equal(c.status, 409);
  assert.equal(c.body.error, 'DEVICE_LIMIT_REACHED');
});

test('dezaktywacja urzadzenia zwalnia slot i pozwala na ponowna aktywacje', async () => {
  const lic = await createTestLicense(t.query, { maxDevices: 2 });
  await activateKey(t.client, lic.key, INSTALL_A, HWID_A);
  await activateKey(t.client, lic.key, INSTALL_B, HWID_B);
  const c1 = await activateKey(t.client, lic.key, INSTALL_C, 'hwid-machine-C-0000');
  assert.equal(c1.status, 409);

  // dezaktywacja przez token urzadzenia B
  const b = await activateKey(t.client, lic.key, INSTALL_B, HWID_B); // re-aktywacja zwraca token
  const deact = await t.client('/api/v1/license/deactivate', { method: 'POST', body: JSON.stringify({ token: b.body.token }) });
  assert.equal(deact.status, 200);

  const c2 = await activateKey(t.client, lic.key, INSTALL_C, 'hwid-machine-C-0000');
  assert.equal(c2.status, 200, 'po dezaktywacji B mozna aktywowac C');
});

test('rownolegle aktywacje trzeciego urzadzenia - tylko jedna moze wygrac (transakcja FOR UPDATE)', async () => {
  const lic = await createTestLicense(t.query, { maxDevices: 2 });
  await activateKey(t.client, lic.key, INSTALL_A, HWID_A);
  await activateKey(t.client, lic.key, INSTALL_B, HWID_B);
  const results = await Promise.all(
    Array.from({ length: 8 }, (_, i) => activateKey(t.client, lic.key, INSTALL_C, 'hwid-machine-C-' + i))
  );
  const okCount = results.filter((r) => r.status === 200).length;
  assert.equal(okCount, 0, 'żadna z 8 równoczesnych aktywacji nie może przekroczyć limitu');
});

test('wygasla licencja -> LICENSE_EXPIRED', async () => {
  const { keyHash, keyPrefix } = await import('../src/utils/licenseKey.js');
  const { generateLicenseKey } = await import('../src/utils/licenseKey.js');
  const key = generateLicenseKey();
  await t.query(
    `INSERT INTO licenses (key_hash, key_prefix, type, expires_at) VALUES ($1,$2,'PREMIUM_30D', now() - interval '1 day')`,
    [keyHash(key), keyPrefix(key)]
  );
  const r = await activateKey(t.client, key, INSTALL_A, HWID_A);
  assert.equal(r.status, 403);
  assert.equal(r.body.error, 'LICENSE_EXPIRED');
});

test('uniewazniona licencja -> LICENSE_REVOKED i sesje uniewaznione', async () => {
  const lic = await createTestLicense(t.query);
  const act = await activateKey(t.client, lic.key, INSTALL_A, HWID_A);
  await t.query(`UPDATE licenses SET status='REVOKED', revoked_at=now() WHERE id=$1`, [lic.id]);
  await t.query(`UPDATE license_sessions SET revoked=TRUE WHERE license_id=$1`, [lic.id]);

  const a2 = await activateKey(t.client, lic.key, INSTALL_B, HWID_B);
  assert.equal(a2.status, 403);
  assert.equal(a2.body.error, 'LICENSE_REVOKED');

  const v = await t.client('/api/v1/license/validate', { method: 'POST', body: JSON.stringify({ token: act.body.token }) });
  assert.equal(v.status, 401);
  assert.equal((await v.json()).error, 'SESSION_REVOKED');
});

test('sfałszowany token (zly podpis) -> 401 + zdarzenie TOKEN_TAMPER', async () => {
  const lic = await createTestLicense(t.query);
  const act = await activateKey(t.client, lic.key, INSTALL_A, HWID_A);
  const forged = act.body.token.slice(0, -4) + 'AAAA';
  const v = await t.client('/api/v1/license/validate', { method: 'POST', body: JSON.stringify({ token: forged }) });
  assert.equal(v.status, 401);
  assert.equal((await v.json()).error, 'INVALID_SIGNATURE');
  const ev = await t.query(`SELECT kind FROM abuse_events WHERE kind='TOKEN_TAMPER' ORDER BY at DESC LIMIT 1`);
  assert.equal(ev.rows[0].kind, 'TOKEN_TAMPER');
});

test('status i lista urzadzen dla wlasciciela tokena', async () => {
  const lic = await createTestLicense(t.query);
  const act = await activateKey(t.client, lic.key, INSTALL_A, HWID_A);
  const s = await t.client('/api/v1/license/status', { method: 'POST', body: JSON.stringify({ token: act.body.token }) });
  assert.equal(s.status, 200);
  const sj = await s.json();
  assert.equal(sj.active_devices, 1);
  const d = await t.client('/api/v1/license/devices', { method: 'POST', body: JSON.stringify({ token: act.body.token }) });
  const dj = await d.json();
  assert.equal(dj.devices.length, 1);
  assert.equal(dj.devices[0].mine, true);
});

test('walidacja blednych danych wejsciowych -> 400', async () => {
  const r = await t.client('/api/v1/license/activate', { method: 'POST', body: JSON.stringify({ key: 'x' }) });
  assert.equal(r.status, 400);
  assert.equal((await r.json()).error, 'VALIDATION_ERROR');
});

test('health endpoint dziala', async () => {
  const r = await t.client('/api/v1/admin/ops/health');
  const j = await r.json();
  assert.equal(j.ok, true);
  assert.equal(j.db, true);
});
