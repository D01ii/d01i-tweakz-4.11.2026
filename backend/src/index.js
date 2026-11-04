import { createApp } from './app.js';
import { config } from './config/index.js';
import { migrate } from './db/migrate.js';
import { healthCheck, closePool } from './db/pool.js';
import { bootstrapAdminIfNeeded } from './services/adminService.js';
import { migrateLegacySecrets, verifySecretKeyIntegrity } from './services/secretMigrationService.js';

async function main() {
  console.log(`[d01i] startuje backend (env=${config.env})...`);
  await migrate();
  // R4: najpierw weryfikacja klucza wobec istniejacych zaszyfrowanych danych (realne odszyfrowanie),
  // potem migracja legacy plaintext -> enc:v1:. Brak zgodnosci klucza = abort PRZED HTTP.
  const v = await verifySecretKeyIntegrity();
  console.log(`[d01i] zweryfikowano SECRET_ENC_KEY wobec ${v.verified} zaszyfrowanych rekordow`);
  await migrateLegacySecrets();
  const dbOk = await healthCheck();
  if (!dbOk) throw new Error('Brak polaczenia z PostgreSQL po migracjach.');
  console.log('[d01i] PostgreSQL OK');
  await bootstrapAdminIfNeeded();

  const app = createApp();
  const server = app.listen(config.port, config.host, () => {
    console.log(`[d01i] nasluchuje na http://${config.host}:${config.port} (publiczny: ${config.publicBaseUrl})`);
    console.log(`[d01i] panel administratora: ${config.publicBaseUrl}/admin`);
  });

  const shutdown = async (signal) => {
    console.log(`[d01i] otrzymano ${signal}, zamykam serwer...`);
    server.close(async () => {
      await closePool();
      process.exit(0);
    });
    setTimeout(() => process.exit(1), 10_000).unref();
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}

main().catch((err) => {
  console.error('[d01i] blad startu:', err);
  process.exit(1);
});
