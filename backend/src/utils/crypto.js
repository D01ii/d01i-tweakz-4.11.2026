import crypto from 'node:crypto';
import { config } from '../config/index.js';

const b64u = (buf) => Buffer.from(buf).toString('base64url');
const fromB64u = (s) => Buffer.from(s, 'base64url');

export function sha256Hex(input) {
  return crypto.createHash('sha256').update(input).digest('hex');
}

/** Pseudonimizowany hash wartosci wraz z pepperem serwera (IP, HWID). */
export function pepperedHash(value) {
  return sha256Hex(`${config.security.pepper}::${value}`);
}

export function randomToken(bytes = 32) {
  return crypto.randomBytes(bytes).toString('base64url');
}

export function randomUuid() {
  return crypto.randomUUID();
}

// ------------------------------ Ed25519 tokeny ------------------------------

const te = new TextEncoder();

export function signToken(payload) {
  const header = { alg: 'Ed25519', typ: 'D01I' };
  const h = b64u(te.encode(JSON.stringify(header)));
  const p = b64u(te.encode(JSON.stringify(payload)));
  const sig = crypto.sign(null, te.encode(`${h}.${p}`), config.keys.privateKey);
  return `${h}.${p}.${b64u(sig)}`;
}

/**
 * Weryfikuje podpis i strukture tokena. Zwraca payload albo null.
 * NIGDY nie zaufaj polom przed weryfikacja podpisu.
 */
export function verifyToken(token) {
  if (typeof token !== 'string') return null;
  const parts = token.split('.');
  if (parts.length !== 3) return null;
  const [h, p, s] = parts;
  let header, payload;
  try {
    header = JSON.parse(fromB64u(h).toString('utf8'));
    payload = JSON.parse(fromB64u(p).toString('utf8'));
  } catch {
    return null;
  }
  if (header?.alg !== 'Ed25519') return null;
  let ok = false;
  try {
    ok = crypto.verify(null, te.encode(`${h}.${p}`), config.keys.publicKey, fromB64u(s));
  } catch {
    return null;
  }
  if (!ok) return null;
  if (
    typeof payload?.jti !== 'string' ||
    typeof payload?.iat !== 'number' ||
    typeof payload?.exp !== 'number' ||
    typeof payload?.lic !== 'string' ||
    typeof payload?.dev !== 'string'
  ) {
    return null;
  }
  return payload;
}

export function tokenExpirySeconds() {
  return config.security.tokenTtlSeconds;
}
