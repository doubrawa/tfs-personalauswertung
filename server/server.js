#!/usr/bin/env node
/*
 * TFS Personalauswertung - Proxy-Backend
 *
 * Statischer Browser-Code (GitHub Pages) darf einen internen TFS-Server wegen CORS
 * normalerweise nicht direkt abfragen. Dieser kleine Dienst loest das:
 *   - er setzt CORS-Header (damit die Pages-Seite ihn aufrufen darf)
 *   - er spricht serverseitig per REST mit dem TFS (WIQL + TFVC-Changesets)
 *
 * Abhaengigkeitsfrei (nur Node-Standardmodule). Start:  node server.js
 *
 * WICHTIG: Selbst hosten (lokal oder im Firmennetz). Zugangsdaten werden nur
 * durchgereicht (TFS Basic-Auth), nie gespeichert.
 */
'use strict';

const http = require('http');
const https = require('https');
const { URL } = require('url');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 8787;
const DOCS_DIR = path.join(__dirname, '..', 'docs');
const deDE = 'de-DE';

// --------------------------------------------------------------------------
// HTTP-Helfer
// --------------------------------------------------------------------------

function requestJson(urlStr, { method = 'GET', headers = {}, body = null, insecure = false } = {}) {
  return new Promise((resolve, reject) => {
    let u;
    try { u = new URL(urlStr.replace(/ /g, '%20')); } catch (e) { return reject(new Error('Ungueltige URL: ' + urlStr)); }
    const mod = u.protocol === 'https:' ? https : http;
    const opts = {
      method,
      headers: Object.assign({ 'Accept': 'application/json' }, headers),
      rejectUnauthorized: !insecure,
    };
    const req = mod.request(u, opts, (res) => {
      let data = '';
      res.on('data', (c) => (data += c));
      res.on('end', () => {
        const status = res.statusCode;
        if (status >= 200 && status < 300) {
          try { resolve(data ? JSON.parse(data) : {}); }
          catch (e) { reject(new Error('Antwort war kein JSON (Status ' + status + '). Stimmt api-version / URL?')); }
        } else {
          const svc = res.headers['x-tfs-serviceerror'];
          let msg = 'TFS antwortete mit HTTP ' + status;
          if (status === 401) msg += ' - Anmeldung fehlgeschlagen (Benutzer/Passwort oder PAT pruefen).';
          else if (status === 404) msg += ' - nicht gefunden (Collection-URL / api-version pruefen).';
          if (svc) msg += ' | ' + decodeURIComponent(svc);
          reject(new Error(msg));
        }
      });
    });
    req.on('error', (e) => reject(new Error('Verbindung fehlgeschlagen: ' + e.message)));
    if (body) req.write(typeof body === 'string' ? body : JSON.stringify(body));
    req.end();
  });
}

function authHeader(auth) {
  if (!auth) return {};
  let pair = null;
  if (auth.user) pair = `${auth.user}:${auth.pass || ''}`;
  else if (auth.pat) pair = `:${auth.pat}`;
  if (!pair) return {};
  return { Authorization: 'Basic ' + Buffer.from(pair, 'utf8').toString('base64') };
}

// --------------------------------------------------------------------------
// Zeit / Monatsreihen
// --------------------------------------------------------------------------

function monthList(months) {
  const now = new Date();
  const list = [];
  for (let i = months - 1; i >= 0; i--) {
    const d = new Date(now.getFullYear(), now.getMonth() - i, 1);
    const key = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0');
    const label = d.toLocaleDateString(deDE, { month: 'short', year: '2-digit' });
    list.push({ key, label });
  }
  return list;
}

function monthKeyOf(dateLike) {
  if (!dateLike) return null;
  const d = new Date(dateLike);
  if (isNaN(d)) return null;
  return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0');
}

// --------------------------------------------------------------------------
// TFS-Abfragen
// --------------------------------------------------------------------------

