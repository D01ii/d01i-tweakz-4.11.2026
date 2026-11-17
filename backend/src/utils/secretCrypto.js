import crypto from 'node:crypto';
import { config } from '../config/index.js';

// Szyfrowanie sekretow w spoczynku (AES-256-GCM). Klucz pochodzi z env (poza baza),
// format w bazie: enc:v1:<iv>:<tag>:<ciphertext> (base64). Wartości legacy bez prefixu
// sa odczytywane jako plaintext (tylko do migracji; nowe zapisy sa zawsze szyfrowane).

function encKey() {
  const raw = config.secrets.encKey; // 32 bajty (hex lub base64)
  const buf = Buffer.from(raw, /^[0-9a-f]{64}$/i.test(raw) ? 'hex' : 'base64');
  if (buf.length !== 32) throw new Error('SECRET_ENC_KEY musi miec 32 bajty (hex/base64). Wygeneruj: openssl rand -hex 32');
  return buf;
}

export function encryptSecret(plain) {
  if (plain === null || plain === undefined || plain === '') return plain;
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', encKey(), iv);
  const ct = Buffer.concat([cipher.update(String(plain), 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return `enc:v1:${iv.toString('base64')}:${tag.toString('base64')}:${ct.toString('base64')}`;
}

export function decryptSecret(value) {
  if (value === null || value === undefined) return value;
  if (!String(value).startsWith('enc:v1:')) return value; // legacy plaintext
  const [, , ivB, tagB, ctB] = String(value).split(':');
  const decipher = crypto.createDecipheriv('aes-256-gcm', encKey(), Buffer.from(ivB, 'base64'));
  decipher.setAuthTag(Buffer.from(tagB, 'base64'));
  return Buffer.concat([decipher.update(Buffer.from(ctB, 'base64')), decipher.final()]).toString('utf8');
}

export function isEncrypted(value) {
  return typeof value === 'string' && value.startsWith('enc:v1:');
}
