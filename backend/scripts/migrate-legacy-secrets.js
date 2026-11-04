// Uzycie: node scripts/migrate-legacy-secrets.js  (wymaga .env z SECRET_ENC_KEY)
import { migrate } from '../src/db/migrate.js';
import { migrateLegacySecrets } from '../src/services/secretMigrationService.js';
import { closePool } from '../src/db/pool.js';

await migrate();
const r = await migrateLegacySecrets();
console.log('[secrets] migracja zakonczona:', r);
await closePool();
