/* D01i Tweakz - panel administratora (SPA, vanilla JS) */
(() => {
  'use strict';
  const view = document.getElementById('view');
  let csrfToken = null;
  let state = { tab: 'dashboard', search: '', licenseId: null };

  function toast(msg, isErr = false) {
    const t = document.getElementById('toast');
    t.textContent = msg;
    t.className = 'toast' + (isErr ? ' err' : '');
    setTimeout(() => t.classList.add('hidden'), 4200);
  }

  async function api(path, { method = 'GET', body } = {}) {
    const headers = { 'Content-Type': 'application/json' };
    if (csrfToken && method !== 'GET') headers['X-CSRF-Token'] = csrfToken;
    const res = await fetch(path, {
      method,
      headers,
      credentials: 'same-origin',
      body: body ? JSON.stringify(body) : undefined,
    });
    let data = null;
    try { data = await res.json(); } catch { /* brak JSON */ }
    if (res.status === 401 && path !== '/api/v1/admin/login' && path !== '/api/v1/admin/me') {
      return renderLogin();
    }
    if (!res.ok) {
      const err = new Error(data?.message || data?.error || `HTTP ${res.status}`);
      err.code = data?.error;
      throw err;
    }
    return data;
  }

  const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const dt = (s) => (s ? new Date(s).toLocaleString('pl-PL') : '—');

  // ------------------------- LOGIN -------------------------
  function renderLogin() {
    view.innerHTML = `
      <div class="login-wrap"><div class="login-box">
        <h1>D01i Tweakz</h1><div class="sub">Panel administratora</div>
        <label>Nazwa użytkownika</label><input id="lg-user" autocomplete="username">
        <label>Hasło</label><input id="lg-pass" type="password" autocomplete="current-password">
        <label id="lg-totp-lbl" class="hidden">Kod MFA (TOTP) lub kod odzyskiwania</label>
        <input id="lg-totp" class="hidden" inputmode="numeric" autocomplete="one-time-code">
        <div style="margin-top:16px"><button id="lg-btn" style="width:100%">Zaloguj się</button></div>
        <div id="lg-err" class="warn-box hidden" style="margin-top:12px"></div>
      </div></div>`;
    const btn = document.getElementById('lg-btn');
    const errBox = document.getElementById('lg-err');
    btn.onclick = async () => {
      errBox.classList.add('hidden');
      try {
        const mfaVal = document.getElementById('lg-totp').value.trim();
        const r = await api('/api/v1/admin/login', {
          method: 'POST',
          body: {
            username: document.getElementById('lg-user').value,
            password: document.getElementById('lg-pass').value,
            // B5: pole MFA przyjmuje kod TOTP (6 cyfr) LUB jednorazowy kod odzyskiwania.
            totp: /^\d{6}$/.test(mfaVal) ? mfaVal : undefined,
            recovery_code: mfaVal && !/^\d{6}$/.test(mfaVal) ? mfaVal : undefined,
          },
        });
        csrfToken = r.csrfToken;
        toast('Zalogowano.');
        renderShell();
      } catch (e) {
        errBox.textContent = e.message;
        errBox.classList.remove('hidden');
        if (e.code === 'TOTP_REQUIRED' || e.code === 'MFA_INVALID') {
          document.getElementById('lg-totp-lbl').classList.remove('hidden');
          document.getElementById('lg-totp').classList.remove('hidden');
          document.getElementById('lg-totp').focus();
        }
      }
    };
    document.getElementById('lg-pass').addEventListener('keydown', (e) => { if (e.key === 'Enter') btn.onclick(); });
  }

  // ------------------------- SHELL -------------------------
  const TABS = [
    ['dashboard', 'Dashboard'], ['licenses', 'Licencje'], ['audit', 'Audit'],
    ['abuse', 'Nadużycia'], ['settings', 'Ustawienia'], ['account', 'Konto'],
  ];
  async function renderShell() {
    view.innerHTML = `
      <div class="nav">
        <span class="brand">D01i Tweakz</span>
        ${TABS.map(([id, lbl]) => `<button data-tab="${id}" class="${state.tab === id ? 'active' : ''}">${lbl}</button>`).join('')}
        <span class="spacer"></span>
        <button id="btn-logout">Wyloguj</button>
      </div>
      <div class="content" id="content"></div>`;
    view.querySelectorAll('[data-tab]').forEach((b) => (b.onclick = () => { state.tab = b.dataset.tab; renderShell(); }));
    document.getElementById('btn-logout').onclick = async () => {
      try { await api('/api/v1/admin/logout', { method: 'POST' }); } catch {}
      csrfToken = null; renderLogin();
    };
    await renderTab();
  }

  async function renderTab() {
    const c = document.getElementById('content');
    try {
      if (state.tab === 'dashboard') return await renderDashboard(c);
      if (state.tab === 'licenses') return await renderLicenses(c);
      if (state.tab === 'audit') return await renderAudit(c);
      if (state.tab === 'abuse') return await renderAbuse(c);
      if (state.tab === 'settings') return await renderSettings(c);
      if (state.tab === 'account') return await renderAccount(c);
    } catch (e) { c.innerHTML = `<div class="warn-box">${esc(e.message)}</div>`; }
  }

  // ------------------------- DASHBOARD -------------------------
  async function renderDashboard(c) {
    const { stats } = await api('/api/v1/admin/ops/stats');
    c.innerHTML = `<h2>Dashboard</h2><div class="cards">
      ${card(stats.licenses_active, 'Aktywne licencje')}
      ${card(stats.licenses_revoked, 'Unieważnione')}
      ${card(stats.devices_active, 'Aktywne urządzenia')}
      ${card(stats.sessions_active, 'Aktywne sesje')}
      ${card(stats.activations_24h, 'Aktywacje 24h')}
      ${card(stats.abuse_open, 'Nadużycia 24h')}
      ${card(stats.admins, 'Administratorzy')}
    </div>`;
  }
  const card = (n, lbl) => `<div class="card"><div class="num">${n}</div><div class="lbl">${lbl}</div></div>`;

  // ------------------------- LICENSES -------------------------
  async function renderLicenses(c) {
    if (state.licenseId) return renderLicenseDetail(c);
    const { licenses, total } = await api(`/api/v1/admin/licenses?search=${encodeURIComponent(state.search)}`);
    c.innerHTML = `
      <h2>Licencje</h2>
      <div class="toolbar">
        <input id="q" placeholder="Szukaj (prefix klucza, typ, status)…" value="${esc(state.search)}">
        <button id="go">Szukaj</button>
        <button id="new">+ Nowa licencja</button>
        <span class="muted">${total} wyników</span>
      </div>
      <div class="panel"><table>
        <tr><th>Klucz</th><th>Typ</th><th>Status</th><th>Urządzenia</th><th>Wygasa</th><th>Utworzono</th><th></th></tr>
        ${licenses.map((l) => `<tr>
          <td class="mono">${esc(l.key_prefix)}…</td>
          <td><span class="badge ${esc(l.type)}">${esc(l.type)}</span></td>
          <td><span class="badge ${esc(l.status)}">${esc(l.status)}</span></td>
          <td>${l.active_devices}/${l.max_devices}</td>
          <td>${dt(l.expires_at)}</td>
          <td>${dt(l.created_at)}</td>
          <td><button class="secondary" data-id="${l.id}">Szczegóły</button></td>
        </tr>`).join('') || '<tr><td colspan="7" class="muted">Brak licencji.</td></tr>'}
      </table></div>`;
    document.getElementById('go').onclick = () => { state.search = document.getElementById('q').value; renderLicenses(c); };
    document.getElementById('new').onclick = () => showCreateModal();
    c.querySelectorAll('[data-id]').forEach((b) => (b.onclick = () => { state.licenseId = b.dataset.id; renderLicenses(c); }));
  }

  function showCreateModal() {
    const bg = document.createElement('div');
    bg.className = 'modal-bg';
    bg.innerHTML = `<div class="modal">
      <h2>Nowa licencja</h2>
      <label>Typ</label>
      <select id="m-type">
        <option value="DEMO">DEMO (7 dni)</option>
        <option value="PREMIUM_30D">PREMIUM 30D</option>
        <option value="PREMIUM_90D">PREMIUM 90D</option>
        <option value="PREMIUM_LIFETIME">PREMIUM LIFETIME</option>
      </select>
      <label>Limit urządzeń (reguła produktu: maks. 2)</label>
      <select id="m-dev"><option value="2">2</option><option value="1">1</option></select>
      <label>Notatka (opcjonalnie)</label>
      <input id="m-notes">
      <div class="row" style="margin-top:16px"><button id="m-ok">Wygeneruj klucz</button><button class="secondary" id="m-cancel">Anuluj</button></div>
      <div id="m-out"></div>
    </div>`;
    document.body.appendChild(bg);
    bg.querySelector('#m-cancel').onclick = () => bg.remove();
    bg.querySelector('#m-ok').onclick = async () => {
      try {
        const r = await api('/api/v1/admin/licenses', {
          method: 'POST',
          body: { type: bg.querySelector('#m-type').value, max_devices: parseInt(bg.querySelector('#m-dev').value, 10), notes: bg.querySelector('#m-notes').value || undefined },
        });
        bg.querySelector('#m-out').innerHTML = `
          <div class="key-display">${esc(r.key)}</div>
          <div class="warn-box">${esc(r.warning)}</div>`;
        toast('Licencja utworzona.');
        setTimeout(() => { bg.remove(); renderShell(); }, 4000);
      } catch (e) { toast(e.message, true); }
    };
  }

  async function renderLicenseDetail(c) {
    const { license, devices, history } = await api(`/api/v1/admin/licenses/${state.licenseId}`);
    c.innerHTML = `
      <div class="toolbar"><button id="back">← Licencje</button>
        <h2 style="margin:0">Licencja ${esc(license.key_prefix)}…</h2>
        <span class="badge ${esc(license.type)}">${esc(license.type)}</span>
        <span class="badge ${esc(license.status)}">${esc(license.status)}</span></div>
      <div class="panel"><div class="row">
        <span class="muted">Limit urządzeń: ${license.max_devices}</span>
        <span class="muted">Wygasa: ${dt(license.expires_at)}</span>
        ${license.status === 'ACTIVE' ? `
          <button class="danger" id="b-revoke">Unieważnij</button>
          <button id="b-extend">Przedłuż</button>
          <button class="secondary" id="b-reset">Reset urządzeń</button>` : ''}
      </div>
      ${license.revoke_reason ? `<div class="warn-box">Powód unieważnienia: ${esc(license.revoke_reason)}</div>` : ''}</div>
      <div class="panel"><h3>Urządzenia</h3><table>
        <tr><th>Install ID</th><th>Etykieta</th><th>Status</th><th>Pierwsze</th><th>Ostatnie</th><th></th></tr>
        ${devices.map((d) => `<tr>
          <td class="mono">${esc(d.install_id.slice(0, 12))}…</td><td>${esc(d.label || '—')}</td>
          <td>${d.active ? '<span class="badge ACTIVE">aktywne</span>' : '<span class="badge REVOKED">nieaktywne</span>'}</td>
          <td>${dt(d.first_seen_at)}</td><td>${dt(d.last_seen_at)}</td>
          <td>${d.active ? `<button class="secondary" data-dev="${d.id}">Dezaktywuj</button>` : ''}</td>
        </tr>`).join('') || '<tr><td colspan="6" class="muted">Brak urządzeń.</td></tr>'}
      </table></div>
      <div class="panel"><h3>Historia aktywacji</h3><table>
        <tr><th>Czas</th><th>Akcja</th><th>IP (hash)</th><th>Meta</th></tr>
        ${history.map((h) => `<tr><td>${dt(h.at)}</td><td>${esc(h.action)}</td><td class="mono">${esc((h.ip_hash || '').slice(0, 10))}…</td>
          <td><pre class="json">${esc(JSON.stringify(h.meta))}</pre></td></tr>`).join('') || '<tr><td colspan="4" class="muted">Brak historii.</td></tr>'}
      </table></div>`;
    c.querySelector('#back').onclick = () => { state.licenseId = null; renderLicenses(c); };
    c.querySelectorAll('[data-dev]').forEach((b) => (b.onclick = async () => {
      if (!confirm('Dezaktywować to urządzenie?')) return;
      try { await api(`/api/v1/admin/licenses/${state.licenseId}/devices/${b.dataset.dev}/deactivate`, { method: 'POST' }); toast('Dezaktywowano.'); renderLicenses(c); }
      catch (e) { toast(e.message, true); }
    }));
    const revoke = c.querySelector('#b-revoke');
    if (revoke) revoke.onclick = async () => {
      const reason = prompt('Powód unieważnienia:') || '';
      try { await api(`/api/v1/admin/licenses/${state.licenseId}/revoke`, { method: 'POST', body: { reason } }); toast('Unieważniono.'); renderLicenses(c); }
      catch (e) { toast(e.message, true); }
    };
    const ext = c.querySelector('#b-extend');
    if (ext) ext.onclick = async () => {
      const days = parseInt(prompt('O ile dni przedłużyć?', '30') || '0', 10);
      if (!days) return;
      try { await api(`/api/v1/admin/licenses/${state.licenseId}/extend`, { method: 'POST', body: { days } }); toast('Przedłużono.'); renderLicenses(c); }
      catch (e) { toast(e.message, true); }
    };
    const reset = c.querySelector('#b-reset');
    if (reset) reset.onclick = async () => {
      if (!confirm('Zresetować wszystkie urządzenia tej licencji?')) return;
      try { await api(`/api/v1/admin/licenses/${state.licenseId}/reset-devices`, { method: 'POST' }); toast('Zresetowano.'); renderLicenses(c); }
      catch (e) { toast(e.message, true); }
    };
  }

  // ------------------------- AUDIT -------------------------
  async function renderAudit(c) {
    const { logs } = await api('/api/v1/admin/ops/audit?limit=200');
    c.innerHTML = `<h2>Audit log</h2><div class="panel"><table>
      <tr><th>Czas</th><th>Aktant</th><th>Akcja</th><th>Cel</th><th>Poziom</th><th>Meta</th></tr>
      ${logs.map((l) => `<tr><td>${dt(l.at)}</td><td>${esc(l.actor_type)}${l.actor_id ? ' (' + esc(l.actor_id.slice(0, 8)) + '…)' : ''}</td>
        <td>${esc(l.action)}</td><td class="mono">${esc((l.target || '').slice(0, 12))}</td>
        <td><span class="badge ${esc(l.severity)}">${esc(l.severity)}</span></td>
        <td><pre class="json">${esc(JSON.stringify(l.meta))}</pre></td></tr>`).join('') || '<tr><td colspan="6" class="muted">Brak wpisów.</td></tr>'}
    </table></div>`;
  }

  // ------------------------- ABUSE -------------------------
  async function renderAbuse(c) {
    const [{ events }, { blocks }] = await Promise.all([
      api('/api/v1/admin/ops/abuse?limit=200'),
      api('/api/v1/admin/ops/blocks'),
    ]);
    c.innerHTML = `
      <h2>Wykryte nadużycia</h2>
      <div class="panel"><table>
        <tr><th>Czas</th><th>Rodzaj</th><th>Poziom</th><th>IP (hash)</th><th>Meta</th></tr>
        ${events.map((e) => `<tr><td>${dt(e.at)}</td><td>${esc(e.kind)}</td>
          <td><span class="badge ${esc(e.severity)}">${esc(e.severity)}</span></td>
          <td class="mono">${esc((e.ip_hash || '').slice(0, 10))}…</td>
          <td><pre class="json">${esc(JSON.stringify(e.meta))}</pre></td></tr>`).join('') || '<tr><td colspan="5" class="muted">Brak zdarzeń.</td></tr>'}
      </table></div>
      <h2>Blokady IP</h2>
      <div class="panel"><table>
        <tr><th>IP (hash)</th><th>Powód</th><th>Od</th><th>Do</th><th></th></tr>
        ${blocks.map((b) => `<tr><td class="mono">${esc(b.ip_hash.slice(0, 12))}…</td><td>${esc(b.reason)}</td>
          <td>${dt(b.blocked_at)}</td><td>${dt(b.until)}</td>
          <td>${!b.lifted ? `<button class="secondary" data-unblock="${esc(b.ip_hash)}">Odblokuj</button>` : '<span class="muted">cofnięta</span>'}</td></tr>`).join('') || '<tr><td colspan="5" class="muted">Brak blokad.</td></tr>'}
      </table></div>`;
    c.querySelectorAll('[data-unblock]').forEach((b) => (b.onclick = async () => {
      try { await api(`/api/v1/admin/ops/blocks/${b.dataset.unblock}/unblock`, { method: 'POST' }); toast('Odblokowano.'); renderAbuse(c); }
      catch (e) { toast(e.message, true); }
    }));
  }

  // ------------------------- SETTINGS -------------------------
  async function renderSettings(c) {
    const me = await api('/api/v1/admin/me').catch(() => null);
    const isSuper = me && me.role === 'superadmin';
    const [{ webhook }, adminsRes] = await Promise.all([
      api('/api/v1/admin/ops/settings/webhook'),
      // B6: /admin/admins wymaga roli superadmin - zwykły admin dostałby 403.
      isSuper ? api('/api/v1/admin/admins') : Promise.resolve(null),
    ]);
    const admins = adminsRes ? adminsRes.admins : [];
    c.innerHTML = `
      <h2>Ustawienia</h2>
      <div class="panel"><h3>Webhook Discord (alerty bezpieczeństwa)</h3>
        <p class="muted">Wysyłane są wyłącznie zminimalizowane, pseudonimizowane dane (bez pełnych kluczy, tokenów, haseł, surowych HWID i pełnych IP).</p>
        <label>Włączony: <input id="wh-en" type="checkbox" ${webhook.enabled ? 'checked' : ''} style="width:auto"></label>
        <label>URL webhooka ${webhook.configured ? '(ustawiony)' : ''}</label>
        <input id="wh-url" type="password" placeholder="https://discord.com/api/webhooks/…">
        <div style="margin-top:10px">${isSuper ? '<button id="wh-save">Zapisz webhook</button>' : '<span class="muted">Zapis webhooka wymaga roli superadmin.</span>'}</div>
      </div>
      ${isSuper ? `
      <div class="panel"><h3>Administratorzy</h3>
        <table><tr><th>Użytkownik</th><th>Rola</th><th>MFA</th><th>Status</th><th></th></tr>
        ${admins.map((a) => `<tr><td>${esc(a.username)}</td><td>${esc(a.role)}</td>
          <td>${a.totp_enabled ? 'włączone' : '—'}</td>
          <td>${a.is_active ? '<span class="badge ACTIVE">aktywny</span>' : '<span class="badge REVOKED">wyłączony</span>'}</td>
          <td>${a.is_active ? `<button class="secondary" data-dis="${a.id}">Wyłącz</button>` : `<button class="secondary" data-en="${a.id}">Włącz</button>`}</td></tr>`).join('')}
        </table>
        <h3 style="margin-top:16px">Nowy administrator</h3>
        <label>Nazwa</label><input id="na-user">
        <label>Hasło (min. 12 znaków)</label><input id="na-pass" type="password">
        <label>Rola</label><select id="na-role"><option value="admin">admin</option><option value="superadmin">superadmin</option></select>
        <div style="margin-top:10px"><button id="na-create">Utwórz administratora</button></div>
      </div>` : '<div class="panel muted">Zarządzanie administratorami i zapis webhooka są dostępne tylko dla superadmina.</div>'}`;
    if (c.querySelector('#wh-save')) c.querySelector('#wh-save').onclick = async () => {
      try {
        await api('/api/v1/admin/ops/settings/webhook', { method: 'POST', body: {
          enabled: c.querySelector('#wh-en').checked,
          url: c.querySelector('#wh-url').value || undefined,
        }});
        toast('Zapisano ustawienia webhooka.');
      } catch (e) { toast(e.message, true); }
    };
    if (c.querySelector('#na-create')) c.querySelector('#na-create').onclick = async () => {
      try {
        await api('/api/v1/admin/admins', { method: 'POST', body: {
          username: c.querySelector('#na-user').value,
          password: c.querySelector('#na-pass').value,
          role: c.querySelector('#na-role').value,
        }});
        toast('Utworzono administratora.'); renderSettings(c);
      } catch (e) { toast(e.message, true); }
    };
    c.querySelectorAll('[data-dis]').forEach((b) => (b.onclick = async () => {
      try { await api(`/api/v1/admin/admins/${b.dataset.dis}/disable`, { method: 'POST' }); renderSettings(c); } catch (e) { toast(e.message, true); }
    }));
    c.querySelectorAll('[data-en]').forEach((b) => (b.onclick = async () => {
      try { await api(`/api/v1/admin/admins/${b.dataset.en}/enable`, { method: 'POST' }); renderSettings(c); } catch (e) { toast(e.message, true); }
    }));
  }

  // ------------------------- ACCOUNT / MFA -------------------------
  async function renderAccount(c) {
    c.innerHTML = `
      <h2>Moje konto</h2>
      <div class="panel"><h3>MFA (TOTP)</h3>
        <p class="muted">Dwuetapowe uwierzytelnianie aplikacją typu Google Authenticator / Aegis.</p>
        <div class="row"><button id="mfa-setup">Skonfiguruj MFA</button></div>
        <div id="mfa-out"></div>
      </div>`;
    c.querySelector('#mfa-setup').onclick = async () => {
      try {
        const r = await api('/api/v1/admin/mfa/setup', { method: 'POST' });
        c.querySelector('#mfa-out').innerHTML = `
          <p>Skanuj lub wpisz sekret w aplikacji uwierzytelniającej:</p>
          <div class="key-display">${esc(r.secret)}</div>
          <p class="muted mono">${esc(r.otpauth)}</p>
          <label>Kod z aplikacji (6 cyfr)</label><input id="mfa-code" inputmode="numeric">
          <div style="margin-top:10px"><button id="mfa-en">Aktywuj MFA</button></div>
          <div id="mfa-rec"></div>`;
        c.querySelector('#mfa-en').onclick = async () => {
          try {
            const rr = await api('/api/v1/admin/mfa/enable', { method: 'POST', body: { code: c.querySelector('#mfa-code').value } });
            c.querySelector('#mfa-rec').innerHTML = `<p>Kody odzyskiwania (zapisz — pokazane tylko raz):</p><div class="key-display">${esc(rr.recovery_codes.join(' '))}</div>`;
            toast('MFA włączone.');
          } catch (e) { toast(e.message, true); }
        };
      } catch (e) { toast(e.message, true); }
    };
  }

  // ------------------------- BOOT -------------------------
  (async () => {
    try {
      const me = await api('/api/v1/admin/me');
      const csrf = await api('/api/v1/admin/csrf');
      csrfToken = csrf.csrfToken;
      renderShell();
    } catch { renderLogin(); }
  })();
})();
