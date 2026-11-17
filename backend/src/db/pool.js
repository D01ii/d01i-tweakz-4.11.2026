import pg from 'pg';
import { config } from '../config/index.js';

export const pool = new pg.Pool({
  connectionString: config.databaseUrl,
  max: config.db.max,
  idleTimeoutMillis: config.db.idleTimeoutMillis,
  connectionTimeoutMillis: config.db.connectionTimeoutMillis,
  // SSL w produkcji konfiguruje sie przez zmienna PGSSLMODE / connection string.
});

pool.on('error', (err) => {
  console.error('[db] nieoczekiwany blad polaczenia z PostgreSQL:', err.message);
});

export async function query(text, params) {
  return pool.query(text, params);
}

export async function withTransaction(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

export async function healthCheck() {
  const r = await query('SELECT 1 AS ok');
  return r.rows[0].ok === 1;
}

export async function closePool() {
  await pool.end();
}
