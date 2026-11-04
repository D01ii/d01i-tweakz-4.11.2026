process.env.TEST_DB_NAME = process.env.TEST_DB_NAME || 'migrations';
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = path.resolve(__dirname, '../migrations');

let t;
before(async () => {
  const h = await import('./helpers.js');
  t = await h.setupTestApp(); // czysta baza + migracje
});
after(async () => { await t.close(); });

test('migrator jest idempotentny - ponowne uruchomienie nie wykonuje migracji ponownie', async () => {
  const { migrate } = await import('../src/db/migrate.js');
  await migrate({ log: () => {} }); // drugi raz
  const applied = await t.query(`SELECT count(*)::int AS n FROM schema_migrations`);
  assert.equal(applied.rows[0].n, 2, 'obie migracje sa w schema_migrations dokładnie raz');
});

test('nieudana migracja nie zostawia wpisu ani czesciowych zmian (jedna transakcja)', async () => {
  const bad = path.join(MIGRATIONS_DIR, '9999_audit_bad.sql');
  fs.writeFileSync(bad, 'CREATE TABLE audit_bad_should_not_exist (id int);\nINSERT INTO nonexistent_table VALUES (1);\n');
  try {
    const { migrate } = await import('../src/db/migrate.js');
    await assert.rejects(() => migrate({ log: () => {} }), /9999_audit_bad/);
    const entry = await t.query(`SELECT count(*)::int AS n FROM schema_migrations WHERE name='9999_audit_bad.sql'`);
    assert.equal(entry.rows[0].n, 0, 'brak wpisu w schema_migrations po bledzie');
    const tbl = await t.query(`SELECT count(*)::int AS n FROM information_schema.tables WHERE table_name='audit_bad_should_not_exist'`);
    assert.equal(tbl.rows[0].n, 0, 'brak czesciowo zastosowanej tabeli (rollback dziala)');
  } finally {
    fs.rmSync(bad, { force: true });
  }
});

test('rownolegle uruchomienie migratora nie duplikuje migracji (advisory lock)', async () => {
  const { migrate } = await import('../src/db/migrate.js');
  await Promise.all([migrate({ log: () => {} }), migrate({ log: () => {} }), migrate({ log: () => {} })]);
  const applied = await t.query(`SELECT name, count(*)::int AS n FROM schema_migrations GROUP BY name HAVING count(*) > 1`);
  assert.equal(applied.rows.length, 0, 'żadna migracja nie zostala zapisana dwa razy');
});