function tfsCfg(body) {
  const base = String(body.baseUrl || '').replace(/\/+$/, '');
  return {
    base,
    project: body.project || '',
    apiVersion: body.apiVersion || '3.0',
    insecure: !!body.insecureTLS,
    headers: authHeader(body.auth),
  };
}

async function fetchDevelopers(cfg) {
  const url = `${cfg.base}/_apis/tfvc/changesets?$top=1500&api-version=${cfg.apiVersion}`;
  const res = await requestJson(url, { headers: cfg.headers, insecure: cfg.insecure });
  const map = new Map();
  for (const c of (res.value || [])) {
    const a = c.author || {};
    const key = a.uniqueName || a.displayName || 'unbekannt';
    if (!map.has(key)) map.set(key, { tfvc: key, display: a.displayName || key, count: 0 });
    map.get(key).count++;
  }
  return Array.from(map.values()).sort((x, y) => y.count - x.count);
}

const WI_FIELDS = [
  'System.Id', 'System.Title', 'System.WorkItemType', 'System.State',
  'System.CreatedDate', 'System.ChangedDate',
  'Microsoft.VSTS.Scheduling.OriginalEstimate', 'Microsoft.VSTS.Scheduling.CompletedWork',
  'Microsoft.VSTS.Scheduling.DueDate',
  'Microsoft.VSTS.Common.Priority', 'Microsoft.VSTS.Common.ClosedDate',
  'Microsoft.VSTS.Common.ResolvedDate', 'Microsoft.VSTS.Common.StateChangeDate',
  'System.TeamProject',
].join(',');

async function fetchWorkItems(cfg, assignedTo, days) {
  const cond = (!assignedTo || assignedTo === '@Me') ? '@Me' : `'${String(assignedTo).replace(/'/g, "''")}'`;
  const wiql = `SELECT [System.Id] FROM WorkItems WHERE [System.AssignedTo] = ${cond} AND [System.ChangedDate] >= @Today - ${days} ORDER BY [System.ChangedDate] DESC`;
  const wiqlUrl = (cfg.project ? `${cfg.base}/${cfg.project}` : cfg.base) + `/_apis/wit/wiql?api-version=${cfg.apiVersion}`;
  const res = await requestJson(wiqlUrl, { method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, cfg.headers), body: { query: wiql }, insecure: cfg.insecure });
  const ids = (res.workItems || []).map((w) => w.id);
  const items = [];
  for (let i = 0; i < ids.length; i += 200) {
    const chunk = ids.slice(i, i + 200).join(',');
    const wiUrl = `${cfg.base}/_apis/wit/workitems?ids=${chunk}&fields=${WI_FIELDS}&api-version=${cfg.apiVersion}`;
    const wi = await requestJson(wiUrl, { headers: cfg.headers, insecure: cfg.insecure });
    for (const w of (wi.value || [])) {
      const f = w.fields || {};
      const closed = f['Microsoft.VSTS.Common.ClosedDate'] || f['Microsoft.VSTS.Common.ResolvedDate'] || f['Microsoft.VSTS.Common.StateChangeDate'] || null;
      items.push({
        id: w.id,
        title: f['System.Title'] || '',
        type: f['System.WorkItemType'] || '',
        state: f['System.State'] || '',
        created: f['System.CreatedDate'] || null,
        changed: f['System.ChangedDate'] || null,
        closed,
        due: f['Microsoft.VSTS.Scheduling.DueDate'] || null,
        original: Number(f['Microsoft.VSTS.Scheduling.OriginalEstimate'] || 0),
        completed: Number(f['Microsoft.VSTS.Scheduling.CompletedWork'] || 0),
        priority: f['Microsoft.VSTS.Common.Priority'] || null,
        project: f['System.TeamProject'] || '',
      });
    }
  }
  return items;
}

