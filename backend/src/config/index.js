import dotenv from 'dotenv';
import { generateKeyPairSync, randomBytes } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

dotenv.config();

const bool = (v, d = false) => (v === undefined ? d : ['1', 'true', 'yes', 'on'].includes(String(v).toLowerCase()));
const int = (v, d) => {
  const n = Number.parseInt(v ?? '', 10);
  return Number.isFinite(n) ? n : d;
};

function loadEd25519Keys() {
  // Klucze Ed25519 moga byc podane jako sciezki (produkcja) lub jako surowe PEM/DER w env.
  const privPath = process.env.ED25519_PRIVATE_KEY_PATH;
  const pubPath = process.env.ED25519_PUBLIC_KEY_PATH;
  const privPem = process.env.ED25519_PRIVATE_KEY_PEM;
  const pubPem = process.env.ED25519_PUBLIC_KEY_PEM;

  if (privPem && pubPem) {
    return { privateKey: privPem, publicKey: pubPem };
  }
  if (privPath && pubPath && fs.existsSync(privPath) && fs.existsSync(pubPath)) {
    return {
      privateKey: fs.readFileSync(privPath, 'utf8'),
      publicKey: fs.readFileSync(pubPath, 'utf8'),
    };
  }
  // Tryb deweloperski: generujemy efemeryczna pare (NIE do produkcji - patrz .env.example).
  if (bool(process.env.ALLOW_EPHEMERAL_KEYS, false)) {
    const { privateKey, publicKey } = generateKeyPairSync('ed25519');
    return {
      privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
      publicKey: publicKey.export({ type: 'spki', format: 'pem' }).toString(),
    };
  }
  throw new Error(
    'Brak kluczy Ed25519. Ustaw ED25519_PRIVATE_KEY_PATH/ED25519_PUBLIC_KEY_PATH (lub *_PEM), ' +
      'albo ALLOW_EPHEMERAL_KEYS=true tylko lokalnie do testow.'
  );
}

