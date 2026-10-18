// Test des BeamNet-Fensters (Client-Mod BeamNetUI, ui/modules/apps/BeamNet/app.js).
//   node BeamNet/tests/ui_window_test.js            Logik (Darstellung, Anfragen, Maskierung) – ueberall
//   Mit Playwright (NODE_PATH mit playwright) zusaetzlich im echten Browser: klicken, Countdown, Einklappen.
//   BEAMNET_SHOTS=1 legt dabei die Bilder fuer die Anleitung an (BeamNet/docs/fenster-*.png).
'use strict';
const path = require('path');
const APP = path.join(__dirname, '..', 'client', 'BeamNetUI', 'ui', 'modules', 'apps', 'BeamNet', 'app.js');
const W = require(APP);

let passed = 0, failed = 0;
function check(cond, what) {
  if (cond) { passed++; } else { failed++; console.log('FEHLER: ' + what); }
}

// Beispielstand, wie ihn BeamNetCore schickt (BN.uiState)
function sample(extra) {
  return Object.assign({
    v: 1, lang: 'de', map: 'italy', server: 'BeamNet | Server 1',
    me: { name: 'Sebi', guest: false, level: 12, league: 'Gold', xp: 3480, weekKm: '42,5 km', seasonXp: 740 },
    players: [{ pid: 3, name: 'Max', level: 9 }, { pid: 5, name: 'Ana', level: 15 }],
    tracks: [
      { name: 'Bergsprint', record: '1:12.4', by: 'Ana' },
      { name: 'Hafenrunde', record: '2:03.9', by: 'Sebi', weekly: true },
      { name: 'Kuestenstrasse' }
    ]
  }, extra || {});
}

// --- Logik ohne Browser ----------------------------------------------------------------------------------------
const ui = { tab: 'races', collapsed: false, target: '', track: '' };
let html = W.render(sample(), ui);
check(html.includes('Bergsprint') && html.includes('Rekord 1:12.4 · Ana'), 'Strecken mit Rekord');
check(html.includes('noch keine Zeit'), 'Strecke ohne Zeit');
check(html.includes('★'), 'Strecke der Woche markiert');
check(html.includes('data-act="race" data-track="Bergsprint"'), 'Knopf Fahren je Strecke');
check(html.includes('Level 12') && html.includes('Saison 740 XP'), 'Profilzeile');
check(!html.includes('Annehmen'), 'ohne Herausforderung kein Annehmen');
html = W.render(sample({ invite: { from: 'Max', track: 'Bergsprint', left: 45 } }), ui);
check(html.includes('⚔️ Max fordert dich heraus!') && html.includes('noch 45 s') && html.includes('data-act="accept"'), 'Herausforderung mit Annehmen');
html = W.render(sample({ group: { track: 'Hafenrunde', by: 'Ana', startsIn: 12, members: 2, joined: false, duel: false } }), ui);
check(html.includes('Gruppenrennen: Hafenrunde') && html.includes('Start in 12 s') && html.includes('data-act="join"'), 'Gruppenrennen mit Mitfahren');
check(/data-act="group"[^>]*disabled/.test(html), 'kein zweites Gruppenrennen');
html = W.render(sample({ race: { track: 'Bergsprint', state: 'armed' } }), ui);
check(html.includes('Dein Rennen: Bergsprint') && html.includes('fahr zum Start') && /data-act="race"[^>]*disabled/.test(html), 'eigenes Rennen');
html = W.render(sample(), { tab: 'duel', collapsed: false, target: '3', track: 'Bergsprint' });
check(html.includes('<option value="3" selected>Max · Level 9</option>'), 'Duell: Gegner ausgewaehlt');
check(/data-act="duel"(?![^>]*disabled)/.test(html), 'Duell: Knopf aktiv mit Gegner und Strecke');
check(/data-act="duel"[^>]*disabled/.test(W.render(sample(), { tab: 'duel', target: '', track: '' })), 'Duell: ohne Auswahl gesperrt');
check(W.render(sample({ players: {} }), { tab: 'duel' }).includes('niemand sonst'), 'Duell: leere Liste (Lua schickt {})');
html = W.render(sample({ lang: 'en', invite: { from: 'Max', track: 'Bergsprint', left: 9 } }), ui);
check(html.includes('Max challenges you!') && html.includes('Accept') && html.includes('9 s left'), 'Englisch');
check(W.render(sample({ invite: { from: 'Max', track: 'x', left: 3 } }), { collapsed: true }).includes('bnw-badge'), 'eingeklappt: Hinweis auf Herausforderung');
check(W.render(null, ui).includes('Verbinde mit dem Server'), 'ohne Stand: Warten');
// Maskierung: Namen und Texte vom Server landen nie als HTML im Fenster
const evil = '<img src=x onerror=alert(1)>';
html = W.render(sample({ server: evil, msg: evil, me: { name: evil, level: '<b>' },
  players: [{ pid: '"><script>', name: evil, level: 1 }], tracks: [{ name: '"><i>', record: evil, by: evil }],
  invite: { from: evil, track: evil, left: 5 } }), ui);