async function fetchChangesets(cfg, author, fromDate, toDate, withFiles) {
  const enc = encodeURIComponent(author);
  const url = `${cfg.base}/_apis/tfvc/changesets?searchCriteria.author=${enc}&searchCriteria.fromDate=${fromDate}&searchCriteria.toDate=${toDate}&$top=10000&api-version=${cfg.apiVersion}`;
  const res = await requestJson(url, { headers: cfg.headers, insecure: cfg.insecure });
  const list = [];
  for (const c of (res.value || [])) {
    let files = null;
    if (withFiles) {
      try {
        const ch = await requestJson(`${cfg.base}/_apis/tfvc/changesets/${c.changesetId}/changes?api-version=${cfg.apiVersion}`, { headers: cfg.headers, insecure: cfg.insecure });
        files = (typeof ch.count === 'number') ? ch.count : (ch.value || []).length;
      } catch (e) { files = null; }
    }
    list.push({ id: c.changesetId, date: c.createdDate, files });
  }
  return list;
}

// --------------------------------------------------------------------------
// Kennzahlen
// --------------------------------------------------------------------------

const DONE_STATES = ['Closed', 'Done', 'Resolved', 'Completed', 'Geschlossen', 'Erledigt', 'Behoben', 'Abgeschlossen', 'Fertig'];

