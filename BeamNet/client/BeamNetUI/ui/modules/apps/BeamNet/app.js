// BeamNet-Fenster (UI-App fuer BeamNG/BeamMP): Rennen, Gruppenrennen und Duelle per Klick statt Chat-Befehl.
// Der Stand kommt vom Server-Plugin BeamNetCore (Ereignis "BeamNetUI"), Klicks gehen als kurze Anfragen zurueck
// (extensions.beamnetUI.uiRequest). Die Darstellung ist reines HTML ohne Bibliotheken, damit sie sich auch ausserhalb
// des Spiels pruefen laesst (tests/ui_window_test.js).
var BeamNetWindow = (function () {
  'use strict';

  var TEXT = {
    de: {
      title: 'BeamNet', races: 'Rennen', duel: 'Duell', level: 'Level', season: 'Saison', guest: 'Gast',
      noTracks: 'Auf dieser Map gibt es noch keine Strecken.', record: 'Rekord', noTime: 'noch keine Zeit',
      weekly: 'Strecke der Woche', drive: 'Fahren', group: 'Gruppe', join: 'Mitfahren', stop: 'Beenden',
      accept: 'Annehmen', decline: 'Ablehnen', challenges: 'fordert dich heraus!', track: 'Strecke',
      secondsLeft: 'noch %s s', groupRace: 'Gruppenrennen', duelRace: 'Duell', startsIn: 'Start in %s s',
      running: 'läuft', drivers: '%s Fahrer', joined: 'du fährst mit', yourRace: 'Dein Rennen',
      armed: 'fahr zum Start', go: 'läuft – ab ins Ziel!', opponent: 'Gegner', pick: 'auswählen …',
      challenge: '⚔️ Herausfordern', noPlayers: 'Gerade ist niemand sonst auf diesem Server.',
      duelHint: 'Der Gegner bekommt die Anfrage hier im Fenster und im Chat (60 s Zeit).',
      waiting: 'Verbinde mit dem Server …', open: 'BeamNet öffnen', close: 'Einklappen'
    },
    en: {
      title: 'BeamNet', races: 'Races', duel: 'Duel', level: 'Level', season: 'Season', guest: 'Guest',
      noTracks: 'There are no tracks on this map yet.', record: 'Record', noTime: 'no time yet',
      weekly: 'Track of the week', drive: 'Drive', group: 'Group', join: 'Join', stop: 'Stop',
      accept: 'Accept', decline: 'Decline', challenges: 'challenges you!', track: 'Track',
      secondsLeft: '%s s left', groupRace: 'Group race', duelRace: 'Duel', startsIn: 'starts in %s s',
      running: 'running', drivers: '%s drivers', joined: 'you are in', yourRace: 'Your race',
      armed: 'drive to the start', go: 'running – go for the finish!', opponent: 'Opponent', pick: 'choose …',
      challenge: '⚔️ Challenge', noPlayers: 'Nobody else is on this server right now.',
      duelHint: 'Your opponent gets the request here in the window and in the chat (60 s).',
      waiting: 'Connecting to the server …', open: 'Open BeamNet', close: 'Collapse'
    }
  };

  var CSS = [
    '.bnw{font-family:"Noto Sans","Segoe UI",Roboto,Arial,sans-serif;font-size:13px;color:#eef1f5;line-height:1.35;',
    'width:100%;max-height:100%;display:flex;flex-direction:column;pointer-events:auto;user-select:none}',
    '.bnw *{box-sizing:border-box}',
    '.bnw-panel{background:rgba(18,21,27,.92);border:1px solid rgba(255,255,255,.08);border-radius:8px;',
    'box-shadow:0 8px 24px rgba(0,0,0,.45);overflow:hidden;display:flex;flex-direction:column;max-height:100%}',
    '.bnw-head{display:flex;align-items:center;gap:8px;padding:9px 10px;background:linear-gradient(90deg,#ff6a00,#ff9a3c);color:#16110b}',
    '.bnw-head b{font-size:14px;letter-spacing:.3px}.bnw-head span{opacity:.8;font-size:12px;flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
    '.bnw-x{border:0;background:rgba(0,0,0,.18);color:#16110b;border-radius:4px;width:24px;height:22px;cursor:pointer;font-weight:700}',
    '.bnw-me{padding:8px 10px;border-bottom:1px solid rgba(255,255,255,.07);display:flex;gap:6px;flex-wrap:wrap;align-items:center}',
    '.bnw-me b{font-size:13px;margin-right:2px}',
    '.bnw-chip{background:rgba(255,255,255,.08);border-radius:10px;padding:1px 8px;font-size:11.5px;color:#cfd6df}',
    '.bnw-banner{margin:8px 10px 0;padding:8px 10px;border-radius:6px;background:rgba(255,122,26,.14);border:1px solid rgba(255,122,26,.45)}',
    '.bnw-banner.blue{background:rgba(64,156,255,.13);border-color:rgba(64,156,255,.45)}',
    '.bnw-banner.green{background:rgba(52,199,120,.13);border-color:rgba(52,199,120,.45)}',
    '.bnw-banner .t{font-weight:700;margin-bottom:2px}.bnw-banner .s{color:#c9d1db;font-size:12px}',
    '.bnw-row{display:flex;gap:6px;margin-top:7px}',
    '.bnw-btn{flex:1;border:0;border-radius:5px;padding:7px 8px;font:inherit;font-weight:700;cursor:pointer;color:#16110b;background:#ff8a2a}',
    '.bnw-btn:hover{filter:brightness(1.12)}.bnw-btn:disabled{opacity:.45;cursor:default;filter:none}',
    '.bnw-btn.ghost{background:rgba(255,255,255,.1);color:#eef1f5}.bnw-btn.green{background:#34c778}.bnw-btn.red{background:#ff5a5a}',
    '.bnw-btn.small{flex:0 0 auto;padding:5px 9px;font-size:12px}',
    '.bnw-tabs{display:flex;margin:10px 10px 0;background:rgba(255,255,255,.06);border-radius:6px;padding:3px}',
    '.bnw-tab{flex:1;border:0;background:transparent;color:#c9d1db;padding:6px;border-radius:4px;font:inherit;font-weight:700;cursor:pointer}',
    '.bnw-tab.on{background:#ff8a2a;color:#16110b}',
    '.bnw-body{padding:8px 10px 10px;overflow-y:auto;flex:1;min-height:60px}',
    '.bnw-track{display:flex;align-items:center;gap:8px;padding:7px 8px;border-radius:6px;background:rgba(255,255,255,.04);margin-bottom:6px}',
    '.bnw-track .n{flex:1;min-width:0}.bnw-track .n b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}',
    '.bnw-track .n small{color:#9aa6b4;font-size:11.5px}.bnw-star{color:#ffc53d}',
    '.bnw-label{display:block;color:#9aa6b4;font-size:11.5px;margin:8px 0 4px}',
    '.bnw-select{width:100%;padding:7px 8px;border-radius:5px;border:1px solid rgba(255,255,255,.14);background:#232833;color:#eef1f5;font:inherit}',
    '.bnw-hint{color:#9aa6b4;font-size:11.5px;margin-top:8px}',
    '.bnw-msg{padding:7px 10px;border-top:1px solid rgba(255,255,255,.07);color:#cfd6df;font-size:12px;background:rgba(0,0,0,.18)}',
    '.bnw-empty{color:#9aa6b4;padding:14px 4px;text-align:center}',
    '.bnw-pill{align-self:flex-end;display:inline-flex;align-items:center;gap:6px;border:0;border-radius:18px;padding:7px 12px;cursor:pointer;',
    'background:linear-gradient(90deg,#ff6a00,#ff9a3c);color:#16110b;font:inherit;font-weight:700;box-shadow:0 4px 14px rgba(0,0,0,.4)}',
    '.bnw-badge{background:#ff3b3b;color:#fff;border-radius:9px;padding:0 6px;font-size:11px}'
  ].join('');

  function esc(v) {
    return String(v == null ? '' : v).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }
  function fmt(text) {
    var args = Array.prototype.slice.call(arguments, 1), i = 0;
    return text.replace(/%s/g, function () { return args[i++]; });
  }
  function list(v) { return Array.isArray(v) ? v : []; }

  // Ganzes Fenster als HTML aus Stand (state, vom Server) und Ansicht (ui: Tab, eingeklappt, Auswahl im Duell).
  function render(state, ui) {
    var t = TEXT[(state && state.lang) === 'en' ? 'en' : 'de'];
    var invite = state && state.invite;
    if (ui.collapsed) {
      return '<button class="bnw-pill" data-act="expand" title="' + esc(t.open) + '">🏁 ' + esc(t.title) +
        (invite ? ' <span class="bnw-badge">1</span>' : '') + '</button>';
    }
    var h = '<div class="bnw-panel"><div class="bnw-head"><b>🏁 ' + esc(t.title) + '</b><span>' +
      esc(state ? [state.server, state.map].filter(Boolean).join(' · ') : '') + '</span>' +
      '<button class="bnw-x" data-act="collapse" title="' + esc(t.close) + '">–</button></div>';
    if (!state) return h + '<div class="bnw-empty">' + esc(t.waiting) + '</div></div>';
    var me = state.me || {};
    h += '<div class="bnw-me"><b>' + esc(me.name) + '</b>' +
      (me.guest ? '<span class="bnw-chip">' + esc(t.guest) + '</span>' : '') +
      '<span class="bnw-chip">' + esc(t.level) + ' ' + esc(me.level) + '</span>' +
      (me.league ? '<span class="bnw-chip">' + esc(me.league) + '</span>' : '') +
      (me.seasonXp > 0 ? '<span class="bnw-chip">' + esc(t.season) + ' ' + esc(me.seasonXp) + ' XP</span>' : '') + '</div>';
    if (invite) {
      h += '<div class="bnw-banner"><div class="t">⚔️ ' + esc(invite.from) + ' ' + esc(t.challenges) + '</div>' +
        '<div class="s">' + esc(t.track) + ': <b>' + esc(invite.track) + '</b> · ' + esc(fmt(t.secondsLeft, Math.max(0, invite.left | 0))) + '</div>' +
        '<div class="bnw-row"><button class="bnw-btn green" data-act="accept">' + esc(t.accept) + '</button>' +
        '<button class="bnw-btn red" data-act="decline">' + esc(t.decline) + '</button></div></div>';
    }
    var g = state.group;
    if (g) {
      var when = g.started ? t.running : fmt(t.startsIn, Math.max(0, g.startsIn | 0));
      h += '<div class="bnw-banner blue"><div class="t">' + (g.duel ? '⚔️ ' + esc(t.duelRace) : '🏁 ' + esc(t.groupRace)) +
        ': ' + esc(g.track) + '</div><div class="s">' + esc(when) + ' · ' + esc(fmt(t.drivers, g.members | 0)) +
        (g.joined ? ' · ' + esc(t.joined) : '') + '</div>' +
        (!g.joined && !g.duel && !g.started ? '<div class="bnw-row"><button class="bnw-btn" data-act="join">' + esc(t.join) + '</button></div>' : '') +
        '</div>';
    }
    var r = state.race;
    if (r) {
      h += '<div class="bnw-banner green"><div class="t">' + esc(t.yourRace) + ': ' + esc(r.track) + '</div>' +
        '<div class="s">' + esc(r.state === 'running' ? t.go : r.state === 'armed' ? t.armed : r.state) + '</div>' +
        '<div class="bnw-row"><button class="bnw-btn ghost" data-act="stop">' + esc(t.stop) + '</button></div></div>';
    }
    h += '<div class="bnw-tabs"><button class="bnw-tab' + (ui.tab !== 'duel' ? ' on' : '') + '" data-act="tab" data-tab="races">' +
      esc(t.races) + '</button><button class="bnw-tab' + (ui.tab === 'duel' ? ' on' : '') + '" data-act="tab" data-tab="duel">' +
      esc(t.duel) + '</button></div><div class="bnw-body">';
    var tracks = list(state.tracks), busy = !!(r || (g && !g.started && g.joined));
    if (ui.tab !== 'duel') {
      if (!tracks.length) h += '<div class="bnw-empty">' + esc(t.noTracks) + '</div>';
      tracks.forEach(function (tk) {
        h += '<div class="bnw-track"><div class="n"><b>' + (tk.weekly ? '<span class="bnw-star" title="' + esc(t.weekly) + '">★</span> ' : '') +
          esc(tk.name) + '</b><small>' + (tk.record ? esc(t.record) + ' ' + esc(tk.record) + (tk.by ? ' · ' + esc(tk.by) : '') : esc(t.noTime)) +
          '</small></div><button class="bnw-btn small" data-act="race" data-track="' + esc(tk.name) + '"' + (busy ? ' disabled' : '') + '>' +
          esc(t.drive) + '</button><button class="bnw-btn small ghost" data-act="group" data-track="' + esc(tk.name) + '"' +
          (g ? ' disabled' : '') + '>' + esc(t.group) + '</button></div>';
      });
    } else {
      var players = list(state.players);
      if (!players.length) {
        h += '<div class="bnw-empty">' + esc(t.noPlayers) + '</div>';
      } else {
        h += '<label class="bnw-label">' + esc(t.opponent) + '</label><select class="bnw-select" data-field="target"><option value="">' +
          esc(t.pick) + '</option>';
        players.forEach(function (p) {
          h += '<option value="' + esc(p.pid) + '"' + (String(ui.target) === String(p.pid) ? ' selected' : '') + '>' + esc(p.name) +
            ' · ' + esc(t.level) + ' ' + esc(p.level) + '</option>';
        });
        h += '</select><label class="bnw-label">' + esc(t.track) + '</label><select class="bnw-select" data-field="track"><option value="">' +
          esc(t.pick) + '</option>';
        tracks.forEach(function (tk) {
          h += '<option value="' + esc(tk.name) + '"' + (ui.track === tk.name ? ' selected' : '') + '>' + esc(tk.name) +
            (tk.record ? ' (' + esc(tk.record) + ')' : '') + '</option>';
        });
        var ready = ui.target !== '' && ui.target != null && ui.track && !g;
        h += '</select><div class="bnw-row" style="margin-top:10px"><button class="bnw-btn" data-act="duel"' + (ready ? '' : ' disabled') + '>' +
          esc(t.challenge) + '</button></div><div class="bnw-hint">' + esc(t.duelHint) + '</div>';
      }
    }
    h += '</div>';
    if (state.msg) h += '<div class="bnw-msg">' + esc(state.msg) + '</div>';
    return h + '</div>';
  }

  // Klick auf ein Element mit data-act: Ansicht aendern oder Anfrage fuer den Server (null = nichts senden).
  function requestFor(act, data, ui) {
    switch (act) {
      case 'race': case 'group': return { a: act, track: data.track };
      case 'join': case 'stop': case 'accept': case 'decline': return { a: act };
      case 'duel':
        if (ui.target === '' || ui.target == null || !ui.track) return null;
        return { a: 'duel', target: Number(ui.target), track: ui.track };
      default: return null;
    }
  }

  // Fenster in ein Element setzen. bridge.send(req) schickt eine Anfrage an den Server.
  function mount(el, bridge) {
    var ui = { tab: 'races', collapsed: false, target: '', track: '' };
    try { ui.collapsed = window.localStorage.getItem('beamnetWindowCollapsed') === '1'; } catch (e) { /* ohne Speicher */ }
    var state = null, received = 0;
    if (!document.getElementById('bnw-style')) {
      var st = document.createElement('style');
      st.id = 'bnw-style';
      st.textContent = CSS;
      document.head.appendChild(st);
    }
    var root = document.createElement('div');
    root.className = 'bnw';
    el.appendChild(root);
    function draw() { root.innerHTML = render(state, ui); }
    function send(req) { if (req && bridge && bridge.send) bridge.send(req); }
    function setCollapsed(v) {
      ui.collapsed = v;
      try { window.localStorage.setItem('beamnetWindowCollapsed', v ? '1' : '0'); } catch (e) { /* ohne Speicher */ }
      if (!v) send({ a: 'state' });
      draw();
    }
    root.addEventListener('click', function (ev) {
      var node = ev.target.closest ? ev.target.closest('[data-act]') : null;
      if (!node || node.disabled) return;
      var act = node.getAttribute('data-act');
      if (act === 'expand') return setCollapsed(false);
      if (act === 'collapse') return setCollapsed(true);
      if (act === 'tab') { ui.tab = node.getAttribute('data-tab'); return draw(); }
      send(requestFor(act, { track: node.getAttribute('data-track') }, ui));
    });
    root.addEventListener('change', function (ev) {
      var field = ev.target.getAttribute && ev.target.getAttribute('data-field');
      if (field === 'target' || field === 'track') { ui[field] = ev.target.value; draw(); }
    });
    // Countdowns lokal weiterzaehlen; solange das Fenster offen ist, alle 3 s den Stand holen.
    var ticks = 0;
    var timer = setInterval(function () {
      if (!state) return;
      var changed = false;
      if (state.invite && state.invite.left > 0) { state.invite.left -= 1; changed = true; }
      if (state.invite && state.invite.left <= 0) { state.invite = null; changed = true; }
      if (state.group && !state.group.started && state.group.startsIn > 0) { state.group.startsIn -= 1; changed = true; }
      ticks += 1;
      if (!ui.collapsed && ticks % 3 === 0) send({ a: 'state' });
      if (changed) draw();
    }, 1000);
    draw();
    return {
      update: function (s) {
        if (!s || typeof s !== 'object') return;
        received += 1;
        // Neue Herausforderung oder /fenster: Fenster aufklappen und Rennen zeigen.
        if ((s.open || (s.invite && !(state && state.invite))) && ui.collapsed) ui.collapsed = false;
        state = s;
        draw();
      },
      send: send,
      view: function () { return ui; },
      destroy: function () { clearInterval(timer); if (root.parentNode) root.parentNode.removeChild(root); }
    };
  }

  return { render: render, requestFor: requestFor, mount: mount, TEXT: TEXT };
})();

if (typeof module !== 'undefined' && module.exports) module.exports = BeamNetWindow;

if (typeof angular !== 'undefined') {
  angular.module('beamng.apps').directive('beamnetWindow', [function () {
    return {
      template: '<div style="width:100%;height:100%;display:flex;flex-direction:column"></div>',
      replace: true,
      restrict: 'EA',
      scope: true,
      link: function (scope, element) {
        function lua(code) { if (typeof bngApi !== 'undefined') bngApi.engineLua(code); }
        var app = BeamNetWindow.mount(element[0], {
          send: function (req) {
            lua('if extensions.beamnetUI then extensions.beamnetUI.uiRequest(' + bngApi.serializeToLua(req) + ') end');
          }
        });
        scope.$on('BeamNetUI', function (ev, data) { app.update(data); });
        scope.$on('$destroy', function () { app.destroy(); });
        lua('if extensions.beamnetUI then extensions.beamnetUI.uiReady() end');
      }
    };
  }]);
}
