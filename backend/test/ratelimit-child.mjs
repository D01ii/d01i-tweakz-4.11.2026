// Proces-dziecko dla testu rate limiting: startuje aplikacje z niskim limitem
// i wykonuje 5 aktywacji, wypisujac kody statusow.
process.env.TEST_DB_NAME = 'ratelimit';
process.env.ARGON2_MEMORY_COST = '19456';
const h = await import('./helpers.js');
const t = await h.setupTestApp({
  RATE_LIMIT_ACTIVATE_MAX: '3',
  RATE_LIMIT_WINDOW_MS: '60000',
});
const lic = await h.createTestLicense(t.query);
const codes = [];
for (let i = 0; i < 5; i++) {
  const r = await h.activateKey(t.client, lic.key, h.INSTALL_A + '-' + i, h.HWID_A);
  codes.push(r.status);
}
console.log('CODES=' + codes.join(','));
await t.close();
process.exit(0);
