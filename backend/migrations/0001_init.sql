-- D01i Tweakz - migracja bazowa
-- gen_random_uuid() jest wbudowany w PostgreSQL >= 13, pgcrypto nie jest wymagane.

-- ============================== ADMINISTRATORZY ==============================
CREATE TABLE IF NOT EXISTS admins (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  username        TEXT NOT NULL UNIQUE,               -- przechowywana malymi literami
  password_hash   TEXT NOT NULL,                -- Argon2id
  role            TEXT NOT NULL DEFAULT 'admin' CHECK (role IN ('admin','superadmin')),
  totp_secret     TEXT,                         -- TOTP (MFA), NULL = MFA wylaczone
  totp_enabled    BOOLEAN NOT NULL DEFAULT FALSE,
  recovery_codes  TEXT[],                       -- hashe kodow odzyskiwania
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  failed_logins   INTEGER NOT NULL DEFAULT 0,
  locked_until    TIMESTAMPTZ,
  last_login_at   TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS admin_sessions (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id      UUID NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
  token_hash    TEXT NOT NULL UNIQUE,           -- sha256 losowego tokena sesji
  csrf_token    TEXT NOT NULL,
  ip_hash       TEXT,
  user_agent    TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL,
  revoked       BOOLEAN NOT NULL DEFAULT FALSE,
  revoked_at    TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_admin_sessions_admin ON admin_sessions(admin_id);
CREATE INDEX IF NOT EXISTS idx_admin_sessions_expires ON admin_sessions(expires_at);

-- ============================== LICENCJE ==============================
CREATE TABLE IF NOT EXISTS licenses (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  key_hash      TEXT NOT NULL UNIQUE,           -- sha256 pelnego klucza; pelny klucz nie jest przechowywany
  key_prefix    TEXT NOT NULL,                  -- np. "D01I-AB12" - do identyfikacji w panelu (nie jest sekret).
  type          TEXT NOT NULL CHECK (type IN ('DEMO','PREMIUM_30D','PREMIUM_90D','PREMIUM_LIFETIME','REVOKED')),
  status        TEXT NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','REVOKED')),
  max_devices   INTEGER NOT NULL DEFAULT 2 CHECK (max_devices >= 1 AND max_devices <= 10),
  expires_at    TIMESTAMPTZ,                    -- NULL = bez wygasniecia (LIFETIME)
  created_by    UUID REFERENCES admins(id),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at    TIMESTAMPTZ,
  revoke_reason TEXT,
  notes         TEXT
);
CREATE INDEX IF NOT EXISTS idx_licenses_status ON licenses(status);
CREATE INDEX IF NOT EXISTS idx_licenses_type ON licenses(type);

-- ============================== URZADZENIA ==============================
CREATE TABLE IF NOT EXISTS devices (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  license_id    UUID NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
  install_id    TEXT NOT NULL,                  -- stabilny UUID instalacji klienta
  hwid_hash     TEXT NOT NULL,                  -- sha256(hwid + pepper); surowy HWID nie jest przechowywany
  label         TEXT,
  active        BOOLEAN NOT NULL DEFAULT TRUE,
  first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deactivated_at TIMESTAMPTZ,
  UNIQUE (license_id, install_id)
);
CREATE INDEX IF NOT EXISTS idx_devices_license ON devices(license_id);
CREATE INDEX IF NOT EXISTS idx_devices_active ON devices(license_id, active);

-- ============================== SESJE LICENCYJNE (tokeny) ==============================
CREATE TABLE IF NOT EXISTS license_sessions (
  jti           UUID PRIMARY KEY,               -- id tokena JWT-like
  license_id    UUID NOT NULL REFERENCES licenses(id) ON DELETE CASCADE,
  device_id     UUID NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
  issued_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL,
  revoked       BOOLEAN NOT NULL DEFAULT FALSE,
  revoked_at    TIMESTAMPTZ,
  revoke_reason TEXT,
  replaced_by   UUID REFERENCES license_sessions(jti)  -- rotacja tokena (refresh)
);
CREATE INDEX IF NOT EXISTS idx_sessions_license ON license_sessions(license_id);
CREATE INDEX IF NOT EXISTS idx_sessions_device ON license_sessions(device_id);
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON license_sessions(expires_at);

-- ============================== HISTORIA AKTYWACJI ==============================
CREATE TABLE IF NOT EXISTS activation_history (
  id          BIGSERIAL PRIMARY KEY,
  license_id  UUID REFERENCES licenses(id) ON DELETE SET NULL,
  device_id   UUID REFERENCES devices(id) ON DELETE SET NULL,
  action      TEXT NOT NULL CHECK (action IN ('ACTIVATE','DEACTIVATE','REACTIVATE','REVOKE_SESSION')),
  at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  ip_hash     TEXT,
  user_agent  TEXT,
  meta        JSONB
);
CREATE INDEX IF NOT EXISTS idx_activation_history_license ON activation_history(license_id, at DESC);

-- ============================== AUDIT LOG ==============================
CREATE TABLE IF NOT EXISTS audit_logs (
  id         BIGSERIAL PRIMARY KEY,
  actor_type TEXT NOT NULL CHECK (actor_type IN ('admin','system','client')),
  actor_id   TEXT,                            -- uuid admina lub 'system'
  action     TEXT NOT NULL,
  target     TEXT,
  ip_hash    TEXT,
  severity   TEXT NOT NULL DEFAULT 'info' CHECK (severity IN ('info','warning','critical')),
  meta       JSONB,
  at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_at ON audit_logs(at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_action ON audit_logs(action);

-- ============================== WYKRYWANIE NADUZYC / BLOKADY ==============================
CREATE TABLE IF NOT EXISTS abuse_events (
  id         BIGSERIAL PRIMARY KEY,
  kind       TEXT NOT NULL,                    -- np. FAILED_KEY, DEVICE_LIMIT, TOKEN_TAMPER, RATE_LIMIT
  severity   TEXT NOT NULL DEFAULT 'low' CHECK (severity IN ('low','medium','high','critical')),
  ip_hash    TEXT,
  key_hash   TEXT,
  install_id TEXT,
  meta       JSONB,
  at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved   BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_abuse_at ON abuse_events(at DESC);
CREATE INDEX IF NOT EXISTS idx_abuse_kind ON abuse_events(kind, at DESC);

CREATE TABLE IF NOT EXISTS ip_blocks (
  ip_hash    TEXT PRIMARY KEY,
  reason     TEXT NOT NULL,
  blocked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  until      TIMESTAMPTZ NOT NULL,
  by_admin   UUID REFERENCES admins(id),
  lifted     BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS idx_ip_blocks_until ON ip_blocks(until) WHERE NOT lifted;

-- ============================== USTAWIENIA SYSTEMOWE ==============================
CREATE TABLE IF NOT EXISTS settings (
  key        TEXT PRIMARY KEY,
  value      JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by UUID REFERENCES admins(id)
);