check(!html.includes('<img') && !html.includes('<script') && !html.includes('"><i>') && html.includes('Level &lt;b&gt;'), 'alles maskiert');
html = W.render(sample({ players: [{ pid: '"><script>', name: evil, level: 1 }] }), { tab: 'duel' });
check(!html.includes('<script') && !html.includes('<img'), 'Duell-Liste maskiert');
// Anfragen
check(JSON.stringify(W.requestFor('race', { track: 'Bergsprint' }, ui)) === '{"a":"race","track":"Bergsprint"}', 'Anfrage: Rennen');
check(JSON.stringify(W.requestFor('accept', {}, ui)) === '{"a":"accept"}', 'Anfrage: Annehmen');
check(JSON.stringify(W.requestFor('duel', {}, { target: '3', track: 'Bergsprint' })) === '{"a":"duel","target":3,"track":"Bergsprint"}', 'Anfrage: Duell');
check(W.requestFor('duel', {}, { target: '', track: 'Bergsprint' }) === null, 'Anfrage: Duell ohne Gegner nicht');
check(W.requestFor('expand', {}, ui) === null, 'Ansicht: keine Anfrage');

// --- Im Browser (Playwright) --------------------------------------------------------------------------------------
async function browser() {
  let pw;
  try { pw = require('playwright'); } catch (e) { console.log('(Browser-Test übersprungen: playwright nicht gefunden)'); return; }
  const fs = require('fs');
  const shots = process.env.BEAMNET_SHOTS === '1';
  const docs = path.join(__dirname, '..', 'docs');
  const b = await pw.chromium.launch();
  const page = await b.newPage({ viewport: { width: 1100, height: 680 }, deviceScaleFactor: 1 });
  // Kulisse: ein schlichtes Bild wie im Spiel (Himmel, Huegel, Strasse), das Fenster rechts wie eine UI-App. Ueber einen
  // kleinen lokalen Server ausgeliefert (sonst gibt es kein localStorage fuer das Einklappen).
  const http = require('http');
  const pageHtml = `<!doctype html><html><head><meta charset="utf-8"><style>
    html,body{margin:0;height:100%;overflow:hidden;font-family:"Noto Sans",Arial,sans-serif}
    .scene{position:absolute;inset:0;background:linear-gradient(#5d8fc7 0%,#a9c9e6 46%,#c9b48a 47%,#8a7a55 70%,#5b5038 100%)}
    .hill{position:absolute;left:-10%;right:-10%;top:38%;height:22%;background:radial-gradient(ellipse at 30% 100%,#4f6b3a 0 55%,transparent 56%),radial-gradient(ellipse at 75% 100%,#5c7a42 0 50%,transparent 51%)}
    .road{position:absolute;left:50%;bottom:0;width:0;height:0;border-left:420px solid transparent;border-right:420px solid transparent;border-bottom:330px solid #3b3d42;transform:translateX(-50%)}
    .line{position:absolute;left:50%;bottom:0;width:10px;height:330px;transform:translateX(-50%);background:repeating-linear-gradient(#f2f2f2 0 28px,transparent 28px 60px);clip-path:polygon(40% 0,60% 0,100% 100%,0 100%)}
    .hud{position:absolute;left:16px;bottom:14px;color:#fff;font-size:28px;font-weight:700;text-shadow:0 2px 6px rgba(0,0,0,.6)}
    .hud small{display:block;font-size:12px;font-weight:400;opacity:.85}
    .tag{position:absolute;left:16px;top:12px;background:rgba(0,0,0,.55);color:#fff;font-size:12px;padding:4px 8px;border-radius:4px}
    #app{position:absolute;right:16px;top:60px;width:340px;height:560px;display:flex;flex-direction:column}
  </style></head><body><div class="scene"><div class="hill"></div><div class="road"></div><div class="line"></div></div>
    <div class="tag">Vorschau mit Testdaten – so sieht das BeamNet-Fenster im Spiel aus</div>
    <div class="hud">87 km/h<small>BeamMP · BeamNet | Server 1</small></div><div id="app"></div></body></html>`;
  const server = http.createServer((req, res) => { res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' }); res.end(pageHtml); });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  await page.goto('http://127.0.0.1:' + server.address().port + '/');
  await page.addScriptTag({ path: APP });
  await page.evaluate(() => {
    window.sent = [];
    window.app = BeamNetWindow.mount(document.getElementById('app'), { send: (r) => window.sent.push(r) });
  });
  const sentAll = () => page.evaluate(() => window.sent);
  const update = (s) => page.evaluate((st) => window.app.update(st), s);
  const shot = async (name) => { if (shots) await page.screenshot({ path: path.join(docs, name) }); };

  check((await page.textContent('#app')).includes('Verbinde mit dem Server'), 'Browser: wartet auf den Stand');
  await update(sample({ group: { track: 'Hafenrunde', by: 'Ana', startsIn: 18, members: 3, joined: false, duel: false },
    msg: 'Gruppenrennen auf Hafenrunde in 20 s, gestartet von Ana! Mitmachen: /rennen mit' }));
  await page.click('[data-act="join"]');
  check(JSON.stringify((await sentAll()).pop()) === '{"a":"join"}', 'Browser: Mitfahren klicken');
  await shot('fenster-rennen.png');
  await update(sample());
  await page.click('[data-act="race"][data-track="Bergsprint"]');
  check(JSON.stringify((await sentAll()).pop()) === '{"a":"race","track":"Bergsprint"}', 'Browser: Rennen starten klicken');
  // Duell: Gegner und Strecke waehlen, herausfordern
  await page.click('[data-act="tab"][data-tab="duel"]');
  check(await page.isDisabled('[data-act="duel"]'), 'Browser: Herausfordern erst nach Auswahl');
  await page.selectOption('[data-field="target"]', '3');
  await page.selectOption('[data-field="track"]', 'Bergsprint');
  check(!(await page.isDisabled('[data-act="duel"]')), 'Browser: Herausfordern freigegeben');
  await update(sample({ msg: 'Herausforderung an Max gesendet.' }));
  await shot('fenster-duell.png');
  await page.click('[data-act="duel"]');
  check(JSON.stringify((await sentAll()).pop()) === '{"a":"duel","target":3,"track":"Bergsprint"}', 'Browser: Herausfordern klicken');
  // Sicht des Gegners: Anfrage erscheint, Countdown laeuft, Annehmen
  await page.evaluate(() => { window.app.destroy(); window.sent = []; localStorage.setItem('beamnetWindowCollapsed', '1');
    window.app = BeamNetWindow.mount(document.getElementById('app'), { send: (r) => window.sent.push(r) }); });
  check(await page.isVisible('.bnw-pill'), 'Browser: eingeklappt bleibt eingeklappt');
  await update(sample({ me: { name: 'Max', level: 9, league: 'Silber', seasonXp: 310 },
    players: [{ pid: 1, name: 'Sebi', level: 12 }, { pid: 5, name: 'Ana', level: 15 }],
    invite: { from: 'Sebi', track: 'Bergsprint', left: 58 }, msg: '⚔️ Sebi fordert dich zum Duell auf Bergsprint heraus! Annehmen: /duell ja · ablehnen: /duell nein (60 s)' }));
  check(await page.isVisible('[data-act="accept"]'), 'Browser: Herausforderung klappt das Fenster auf');
  await page.waitForTimeout(2100);
  check(/noch 5[56] s/.test(await page.textContent('#app')), 'Browser: Countdown laeuft');
  await shot('fenster-anfrage.png');
  await page.click('[data-act="accept"]');
  check((await sentAll()).some((r) => r.a === 'accept'), 'Browser: Annehmen klicken');
  await update(sample({ me: { name: 'Max', level: 9, league: 'Silber' }, race: { track: 'Bergsprint', state: 'armed' },
    group: { track: 'Bergsprint', by: 'Sebi', startsIn: 15, members: 2, joined: true, duel: true },
    msg: '⚔️ Duell gegen Sebi auf Bergsprint – Start in 15 s.' }));
  check((await page.textContent('#app')).includes('Duell: Bergsprint'), 'Browser: Duell laeuft');
  await shot('fenster-duell-start.png');
  await page.click('[data-act="collapse"]');
  check(await page.isVisible('.bnw-pill'), 'Browser: einklappen');
  if (shots) {
    // Eingeklappt: nur der kleine Knopf am Rand
    await page.screenshot({ path: path.join(docs, 'fenster-zu.png'), clip: { x: 700, y: 30, width: 400, height: 110 } });
  }
  await b.close();
  server.close();
  if (shots) console.log('Bilder: ' + fs.readdirSync(docs).filter((f) => f.startsWith('fenster-')).join(', '));
}

browser().then(() => {
  console.log('Fenster: ' + passed + ' Prüfungen bestanden, ' + failed + ' fehlgeschlagen');
  process.exit(failed ? 1 : 0);
}).catch((e) => { console.log('FEHLER: ' + e.message); process.exit(1); });
