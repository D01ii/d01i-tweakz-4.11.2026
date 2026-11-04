// Proces-dziecko dla testu wspolbieznosci migratora: sama migracja na wskazana baze.
// Uzycie: MIGRACE_DB_URL=... node test/migrator-race-child.mjs
import { migrate } from '../src/db/migrate.js';
import { pool } from '../src/db/pool.js';
await migrate({ log: () => {} });
await pool.end();
console.log('MIGRATED');