function median(arr) {
  if (!arr.length) return 0;
  const s = [...arr].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

function computeMetrics(name, hours, workItems, changesets, months) {
  const ml = months;
  for (const it of workItems) it.doneDate = it.closed || it.changed;
  const done = workItems.filter((w) => DONE_STATES.includes(w.state));
  const open = workItems.filter((w) => !DONE_STATES.includes(w.state));
  const est = workItems.filter((w) => w.original > 0);
  const planned = est.reduce((s, w) => s + w.original, 0);
  const actual = est.reduce((s, w) => s + w.completed, 0);
  const accuracy = planned > 0 ? (100 * actual) / planned : 0;
  const onBudget = est.filter((w) => w.completed > 0 && w.completed <= w.original * 1.1).length;
  const budgetPct = est.length ? (100 * onBudget) / est.length : 0;

  let onTime = 0, late = 0;
  for (const it of done) {
    let ok = null;
    if (it.due && it.closed) ok = new Date(it.closed) <= new Date(it.due);
    else if (it.original > 0 && it.completed > 0) ok = it.completed <= it.original * 1.15;
    if (ok === true) onTime++;
    else if (ok === false) late++;
  }
  const termintreuePct = (onTime + late) > 0 ? (100 * onTime) / (onTime + late) : 0;
  const projectCount = new Set(workItems.filter((w) => w.project).map((w) => w.project)).size;

  const deviations = est.filter((w) => w.completed > 0)
    .map((w) => ({ id: w.id, title: w.title, original: w.original, completed: w.completed, diff: w.completed - w.original }))
    .sort((a, b) => Math.abs(b.diff) - Math.abs(a.diff)).slice(0, 8);

  const countByMonth = [], plannedByMonth = [], actualByMonth = [], csByMonth = [];
  for (const m of ml) {
    const miDone = done.filter((w) => monthKeyOf(w.doneDate) === m.key);
    const miEst = miDone.filter((w) => w.original > 0);
    countByMonth.push(miDone.length);
    plannedByMonth.push(miEst.reduce((s, w) => s + w.original, 0));
    actualByMonth.push(miEst.reduce((s, w) => s + w.completed, 0));
    csByMonth.push(changesets.filter((c) => monthKeyOf(c.date) === m.key).length);
  }
  const csTotal = changesets.length;
  const withFiles = changesets.filter((c) => c.files != null);
  const filesTotal = withFiles.reduce((s, c) => s + c.files, 0);
  const avgFiles = withFiles.length ? filesTotal / withFiles.length : 0;
  const activeMonths = csByMonth.filter((x) => x > 0).length;
  const csPerMonth = activeMonths ? csTotal / activeMonths : 0;

  return {
    name, hours,
    doneCount: done.length, openCount: open.length, total: workItems.length,
    planned, actual, accuracy, budgetPct, estCount: est.length,
    onTime, late, termintreuePct, projectCount,
    csTotal, filesTotal, avgFiles, csPerMonth,
    countByMonth, plannedByMonth, actualByMonth, csByMonth,
    deviations,
  };
}

// --------------------------------------------------------------------------
// Demo-Daten (ohne TFS testbar)
// --------------------------------------------------------------------------

function rng(seed) { let s = seed >>> 0; return () => { s = (s * 1664525 + 1013904223) >>> 0; return s / 4294967296; }; }

function demoDevelopers() {
  return [
    { tfvc: 'DEMO\\keil', display: 'Eugen Keil', count: 224 },
    { tfvc: 'DEMO\\skibbe', display: 'Kirsten Skibbe', count: 122 },
    { tfvc: 'DEMO\\pape', display: 'Patrick Pape', count: 102 },
    { tfvc: 'DEMO\\theuner', display: 'Jari Theuner', count: 120 },
    { tfvc: 'DEMO\\desoi', display: 'Daniel Desoi', count: 155 },
    { tfvc: 'DEMO\\doubrawa', display: 'Juergen Doubrawa', count: 244 },
  ].sort((a, b) => b.count - a.count);
}

function demoData(months, seed) {
  const r = rng(seed);
  const types = ['Task', 'Task', 'Bug', 'Bug', 'Feature', 'User Story'];
  const projects = ['Produkt Core', 'Mobile', 'Kunde Alpha GmbH', 'Kunde Beta AG', 'Web'];
  const wi = [];
  let id = 41000 + Math.floor(seed % 1000);
  for (let m = months - 1; m >= 0; m--) {
    const count = 2 + Math.floor(r() * 6);
    for (let k = 0; k < count; k++) {
      const created = new Date(); created.setMonth(created.getMonth() - m); created.setDate(1 + Math.floor(r() * 25));
      const orig = Math.round((2 + r() * 38) * 10) / 10;
      const comp = Math.round(orig * (0.7 + r() * 0.8) * 10) / 10;
      const closed = new Date(created); closed.setDate(closed.getDate() + 1 + Math.floor(r() * 24));
      const due = new Date(created); due.setDate(due.getDate() + 5 + Math.floor(r() * 15));
      id++;
      wi.push({ id, title: types[Math.floor(r() * types.length)] + ' #' + id, type: types[Math.floor(r() * types.length)], state: ['Closed', 'Done', 'Resolved'][Math.floor(r() * 3)], created: created.toISOString(), changed: closed.toISOString(), closed: closed.toISOString(), due: due.toISOString(), original: orig, completed: comp, priority: 1 + Math.floor(r() * 4), project: projects[Math.floor(r() * projects.length)] });
    }
  }
  const cs = [];
  let cid = 88000 + Math.floor(seed % 1000);
  for (let m = months - 1; m >= 0; m--) {
    const count = 4 + Math.floor(r() * 16);
    for (let k = 0; k < count; k++) { const d = new Date(); d.setMonth(d.getMonth() - m); d.setDate(1 + Math.floor(r() * 27)); cid++; cs.push({ id: cid, date: d.toISOString(), files: 1 + Math.floor(r() * 14) }); }
  }
  return { wi, cs };
}

// --------------------------------------------------------------------------
// API-Handler
// --------------------------------------------------------------------------

async function handleDevelopers(body) {
  if (body.demo) return { developers: demoDevelopers() };
  const cfg = tfsCfg(body);
  if (!cfg.base) throw new Error('Bitte TFS-Adresse (Collection-URL) angeben.');
  const developers = await fetchDevelopers(cfg);
  return { developers };
}

async function handleCompare(body) {
  const months = Math.max(1, Number(body.months || 12));
  const fteHours = Number(body.fteHours || 40);
  const days = Math.round(months * 30.44);
  const ml = monthList(months);
  const to = new Date();
  const from = new Date(); from.setMonth(from.getMonth() - months);
  const fromS = from.toISOString().slice(0, 10);
  const toS = to.toISOString().slice(0, 10);
  const devs = (body.developers || []).slice(0, 2);
  if (devs.length < 2 && !body.demo) throw new Error('Bitte zwei Entwickler waehlen.');

  const metrics = [];
  if (body.demo) {
    const seeds = [111, 333];
    const hoursArr = [Number((devs[0] && devs[0].hours) || 25), Number((devs[1] && devs[1].hours) || 40)];
    const names = [(devs[0] && devs[0].name) || 'Entwickler A (Teilzeit)', (devs[1] && devs[1].name) || 'Entwickler B (Vollzeit)'];
    for (let i = 0; i < 2; i++) { const d = demoData(months, seeds[i]); metrics.push(computeMetrics(names[i], hoursArr[i], d.wi, d.cs, ml)); }
  } else {
    const cfg = tfsCfg(body);
    if (!cfg.base) throw new Error('Bitte TFS-Adresse (Collection-URL) angeben.');
    for (const d of devs) {
      const name = d.name || d.assignedTo || d.tfvc;
      const wItems = await fetchWorkItems(cfg, d.assignedTo || '@Me', days);
      let cs = [];
      try { cs = await fetchChangesets(cfg, d.tfvc || d.assignedTo, fromS, toS, !!body.includeFiles); }
      catch (e) { cs = []; }
      metrics.push(computeMetrics(name, Number(d.hours || fteHours), wItems, cs, ml));
    }
  }
  return { months: ml, fteHours, metrics };
}

// --------------------------------------------------------------------------
// HTTP-Server (API + statische Dateien)
// --------------------------------------------------------------------------

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.json': 'application/json' };

function sendJson(res, status, obj) {
  const data = JSON.stringify(obj);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
  });
  res.end(data);
}

