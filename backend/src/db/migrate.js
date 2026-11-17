// Prosty, idempotentny runner migracji: wykonuje pliki migrations/*.sql w kolejnosci,
// sledzac wykonane migracje w tabeli schema_migrations.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { pool } from './pool.js';
import pg from 'pg';
import { config } from '../config/index.js';

// R7: opcjonalny osobny użytkownik migracyjny (MIGRATIONS_DATABASE_URL) — runtime aplikacji
// nie ma wtedy uprawnień DDL. Bez zmiennej używany jest standardowy pool (DATABASE_URL).
function getPool() {
  if (config.db.migrationsUrl) return new pg.Pool({ connectionString: config.db.migrationsUrl, max: 1 });
  return pool;
}

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = path.resolve(__dirname, '../../migrations');

export async function migrate({ log = console.log } = {}) {
  const files = fs
    .readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .sort();

  // R4: caly przebieg w JEDNEJ transakcji z advisory lock NA POCZATKU.
  // Zestaw wykonanych migracji odczytujemy DOPIERO po uzyskaniu blokady -
  // wczesniejszy odczyt `done` przed lockiem moglby uzyc nieaktualnych danych.
  const p = getPool();
  const client = await p.connect();
  let current = null;
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', ['d01i_tweakz_migrations']);
    // R6: tabela sledzenia też powstaje WEWNĄTRZ locka — równoległe procesy na pustej bazie
    // mogły wyścigać się o wpisy katalogowe pg_type (CREATE TABLE IF NOT EXISTS poza lockiem).
    await client.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        name TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
      )
    `);
    const done = new Set((await client.query('SELECT name FROM schema_migrations')).rows.map((r) => r.name));
    for (const file of files) {
      if (done.has(file)) {
        log(`[migrate] pomijam (juz wykonana): ${file}`);
        continue;
      }
      current = file;
      const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, file), 'utf8');
      log(`[migrate] wykonuje: ${file}`);
      await client.query(sql);
      await client.query('INSERT INTO schema_migrations(name) VALUES ($1)', [file]);
      log(`[migrate] OK: ${file}`);
    }
    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK');
    throw new Error(`Migracja ${current || '?'} nieudana: ${err.message}`);
  } finally {
    client.release();
    if (p !== pool) await p.end();
  }
  return files.length;
}

// Uruchomienie bezposrednie: node src/db/migrate.js
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  migrate()
    .then((n) => {
      console.log(`[migrate] zakonczono. Sprawdzonych plikow: ${n}`);
      return getPool() === pool ? pool.end() : Promise.resolve();
    })
    .catch((err) => {
      console.error(err);
      process.exit(1);
    });
}