export const config = {
  env: process.env.NODE_ENV || 'development',
  port: int(process.env.PORT, 8080),
  host: process.env.HOST || '127.0.0.1',
  publicBaseUrl: process.env.PUBLIC_BASE_URL || `http://127.0.0.1:${int(process.env.PORT, 8080)}`,
  databaseUrl: process.env.DATABASE_URL || 'postgres://d01i:d01i@127.0.0.1:5432/d01i_tweakz',
  db: {
    max: int(process.env.DB_POOL_MAX, 10),
    idleTimeoutMillis: int(process.env.DB_IDLE_TIMEOUT_MS, 30000),
    connectionTimeoutMillis: int(process.env.DB_CONNECT_TIMEOUT_MS, 5000),
  },
  security: {
    // "Pepper" do haszowania IP / HWID - losowy sekret serwera, nigdy nie wychodzi na zewnatrz.
    pepper: process.env.SECURITY_PEPPER || (() => {
      if (bool(process.env.ALLOW_EPHEMERAL_KEYS, false)) return 'dev-only-pepper-not-for-production';
      throw new Error('Brak SECURITY_PEPPER. Wygeneruj: openssl rand -hex 32');
    })(),
    tokenTtlSeconds: (() => {
      // D1: TTL tokena walidujemy przy starcie - cichy clamp byłby niebezpieczny.
      const ttl = int(process.env.TOKEN_TTL_SECONDS, 120);
      if (ttl < 30 || ttl > 120) {
        throw new Error(`TOKEN_TTL_SECONDS=${ttl} poza dozwolonym zakresem 30-120 s. Ustaw poprawna wartosc.`);
      }
      return ttl;
    })(),
    refreshReplayWindowSeconds: int(process.env.REFRESH_REPLAY_WINDOW_SECONDS, 60),
    adminSessionTtlHours: int(process.env.ADMIN_SESSION_TTL_HOURS, 8),
    maxDevicesDefault: int(process.env.MAX_DEVICES_DEFAULT, 2),
  },
  admin: {
    // R7: wymuszaj MFA dla wszystkich kont adminów (zalecane w produkcji: ADMIN_REQUIRE_MFA=true)
    mfaRequired: bool(process.env.ADMIN_REQUIRE_MFA, false),
    bootstrapEnabled: bool(process.env.ADMIN_BOOTSTRAP_ENABLED, false),
    bootstrapUsername: process.env.ADMIN_BOOTSTRAP_USERNAME || 'admin',
    bootstrapPassword: process.env.ADMIN_BOOTSTRAP_PASSWORD || '',
    cookieName: 'd01i_admin_session',
    csrfCookieName: 'd01i_csrf',
  },
  rateLimit: {
    windowMs: int(process.env.RATE_LIMIT_WINDOW_MS, 60_000),
    activateMax: int(process.env.RATE_LIMIT_ACTIVATE_MAX, 10),
    validateMax: int(process.env.RATE_LIMIT_VALIDATE_MAX, 120),
    loginMax: int(process.env.RATE_LIMIT_LOGIN_MAX, 5),
    adminApiMax: int(process.env.RATE_LIMIT_ADMIN_API_MAX, 120),
  },
  abuse: {
    failedKeyThreshold: int(process.env.ABUSE_FAILED_KEY_THRESHOLD, 10), // bledne klucze w oknie -> alert
    windowMinutes: int(process.env.ABUSE_WINDOW_MINUTES, 15),
    tempBlockMinutes: int(process.env.ABUSE_TEMP_BLOCK_MINUTES, 30),
  },
  discord: {
    enabled: bool(process.env.DISCORD_WEBHOOK_ENABLED, false),
    url: process.env.DISCORD_WEBHOOK_URL || '',
  },
  db: { migrationsUrl: process.env.MIGRATIONS_DATABASE_URL || null }, // R7: opcjonalny osobny użytkownik migracyjny
  secrets: {
    // R7: osobny pepper do HMAC hashy kluczy licencyjnych (NIE ten sam co SECURITY_PEPPER).
    // Fallback do SECURITY_PEPPER tylko dla kompatybilnosci; w produkcji ustaw LICENSE_KEY_PEPPER.
    licenseKeyPepper: process.env.LICENSE_KEY_PEPPER || process.env.SECURITY_PEPPER || (() => {
      if (bool(process.env.ALLOW_EPHEMERAL_KEYS, false)) return 'dev-only-pepper-not-for-production';
      throw new Error('Brak LICENSE_KEY_PEPPER. Wygeneruj: openssl rand -hex 32');
    })(),
    // B4: klucz szyfrowania sekretow w bazie (TOTP, webhook). Wymagany w produkcji.
    encKey: (() => {
      const v = process.env.SECRET_ENC_KEY;
      if (!v) {
        if (bool(process.env.ALLOW_EPHEMERAL_KEYS, false)) return randomBytes(32).toString('hex');
        throw new Error('Brak SECRET_ENC_KEY. Wygeneruj: openssl rand -hex 32');
      }
      // Walidacja formatu przy starcie: dokladnie 64 znaki HEX (32 bajty).
      if (!/^[0-9a-fA-F]{64}$/.test(v)) {
        throw new Error('SECRET_ENC_KEY musi byc 64-znakowa wartoscia HEX (32 bajty). Uzyj: openssl rand -hex 32');
      }
      return v.toLowerCase();
    })(),
  },
  keys: loadEd25519Keys(),
  isProduction: (process.env.NODE_ENV || 'development') === 'production',
};

export function safePublicConfig() {
  return {
    env: config.env,
    tokenTtlSeconds: config.security.tokenTtlSeconds,
    maxDevicesDefault: config.security.maxDevicesDefault,
    licenseTypes: ['DEMO', 'PREMIUM_30D', 'PREMIUM_90D', 'PREMIUM_LIFETIME'],
  };
}

export function resolvePath(p) {
  return path.resolve(process.cwd(), p);
}
