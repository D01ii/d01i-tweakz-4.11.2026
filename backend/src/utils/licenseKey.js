import crypto from 'node:crypto';
import { sha256Hex } from './crypto.js';
import { config } from '../config/index.js';

// alfabet bez dwuznacznych znakow (0/O, 1/I/L)
const ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

export const LICENSE_TYPES = ['DEMO', 'PREMIUM_30D', 'PREMIUM_90D', 'PREMIUM_LIFETIME'];

export function licenseDurationDays(type) {
  switch (type) {
    case 'DEMO':
      return 7;
    case 'PREMIUM_30D':
      return 30;
    case 'PREMIUM_90D':
      return 90;
    case 'PREMIUM_LIFETIME':
      return null; // brak wygasniecia
    default:
      throw new Error(`Nieznany typ licencji: ${type}`);
  }
}

/** Kryptograficznie bezpieczny generator klucza: D01I-XXXX-XXXX-XXXX-XXXX (~80 bitow entropii). */
export function generateLicenseKey() {
  const pick = (n) => {
    const bytes = crypto.randomBytes(n);
    let out = '';
    for (let i = 0; i < n; i++) out += ALPHABET[bytes[i] % ALPHABET.length];
    return out;
  };
  return `D01I-${pick(4)}-${pick(4)}-${pick(4)}-${pick(4)}`;
}

export function normalizeKey(input) {
  if (typeof input !== 'string') return null;
  return input.trim().toUpperCase().replace(/\s+/g, '');
}

/** Walidacja formatu klucza (bez dotykania bazy). */
export function isValidKeyFormat(key) {
  return /^D01I-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$/.test(key);
}

/** v2: HMAC-SHA256 z osobnym LICENSE_KEY_PEPPER (R7). Prefix 'v2:' rozróżnia wersje. */
export function keyHash(key) {
  const k = normalizeKey(key);
  return 'v2:' + crypto.createHmac('sha256', config.secrets.licenseKeyPepper).update(k).digest('hex');
}

/** Legacy (v1): niepepperowany SHA-256 — tylko do odczytu istniejących licencji. */
export function keyHashLegacy(key) {
  return sha256Hex(normalizeKey(key));
}

/** Prefix do bezpiecznej identyfikacji klucza w panelu (nie pozwala odtworzyc klucza). */
export function keyPrefix(key) {
  const k = normalizeKey(key);
  return k.slice(0, 9); // "D01I-XXXX"
}
