'use strict';
/* Encore NAS web admin: a small desktop-style UI for the DroboFS. No dependencies. */

// ---------------------------------------------------------------- helpers
const $ = (sel, el = document) => el.querySelector(sel);
const $$ = (sel, el = document) => [...el.querySelectorAll(sel)];

function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k === 'html') el.innerHTML = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) {
    if (kid == null || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

const fmt = {
  bytes(n, digits = 1) {
    if (n == null || isNaN(n)) return '–';
    const u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    let i = 0;
    while (Math.abs(n) >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return `${n.toFixed(i ? digits : 0)} ${u[i]}`;
  },
  rate(n) { return `${fmt.bytes(n)}/s`; },
  pct(x) { return `${Math.round(x * 100)}%`; },
  dur(sec) {
    sec = Math.floor(sec);
    const d = Math.floor(sec / 86400), hr = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
    return [d && `${d}d`, (d || hr) && `${hr}h`, `${m}m`].filter(Boolean).join(' ');
  },
  date(t) { return t ? new Date(t * 1000).toLocaleString() : '–'; },
};

function toast(msg, isErr) {
  const t = h('div', { class: 'toast' + (isErr ? ' err' : '') }, msg);
  $('#toasts').append(t);
  setTimeout(() => t.remove(), isErr ? 7000 : 3500);
}

// ---------------------------------------------------------------- API
async function call(method, path, body) {
  const opts = { method, credentials: 'same-origin', headers: {} };
  if (method !== 'GET') opts.headers['X-Encore'] = '1';
  if (body !== undefined) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  let res;
  try {
    res = await fetch('api/' + path, opts);
    $('#tb-status')?.classList.remove('down');
  } catch (e) {
    $('#tb-status')?.classList.add('down');
    throw new Error('Cannot reach the Drobo');
  }
  let data = {};
  try { data = await res.json(); } catch { /* empty body */ }
  if (res.status === 401 && path !== 'login') { showLogin(); throw new Error('Signed out'); }
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}
const api = {
  get: p => call('GET', p),
  post: (p, b) => call('POST', p, b ?? {}),
  put: (p, b) => call('PUT', p, b ?? {}),
};

// ---------------------------------------------------------------- icons
const GLYPH = {
  info: '<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"/><rect x="11" y="10" width="2" height="7" rx="1" fill="currentColor"/><circle cx="12" cy="7" r="1.3" fill="currentColor"/>',
  control: '<path fill="currentColor" d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7Zm8.4 5-1.9-.3a6.9 6.9 0 0 1-.6 1.5l1.1 1.6-1.6 1.6-1.6-1.1c-.5.3-1 .5-1.5.6l-.3 1.9h-2.2l-.3-1.9a6.9 6.9 0 0 1-1.5-.6l-1.6 1.1-1.6-1.6 1.1-1.6c-.3-.5-.5-1-.6-1.5l-1.9-.3v-2.2l1.9-.3c.1-.5.3-1 .6-1.5L5.1 7.1l1.6-1.6 1.6 1.1c.5-.3 1-.5 1.5-.6l.3-1.9h2.2l.3 1.9c.5.1 1 .3 1.5.6l1.6-1.1 1.6 1.6-1.1 1.6c.3.5.5 1 .6 1.5l1.9.3v2.2Z"/>',
  storage: '<rect x="4" y="4" width="16" height="6" rx="2" fill="currentColor"/><rect x="4" y="14" width="16" height="6" rx="2" fill="currentColor" opacity=".75"/><circle cx="16.5" cy="7" r="1.2" fill="#fff"/><circle cx="16.5" cy="17" r="1.2" fill="#fff"/>',
  monitor: '<path d="M3 13h4l2-6 4 11 2-5h6" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>',
  logs: '<rect x="5" y="3" width="14" height="18" rx="2" fill="none" stroke="currentColor" stroke-width="2"/><path d="M8 8h8M8 12h8M8 16h5" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
  help: '<circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"/><path d="M9.5 9.5a2.6 2.6 0 1 1 3.6 2.4c-.7.3-1.1.9-1.1 1.6v.5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="17" r="1.2" fill="currentColor"/>',
  smb: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7Z" fill="currentColor"/><path d="M8 13h8" stroke="#fff" stroke-width="1.8" stroke-linecap="round"/>',
  share: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7Z" fill="currentColor"/>',
  users: '<circle cx="9" cy="9" r="3.2" fill="currentColor"/><path d="M3 19c.8-3.4 3.2-5 6-5s5.2 1.6 6 5" fill="currentColor"/><circle cx="17" cy="8" r="2.5" fill="currentColor" opacity=".7"/><path d="M15.5 13.2c2.6-.4 4.8 1 5.5 4.3" fill="none" stroke="currentColor" stroke-width="1.8" opacity=".7"/>',
  network: '<circle cx="12" cy="5" r="2.2" fill="currentColor"/><circle cx="5" cy="18" r="2.2" fill="currentColor"/><circle cx="19" cy="18" r="2.2" fill="currentColor"/><path d="M12 7v5M12 12l-6 5M12 12l6 5" stroke="currentColor" stroke-width="2"/>',
  shield: '<path d="M12 3 4.5 6v5.5c0 4.6 3.2 8.2 7.5 9.5 4.3-1.3 7.5-4.9 7.5-9.5V6L12 3Z" fill="currentColor"/><path d="m9 12 2.2 2.2L15.5 10" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
  clock: '<circle cx="12" cy="12" r="8.5" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 7.5V12l3 2" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"/>',
  mail: '<rect x="3" y="5" width="18" height="14" rx="2" fill="currentColor"/><path d="m4 7 8 6 8-6" fill="none" stroke="#fff" stroke-width="1.8" stroke-linejoin="round"/>',
  apple: '<path fill="currentColor" d="M16.4 12.6c0-2.3 1.9-3.4 2-3.5-1.1-1.6-2.8-1.8-3.4-1.8-1.4-.2-2.8.8-3.5.8-.7 0-1.9-.8-3.1-.8-1.6 0-3 .9-3.8 2.3-1.6 2.8-.4 7 1.2 9.3.8 1.1 1.7 2.4 2.9 2.3 1.2 0 1.6-.7 3-.7s1.8.7 3 .7c1.3 0 2.1-1.1 2.8-2.3.9-1.3 1.3-2.6 1.3-2.6s-2.4-1-2.4-3.7ZM14.2 5.8c.6-.8 1.1-1.9 1-3-.9 0-2.1.6-2.7 1.4-.6.7-1.1 1.8-1 2.9 1 .1 2.1-.5 2.7-1.3Z"/>',
};
function icon(name, color) {
  return h('span', { class: 'ico', style: { background: color }, html: `<svg viewBox="0 0 24 24">${GLYPH[name] || ''}</svg>` });
}
const CTL = {
  min: '<svg viewBox="0 0 14 14"><path d="M2 10h10" stroke="currentColor" stroke-width="1.6"/></svg>',
  max: '<svg viewBox="0 0 14 14"><rect x="2.5" y="2.5" width="9" height="9" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.5"/></svg>',
  close: '<svg viewBox="0 0 14 14"><path d="m3 3 8 8M11 3l-8 8" stroke="currentColor" stroke-width="1.6"/></svg>',
};

// ---------------------------------------------------------------- window manager
const WM = {
  wins: new Map(), z: 10, offset: 0,

  open(appId) {
    const app = APPS.find(a => a.id === appId);
    if (!app) return;
    const existing = this.wins.get(appId);
    if (existing) { this.restore(appId); return; }

    const ws = $('#workspace');
    // Keep new windows clear of the desktop icon column (and the widgets when there's room).
    const ICONS_W = 120, WIDGETS_W = ws.clientWidth >= 1400 ? 320 : 0;
    const W = Math.min(app.w || 860, ws.clientWidth - ICONS_W - WIDGETS_W - 20);
    const H = Math.min(app.h || 560, ws.clientHeight - 30);
    const free = ws.clientWidth - ICONS_W - WIDGETS_W;
    const left = ICONS_W + Math.max(0, Math.round((free - W) / 2)) + this.offset;
    const top = Math.max(10, Math.round((ws.clientHeight - H) / 3) + this.offset);
    this.offset = (this.offset + 26) % 130;

    const body = h('div', { class: 'win-body' });
    const el = h('section', { class: 'win', role: 'dialog', 'aria-label': app.title, style: { left: left + 'px', top: top + 'px', width: W + 'px', height: H + 'px' } },
      h('div', { class: 'win-title' },
        icon(app.icon, app.color),
        h('h2', {}, app.title),
        h('button', { class: 'win-ctl', title: 'Minimize', html: CTL.min, onclick: e => { e.stopPropagation(); this.minimize(appId); } }),
        h('button', { class: 'win-ctl', title: 'Maximize', html: CTL.max, onclick: e => { e.stopPropagation(); el.classList.toggle('maximized'); } }),
        h('button', { class: 'win-ctl close', title: 'Close', html: CTL.close, onclick: e => { e.stopPropagation(); this.close(appId); } })),
      body);
    ws.append(el);

    const tb = h('button', { class: 'tb-btn tb-win', title: app.title, onclick: () => {
      const w = this.wins.get(appId);
      if (w.minimized) this.restore(appId);
      else if (w.el.style.zIndex == this.z) this.minimize(appId);
      else this.focus(appId);
    } }, icon(app.icon, app.color), h('span', { class: 't' }, app.title));
    $('#tb-windows').append(tb);

    const win = { el, tb, body, minimized: false, dispose: null };
    this.wins.set(appId, win);
    this.drag(el, $('.win-title', el));
    el.addEventListener('mousedown', () => this.focus(appId));
    $('.win-title', el).addEventListener('dblclick', () => el.classList.toggle('maximized'));
    this.focus(appId);
    try { win.dispose = app.render(body, win) || null; }
    catch (e) { body.append(h('p', { class: 'empty' }, 'Failed to open: ' + e.message)); }
  },

  focus(appId) {
    for (const [id, w] of this.wins) {
      w.el.classList.toggle('inactive', id !== appId);
      w.tb.classList.toggle('active', id === appId);
    }
    const w = this.wins.get(appId);
    if (w) w.el.style.zIndex = ++this.z;
  },
  minimize(appId) {
    const w = this.wins.get(appId);
    w.minimized = true; w.el.hidden = true; w.tb.classList.add('minimized'); w.tb.classList.remove('active');
  },
  restore(appId) {
    const w = this.wins.get(appId);
    w.minimized = false; w.el.hidden = false; w.tb.classList.remove('minimized');
    this.focus(appId);
  },
  close(appId) {
    const w = this.wins.get(appId);
    if (!w) return;
    if (typeof w.dispose === 'function') w.dispose();
    w.el.remove(); w.tb.remove();
    this.wins.delete(appId);
  },
  closeAll() { for (const id of [...this.wins.keys()]) this.close(id); },

  drag(el, handle) {
    handle.addEventListener('pointerdown', e => {
      if (e.target.closest('button') || el.classList.contains('maximized') || window.innerWidth <= 820) return;
      const sx = e.clientX - el.offsetLeft, sy = e.clientY - el.offsetTop;
      const ws = $('#workspace');
      handle.setPointerCapture(e.pointerId);
      const move = ev => {
        el.style.left = Math.min(Math.max(ev.clientX - sx, -el.offsetWidth + 80), ws.clientWidth - 80) + 'px';
        el.style.top = Math.min(Math.max(ev.clientY - sy, 0), ws.clientHeight - 40) + 'px';
      };
      const up = () => { handle.removeEventListener('pointermove', move); handle.removeEventListener('pointerup', up); };
      handle.addEventListener('pointermove', move);
      handle.addEventListener('pointerup', up);
    });
  },
};

// ---------------------------------------------------------------- shared UI bits
function loading(el) { el.replaceChildren(h('div', { class: 'spinner' })); }
function errorBox(el, e) { el.replaceChildren(h('p', { class: 'empty' }, e.message || String(e))); }

function bar(frac) {
  const cls = frac > .92 ? 'bad' : frac > .8 ? 'warn' : '';
  return h('div', { class: 'bar ' + cls }, h('i', { style: { width: Math.min(100, frac * 100).toFixed(1) + '%' } }));
}

function ring(frac, label, sub) {
  const r = 46, c = 2 * Math.PI * r, f = Math.max(0, Math.min(1, frac || 0));
  const color = f > .92 ? 'var(--bad)' : f > .8 ? 'var(--warn)' : 'var(--accent)';
  return h('div', { class: 'gauge' },
    h('div', { html: `<svg viewBox="0 0 120 120"><circle cx="60" cy="60" r="${r}" fill="none" stroke="var(--surface-3)" stroke-width="12"/>` +
      `<circle cx="60" cy="60" r="${r}" fill="none" stroke="${color}" stroke-width="12" stroke-linecap="round" stroke-dasharray="${c * f} ${c}" transform="rotate(-90 60 60)"/>` +
      `<text x="60" y="66" text-anchor="middle" font-size="22" font-weight="700" fill="var(--text)">${Math.round(f * 100)}%</text></svg>` }),
    h('div', {}, h('b', {}, label)), h('div', { class: 'lbl' }, sub || ''));
}

function sidebarApp(body, sections, initial) {
  const content = h('div', { class: 'content' });
  const side = h('nav', { class: 'side' });
  let dispose = null;
  const show = id => {
    if (typeof dispose === 'function') dispose();
    dispose = null;
    $$('button', side).forEach(b => b.classList.toggle('active', b.dataset.id === id));
    const s = sections.find(x => x.id === id);
    content.replaceChildren();
    content.scrollTop = 0;
    dispose = s.render(content) || null;
  };
  for (const s of sections) {
    side.append(h('button', { 'data-id': s.id, onclick: () => show(s.id) }, icon(s.icon, s.color), h('span', { class: 'lbl' }, s.title)));
  }
  body.append(h('div', { class: 'split' }, side, content));
  show(initial || sections[0].id);
  return () => { if (typeof dispose === 'function') dispose(); };
}

function modal(host, title, buildBody, onSave, saveLabel) {
  const back = h('div', { class: 'modal-back' });
  const err = h('p', { class: 'login-error' });
  const form = h('form', { class: 'modal' }, h('h4', {}, title));
  buildBody(form);
  const save = h('button', { class: 'btn ' + (/delete/i.test(saveLabel || '') ? 'danger' : 'primary'), type: 'submit' }, saveLabel || 'Save');
  form.append(err, h('div', { class: 'actions' }, h('button', { class: 'btn', type: 'button', onclick: () => back.remove() }, 'Cancel'), save));
  form.addEventListener('submit', async e => {
    e.preventDefault();
    save.disabled = true; err.textContent = '';
    try { await onSave(new FormData(form), form); back.remove(); }
    catch (ex) { err.textContent = ex.message; save.disabled = false; }
  });
  back.append(form);
  back.addEventListener('mousedown', e => { if (e.target === back) back.remove(); });
  host.closest('.win').append(back);
  $('input,select', form)?.focus();
}

const select = (name, value, options) =>
  h('select', { name }, options.map(([v, label]) => h('option', { value: v, selected: v === value }, label)));
const checkbox = (name, checked, label, help) =>
  h('label', { class: 'check' }, h('input', { type: 'checkbox', name, checked }), h('span', {}, label, help && h('small', {}, help)));
const field = (label, input, help) => h('label', { class: 'field' }, label, input, help && h('div', { class: 'help' }, help));

// ---------------------------------------------------------------- apps
const PROTO = [['NT1', 'SMB1 (insecure, legacy devices only)'], ['SMB2_02', 'SMB 2.0'], ['SMB2_10', 'SMB 2.1'], ['SMB3_00', 'SMB 3.0'], ['SMB3_11', 'SMB 3.1.1']];
const PROTO_MAX = [['SMB2_10', 'SMB 2.1'], ['SMB3_00', 'SMB 3.0'], ['SMB3_02', 'SMB 3.0.2'], ['SMB3_11', 'SMB 3.1.1'], ['SMB3', 'Latest SMB 3']];
const ENCRYPT = [['off', 'Off'], ['if_required', 'If the client asks (recommended)'], ['desired', 'Preferred'], ['required', 'Required (SMB3 clients only)']];
const SIGNING = [['default', 'Default'], ['desired', 'Preferred'], ['required', 'Required']];

function renderOverview(body) {
  loading(body);
  let timer;
  const load = async () => {
    try {
      const o = await api.get('overview');
      const memUsed = o.memory.total ? 1 - o.memory.free / o.memory.total : 0;
      const vol = o.volume;
      const notices = [];
      if (o.warnings.root_default_password) notices.push(h('div', { class: 'notice warn' }, h('b', {}, 'The root password is still the factory default. '), 'Anyone on your network can sign in to this page and over SSH. Change it from an SSH session with ', h('code', {}, 'passwd'), '.'));
      if (o.samba.mode === 'stock') notices.push(h('div', { class: 'notice info' }, 'File sharing is running the original Samba 3.4 (SMB1 only). Turn on Samba 4 in Control Panel → File Services.'));
      if (o.warnings.smb1_enabled) notices.push(h('div', { class: 'notice warn' }, 'SMB1 is allowed. Only keep it if you have devices that cannot use SMB2 or later.'));
      body.replaceChildren(h('div', { class: 'content' },
        ...notices,
        h('div', { class: 'gauges card' },
          ring(memUsed, 'Memory', `${fmt.bytes(o.memory.total - o.memory.free)} of ${fmt.bytes(o.memory.total)}`),
          vol ? ring(vol.used / vol.total, 'Volume', `${fmt.bytes(vol.free)} free of ${fmt.bytes(vol.total)}`) : h('div', { class: 'empty' }, 'Volume not mounted'),
          h('div', { class: 'gauge' }, h('div', { style: { fontSize: '30px', fontWeight: 700, padding: '30px 0 18px' } }, o.connections), h('b', {}, 'SMB sessions'), h('div', { class: 'lbl' }, 'connected right now'))),
        h('div', { class: 'grid2' },
          h('div', { class: 'card' }, h('h4', {}, 'System'), h('dl', { class: 'kv' },
            h('dt', {}, 'Name'), h('dd', {}, o.hostname),
            h('dt', {}, 'Model'), h('dd', {}, o.model),
            h('dt', {}, 'Processor'), h('dd', {}, o.cpu || '–'),
            h('dt', {}, 'Kernel'), h('dd', {}, o.kernel || '–'),
            h('dt', {}, 'Uptime'), h('dd', {}, fmt.dur(o.uptime)),
            h('dt', {}, 'Load average'), h('dd', {}, o.load || '–'))),
          h('div', { class: 'card' }, h('h4', {}, 'File sharing'), h('dl', { class: 'kv' },
            h('dt', {}, 'Engine'), h('dd', {}, o.samba.mode === 'encore' ? h('span', { class: 'pill ok' }, 'Samba 4') : o.samba.mode === 'stock' ? h('span', { class: 'pill warn' }, 'Stock Samba 3.4') : h('span', { class: 'pill bad' }, 'Stopped')),
            h('dt', {}, 'Samba version'), h('dd', {}, o.samba.version || '–'),
            h('dt', {}, 'Protocols'), h('dd', {}, `${o.samba.min} → ${o.samba.max}`),
            h('dt', {}, 'Encryption'), h('dd', {}, (ENCRYPT.find(e => e[0] === o.samba.encrypt) || [, o.samba.encrypt])[1])))),
        h('div', { class: 'card' }, h('h4', {}, 'Services'),
          h('table', { class: 'tbl' }, h('tbody', {}, o.services.map(s =>
            h('tr', {}, h('td', {}, h('span', { class: 'dot ' + (s.running ? 'ok' : 'bad') }), s.name), h('td', {}, s.running ? 'Running' : 'Stopped')))))),
        h('div', { class: 'card' }, h('h4', {}, 'Network'),
          h('table', { class: 'tbl' }, h('thead', {}, h('tr', {}, h('th', {}, 'Interface'), h('th', {}, 'Address'), h('th', {}, 'MAC'), h('th', {}, 'MTU'))),
            h('tbody', {}, o.interfaces.map(i => h('tr', {}, h('td', {}, i.name), h('td', {}, i.ip ? `${i.ip} / ${i.mask}` : '–'), h('td', {}, i.mac || '–'), h('td', {}, i.mtu || '–'))))))));
    } catch (e) { errorBox(body, e); }
  };
  load();
  timer = setInterval(load, 15000);
  return () => clearInterval(timer);
}

// ---- Control Panel sections
function cpFileServices(el) {
  el.append(h('h3', {}, 'File Services'), h('p', { class: 'lead' }, 'SMB file sharing for Windows, macOS and Linux.'));
  const box = h('div'); el.append(box); loading(box);
  (async () => {
    try {
      const [{ settings: s }, o] = await Promise.all([api.get('settings'), api.get('overview')]);
      const mode = o.samba.mode;
      const engine = h('div', { class: 'card' }, h('h4', {}, 'SMB engine'),
        h('p', {}, mode === 'encore' ? h('span', { class: 'pill ok' }, `Samba ${o.samba.version}`) : mode === 'stock' ? h('span', { class: 'pill warn' }, 'Stock Samba 3.4 (SMB1 only)') : h('span', { class: 'pill bad' }, 'Stopped'),
          ' ', mode === 'encore' ? 'SMB2 and SMB3 are available.' : 'Switch to Samba 4 for SMB2/SMB3, encryption and Time Machine.'),
        h('div', { class: 'actions', style: { justifyContent: 'flex-start' } },
          mode !== 'encore' && h('button', { class: 'btn primary', onclick: e => sambaAction(e.target, 'encore') }, 'Use Samba 4'),
          mode === 'encore' && h('button', { class: 'btn', onclick: e => sambaAction(e.target, 'restart') }, 'Restart'),
          mode === 'encore' && h('button', { class: 'btn danger', onclick: e => sambaAction(e.target, 'stock') }, 'Revert to stock Samba')));

      const form = h('form', { class: 'card' }, h('h4', {}, 'SMB settings'),
        h('div', { class: 'grid2' },
          field('Minimum protocol', select('SMB_MIN_PROTOCOL', s.SMB_MIN_PROTOCOL, PROTO), 'Clients older than this cannot connect.'),
          field('Maximum protocol', select('SMB_MAX_PROTOCOL', s.SMB_MAX_PROTOCOL, PROTO_MAX)),
          field('Transport encryption', select('SMB_ENCRYPT', s.SMB_ENCRYPT, ENCRYPT), 'Encryption costs throughput on this CPU. You can also require it per shared folder.'),
          field('Signing', select('SMB_SIGNING', s.SMB_SIGNING, SIGNING), 'Windows 11 24H2 requires signing by default.'),
          field('Log level', select('SMB_LOG_LEVEL', s.SMB_LOG_LEVEL, [['0', '0 – errors'], ['1', '1 – normal'], ['2', '2 – verbose'], ['3', '3 – debug']]))),
        checkbox('SMB_MACOS', s.SMB_MACOS === '1', 'Enhanced macOS support', 'Finder metadata, resource forks and Time Machine over SMB (vfs_fruit).'),
        checkbox('SMB_NETBIOS', s.SMB_NETBIOS === '1', 'NetBIOS name service', 'Lets older Windows PCs find the Drobo by name. Uses ports 137–139.'),
        h('div', { class: 'actions' }, h('button', { class: 'btn primary', type: 'submit' }, 'Apply')));
      form.addEventListener('submit', async e => {
        e.preventDefault();
        const fd = new FormData(form);
        const body = Object.fromEntries(['SMB_MIN_PROTOCOL', 'SMB_MAX_PROTOCOL', 'SMB_ENCRYPT', 'SMB_SIGNING', 'SMB_LOG_LEVEL'].map(k => [k, fd.get(k)]));
        body.SMB_MACOS = fd.get('SMB_MACOS') ? '1' : '0';
        body.SMB_NETBIOS = fd.get('SMB_NETBIOS') ? '1' : '0';
        const btn = $('button[type=submit]', form); btn.disabled = true;
        try { await api.put('settings', body); toast('SMB settings applied'); }
        catch (ex) { toast(ex.message, true); }
        btn.disabled = false;
      });

      const conf = h('pre', { class: 'code' }, 'Loading…');
      const details = h('details', { class: 'card', ontoggle: async () => {
        if (!details.open) return;
        try { const c = await api.get('smbconf'); conf.textContent = c.generated || '(not generated yet)'; }
        catch (ex) { conf.textContent = ex.message; }
      } }, h('summary', {}, h('b', {}, 'Generated smb.conf')), h('p', { class: 'lead', style: { margin: '10px 0' } }, 'Built from Drobo Dashboard\'s share list plus the settings above.'), conf);

      box.replaceChildren(engine, form, details);
    } catch (e) { errorBox(box, e); }
  })();

  async function sambaAction(btn, action) {
    if (action === 'stock' && !confirm('Switch file sharing back to the original Samba 3.4? Clients will reconnect using SMB1.')) return;
    btn.disabled = true;
    try { await api.post('samba', { action }); toast(action === 'restart' ? 'Samba restarted' : action === 'encore' ? 'Samba 4 is now serving files' : 'Stock Samba restored'); }
    catch (e) { toast(e.message, true); }
    el.replaceChildren(); cpFileServices(el);
  }
}

// ---- Drobo management (users, shares, network, alerts) through nasd jobs
let droboCache = null;
async function loadDrobo(force) {
  if (!droboCache || force) droboCache = await api.get('drobo');
  return droboCache;
}

// Run a management change as a background job and show progress until nasd is done.
function runJob(host, label, payload) {
  return new Promise((resolve, reject) => {
    const back = h('div', { class: 'modal-back' });
    const msg = h('p', { class: 'lead', style: { margin: '6px 0 0' } }, 'The Drobo is applying the change. File sharing restarts briefly; this usually takes 1–3 minutes.');
    const elapsed = h('span', { class: 'pill' }, '0:00');
    back.append(h('div', { class: 'modal' }, h('h4', {}, label), h('div', { class: 'spinner', style: { margin: '18px auto' } }), h('div', { style: { textAlign: 'center' } }, elapsed), msg));
    host.closest('.win').append(back);
    const t0 = Date.now();
    const tick = setInterval(() => { const s = Math.round((Date.now() - t0) / 1000); elapsed.textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`; }, 1000);
    const finish = (err) => { clearInterval(tick); back.remove(); droboCache = null; err ? reject(err) : resolve(); };
    api.post('drobo/job', { ...payload, label }).then(({ job }) => {
      const poll = async () => {
        try {
          const st = await api.get('job/' + job);
          if (st.state === 'done') return finish();
          if (st.state === 'error') return finish(new Error(st.message || 'The Drobo could not apply the change'));
        } catch (e) { /* transient while Samba restarts */ }
        setTimeout(poll, 3000);
      };
      setTimeout(poll, 3000);
    }).catch(finish);
  });
}

const ACCESS = [['none', 'No access'], ['ro', 'Read only'], ['rw', 'Read & write']];

function cpShares(el) {
  el.append(h('div', { class: 'toolbar', style: { justifyContent: 'space-between' } },
    h('div', {}, h('h3', {}, 'Shared Folders'), h('p', { class: 'lead', style: { margin: 0 } }, 'Folders on the Drobo that computers on your network can open.')),
    h('button', { class: 'btn primary', onclick: () => edit(null) }, 'Create')));
  const box = h('div'); el.append(box); loading(box);
  let data;
  const load = async (force) => {
    try {
      data = await loadDrobo(force);
      if (!data.shares.length) { box.replaceChildren(h('p', { class: 'empty' }, 'No shared folders yet.')); return; }
      box.replaceChildren(h('table', { class: 'tbl' },
        h('thead', {}, h('tr', {}, h('th', {}, 'Name'), h('th', {}, 'Who can access'), h('th', {}, 'Options'))),
        h('tbody', {}, data.shares.map(s => h('tr', { class: 'click', onclick: () => edit(s) },
          h('td', {}, h('b', {}, s.name)),
          h('td', {}, s.access.map(a => h('span', { class: 'pill ' + (a.user === 'Everyone' ? 'warn' : ''), style: { marginRight: '4px' } }, `${a.user}: ${a.access === 'rw' ? 'read & write' : 'read only'}`))),
          h('td', {},
            s.timemachine && h('span', { class: 'pill accent' }, 'Time Machine'), ' ',
            s.recycle && h('span', { class: 'pill' }, 'Recycle bin'), ' ',
            s.hidden && h('span', { class: 'pill' }, 'Hidden'), ' ',
            s.encrypt !== 'default' && h('span', { class: 'pill ok' }, 'Encrypt: ' + s.encrypt)))))));
    } catch (e) { errorBox(box, e); }
  };

  const edit = s => {
    const isNew = !s;
    s = s || { name: '', access: [{ user: 'Everyone', access: 'rw' }], timemachine: false, tm_max_gb: 0, recycle: false, hidden: false, encrypt: 'default' };
    const people = ['Everyone', data.admin.username || 'Admin', ...data.users.map(u => u.name)];
    const cur = Object.fromEntries(s.access.map(a => [a.user.toLowerCase(), a.access]));
    modal(el, isNew ? 'Create shared folder' : `Shared folder “${s.name}”`, f => {
      f.append(
        field('Name', h('input', { name: 'name', value: s.name, required: true, maxlength: 64, placeholder: 'e.g. Photos' }),
          isNew ? null : 'Renaming moves the folder on the Drobo. Computers will need to reconnect.'),
        h('div', { class: 'field' }, h('b', {}, 'Permissions'),
          h('table', { class: 'tbl', style: { marginTop: '6px' } }, h('tbody', {}, people.map(p =>
            h('tr', {}, h('td', {}, p === 'Everyone' ? h('span', {}, 'Everyone ', h('small', { style: { color: 'var(--muted)' } }, '(guests, no password)')) : p),
              h('td', { style: { width: '50%' } }, select('acc:' + p, cur[p.toLowerCase()] || 'none', ACCESS))))))),
        checkbox('timemachine', s.timemachine, 'Time Machine backup destination', 'Macs can back up here over SMB (and AFP).'),
        field('Time Machine size limit (GB)', h('input', { name: 'tm_max_gb', type: 'number', min: 0, step: 1, value: Math.round(s.tm_max_gb || 0) }), '0 means no limit.'),
        checkbox('recycle', s.recycle, 'Recycle bin', 'Deleted files go to a #recycle folder in the share.'),
        checkbox('hidden', s.hidden, 'Hide from network browsing'),
        field('Encryption', select('encrypt', s.encrypt, [['default', 'Use the File Services setting'], ...ENCRYPT])));
      if (!isNew) {
        f.append(h('div', { class: 'notice warn', style: { marginTop: '6px' } },
          h('b', {}, 'Delete this shared folder'), h('br'),
          'Deleting removes the folder ', h('b', {}, 'and every file in it'), '. Type the folder name to confirm: ',
          h('input', { name: 'confirm_delete', placeholder: s.name, style: { marginTop: '6px' } }),
          h('div', { class: 'actions', style: { justifyContent: 'flex-start' } },
            h('button', { class: 'btn danger', type: 'button', onclick: async e => {
              const typed = e.target.closest('form').querySelector('[name=confirm_delete]').value;
              if (typed !== s.name) { toast('Type the folder name exactly to delete it.', true); return; }
              e.target.closest('.modal-back').remove();
              try { await runJob(el, `Delete shared folder ${s.name}`, { op: 'share_delete', name: s.name }); toast(`Deleted ${s.name}`); }
              catch (ex) { toast(ex.message, true); }
              load(true);
            } }, 'Delete folder and its files'))));
      }
    }, async fd => {
      const name = fd.get('name').trim();
      const access = people.map(p => ({ user: p, access: fd.get('acc:' + p) })).filter(a => a.access !== 'none');
      if (!access.length) throw new Error('Give at least one person access.');
      const gb = Math.max(0, Number(fd.get('tm_max_gb')) || 0);
      const spec = { name, access, timemachine: !!fd.get('timemachine'), tm_max_gb: gb };
      const nasdChanged = isNew || name !== s.name || spec.timemachine !== s.timemachine || gb !== Math.round(s.tm_max_gb || 0) ||
        JSON.stringify(access.map(a => a.user.toLowerCase() + a.access).sort()) !== JSON.stringify(s.access.map(a => a.user.toLowerCase() + a.access).sort());
      // close the dialog first; the job dialog takes over
      document.querySelector('.modal-back form.modal')?.closest('.modal-back')?.remove();
      try {
        if (nasdChanged) {
          await runJob(el, isNew ? `Create shared folder ${name}` : `Update shared folder ${name}`,
            isNew ? { op: 'share_add', spec } : { op: 'share_update', old: s.name, spec });
        }
        await api.put('shares/' + encodeURIComponent(name), {
          timemachine: spec.timemachine, tm_max_size: gb ? `${gb}G` : '',
          recycle: !!fd.get('recycle'), hidden: !!fd.get('hidden'), encrypt: fd.get('encrypt'),
        });
        toast(`Saved ${name}`);
      } catch (ex) { toast(ex.message, true); }
      load(true);
    });
  };
  load();
}

function cpUsers(el) {
  el.append(h('div', { class: 'toolbar', style: { justifyContent: 'space-between' } },
    h('div', {}, h('h3', {}, 'Users'), h('p', { class: 'lead', style: { margin: 0 } }, 'People who can sign in to shared folders.')),
    h('button', { class: 'btn primary', onclick: () => addUser() }, 'Add user')));
  const box = h('div'); el.append(box); loading(box);
  let data, admins = {};
  const pwFields = () => [
    field('Password', h('input', { name: 'pw', type: 'password', required: true, minlength: 6, maxlength: 64, autocomplete: 'new-password' }), 'At least 6 characters. Avoid including the user name.'),
    field('Confirm password', h('input', { name: 'pw2', type: 'password', required: true, autocomplete: 'new-password' }))];
  const checkPw = fd => { if (fd.get('pw') !== fd.get('pw2')) throw new Error('The passwords don’t match.'); return fd.get('pw'); };
  const closeForm = () => document.querySelector('.modal-back form.modal')?.closest('.modal-back')?.remove();

  const load = async (force) => {
    try {
      const [d, s] = await Promise.all([loadDrobo(force), api.get('settings')]);
      data = d;
      admins = Object.fromEntries((s.settings.ADMIN_USERS || '').split(/[,\s]+/).filter(Boolean).map(n => [n.toLowerCase(), true]));
      const adminName = data.admin.username || 'Admin';
      box.replaceChildren(
        h('table', { class: 'tbl' },
          h('thead', {}, h('tr', {}, h('th', {}, 'User'), h('th', {}, 'Shared folders'), h('th', {}, ''))),
          h('tbody', {},
            h('tr', {}, h('td', {}, h('b', {}, adminName), ' ', h('span', { class: 'pill accent' }, 'Drobo administrator')),
              h('td', {}, 'DroboApps and any folder it is given'),
              h('td', { style: { textAlign: 'right' } }, h('button', { class: 'btn', onclick: () => adminPassword(adminName) }, 'Change password'))),
            data.users.map(u => h('tr', {},
              h('td', {}, h('b', {}, u.name), admins[u.name.toLowerCase()] ? [' ', h('span', { class: 'pill' }, 'Web admin')] : null),
              h('td', {}, data.shares.filter(sh => sh.access.some(a => a.user.toLowerCase() === u.name.toLowerCase())).map(sh => sh.name).join(', ') || h('span', { style: { color: 'var(--muted)' } }, 'none')),
              h('td', { style: { textAlign: 'right', whiteSpace: 'nowrap' } },
                h('button', { class: 'btn', onclick: () => changePw(u.name) }, 'Password'), ' ',
                h('button', { class: 'btn danger', onclick: () => delUser(u.name) }, 'Delete')))))),
        h('p', { class: 'lead', style: { marginTop: '12px' } }, 'Give users access to folders in Shared Folders. “Web admin” users can also sign in here (Admin & Security).'));
    } catch (e) { errorBox(box, e); }
  };

  const addUser = () => modal(el, 'Add user', f => {
    f.append(field('User name', h('input', { name: 'name', required: true, maxlength: 32, pattern: '[A-Za-z_][A-Za-z0-9_.\\-]*', autocomplete: 'off' }), 'Letters, digits, . _ - (start with a letter).'), ...pwFields());
  }, async fd => {
    const pw = checkPw(fd), name = fd.get('name').trim();
    closeForm();
    try { await runJob(el, `Add user ${name}`, { op: 'user_add', name, password: pw }); toast(`Added ${name}`); }
    catch (ex) { toast(ex.message, true); }
    load(true);
  });

  const changePw = name => modal(el, `Change password for ${name}`, f => f.append(...pwFields()), async fd => {
    const pw = checkPw(fd);
    closeForm();
    try { await runJob(el, `Change password for ${name}`, { op: 'user_password', name, password: pw }); toast(`Password changed for ${name}`); }
    catch (ex) { toast(ex.message, true); }
  });

  const adminPassword = name => modal(el, `Change password for ${name}`, f => {
    f.append(h('p', { class: 'lead' }, 'This is the Drobo administrator account used by Drobo Dashboard and the DroboApps share.'), ...pwFields());
  }, async fd => {
    const pw = checkPw(fd);
    closeForm();
    try { await runJob(el, 'Change administrator password', { op: 'admin_password', password: pw }); toast('Administrator password changed'); }
    catch (ex) { toast(ex.message, true); }
  });

  const delUser = name => modal(el, `Delete user ${name}?`, f => {
    f.append(h('p', {}, `${name} will no longer be able to sign in, and is removed from every shared folder. Files are not deleted.`));
  }, async () => {
    closeForm();
    try { await runJob(el, `Delete user ${name}`, { op: 'user_delete', name }); toast(`Deleted ${name}`); }
    catch (ex) { toast(ex.message, true); }
    load(true);
  }, 'Delete user');

  load();
}

function cpNetwork(el) {
  el.append(h('h3', {}, 'Network'), h('p', { class: 'lead' }, 'The Drobo’s name on the network and how it gets an address.'));
  const box = h('div'); el.append(box); loading(box);
  loadDrobo(true).then(d => {
    const n = d.network;
    const ipFields = h('div', { class: 'grid2' },
      field('IP address', h('input', { name: 'ip', value: n.ip || '' })),
      field('Subnet mask', h('input', { name: 'subnet', value: n.subnet || '' })),
      field('Router (gateway)', h('input', { name: 'gateway', value: n.gateway || '' })));
    const mode = select('mode', n.mode, [['dhcp', 'Automatically (DHCP)'], ['static', 'Manually (static)']]);
    const sync = () => { ipFields.hidden = mode.value !== 'static'; };
    mode.addEventListener('change', sync); sync();
    const form = h('form', { class: 'card' },
      h('div', { class: 'grid2' },
        field('Drobo name', h('input', { name: 'name', value: n.name, maxlength: 15, required: true }), 'How it appears in Finder and Windows.'),
        field('Workgroup', h('input', { name: 'workgroup', value: n.workgroup, maxlength: 15, required: true }))),
      field('Get IP address', mode), ipFields,
      h('div', { class: 'grid2' },
        field('DNS server 1', h('input', { name: 'dns1', value: n.dns1 || '' })),
        field('DNS server 2', h('input', { name: 'dns2', value: n.dns2 || '' }))),
      checkbox('jumbo', n.jumbo, 'Jumbo frames', 'Only if every switch and computer on your network supports them.'),
      field('MTU', h('input', { name: 'mtu', type: 'number', min: 1500, max: 9000, value: n.mtu || 1500 })),
      h('p', { class: 'help', style: { color: 'var(--muted)' } }, `MAC address ${n.mac || '–'}`),
      h('div', { class: 'notice warn' }, 'Changing the address or name can disconnect you from this page. If the address changes, open the new address in your browser.'),
      h('div', { class: 'actions' }, h('button', { class: 'btn primary', type: 'submit' }, 'Apply')));
    form.addEventListener('submit', async e => {
      e.preventDefault();
      const fd = new FormData(form);
      const spec = { name: fd.get('name').trim(), workgroup: fd.get('workgroup').trim(), mode: fd.get('mode'),
        dns1: fd.get('dns1').trim(), dns2: fd.get('dns2').trim(), jumbo: !!fd.get('jumbo'), mtu: Number(fd.get('mtu')) || 1500 };
      if (spec.mode === 'static') Object.assign(spec, { ip: fd.get('ip').trim(), subnet: fd.get('subnet').trim(), gateway: fd.get('gateway').trim() });
      try { await runJob(el, 'Apply network settings', { op: 'network_set', spec }); toast('Network settings applied'); }
      catch (ex) { toast(ex.message, true); }
    });
    box.replaceChildren(form);
  }).catch(e => errorBox(box, e));
}

function cpAlerts(el) {
  el.append(h('h3', {}, 'Notifications'), h('p', { class: 'lead' }, 'Email when the Drobo needs attention: drive failures, low space, and more.'));
  const box = h('div'); el.append(box); loading(box);
  loadDrobo(true).then(d => {
    const m = d.email;
    const form = h('form', { class: 'card' },
      checkbox('enabled', m.enabled, 'Send email alerts'),
      h('div', { class: 'grid2' },
        field('Send to', h('input', { name: 'to', value: m.to || '', placeholder: 'you@example.com' })),
        field('From', h('input', { name: 'from', value: m.from || '' })),
        field('Alert level', select('level', String(m.level), [['0', 'Critical only'], ['1', 'Critical and warnings'], ['2', 'Everything']])),
        field('Mail server', h('input', { name: 'server', value: m.server || '' })),
        field('Port', h('input', { name: 'port', type: 'number', value: m.port || 25 }))),
      checkbox('ssl', m.ssl, 'Use SSL', 'Only SSL from 2015 is available on this firmware; many providers now require newer TLS.'),
      checkbox('auth', m.auth, 'Server requires sign-in'),
      h('div', { class: 'grid2' },
        field('User name', h('input', { name: 'username', value: m.username || '', autocomplete: 'off' })),
        field('Password', h('input', { name: 'password', type: 'password', placeholder: 'unchanged', autocomplete: 'new-password' }))),
      h('div', { class: 'actions' }, h('button', { class: 'btn primary', type: 'submit' }, 'Apply')));
    form.addEventListener('submit', async e => {
      e.preventDefault();
      const fd = new FormData(form);
      const spec = { enabled: !!fd.get('enabled'), to: fd.get('to').trim(), from: fd.get('from').trim(), level: Number(fd.get('level')),
        server: fd.get('server').trim(), port: Number(fd.get('port')) || 25, ssl: !!fd.get('ssl'), auth: !!fd.get('auth'),
        username: fd.get('username').trim(), password: fd.get('password') };
      try { await runJob(el, 'Apply email alert settings', { op: 'email_set', spec }); toast('Notification settings applied'); }
      catch (ex) { toast(ex.message, true); }
    });
    box.replaceChildren(form);
  }).catch(e => errorBox(box, e));
}

function cpSecurity(el) {
  el.append(h('h3', {}, 'Admin & Security'), h('p', { class: 'lead' }, 'Who can sign in to this page, and how it is served.'));
  const box = h('div'); el.append(box); loading(box);
  (async () => {
    try {
      const { settings: s } = await api.get('settings');
      const form = h('form', { class: 'card' },
        field('Admin users', h('input', { name: 'ADMIN_USERS', value: s.ADMIN_USERS }), 'Drobo Dashboard users allowed to sign in here, separated by commas. root can always sign in.'),
        field('HTTPS port', h('input', { name: 'WEB_PORT', type: 'number', min: 1024, max: 65535, value: s.WEB_PORT }), 'The page reloads on the new port after saving.'),
        field('Finder icon', select('BONJOUR_MODEL', s.BONJOUR_MODEL, [['Xserve', 'Rack server'], ['RackMac', 'Rack server (alt)'], ['TimeCapsule8,119', 'Time Capsule'], ['MacPro7,1@ECOLOR=226,226,224', 'Mac Pro']])),
        h('div', { class: 'actions' }, h('button', { class: 'btn primary', type: 'submit' }, 'Save')));
      form.addEventListener('submit', async e => {
        e.preventDefault();
        const fd = new FormData(form);
        try {
          const r = await api.put('settings', { ADMIN_USERS: fd.get('ADMIN_USERS').trim(), WEB_PORT: String(fd.get('WEB_PORT')), BONJOUR_MODEL: fd.get('BONJOUR_MODEL') });
          toast('Saved');
          if (r.web_restart) setTimeout(() => { location.port = fd.get('WEB_PORT'); }, 3500);
        } catch (ex) { toast(ex.message, true); }
      });
      box.replaceChildren(form, h('div', { class: 'card' }, h('h4', {}, 'Certificate'),
        h('p', { style: { margin: 0 } }, 'This page uses a self-signed certificate created on the Drobo, so browsers will warn the first time. The certificate is in ', h('code', {}, 'DroboApps/encore/var/ssl'), '.')));
    } catch (e) { errorBox(box, e); }
  })();
}


const TIME_ZONES = [
  ['EST5EDT,M3.2.0,M11.1.0', 'US Eastern (New York)'], ['CST6CDT,M3.2.0,M11.1.0', 'US Central (Chicago)'],
  ['MST7MDT,M3.2.0,M11.1.0', 'US Mountain (Denver)'], ['MST7', 'US Arizona'], ['PST8PDT,M3.2.0,M11.1.0', 'US Pacific (Los Angeles)'],
  ['AKST9AKDT,M3.2.0,M11.1.0', 'US Alaska'], ['HST10', 'US Hawaii'], ['UTC0', 'UTC'],
  ['GMT0BST,M3.5.0/1,M10.5.0', 'UK (London)'], ['CET-1CEST,M3.5.0,M10.5.0/3', 'Central Europe'],
  ['EET-2EEST,M3.5.0/3,M10.5.0/4', 'Eastern Europe'], ['IST-5:30', 'India'], ['CST-8', 'China'],
  ['JST-9', 'Japan'], ['AEST-10AEDT,M10.1.0,M4.1.0/3', 'Australia Eastern (Sydney)'],
];

function cpTime(el) {
  el.append(h('h3', {}, 'Date & Time'), h('p', { class: 'lead' }, 'The Drobo sets its clock from internet time servers. Encore keeps retrying after boot and re-syncs every hour.'));
  const box = h('div'); el.append(box); loading(box);
  let timer;
  const describe = (st) => {
    const skew = st.epoch - Math.round(Date.now() / 1000);
    const abs = Math.abs(skew);
    const human = abs < 60 ? `${abs} s` : abs < 3600 ? `${Math.round(abs / 60)} min` : `${(abs / 3600).toFixed(1)} h`;
    return abs <= 5 ? h('span', { class: 'pill ok' }, 'In sync with this computer')
      : h('span', { class: 'pill ' + (abs > 300 ? 'bad' : 'warn') }, `${human} ${skew < 0 ? 'behind' : 'ahead of'} this computer`);
  };
  const render = (st) => {
    const sync = st.sync;
    const status = h('div', { class: 'card' }, h('h4', {}, 'Clock'),
      h('dl', { class: 'kv' },
        h('dt', {}, 'Drobo time'), h('dd', {}, new Date(st.epoch * 1000).toLocaleString(), ' ', describe(st)),
        h('dt', {}, 'Last sync'), h('dd', {}, !sync ? 'Not yet' : sync.ok
          ? `${new Date(sync.at * 1000).toLocaleString()} from ${sync.server}${sync.manual ? ' (set by hand)' : ''}`
          : h('span', { style: { color: 'var(--bad)' } }, `Failed at ${new Date(sync.at * 1000).toLocaleString()}; no time server answered`))),
      h('div', { class: 'actions', style: { justifyContent: 'flex-start' } },
        h('button', { class: 'btn primary', onclick: async e => {
          e.target.disabled = true; e.target.textContent = 'Syncing…';
          try { const r = await api.post('time/sync'); toast(r.sync && r.sync.ok ? `Clock synced from ${r.sync.server}` : 'No time server answered', !(r.sync && r.sync.ok)); render(r); }
          catch (ex) { toast(ex.message, true); e.target.disabled = false; }
        } }, 'Sync now'),
        h('button', { class: 'btn', onclick: async () => {
          try { const r = await api.post('time/set', { epoch: Math.round(Date.now() / 1000) }); toast('Clock set from this computer'); render(r); }
          catch (ex) { toast(ex.message, true); }
        } }, 'Use this computer’s time')));
    const known = TIME_ZONES.some(z => z[0] === st.time_zone);
    const form = h('form', { class: 'card' }, h('h4', {}, 'Settings'),
      field('Time servers', h('input', { name: 'NTP_SERVERS', value: st.ntp_servers || '' }), 'Tried in order, separated by spaces. Your router can be used if it serves NTP.'),
      field('Time zone', select('TIME_ZONE', st.time_zone, known ? TIME_ZONES : [[st.time_zone, st.time_zone], ...TIME_ZONES]),
        'Used for Encore’s logs. Drobo Dashboard and the firmware keep their own Pacific time zone.'),
      h('div', { class: 'actions' }, h('button', { class: 'btn primary', type: 'submit' }, 'Save')));
    form.addEventListener('submit', async e => {
      e.preventDefault();
      const fd = new FormData(form);
      try { await api.put('settings', { NTP_SERVERS: fd.get('NTP_SERVERS').trim(), TIME_ZONE: fd.get('TIME_ZONE') }); toast('Saved'); }
      catch (ex) { toast(ex.message, true); }
    });
    box.replaceChildren(status, form);
  };
  const load = async () => { try { render(await api.get('time')); } catch (e) { errorBox(box, e); } };
  load();
  timer = setInterval(async () => {
    const dd = box.querySelector('dd'); if (!dd) return;
    try { const st = await api.get('time'); dd.replaceChildren(new Date(st.epoch * 1000).toLocaleString(), ' ', describe(st)); } catch { }
  }, 10000);
  return () => clearInterval(timer);
}

function renderControlPanel(body) {
  return sidebarApp(body, [
    { id: 'smb', title: 'File Services', icon: 'smb', color: '#2f7fd6', render: cpFileServices },
    { id: 'shares', title: 'Shared Folders', icon: 'share', color: '#e0a106', render: cpShares },
    { id: 'users', title: 'Users', icon: 'users', color: '#7a5bd6', render: cpUsers },
    { id: 'network', title: 'Network', icon: 'network', color: '#1c9a8a', render: cpNetwork },
    { id: 'alerts', title: 'Notifications', icon: 'mail', color: '#c0662b', render: cpAlerts },
    { id: 'time', title: 'Date & Time', icon: 'clock', color: '#3b7dd8', render: cpTime },
    { id: 'security', title: 'Admin & Security', icon: 'shield', color: '#d2553f', render: cpSecurity },
  ]);
}

function renderStorage(body) {
  loading(body);
  const STATUS = { healthy: ['ok', 'Healthy'], warning: ['warn', 'Warning'], failed: ['bad', 'Failed'],
    rebuilding: ['warn', 'Rebuilding'], empty: ['', 'Empty'], off: ['', 'Off'] };
  Promise.all([api.get('drobo/status'), api.get('overview')]).then(([st, o]) => {
    const p = st.protected || {};
    const frac = p.total ? p.used / p.total : 0;
    const v = o.volume;
    const bays = h('div', { class: 'bays' }, st.slots.map(sl => {
      const [cls, label] = STATUS[sl.status] || ['warn', sl.status];
      return h('div', { class: 'bay ' + (sl.status === 'empty' ? 'empty' : '') },
        h('div', { class: 'bay-led ' + cls }),
        h('div', {}, h('b', {}, `Bay ${sl.slot + 1}`), h('div', { class: 'lbl' }, sl.capacity ? fmt.bytes(sl.capacity, 0) : 'No drive')),
        h('span', { class: 'pill ' + cls }, label));
    }));
    body.replaceChildren(h('div', { class: 'content' },
      h('h3', {}, st.name || 'Drobo'),
      h('p', { class: 'lead' }, `Firmware ${st.firmware || '?'} · BeyondRAID storage pool`),
      h('div', { class: 'card' }, h('h4', {}, 'Drive bays'), bays,
        h('p', { class: 'help', style: { color: 'var(--muted)', marginBottom: 0 } }, 'Drive status as reported by the Drobo’s storage controller.')),
      h('div', { class: 'card' }, h('h4', {}, 'Protected capacity'),
        h('div', { class: 'gauges' }, ring(frac, 'Used', `${fmt.bytes(p.used)} of ${fmt.bytes(p.total)}`)),
        h('div', { style: { marginTop: '12px' } }, bar(frac)),
        h('dl', { class: 'kv', style: { marginTop: '12px' } },
          h('dt', {}, 'Free'), h('dd', {}, fmt.bytes(p.free)),
          h('dt', {}, 'Warning level'), h('dd', {}, `${st.yellow_threshold}% full`),
          h('dt', {}, 'Critical level'), h('dd', {}, `${st.red_threshold}% full`),
          h('dt', {}, 'Relayouts'), h('dd', {}, String(st.relayout_count ?? '–')))),
      v && h('div', { class: 'card' }, h('h4', {}, 'File system'),
        h('dl', { class: 'kv' },
          h('dt', {}, 'Mount point'), h('dd', {}, '/mnt/DroboFS (ext3)'),
          h('dt', {}, 'Logical size'), h('dd', {}, fmt.bytes(v.total)),
          h('dt', {}, 'Used'), h('dd', {}, fmt.bytes(v.used)))),
      h('p', { class: 'help', style: { color: 'var(--muted)' } }, 'The volume’s logical size is larger than the protected capacity; add or upgrade drives before the protected space runs out.')));
  }).catch(e => errorBox(body, e));
}

function lineChart(canvas, series, opts = {}) {
  const dpr = window.devicePixelRatio || 1;
  const W = canvas.clientWidth, H = canvas.clientHeight;
  if (!W || !H) return;
  if (canvas.width !== W * dpr) { canvas.width = W * dpr; canvas.height = H * dpr; }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, W, H);
  const css = getComputedStyle(document.documentElement);
  const N = opts.points || 60;
  let max = opts.max || 0;
  if (!opts.max) for (const s of series) for (const v of s.data) max = Math.max(max, v);
  max = max || 1;
  ctx.strokeStyle = css.getPropertyValue('--border'); ctx.lineWidth = 1;
  for (let i = 1; i < 4; i++) { const y = Math.round(H * i / 4) + .5; ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke(); }
  for (const s of series) {
    const color = s.color.startsWith('--') ? css.getPropertyValue(s.color) : s.color;
    const pts = s.data.map((v, i) => [W - (s.data.length - 1 - i) * (W / (N - 1)), H - 2 - (v / max) * (H - 6)]);
    if (pts.length < 2) continue;
    ctx.beginPath(); pts.forEach(([x, y], i) => i ? ctx.lineTo(x, y) : ctx.moveTo(x, y));
    ctx.strokeStyle = color; ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.stroke();
    ctx.lineTo(pts[pts.length - 1][0], H); ctx.lineTo(pts[0][0], H); ctx.closePath();
    ctx.globalAlpha = .12; ctx.fillStyle = color; ctx.fill(); ctx.globalAlpha = 1;
  }
}

function renderMonitor(body) {
  const N = 60, hist = { cpu: [], mem: [], rx: [], tx: [], rd: [], wr: [] };
  const push = (k, v) => { hist[k].push(v); if (hist[k].length > N) hist[k].shift(); };
  const card = (title, id, legend) => h('div', { class: 'chart-card' },
    h('div', { class: 'chart-head' }, h('b', {}, title), h('span', { id: 'v-' + id })),
    h('canvas', { class: 'chart', id: 'c-' + id }),
    legend && h('div', { class: 'legend' }, legend.map(([c, l]) => h('span', {}, h('i', { style: { background: c.startsWith('--') ? `var(${c})` : c } }), l))));
  const perf = h('div', {},
    card('CPU', 'cpu'), card('Memory', 'mem'),
    card('Network', 'net', [['--accent', 'Received'], ['#d2553f', 'Sent']]),
    card('Volume I/O', 'disk', [['#2f7fd6', 'Read'], ['#e0a106', 'Write']]));
  const conns = h('div');
  const tabs = h('div', { class: 'tabs' });
  const view = h('div');
  const setTab = t => {
    $$('button', tabs).forEach(b => b.classList.toggle('active', b.dataset.t === t));
    view.replaceChildren(t === 'perf' ? perf : conns);
    if (t === 'conn') loadConns();
  };
  tabs.append(h('button', { 'data-t': 'perf', onclick: () => setTab('perf') }, 'Performance'), h('button', { 'data-t': 'conn', onclick: () => setTab('conn') }, 'Connections'));
  body.append(h('div', { class: 'content' }, h('div', { class: 'toolbar' }, tabs), view));
  setTab('perf');

  async function loadConns() {
    loading(conns);
    try {
      const r = await api.get('connections');
      if (r.mode !== 'encore') { conns.replaceChildren(h('p', { class: 'empty' }, 'Connection details are available when Samba 4 is serving files.')); return; }
      conns.replaceChildren(r.connections.length ? h('table', { class: 'tbl' },
        h('thead', {}, h('tr', {}, ['User', 'Computer', 'Protocol', 'Encryption', 'Signing', 'PID'].map(t => h('th', {}, t)))),
        h('tbody', {}, r.connections.map(c => h('tr', {}, h('td', {}, c.user), h('td', {}, c.machine), h('td', {}, h('span', { class: 'pill accent' }, c.protocol)),
          h('td', {}, c.encryption), h('td', {}, c.signing), h('td', {}, c.pid))))) : h('p', { class: 'empty' }, 'No one is connected.'));
    } catch (e) { errorBox(conns, e); }
  }

  let prev = null;
  const tick = async () => {
    try {
      const r = await api.get('resources');
      if (prev) {
        const dt = Math.max(1, r.t - prev.t);
        const dTot = r.cpu.total - prev.cpu.total;
        push('cpu', dTot > 0 ? 1 - (r.cpu.idle - prev.cpu.idle) / dTot : 0);
        let rx = 0, tx = 0;
        for (const [n, c] of Object.entries(r.net)) if (prev.net[n]) { rx += c.rx - prev.net[n].rx; tx += c.tx - prev.net[n].tx; }
        push('rx', Math.max(0, rx / dt)); push('tx', Math.max(0, tx / dt));
        push('rd', Math.max(0, ((r.disk.read_sectors || 0) - (prev.disk.read_sectors || 0)) * 512 / dt));
        push('wr', Math.max(0, ((r.disk.write_sectors || 0) - (prev.disk.write_sectors || 0)) * 512 / dt));
      }
      const m = r.memory;
      push('mem', m.total ? (m.total - m.free - m.buffers - m.cached) / m.total : 0);
      prev = r;
      const last = k => hist[k][hist[k].length - 1] || 0;
      const set = (id, t) => { const e = $('#v-' + id, body); if (e) e.textContent = t; };
      set('cpu', `${fmt.pct(last('cpu'))} · load ${r.load}`);
      set('mem', `${fmt.pct(last('mem'))} of ${fmt.bytes(m.total)}`);
      set('net', `↓ ${fmt.rate(last('rx'))}  ↑ ${fmt.rate(last('tx'))}`);
      set('disk', `R ${fmt.rate(last('rd'))}  W ${fmt.rate(last('wr'))}`);
      const c = id => $('#c-' + id, body);
      if (c('cpu')) {
        lineChart(c('cpu'), [{ data: hist.cpu, color: '--accent' }], { max: 1, points: N });
        lineChart(c('mem'), [{ data: hist.mem, color: '#7a5bd6' }], { max: 1, points: N });
        lineChart(c('net'), [{ data: hist.rx, color: '--accent' }, { data: hist.tx, color: '#d2553f' }], { points: N });
        lineChart(c('disk'), [{ data: hist.rd, color: '#2f7fd6' }, { data: hist.wr, color: '#e0a106' }], { points: N });
      }
    } catch { /* keep polling */ }
  };
  tick();
  const timer = setInterval(tick, 2000);
  return () => clearInterval(timer);
}

function renderLogs(body) {
  const LOGS = [['encore', 'Encore'], ['samba', 'Samba'], ['nasd', 'Drobo NAS'], ['web', 'Web server'], ['kernel', 'Kernel']];
  let current = 'encore', timer = null, raw = '';
  const box = h('pre', { class: 'logbox' });
  const filter = h('input', { placeholder: 'Filter', 'aria-label': 'Filter log lines', oninput: () => paint() });
  const lines = select('lines', '300', [['100', '100 lines'], ['300', '300 lines'], ['1000', '1000 lines']]);
  lines.addEventListener('change', () => load());
  const auto = h('input', { type: 'checkbox', onchange: e => { clearInterval(timer); timer = e.target.checked ? setInterval(load, 4000) : null; } });
  const tabs = h('div', { class: 'tabs' }, LOGS.map(([id, label]) => h('button', { 'data-id': id, onclick: () => { current = id; load(); } }, label)));
  const paint = () => {
    const q = filter.value.trim().toLowerCase();
    const shown = q ? raw.split('\n').filter(l => l.toLowerCase().includes(q)).join('\n') : raw;
    box.textContent = shown || '(empty)';
    box.scrollTop = box.scrollHeight;
  };
  const load = async () => {
    $$('button', tabs).forEach(b => b.classList.toggle('active', b.dataset.id === current));
    try { raw = (await api.get(`logs?name=${current}&lines=${lines.value}`)).text || ''; }
    catch (e) { raw = e.message; }
    paint();
  };
  body.append(h('div', { class: 'content', style: { height: '100%', display: 'flex', flexDirection: 'column' } },
    h('div', { class: 'toolbar' }, tabs, filter, lines, h('label', { class: 'check', style: { margin: 0 } }, auto, 'Live'),
      h('button', { class: 'btn', onclick: () => load() }, 'Refresh')),
    box));
  load();
  return () => clearInterval(timer);
}

function renderHelp(body) {
  body.append(h('div', { class: 'content' },
    h('h3', {}, 'About Encore'),
    h('p', { class: 'lead' }, 'Modern file sharing and a web admin for the Drobo FS, installed as a DroboApp.'),
    h('div', { class: 'card' }, h('h4', {}, 'What it changes'),
      h('ul', {},
        h('li', {}, 'Replaces the built-in Samba 3.4 (SMB1) with Samba 4 (SMB2/SMB3, encryption, signing, Time Machine).'),
        h('li', {}, 'Advertises SMB and Time Machine shares over Bonjour.'),
        h('li', {}, 'Adds this web admin over HTTPS.'))),
    h('div', { class: 'card' }, h('h4', {}, 'What it never changes'),
      h('ul', {},
        h('li', {}, 'The Drobo firmware in flash. Everything runs from the DroboApps share.'),
        h('li', {}, 'Your data or the BeyondRAID volume.'),
        h('li', {}, 'How users and shares are stored: changes go through the Drobo’s own management service, exactly as Drobo Dashboard makes them, so Dashboard keeps working.'))),
    h('div', { class: 'card' }, h('h4', {}, 'Undo'),
      h('p', {}, 'Control Panel → File Services → Revert to stock Samba switches back immediately. To remove Encore completely, delete the ', h('code', {}, 'DroboApps/encore'), ' folder and restart the Drobo.'))));
}

const APPS = [
  { id: 'overview', title: 'System Info', icon: 'info', color: '#2f7fd6', render: renderOverview, w: 820, h: 620 },
  { id: 'control', title: 'Control Panel', icon: 'control', color: '#55708a', render: renderControlPanel, w: 900, h: 600 },
  { id: 'storage', title: 'Storage', icon: 'storage', color: '#1c9a8a', render: renderStorage, w: 640, h: 520 },
  { id: 'monitor', title: 'Resource Monitor', icon: 'monitor', color: '#d2553f', render: renderMonitor, w: 760, h: 640 },
  { id: 'logs', title: 'Log Center', icon: 'logs', color: '#7a5bd6', render: renderLogs, w: 880, h: 560 },
  { id: 'help', title: 'Help', icon: 'help', color: '#e0a106', render: renderHelp, w: 620, h: 520 },
];

// ---------------------------------------------------------------- desktop, widgets, launcher
let widgetTimer = null;
function buildDesktop() {
  const icons = $('#desktop-icons');
  icons.replaceChildren(...APPS.slice(0, 5).map(a => h('button', { class: 'dicon', title: `Open ${a.title}`, onclick: () => WM.open(a.id) },
    icon(a.icon, a.color), h('span', {}, a.title))));
  const grid = $('#launcher-grid');
  const fill = q => grid.replaceChildren(...APPS.filter(a => a.title.toLowerCase().includes(q)).map(a =>
    h('button', { onclick: () => { hideLauncher(); WM.open(a.id); } }, icon(a.icon, a.color), h('span', {}, a.title))));
  fill('');
  $('#launcher-search').oninput = e => fill(e.target.value.toLowerCase());
  $('#launcher-search').onkeydown = e => { if (e.key === 'Enter') $('button', grid)?.click(); };
}

async function refreshWidgets() {
  const el = $('#widgets');
  try {
    const o = await api.get('overview');
    const v = o.volume;
    el.replaceChildren(
      h('div', { class: 'widget' }, h('h3', {}, 'System health'),
        h('div', { class: 'wrow' }, h('span', {}, 'Status'), h('b', { style: { color: 'var(--ok)' } }, 'Healthy')),
        h('div', { class: 'wrow' }, h('span', {}, 'Name'), h('span', {}, o.hostname)),
        h('div', { class: 'wrow' }, h('span', {}, 'Uptime'), h('span', {}, fmt.dur(o.uptime))),
        h('div', { class: 'wrow' }, h('span', {}, 'Load'), h('span', {}, o.load))),
      h('div', { class: 'widget' }, h('h3', {}, 'Storage'),
        v ? [h('div', { class: 'wrow' }, h('span', {}, 'Used'), h('span', {}, `${fmt.bytes(v.used)} / ${fmt.bytes(v.total)}`)), bar(v.used / v.total)]
          : h('div', {}, 'Volume not mounted')),
      h('div', { class: 'widget' }, h('h3', {}, 'File sharing'),
        h('div', { class: 'wrow' }, h('span', {}, 'Engine'), h('span', {}, o.samba.mode === 'encore' ? `Samba ${o.samba.version}` : o.samba.mode === 'stock' ? 'Stock 3.4' : 'Stopped')),
        h('div', { class: 'wrow' }, h('span', {}, 'Protocols'), h('span', {}, `${o.samba.min} – ${o.samba.max}`)),
        h('div', { class: 'wrow' }, h('span', {}, 'Sessions'), h('span', {}, o.connections))));
  } catch { /* offline indicator already set */ }
}

function showLauncher() { $('#launcher').hidden = false; $('#launcher-search').value = ''; $('#launcher-search').dispatchEvent(new Event('input')); $('#launcher-search').focus(); }
function hideLauncher() { $('#launcher').hidden = true; }

function tickClock() {
  $('#tb-clock').textContent = new Date().toLocaleString([], { weekday: 'short', hour: '2-digit', minute: '2-digit' });
}

// ---------------------------------------------------------------- session
function showLogin(host) {
  clearInterval(widgetTimer);
  WM.closeAll();
  $('#desktop').hidden = true;
  $('#login').hidden = false;
  if (host) { $('#login-host').textContent = host; document.title = `${host} – Encore NAS`; }
  $('#login-user').focus();
}

function showDesktop(user, host) {
  $('#login').hidden = true;
  $('#desktop').hidden = false;
  $('#user-name').textContent = user;
  if (host) document.title = `${host} – Encore NAS`;
  buildDesktop();
  refreshWidgets();
  clearInterval(widgetTimer);
  widgetTimer = setInterval(refreshWidgets, 20000);
  if (!WM.wins.size) WM.open('overview');
}

$('#login-form').addEventListener('submit', async e => {
  e.preventDefault();
  const fd = new FormData(e.target);
  const btn = $('#login-btn');
  btn.disabled = true; $('#login-error').textContent = '';
  try {
    const r = await api.post('login', { user: fd.get('user'), password: fd.get('password') });
    e.target.reset();
    const s = await api.get('session');
    showDesktop(r.user, s.hostname);
  } catch (ex) { $('#login-error').textContent = ex.message; }
  btn.disabled = false;
});

$('#launcher-btn').addEventListener('click', () => $('#launcher').hidden ? showLauncher() : hideLauncher());
$('#launcher').addEventListener('mousedown', e => { if (e.target.id === 'launcher') hideLauncher(); });
$('#user-btn').addEventListener('click', () => { $('#user-menu').hidden = !$('#user-menu').hidden; });
document.addEventListener('mousedown', e => { if (!e.target.closest('.tb-user')) $('#user-menu').hidden = true; });
document.addEventListener('keydown', e => { if (e.key === 'Escape') { hideLauncher(); $('#user-menu').hidden = true; } });
$('#signout-btn').addEventListener('click', async () => { try { await api.post('logout'); } catch { } showLogin(); });

tickClock();
setInterval(tickClock, 15000);
api.get('session').then(s => s.authenticated ? showDesktop(s.user, s.hostname) : showLogin(s.hostname)).catch(() => showLogin());
