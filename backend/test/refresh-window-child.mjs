// Proces-dziecko: weryfikuje, że replay starego (rotowanego) tokena działa tylko
// w oknie idempotencji - po jego upływie token jest odrzucany (TOKEN_ROTATED).
process.env.TEST_DB_NAME = 'refreshwin';
process.env.REFRESH_REPLAY_WINDOW_SECONDS = '1';
process.env.ARGON2_MEMORY_COST = '19456';
const h = await import('./helpers.js');
const t = await h.setupTestApp({ REFRESH_REPLAY_WINDOW_SECONDS: '1' });
const lic = await h.createTestLicense(t.query);
const act = await h.activateKey(t.client, lic.key, h.INSTALL_A, h.HWID_A);
const token = act.body.token;

const r1 = await t.client('/api/v1/license/refresh', { method: 'POST', body: JSON.stringify({ token }) });
const j1 = await r1.json();
console.log('FIRST=' + r1.status);

const r2 = await t.client('/api/v1/license/refresh', { method: 'POST', body: JSON.stringify({ token }) });
const j2 = await r2.json();
console.log('REPLAY_IN_WINDOW=' + r2.status + ' same=' + (j2.token === j1.token));

await new Promise((r) => setTimeout(r, 1500)); // przekraczamy okno 1 s

const r3 = await t.client('/api/v1/license/refresh', { method: 'POST', body: JSON.stringify({ token }) });
const j3 = await r3.json();
console.log('REPLAY_AFTER_WINDOW=' + r3.status + ' error=' + j3.error);

await t.close();
process.exit(0);
