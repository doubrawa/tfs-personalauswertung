'use strict';

const $ = (id) => document.getElementById(id);

// --- Helfer ---------------------------------------------------------------
function fmt(v, d = 1) { return Number(v).toLocaleString('de-DE', { minimumFractionDigits: d, maximumFractionDigits: d }); }
function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
function formatMetric(v, t) {
  if (t === 'int') return Math.round(v).toLocaleString('de-DE');
  if (t === 'h') return fmt(v, 0) + ' h';
  return fmt(v, 0) + ' %';
}
function backendBase() { return ($('backend').value || '').trim().replace(/\/+$/, ''); }

async function callApi(path, body) {
  const res = await fetch(backendBase() + path, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  let json;
  try { json = await res.json(); } catch (e) { throw new Error('Backend nicht erreichbar oder ungueltige Antwort. Laeuft der Proxy-Dienst?'); }
  if (!res.ok || json.error) throw new Error(json.error || ('HTTP ' + res.status));
  return json;
}

function readConn() {
  const auth = {};
  if ($('pat').value) auth.pat = $('pat').value;
  else if ($('user').value) { auth.user = $('user').value; auth.pass = $('pass').value; }
  return {
    demo: $('demo').checked,
    baseUrl: $('baseUrl').value.trim(),
    project: $('project').value.trim(),
    apiVersion: $('apiVersion').value.trim() || '3.0',
    insecureTLS: $('insecure').checked,
    months: Number($('months').value || 12),
    auth,
  };
}

// --- Diagramme (SVG, Punkt-Dezimal!) -------------------------------------
function niceMax(max) {
  if (max <= 0) return 1;
  const exp = Math.floor(Math.log10(max)), base = Math.pow(10, exp);
  let n = Math.ceil(max / base);
  n = n <= 1 ? 1 : n <= 2 ? 2 : n <= 5 ? 5 : 10;
  return n * base;
}
function groupedBar(labels, A, B, nameA, nameB, colorA, colorB) {
  if (!labels.length) return '<p class="desc">Keine Daten.</p>';
  const w = 860, h = 320, padL = 44, padR = 14, padT = 14, padB = 40;
  const plotW = w - padL - padR, plotH = h - padT - padB;
  const max = niceMax(Math.max(0, ...A, ...B));
  const n = labels.length, groupW = plotW / n, barW = Math.min(26, (groupW - 8) / 2);
  let s = `<svg viewBox="0 0 ${w} ${h}" class="chart" preserveAspectRatio="xMidYMid meet">`;
  for (let g = 0; g <= 4; g++) {
    const yv = max * g / 4, y = padT + plotH - plotH * g / 4;
    s += `<line x1="${padL}" y1="${y}" x2="${padL + plotW}" y2="${y}" class="grid"/>`;
    s += `<text x="${padL - 6}" y="${y + 4}" class="axlbl" text-anchor="end">${Math.round(yv)}</text>`;
  }
  for (let i = 0; i < n; i++) {
    const cx = padL + i * groupW + groupW / 2;
    const hA = max > 0 ? plotH * A[i] / max : 0, hB = max > 0 ? plotH * B[i] / max : 0;
    const xA = cx - barW - 2, xB = cx + 2, yA = padT + plotH - hA, yB = padT + plotH - hB;
    s += `<rect x="${xA.toFixed(1)}" y="${yA.toFixed(1)}" width="${barW.toFixed(1)}" height="${hA.toFixed(1)}" rx="2" fill="${colorA}"><title>${esc(labels[i])} ${esc(nameA)}: ${fmt(A[i], 1)}</title></rect>`;
    s += `<rect x="${xB.toFixed(1)}" y="${yB.toFixed(1)}" width="${barW.toFixed(1)}" height="${hB.toFixed(1)}" rx="2" fill="${colorB}"><title>${esc(labels[i])} ${esc(nameB)}: ${fmt(B[i], 1)}</title></rect>`;
    s += `<text x="${cx.toFixed(1)}" y="${h - 22}" class="axlbl" text-anchor="middle">${esc(labels[i])}</text>`;
  }
  s += '</svg>';
  s += `<div class="legend"><span><i style="background:${colorA}"></i>${esc(nameA)}</span><span><i style="background:${colorB}"></i>${esc(nameB)}</span></div>`;
  return s;
}

// --- Report rendern ------------------------------------------------------
function renderReport(data) {
  const [a, b] = data.metrics;
  const fte = data.fteHours || 40;
  const fA = a.hours > 0 ? fte / a.hours : 1;
  const fB = b.hours > 0 ? fte / b.hours : 1;
  const labels = data.months.map((m) => m.label);

  const rowsDef = [
    { label: 'Aufgaben erledigt', a: a.doneCount, b: b.doneCount, t: 'int', norm: true, better: 'high' },
    { label: 'Offene Aufgaben', a: a.openCount, b: b.openCount, t: 'int', norm: false, better: 'none' },
    { label: 'Geplant', a: a.planned, b: b.planned, t: 'h', norm: false, better: 'none' },
    { label: 'Tatsächlich', a: a.actual, b: b.actual, t: 'h', norm: false, better: 'none' },
    { label: 'Schätzgenauigkeit', a: a.accuracy, b: b.accuracy, t: 'pct', norm: false, better: 'acc' },
    { label: 'Termintreue', a: a.termintreuePct, b: b.termintreuePct, t: 'pct', norm: false, better: 'high' },
    { label: 'Projekte/Kunden', a: a.projectCount, b: b.projectCount, t: 'int', norm: false, better: 'none' },
    { label: 'Changesets', a: a.csTotal, b: b.csTotal, t: 'int', norm: true, better: 'high' },
    { label: 'Geänderte Dateien', a: a.filesTotal, b: b.filesTotal, t: 'int', norm: true, better: 'high' },
  ];
  const rowsHtml = rowsDef.map((r) => {
    const vA = r.norm ? r.a * fA : r.a;
    const vB = r.norm ? r.b * fB : r.b;
    let ca = '', cb = '';
    if (r.better === 'high') { if (vA > vB) ca = 'win'; else if (vB > vA) cb = 'win'; }
    else if (r.better === 'acc') {
      if (Math.abs(vA - 100) < Math.abs(vB - 100)) ca = 'win';
      else if (Math.abs(vB - 100) < Math.abs(vA - 100)) cb = 'win';
    }
    const subA = r.norm ? `<div class="sub">absolut ${Math.round(r.a).toLocaleString('de-DE')}</div>` : '';
    const subB = r.norm ? `<div class="sub">absolut ${Math.round(r.b).toLocaleString('de-DE')}</div>` : '';
    const extra = r.norm ? ' <span class="sub" style="display:inline">(je Vollzeit)</span>' : '';
    return `<tr><td>${esc(r.label)}${extra}</td><td class="num ${ca}">${formatMetric(vA, r.t)}${subA}</td><td class="num ${cb}">${formatMetric(vB, r.t)}${subB}</td></tr>`;
  }).join('');

  const nTasksA = a.countByMonth.map((v) => v * fA), nTasksB = b.countByMonth.map((v) => v * fB);
  const nCsA = a.csByMonth.map((v) => v * fA), nCsB = b.csByMonth.map((v) => v * fB);
  const cA = '#2563eb', cB = '#16a34a';

  $('report').innerHTML = `
    <div class="card">
      <h2>Kennzahlen im Vergleich &ndash; fair nach Arbeitszeit</h2>
      <p class="desc">
        <b>${esc(a.name)}</b> ${a.hours} h/Woche (Faktor &times;${fmt(fA, 2)}),
        <b>${esc(b.name)}</b> ${b.hours} h/Woche (Faktor &times;${fmt(fB, 2)}).
        Output-Kennzahlen (Aufgaben, Changesets, Dateien) sind auf <b>${fmt(fte, 0)}-Std-Vollzeit hochgerechnet</b>;
        der tatsächliche Wert steht klein als „absolut" darunter. Quoten (Genauigkeit, Termintreue) und Stunden bleiben unverändert.
        Grün = der jeweils günstigere Wert.
      </p>
      <table class="cmp">
        <thead><tr><th>Kennzahl</th><th class="num">${esc(a.name)}<div class="sub">${a.hours} h/Woche</div></th><th class="num">${esc(b.name)}<div class="sub">${b.hours} h/Woche</div></th></tr></thead>
        <tbody>${rowsHtml}</tbody>
      </table>
    </div>
    <div class="card">
      <h2>Erledigte Aufgaben pro Monat <span class="sub" style="display:inline">(auf ${fmt(fte, 0)}-h-Vollzeit hochgerechnet)</span></h2>
      ${groupedBar(labels, nTasksA, nTasksB, a.name, b.name, cA, cB)}
    </div>
    <div class="card">
      <h2>Changesets pro Monat <span class="sub" style="display:inline">(auf ${fmt(fte, 0)}-h-Vollzeit hochgerechnet)</span></h2>
      ${groupedBar(labels, nCsA, nCsB, a.name, b.name, cA, cB)}
    </div>
    <div class="card">
      <h2>Erfasste Arbeitszeit (Ist, Stunden) pro Monat <span class="sub" style="display:inline">(tatsächlich geleistet, nicht hochgerechnet)</span></h2>
      ${groupedBar(labels, a.actualByMonth, b.actualByMonth, a.name, b.name, cA, cB)}
    </div>`;
  $('report').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

// --- Entwickler in Comboboxen ---
function fillSelect(sel, devs, preferred) {
  sel.innerHTML = devs.map((d) => `<option value="${esc(d.tfvc)}" data-display="${esc(d.display)}">${esc(d.display)} — ${esc(d.tfvc)} (${d.count})</option>`).join('');
  if (preferred != null && devs[preferred]) sel.selectedIndex = preferred;
}

// --- Events ---
let DEVS = [];

$('loadDevs').addEventListener('click', async () => {
  const conn = readConn();
  const st = $('connStatus');
  if (!conn.demo && !conn.baseUrl) { st.className = 'status err'; st.textContent = 'Bitte TFS-Adresse eingeben (oder Demo-Modus aktivieren).'; return; }
  st.className = 'status'; st.textContent = 'Lade Entwickler …';
  $('loadDevs').disabled = true;
  try {
    const out = await callApi('/api/developers', conn);
    DEVS = out.developers || [];
    if (!DEVS.length) { st.className = 'status err'; st.textContent = 'Keine Entwickler gefunden (Changeset-Autoren). Stimmen Adresse/Anmeldung/api-version?'; return; }
    fillSelect($('devA'), DEVS, 0);
    fillSelect($('devB'), DEVS, Math.min(1, DEVS.length - 1));
    $('selectCard').hidden = false;
    st.className = 'status ok'; st.textContent = `${DEVS.length} Entwickler geladen.`;
    $('selectCard').scrollIntoView({ behavior: 'smooth', block: 'start' });
  } catch (e) {
    st.className = 'status err'; st.textContent = 'Fehler: ' + e.message;
  } finally { $('loadDevs').disabled = false; }
});

$('runCompare').addEventListener('click', async () => {
  const conn = readConn();
  const st = $('compStatus');
  const optA = $('devA').selectedOptions[0], optB = $('devB').selectedOptions[0];
  if (!optA || !optB) { st.className = 'status err'; st.textContent = 'Bitte zwei Entwickler waehlen.'; return; }
  const body = Object.assign({}, conn, {
    fteHours: Number($('fteHours').value || 40),
    includeFiles: $('includeFiles').checked,
    developers: [
      { name: optA.dataset.display, assignedTo: optA.dataset.display, tfvc: optA.value, hours: Number($('hoursA').value || 40) },
      { name: optB.dataset.display, assignedTo: optB.dataset.display, tfvc: optB.value, hours: Number($('hoursB').value || 40) },
    ],
  });
  st.className = 'status'; st.textContent = 'Vergleich läuft … (kann bei „Dateien zählen" etwas dauern)';
  $('runCompare').disabled = true;
  try {
    const data = await callApi('/api/compare', body);
    renderReport(data);
    st.className = 'status ok'; st.textContent = 'Fertig.';
  } catch (e) {
    st.className = 'status err'; st.textContent = 'Fehler: ' + e.message;
  } finally { $('runCompare').disabled = false; }
});