function serveStatic(req, res) {
  let rel = decodeURIComponent(req.url.split('?')[0]);
  if (rel === '/' || rel === '') rel = '/index.html';
  const filePath = path.normalize(path.join(DOCS_DIR, rel));
  if (!filePath.startsWith(DOCS_DIR)) { res.writeHead(403); return res.end('Forbidden'); }
  fs.readFile(filePath, (err, data) => {
    if (err) { res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }); return res.end('Nicht gefunden. Frontend liegt unter /docs.'); }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(filePath)] || 'application/octet-stream' });
    res.end(data);
  });
}

const server = http.createServer((req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'Content-Type', 'Access-Control-Allow-Methods': 'POST, GET, OPTIONS' });
    return res.end();
  }
  if (req.method === 'POST' && req.url.startsWith('/api/')) {
    let raw = '';
    req.on('data', (c) => { raw += c; if (raw.length > 5e6) req.destroy(); });
    req.on('end', async () => {
      let body = {};
      try { body = raw ? JSON.parse(raw) : {}; } catch (e) { return sendJson(res, 400, { error: 'Ungueltiges JSON im Request.' }); }
      try {
        let out;
        if (req.url.startsWith('/api/developers')) out = await handleDevelopers(body);
        else if (req.url.startsWith('/api/compare')) out = await handleCompare(body);
        else return sendJson(res, 404, { error: 'Unbekannter Endpunkt.' });
        sendJson(res, 200, out);
      } catch (e) {
        sendJson(res, 502, { error: e.message || String(e) });
      }
    });
    return;
  }
  if (req.method === 'GET') return serveStatic(req, res);
  sendJson(res, 405, { error: 'Methode nicht erlaubt.' });
});

server.listen(PORT, () => {
  console.log(`TFS-Personalauswertung Backend laeuft:  http://localhost:${PORT}`);
  console.log(`Frontend (lokal):                        http://localhost:${PORT}/`);
  console.log(`API:  POST /api/developers   POST /api/compare   (CORS aktiviert)`);
});
