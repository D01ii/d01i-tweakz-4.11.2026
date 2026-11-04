import { config } from '../config/index.js';
import { query } from '../db/pool.js';
import { decryptSecret } from '../utils/secretCrypto.js';

/**
 * Opcjonalny kanal alertow Discord.
 * WYSYLANE SA WYLACZNIE zminimalizowane, pseudonimizowane dane:
 *  - nigdy pelne klucze licencyjne, tokeny, hasla ani surowe HWID
 *  - IP tylko jako przyciety hash, domyslnie w ogole nie wysylamy IP
 * Admin moze wylaczyc webhook w ustawieniach (tabela settings / DISCORD_WEBHOOK_ENABLED).
 */

async function getWebhookConfig() {
  try {
    const r = await query(`SELECT value FROM settings WHERE key = 'discord_webhook'`);
    if (r.rows.length) {
      const v = r.rows[0].value;
      // B4: URL webhooka może być zapisany zaszyfrowanie (enc:v1:...); odszyfrowujemy tylko do użycia.
      if (v && v.url) return { ...v, url: decryptSecret(v.url) };
      return v;
    }
  } catch {
    /* tabela moze nie istniec przed migracja */
  }
  return { enabled: config.discord.enabled, url: config.discord.url };
}

export async function sendDiscordAlert({ title, severity = 'medium', fields = {} }) {
  const cfg = await getWebhookConfig();
  if (!cfg || !cfg.enabled || !cfg.url) return false;
  if (!/^https:\/\/(discord\.com|discordapp\.com)\/api\/webhooks\//.test(cfg.url)) {
    console.error('[discord] odrzucono nieprawidlowy URL webhooka');
    return false;
  }
  const color = { low: 0x9e9e9e, medium: 0xffa000, high: 0xff5722, critical: 0xd50000 }[severity] || 0x9e9e9e;
  const cleanFields = Object.entries(fields)
    .filter(([, v]) => v !== null && v !== undefined && v !== '')
    .map(([name, value]) => ({ name, value: String(value).slice(0, 200), inline: true }));
  const body = {
    username: 'D01i Tweakz Security',
    embeds: [
      {
        title: String(title).slice(0, 200),
        color,
        fields: cleanFields,
        timestamp: new Date().toISOString(),
        footer: { text: 'D01i Tweakz - dane pseudonimizowane' },
      },
    ],
  };
  try {
    const res = await fetch(cfg.url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(5000),
    });
    return res.ok;
  } catch (err) {
    console.error('[discord] blad wysylania alertu:', err.message);
    return false;
  }
}
