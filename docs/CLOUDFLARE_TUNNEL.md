# Cloudflare Tunnel — wystawienie panelu i API na domenę

Cel: backend słucha tylko na `127.0.0.1:8080`; ruch z internetu idzie przez Cloudflare Tunnel
(szyfrowany, bez otwierania portów na VPS; UFW blokuje wszystko oprócz SSH).

## Kroki

1. W panelu Cloudflare (Zero Trust → Networks → Tunnels) utwórz tunnel i pobierz token
   (`cloudflared tunnel run --token ...`) LUB zainstaluj lokalnie:
   `curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /usr/local/bin/cloudflared && chmod +x /usr/local/bin/cloudflared`
2. `cloudflared tunnel login` (wygeneruje cert) lub użyj tokena z dashboardu.
3. Konfiguracja `/etc/cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /etc/cloudflared/<TUNNEL_ID>.json
ingress:
  - hostname: api.twojadomena.pl
    service: http://127.0.0.1:8080
  - service: http_status:404
```

4. DNS: rekord CNAME `api.twojadomena.pl` → `<TUNNEL_ID>.cfargotunnel.com` (proxy ON — pomarańczowa chmura).
5. `cloudflared service install` + `systemctl enable --now cloudflared`.
6. Opcjonalnie Cloudflare Access (Zero Trust → Access) — dodatkowe logowanie (np. SSO/email OTP)
   przed panelem admina `/admin/`.

## Uwagi bezpieczeństwa

- Backend ma `trust proxy=1` w produkcji, ale Caddy/Tunnel ustawia `X-Forwarded-For` —
  rate limiting używa realnego IP klienta.
- Nie wystawiaj portu 8080 publicznie (UFW: `ufw deny 8080` z zewnątrz).
- Panel admin tylko przez domenę z Access lub mocne MFA (`ADMIN_REQUIRE_MFA=true`).

## Weryfikacja

`curl -s https://api.twojadomena.pl/api/v1/config` → JSON konfigu; nagłówki odpowiedzi
powinny zawierać `Cache-Control: no-store` (R7) dla ścieżek `/api`.
