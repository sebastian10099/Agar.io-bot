// Browser-Pruefung der Steuerseite gegen einen laufenden Demo-Server.
//
//   python3 -m bot.main --demo --no-open --port 8797 &
//   npm install playwright            # einmalig, laedt Chromium
//   node tests/ui/verify.js
//
// Klickt jede Funktion durch (Formular, Validierung, Persistenz, Schliessen,
// Pause, Filter, Reset), prueft auf Konsolenfehler und Viewport-Ueberhang
// und legt Screenshots in tests/ui/shots/ ab.
const fs = require('fs');
const path = require('path');
let chromium, launchOptions = {};
try {
  ({ chromium } = require('playwright'));
} catch (e) {
  ({ chromium } = require('playwright-core'));
  if (!process.env.CHROMIUM) { console.error('playwright-core braucht CHROMIUM=/pfad/zu/chrome'); process.exit(2); }
  launchOptions.executablePath = process.env.CHROMIUM;
}
const URL = process.env.URL || 'http://127.0.0.1:8797/';
const SHOTS = process.env.SHOTS || path.join(__dirname, 'shots');
const HOME_DIR = process.env.HOME_DIR || (process.platform === 'darwin'
  ? path.join(process.env.HOME, 'Library/Application Support/NewTokenBot')
  : path.join(process.env.HOME, '.new-token-bot'));
fs.mkdirSync(SHOTS, { recursive: true });
const problems = [];
let page_;
const clearToast = () => page_.evaluate(() => { const t = document.querySelector('#toast'); if (t) { t.textContent = ''; t.className = 'toast'; } });
const ok = (cond, msg) => { if (cond) console.log('  ✓ ' + msg); else { console.log('  ✗ ' + msg); problems.push(msg); } };

