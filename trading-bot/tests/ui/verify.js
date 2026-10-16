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
const ok = (cond, msg) => { if (cond) console.log('  ✓ ' + msg); else { console.log('  ✗ ' + msg); problems.push(msg); } };

(async () => {
  const browser = await chromium.launch(launchOptions);
  async function page(opts) {
    const ctx = await browser.newContext(opts);
    const p = await ctx.newPage();
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
  await p.click('#b-save');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('Gespeichert'));
  ok((await p.inputValue('input[data-path="exits.take_profit_ladder"]')) === '30: 0.5, 80: 0.5', 'Leiter gespeichert und normalisiert angezeigt');
  const cfg = await (await p.request.get(URL + 'api/config')).json();
  ok(JSON.stringify(cfg.config.chains) === '["solana","base"]' && cfg.config['filters.allow_rugcheck_unknown'] === true, 'Chips/Schalter serverseitig übernommen');

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
  await p.keyboard.press('4'); ok(!(await p.$eval('#tab-log', (e) => e.hidden)), 'Taste 4 -> Protokoll');
  await p.keyboard.press('/'); ok(await p.evaluate(() => document.activeElement.id === 'q'), 'Taste / springt in die Suche');
  await p.keyboard.type('p'); ok((await p.inputValue('#q')) === 'p' && (await p.$eval('#paused', (e) => e.hidden)), 'p im Suchfeld tippt, pausiert nicht');
  await p.fill('#q', ''); await p.evaluate(() => document.activeElement.blur());
  await p.keyboard.press('p'); await p.waitForFunction(() => !document.querySelector('#paused').hidden);
  ok(true, 'Taste p pausiert');
  await p.keyboard.press('p'); await p.waitForFunction(() => document.querySelector('#paused').hidden);

  // --- Protokoll ---
  await p.click('nav [data-tab="log"]');
  const log = await p.textContent('#log');
  ok(log.includes('dashboard') && log.includes('manual'), 'Protokoll enthält Dashboard-Aktionen');
  await p.screenshot({ path: SHOTS + '/06-log.png' });

  // --- Reset + Reload merkt Reiter ---
  await p.click('nav [data-tab="control"]');
  await p.click('#b-reset-pos');
  await p.waitForSelector('dialog[open]');
  await p.click('#c-yes');
  await p.waitForFunction(() => document.querySelector('#toast').textContent.includes('zurückgesetzt'));
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
  for (const tab of ['overview', 'control', 'candidates']) {
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
