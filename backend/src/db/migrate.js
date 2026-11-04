// Prosty, idempotentny runner migracji: wykonuje pliki migrations/*.sql w kolejnosci,
// sledzac wykonane migracje w tabeli schema_migrations.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { pool, query } from './pool.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const MIGRATIONS_DIR = path.resolve(__dirname, '../../migrations');

export async function migrate({ log = console.log } = {}) {
  await query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      name TEXT PRIMARY KEY,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )
  `);

  const files = fs
    .readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .sort();

  // R4: caly przebieg w JEDNEJ transakcji z advisory lock NA POCZATKU.
  // Zestaw wykonanych migracji odczytujemy DOPIERO po uzyskaniu blokady -
  // wczesniejszy odczyt `done` przed lockiem moglby uzyc nieaktualnych danych.
  const client = await pool.connect();
  let current = null;
  try {
    await client.query('BEGIN');
    await client.query('SELECT pg_advisory_xact_lock(hashtext($1))', ['d01i_tweakz_migrations']);
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
  }
  return files.length;
}

// Uruchomienie bezposrednie: node src/db/migrate.js
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  migrate()
    .then((n) => {
      console.log(`[migrate] zakonczono. Sprawdzonych plikow: ${n}`);
      return pool.end();
    })
    .catch((err) => {
      console.error(err);
      process.exit(1);
    });
}