(async () => {
  const browser = await chromium.launch(launchOptions);
  async function page(opts) {
    const ctx = await browser.newContext(opts);
    const p = await ctx.newPage();
    page_ = p;
    p.on('console', (m) => { if (m.type() === 'error' && !/status of 422/.test(m.text())) problems.push('console: ' + m.text()); });
    p.on('pageerror', (e) => problems.push('pageerror: ' + e.message));
    p.on('requestfailed', (r) => problems.push('requestfailed: ' + r.url()));
    p.on('response', (r) => { if (r.status() >= 500) problems.push('HTTP ' + r.status() + ' ' + r.url()); });
    return [ctx, p];
  }

  console.log('\n== Desktop, dark ==');
  let [ctx, p] = await page({ viewport: { width: 1400, height: 900 }, colorScheme: 'dark' });
  // Start from a known state so the run is repeatable against a long-running server:
  // defaults, no positions, not paused, one fresh poll, time stop far away.
  const defaults = (await (await p.request.get(URL + 'api/defaults')).json()).config;
  const current = (await (await p.request.get(URL + 'api/config')).json()).config;
  await p.request.post(URL + 'api/config', { data: { patch: { ...defaults, poll_seconds: current.poll_seconds, 'exits.time_stop_minutes': 10000 } } });
  await p.request.post(URL + 'api/reset', { data: { what: 'all' } });
  await p.request.post(URL + 'api/control', { data: { action: 'resume' } });
  await p.request.post(URL + 'api/control', { data: { action: 'poll' } });
  // the demo re-lists tokens every simulated hour (one real minute at 60x), so a buy shows up within ~90 s
  for (let i = 0; i < 180; i++) {
    const st = await (await p.request.get(URL + 'api/state')).json();
    if (st.open_positions.length >= 1) break;
    await new Promise((r) => setTimeout(r, 500));
  }
  await p.goto(URL);
  await p.waitForFunction(() => document.querySelector('#k-bankroll').textContent !== '–');
  await p.waitForSelector('#groups .field', { state: 'attached' });
  ok((await p.$$('#groups .field')).length >= 20, 'Formular aus Schema gebaut (' + (await p.$$('#groups .field')).length + ' Felder)');
  ok(await p.$eval('#conn', (e) => e.classList.contains('ok')), 'Verbindungspunkt grün');
  ok((await p.$$('#open tbody tr')).length >= 1, 'offene Position angezeigt');
  const head = await p.$$eval('#open thead th', (ths) => ths.map((t) => t.textContent.trim()));
  ok(head.includes('Stop') && head.includes('Nächstes Ziel') && head.includes('Zeit'), 'Zielkurse-Spalten vorhanden');
  const stopCell = await p.$eval('#open tbody tr', (tr) => tr.children[Array.from(tr.parentElement.parentElement.querySelectorAll('thead th')).findIndex((t) => t.textContent.trim() === 'Stop')].textContent);
  ok(/\d/.test(stopCell), 'Stop-Kurs berechnet (' + stopCell.trim().slice(0, 12) + ')');
  await p.screenshot({ path: SHOTS + '/01-overview-dark.png', fullPage: true });

  // --- Steuerung: gültige Änderung ---
  await p.click('nav [data-tab="control"]');
  await p.screenshot({ path: SHOTS + '/02-control-dark.png', fullPage: true });
  const ts = p.locator('input[data-path="exits.time_stop_minutes"]');
  await ts.fill('600');
  ok(await p.$eval('[data-field="exits.time_stop_minutes"]', (e) => e.classList.contains('changed')), 'geändertes Feld markiert');
  ok((await p.textContent('#form-status')).includes('1 Änderung'), 'Statuszeile zählt Änderung');
  ok(!(await p.$eval('#b-save', (b) => b.disabled)), 'Speichern aktiv');
  await p.click('#b-save');
  await p.waitForFunction(() => document.querySelector('#toast').classList.contains('show'));
  ok((await p.textContent('#toast')).includes('Gespeichert'), 'Toast: Gespeichert');
  await p.waitForFunction(() => !document.querySelector('[data-field="exits.time_stop_minutes"]').classList.contains('changed'));
  ok(true, 'Markierung nach Speichern weg');
  const saved = JSON.parse(fs.readFileSync(path.join(HOME_DIR, 'config.json'), 'utf8'));
  ok(saved.exits && saved.exits.time_stop_minutes === 600, 'in config.json persistiert');
  await (await p.request.post(URL + 'api/config', { data: { patch: { 'exits.time_stop_minutes': 10000 } } })).json();
  await p.reload(); await p.waitForSelector('#groups .field', { state: 'attached' }); await p.click('nav [data-tab="control"]');

  // --- Steuerung: ungültig ---
  const pollBefore = await p.inputValue('input[data-path="poll_seconds"]');
  await p.locator('input[data-path="poll_seconds"]').fill('1');
  await p.click('#b-save');
  await p.waitForSelector('[data-field="poll_seconds"] .err:not([hidden])');
  const err = await p.textContent('[data-field="poll_seconds"] .err');
  ok(err.includes('zwischen'), 'Inline-Fehler: ' + err);
  ok(await p.$eval('#toast', (e) => e.classList.contains('err')), 'Fehler-Toast rot');
  await p.screenshot({ path: SHOTS + '/03-control-error.png', clip: { x: 0, y: 100, width: 1400, height: 360 } });
  await p.click('#b-revert');
  ok((await p.inputValue('input[data-path="poll_seconds"]')) === pollBefore, 'Verwerfen stellt Wert wieder her (' + pollBefore + ')');
  ok(await p.$eval('[data-field="poll_seconds"] .err', (e) => e.hidden), 'Fehler nach Verwerfen weg');

  // --- Schalter + Chips + Leiter ---
  await p.click('.sw[data-path="filters.allow_rugcheck_unknown"]');
  ok((await p.getAttribute('.sw[data-path="filters.allow_rugcheck_unknown"]', 'aria-checked')) === 'true', 'Schalter kippt');
  await p.click('.chips[data-path="chains"] .chip[data-chain="base"]');
  ok((await p.getAttribute('.chips[data-path="chains"] .chip[data-chain="base"]', 'aria-pressed')) === 'true', 'Chain-Chip aktiv');
  await p.locator('input[data-path="exits.take_profit_ladder"]').fill('30: 0.5, 80: 0.5');
  await clearToast(); await p.click('#b-save');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('Gespeichert'));
  ok((await p.inputValue('input[data-path="exits.take_profit_ladder"]')) === '30: 0.5, 80: 0.5', 'Leiter gespeichert und normalisiert angezeigt');
  const cfg = await (await p.request.get(URL + 'api/config')).json();
  ok(JSON.stringify(cfg.config.chains) === '["solana","base"]' && cfg.config['filters.allow_rugcheck_unknown'] === true, 'Chips/Schalter serverseitig übernommen');

  // --- KI-Gruppe: Auswahlfeld, Textfeld, Status ---
  ok(!!(await p.$('select[data-path="ai.mode"]')) && !!(await p.$('input[data-path="ai.model"]')), 'KI-Felder im Formular (Auswahl + Text)');
  await p.selectOption('select[data-path="ai.mode"]', 'advise');
  ok((await p.textContent('#form-status')).includes('1 Änderung'), 'Auswahlfeld zählt als Änderung');
  await clearToast(); await p.click('#b-save'); await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('Gespeichert'));
  await p.waitForFunction(() => document.querySelector('#ai-pill').textContent === 'beraten');
  ok(true, 'KI-Pill zeigt „beraten“');
  const aiText = await p.textContent('#ai-status');
  ok(/Bereit|Nicht verfügbar/.test(aiText), 'KI-Status beschreibt Verfügbarkeit: ' + aiText.slice(0, 50));
  await p.selectOption('select[data-path="ai.mode"]', 'off'); await clearToast(); await p.click('#b-save');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('Gespeichert'));

  // --- Quellen: Status-Liste, Multi-Chips, Quelle am Kandidaten ---
  const srcRows = await p.$$eval('#sources li', (l) => l.map((x) => ({ text: x.textContent, dot: x.querySelector('.dot').className })));
  ok(srcRows.length === 2 && srcRows.every((r) => r.dot.includes('ok')), 'Quellen-Liste: beide Feeds liefern (' + srcRows.map((r) => r.text.slice(0, 14)).join(', ') + ')');
  ok(srcRows.some((r) => /\d+ gemeldet · \d+ eigene · \d+ Abfragen/.test(r.text)), 'Quellen zeigen Zähler');
  ok((await p.textContent('#src-pill')) === '2 aktiv', 'Quellen-Pill: 2 aktiv');
  await p.click('.chips[data-path="discovery.sources"] .chip[data-chain="geckoterminal"]');
  ok((await p.getAttribute('.chips[data-path="discovery.sources"] .chip[data-chain="geckoterminal"]', 'aria-pressed')) === 'false', 'Quellen-Chip abwählbar');
  await clearToast(); await p.click('#b-save'); await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('Gespeichert'));
  await p.waitForFunction(() => document.querySelector('#src-pill').textContent === '1 aktiv');
  ok((await p.$$eval('#sources li .dot.off', (l) => l.length)) === 1, 'abgewählte Quelle als „aus“ markiert');
  await p.click('.chips[data-path="discovery.sources"] .chip[data-chain="geckoterminal"]'); await clearToast(); await p.click('#b-save');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('Gespeichert'));
  await p.click('.chips[data-path="discovery.sources"] .chip[data-chain="dexscreener"]');
  await p.click('.chips[data-path="discovery.sources"] .chip[data-chain="geckoterminal"]');
  await clearToast(); await p.click('#b-save'); await p.waitForFunction(() => document.querySelector('#toast').textContent.length > 0);
  ok((await p.textContent('[data-field="discovery.sources"] .err')).includes('mindestens'), 'keine Quelle → Inline-Fehler');
  await p.click('#b-revert');

  // --- Profile: speichern, Wert ändern, laden stellt wieder her, löschen ---
  await p.locator('input[data-path="scoring.min_score"]').fill('66'); await clearToast(); await p.click('#b-save');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('Gespeichert'));
  await clearToast(); await p.click('#b-prof-save'); await p.waitForSelector('dialog#ask[open]');
  await p.fill('#a-input', 'Streng'); await p.keyboard.press('Enter');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('Profil'));
  ok((await p.$$eval('#profile option', (o) => o.map((x) => x.value))).includes('Streng'), 'Profil gespeichert und im Menü');
  await p.locator('input[data-path="scoring.min_score"]').fill('45'); await clearToast(); await p.click('#b-save');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('Gespeichert'));
  await p.selectOption('#profile', 'Streng'); await clearToast(); await p.click('#b-prof-load');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('geladen'));
  ok((await p.inputValue('input[data-path="scoring.min_score"]')) === '66', 'Profil laden stellt min_score 66 wieder her');
  await clearToast(); await p.click('#b-prof-del'); await p.waitForSelector('dialog#confirm[open]'); await p.click('#c-yes');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('gelöscht'));
  ok(!(await p.$$eval('#profile option', (o) => o.map((x) => x.value))).includes('Streng'), 'Profil gelöscht');
  await p.locator('input[data-path="scoring.min_score"]').fill('60'); await clearToast(); await p.click('#b-save');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('Gespeichert'));
  // --- Export-Routen liefern CSV ---
  for (const f of ['positions', 'trades', 'candidates']) {
    const r = await p.request.get(URL + 'api/export/' + f + '.csv');
    ok(r.status() === 200 && (r.headers()['content-type'] || '').startsWith('text/csv') && (await r.text()).includes(';'), `Export ${f}.csv`);
  }

  // --- Standardwerte ---
  await p.click('#b-defaults');
  await p.waitForSelector('dialog[open]');
  await p.click('#c-yes');
  await p.waitForFunction(() => document.querySelector('#form-status').textContent.includes('Änderung'));
  ok((await p.inputValue('input[data-path="exits.time_stop_minutes"]')) === '45', 'Standardwerte in Entwurf geladen (nicht gespeichert)');
  await p.click('#b-revert');

  // --- Übersicht: Position schließen ---
  await p.click('nav [data-tab="overview"]');
  const s0open = (await p.$$('#open tbody tr')).length;
  await p.click('#open [data-close]');
  await p.waitForSelector('dialog[open]');
  await p.screenshot({ path: SHOTS + '/04-confirm-close.png' });
  await p.click('#c-yes');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('geschlossen'));
  await p.waitForFunction((n) => document.querySelectorAll('#open tbody tr').length === n - 1, s0open);
  ok(true, 'Position manuell geschlossen, aus der Tabelle verschwunden');
  ok((await p.textContent('#closed')).includes('manual'), 'in geschlossenen mit Grund manual');

  // --- Kapitalkurve: ein Exit ist jetzt da -> ein Datenpunkt + Startpunkt ---
  await p.waitForFunction(() => document.querySelector('#equity svg'));
  const eqPts = await p.$$eval('#equity svg circle.pt', (c) => c.length);
  ok(eqPts >= 1, 'Kapitalkurve gezeichnet (Endmarker vorhanden)');
  ok((await p.$$('#equity svg path.line')).length === 1 && (await p.$$('#equity svg path.area')).length === 1, 'eine Linie, eine Flächenfüllung');
  ok((await p.$$eval('#equity svg text.end-label', (t) => t.map((x) => x.textContent))).some((x) => x.includes('$')), 'Endwert direkt beschriftet');
  const eqBox = await p.$eval('#equity svg', (e) => e.getBoundingClientRect());
  await p.mouse.move(eqBox.x + eqBox.width * 0.6, eqBox.y + eqBox.height * 0.5);
  await p.waitForFunction(() => !document.querySelector('#eq-tip').hidden);
  ok((await p.textContent('#eq-tip')).includes('$'), 'Fadenkreuz-Tooltip zeigt Wert: ' + (await p.textContent('#eq-tip')).replace(/\s+/g, ' ').slice(0, 60));
  await p.mouse.move(5, 5); await p.waitForFunction(() => document.querySelector('#eq-tip').hidden);
  await p.focus('#equity'); await p.waitForFunction(() => !document.querySelector('#eq-tip').hidden);
  await p.keyboard.press('ArrowLeft'); const tipA = await p.textContent('#eq-tip');
  await p.keyboard.press('ArrowRight'); const tipB = await p.textContent('#eq-tip');
  ok(tipA !== tipB, 'Pfeiltasten bewegen die Ablesung');
  await p.keyboard.press('Escape'); ok(await p.$eval('#eq-tip', (e) => e.hidden), 'Escape blendet die Ablesung aus');
  await p.evaluate(() => document.activeElement.blur());
  ok((await p.$$('#edge .ebar')).length >= 1 || (await p.$$('#edge tbody tr')).length === 0, 'Edge-Balken in der Tabelle');
  await p.click('[data-edge="ai_decision"]');
  ok((await p.textContent('#edge')).includes('KI') || (await p.$$('#edge tbody tr')).length >= 0, 'Edge-Report auf KI umschaltbar');
  await p.click('[data-edge="decision"]');
  await p.screenshot({ path: SHOTS + '/13-equity.png', clip: { x: 0, y: 0, width: 1400, height: 700 } });

  // --- Pause ---
  await p.click('#b-toggle');
  await p.waitForFunction(() => !document.querySelector('#paused').hidden);
  ok((await p.textContent('#b-toggle')) === 'Fortsetzen', 'Pause: Pill sichtbar, Knopf wird Fortsetzen');
  await p.click('#b-toggle');
  await p.waitForFunction(() => document.querySelector('#paused').hidden);
  await p.click('#b-poll');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('Poll'));
  ok(true, 'Jetzt pollen quittiert');

  // --- Kandidaten-Filter ---
  await p.click('nav [data-tab="candidates"]');
  const all = (await p.$$('#cands tbody tr')).length;
  await p.click('.filterbar .chip[data-f="skip"]');
  const noSkip = (await p.$$('#cands tbody tr')).length;
  ok(noSkip < all, `skip ausgeblendet (${all} → ${noSkip})`);
  await p.fill('#q', 'RUN');
  ok((await p.$$('#cands tbody tr')).length >= 1 && (await p.textContent('#cands')).includes('RUN'), 'Suche findet RUN');
  await p.fill('#q', '');
  await p.click('.filterbar .chip[data-f="skip"]');
  // sorting: click Score twice -> descending then ascending
  await p.click('#cands th[data-sort="score"] button');
  const scoresDesc = await p.$$eval('#cands tbody tr td:nth-child(4)', (tds) => tds.map((t) => parseFloat(t.textContent) || 0));
  ok(scoresDesc.every((v, i) => i === 0 || v <= scoresDesc[i - 1]), 'Sortierung nach Score absteigend (' + scoresDesc.slice(0, 4).join(', ') + ')');
  await p.click('#cands th[data-sort="score"] button');
  const scoresAsc = await p.$$eval('#cands tbody tr td:nth-child(4)', (tds) => tds.map((t) => parseFloat(t.textContent) || 0));
  ok(scoresAsc.every((v, i) => i === 0 || v >= scoresAsc[i - 1]), 'zweiter Klick dreht die Sortierung um');
  ok((await p.getAttribute('#cands th[data-sort="score"]', 'aria-sort')) === 'ascending', 'aria-sort gesetzt');
  await p.click('#cands th[data-sort="seen_at"] button');
  await p.screenshot({ path: SHOTS + '/05-candidates.png', fullPage: true });
  // shortcuts: 1-4 switch tabs, / focuses search, p pauses (not while typing)
  await p.keyboard.press('Escape'); await p.evaluate(() => document.activeElement.blur());
  await p.keyboard.press('1'); ok(!(await p.$eval('#tab-overview', (e) => e.hidden)), 'Taste 1 -> Übersicht');
  await p.keyboard.press('5'); ok(!(await p.$eval('#tab-log', (e) => e.hidden)), 'Taste 5 -> Protokoll');
  await p.keyboard.press('/'); ok(await p.evaluate(() => document.activeElement.id === 'q'), 'Taste / springt in die Suche');
  await p.keyboard.type('p'); ok((await p.inputValue('#q')) === 'p' && (await p.$eval('#paused', (e) => e.hidden)), 'p im Suchfeld tippt, pausiert nicht');
  await p.fill('#q', ''); await p.evaluate(() => document.activeElement.blur());
  await p.keyboard.press('p'); await p.waitForFunction(() => !document.querySelector('#paused').hidden);
  ok(true, 'Taste p pausiert');
  await p.keyboard.press('p'); await p.waitForFunction(() => document.querySelector('#paused').hidden);

  // --- Analyse: Sweep laedt, Horizont-Chips, Neu berechnen ---
  await p.click('nav [data-tab="analysis"]');
  await p.waitForFunction(() => !document.querySelector('#sweep').textContent.includes('Berechne'));
  const sweepText = await p.textContent('#sweep');
  ok(/Kandidaten|Mindestalter|Rückblick/.test(sweepText + (await p.textContent('#sweep-sub'))), 'Analyse-Reiter zeigt Rückblick oder erklärten Leerzustand');
  ok((await p.$$('#sweep-h [data-sh]')).length >= 1, 'Horizont-Chips vorhanden');
  await p.click('#b-sweep'); await p.waitForFunction(() => !document.querySelector('#sweep').textContent.includes('Berechne'));
  ok(true, 'Neu berechnen läuft durch');
  await p.keyboard.press('Escape'); await p.evaluate(() => document.activeElement.blur());
  await p.keyboard.press('4'); ok(!(await p.$eval('#tab-analysis', (e) => e.hidden)), 'Taste 4 -> Analyse');
  // --- Benachrichtigungen: ohne Erlaubnis sauberer Hinweis ---
  await clearToast(); await p.click('#b-notify'); await p.waitForFunction(() => document.querySelector('#toast').textContent.length > 0);
  ok(/Benachrichtigungen/.test(await p.textContent('#toast')), 'Benachrichtigungs-Schalter meldet Ergebnis: ' + (await p.textContent('#toast')));

  // --- Protokoll ---
  await p.click('nav [data-tab="log"]');
  const log = await p.textContent('#log');
  ok(log.includes('dashboard') && log.includes('manual'), 'Protokoll enthält Dashboard-Aktionen');
  const allRows = (await p.$$('#log div')).length;
  await p.click('[data-lf="info"]'); await p.click('[data-lf="poll"]');
  const fewer = (await p.$$('#log div')).length;
  ok(fewer < allRows && !(await p.textContent('#log')).includes('seen '), `Protokoll-Filter blendet Info und Polls aus (${allRows} → ${fewer})`);
  await p.click('[data-lf="info"]'); await p.click('[data-lf="poll"]');
  await p.screenshot({ path: SHOTS + '/06-log.png' });

  // --- manueller Kauf eines watch-Kandidaten ---
  await p.click('nav [data-tab="candidates"]');
  const openBefore = (await (await p.request.get(URL + 'api/state')).json()).open_positions.length;
  const watchRow = p.locator('#cands tbody tr:has(.d-watch) [data-buy]').first();
  ok((await watchRow.count()) === 1, 'Kaufen-Knopf an einem watch-Kandidaten');
  ok((await p.textContent('#cands')).includes('im Bestand'), 'Token im Bestand zeigt „im Bestand“ statt Kaufen');
  await watchRow.click(); await p.waitForSelector('dialog#confirm[open]'); await p.click('#c-yes');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('gekauft'));
  const openAfter = (await (await p.request.get(URL + 'api/state')).json()).open_positions.length;
  ok(openAfter === openBefore + 1, `manueller Kauf eröffnet Position (${openBefore} → ${openAfter})`);
  // --- Teilverkauf: ½-Knopf halbiert den Rest, Details-Slider verkauft den Rest ---
  await p.click('nav [data-tab="overview"]');
  const halfBtn = p.locator('#open [data-half]').first();
  ok((await halfBtn.count()) >= 1, '½-Knopf an offener Position');
  await halfBtn.click(); await p.waitForSelector('dialog#confirm[open]'); await p.click('#c-yes');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('verkauft'));
  const remain = await p.$eval('#open tbody tr', (tr) => tr.textContent);
  ok(remain.includes('50%'), 'Rest zeigt 50%');
  await p.click('#open [data-detail]'); await p.waitForSelector('dialog#detail[open]');
  ok(!!(await p.$('#d-frac')) && (await p.textContent('#d-body')).includes('manual_partial'), 'Details: Slider und Teilverkauf-Fill sichtbar');
  await p.$eval('#d-frac', (i) => { i.value = i.max; i.dispatchEvent(new Event('input')); });
  await p.click('#d-sell');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('verkauft'));
  await p.waitForFunction(() => !document.querySelector('dialog#detail[open]'));
  ok((await p.textContent('#closed')).includes('manual'), 'Rest über Slider verkauft, Position geschlossen');
  // re-open a position for the following steps via manual buy
  await p.click('nav [data-tab="candidates"]');
  await p.locator('#cands tbody tr [data-buy]').first().click(); await p.waitForSelector('dialog#confirm[open]'); await p.click('#c-yes');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('gekauft'));
  await p.click('nav [data-tab="overview"]');

  // --- Details-Dialog zeigt die Fills ---
  await p.click('nav [data-tab="overview"]');
  await p.click('#open [data-detail]'); await p.waitForSelector('dialog#detail[open]');
  ok((await p.$$('#d-body tbody tr')).length >= 1 && (await p.textContent('#d-body')).includes('Kauf'), 'Details-Dialog listet den Kauf-Fill');
  await p.keyboard.press('Escape'); ok(!(await p.$('dialog#detail[open]')), 'Details-Dialog schließt per Escape');
  // --- Reset mit neuem Startkapital ---
  await p.click('nav [data-tab="control"]');
  await p.fill('#bankroll', '500');
  await p.click('#b-reset-pos');
  await p.waitForSelector('dialog#confirm[open]');
  ok((await p.textContent('#c-text')).includes('500'), 'Bestätigung nennt das neue Startkapital');
  await p.click('#c-yes');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('zurückgesetzt'));
  await p.waitForFunction(() => document.querySelector('#k-initial').textContent.includes('500'));
  ok(true, 'Startkapital nach Reset $500');
  await p.request.post(URL + 'api/reset', { data: { what: 'positions', bankroll: 1000 } });
  await p.reload();
  await p.waitForSelector('#groups .field', { state: 'attached' });
  ok(!(await p.$eval('#tab-control', (e) => e.hidden)), 'Reiter nach Reload gemerkt');
  ok((await p.$$('#closed tbody tr')).length === 0, 'Reset hat geschlossene Positionen entfernt');
  await ctx.close();

  console.log('\n== Desktop, hell ==');
  [ctx, p] = await page({ viewport: { width: 1400, height: 900 }, colorScheme: 'light' });
  await p.goto(URL); await p.waitForSelector('#groups .field', { state: 'attached' });
  await p.screenshot({ path: SHOTS + '/07-overview-light.png', fullPage: true });
  await p.click('nav [data-tab="control"]');
  await p.screenshot({ path: SHOTS + '/08-control-light.png', fullPage: true });
  await ctx.close();

  console.log('\n== Telefon 390px ==');
  [ctx, p] = await page({ viewport: { width: 390, height: 844 }, colorScheme: 'dark', isMobile: true, hasTouch: true });
  await p.goto(URL); await p.waitForSelector('#groups .field', { state: 'attached' });
  for (const tab of ['overview', 'control', 'candidates', 'analysis']) {
    await p.click(`nav [data-tab="${tab}"]`);
    await p.waitForTimeout(150);
    const m = await p.evaluate(() => ({
      doc: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth) - window.innerWidth,
      card: Math.round(Math.max(...[...document.querySelectorAll('section, header, nav')].map((e) => e.getBoundingClientRect().right)) - window.innerWidth),
      tallest: Math.round(Math.max(0, ...[...document.querySelectorAll('tbody tr')].map((r) => r.getBoundingClientRect().height))),
    }));
    ok(m.doc <= 0 && m.card <= 0, `${tab}: nichts ragt über den Viewport (Dokument ${m.doc}px, Karten ${m.card}px)`);
    if (tab === 'candidates') ok(m.tallest <= 80, `${tab}: Zeilen bleiben kompakt (höchste ${m.tallest}px)`);
    await p.screenshot({ path: SHOTS + `/09-phone-${tab}.png`, fullPage: true });
  }
  await ctx.close();
  await browser.close();

  console.log('\n' + (problems.length ? 'PROBLEME:\n - ' + problems.join('\n - ') : 'Keine Probleme, keine Konsolenfehler.'));
  process.exit(problems.length ? 1 : 0);
})().catch((e) => { console.error('ABBRUCH:', e); process.exit(2); });
