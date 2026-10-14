-- Tests fuer BeamNetCore mit nachgebauter BeamMP-Schnittstelle (MP, FS).
-- Ausfuehren: python3 BeamNet/tests/run_lua_tests.py   (laeuft unter Lua 5.3, 5.4 und LuaJIT)

local SHARED = os.getenv("BEAMNET_SHARED")
local PLUGIN = os.getenv("BEAMNET_PLUGIN")
assert(SHARED and PLUGIN, "BEAMNET_SHARED und BEAMNET_PLUGIN muessen gesetzt sein")

local passed, failed = 0, 0
local function check(cond, what)
    if cond then passed = passed + 1 else failed = failed + 1; print("FEHLER: " .. what) end
end
local function eq(a, b, what)
    check(a == b, what .. " (erwartet " .. tostring(b) .. ", war " .. tostring(a) .. ")")
end
local function near(a, b, eps, what)
    check(type(a) == "number" and math.abs(a - b) <= eps, what .. " (erwartet ~" .. tostring(b) .. ", war " .. tostring(a) .. ")")
end

-- --- Attrappen ---------------------------------------------------------------------------------------------------
local players = {}      -- pid -> {name, ids, vehicles = {vid -> {pos, tim, vel}}}
local chatLog = {}
local events = {}
local timers = {}

MP = {}
function MP.RegisterEvent(ev, fn) events[ev] = fn end
function MP.CreateEventTimer(ev, ms) timers[ev] = ms end
function MP.CancelEventTimer(ev) timers[ev] = nil end
function MP.SendChatMessage(pid, msg) chatLog[#chatLog + 1] = { pid = pid, msg = msg } end
function MP.GetPlayers()
    local t = {}
    for pid, p in pairs(players) do t[pid] = p.name end
    return t
end
function MP.GetPlayerName(pid) return players[pid] and players[pid].name or "" end
function MP.GetPlayerIdentifiers(pid) return players[pid] and players[pid].ids or {} end
function MP.GetPlayerVehicles(pid)
    local p = players[pid]
    if not p or next(p.vehicles) == nil then return nil end
    local t = {}
    for vid in pairs(p.vehicles) do t[vid] = "{}" end
    return t
end
function MP.GetPositionRaw(pid, vid)
    local v = players[pid] and players[pid].vehicles[vid]
    if not v then return nil, "kein Fahrzeug" end
    return { pos = { v.pos[1], v.pos[2], v.pos[3] }, tim = v.tim, vel = v.vel }, ""
end

FS = {}
function FS.Exists(path) return os.execute('test -e "' .. path .. '"') == true or os.execute('test -e "' .. path .. '"') == 0 end
function FS.CreateDirectory(path) os.execute('mkdir -p "' .. path .. '"'); return false, "" end
-- Ohne io.popen (gibt es nicht in jeder Lua-Laufzeit): Ausgabe von ls ueber eine Hilfsdatei.
function FS.ListFiles(path)
    local out = {}
    local tmp = os.tmpname()
    os.execute('ls -1 "' .. path .. '" > "' .. tmp .. '" 2>/dev/null')
    local f = io.open(tmp, "r")
    if f then
        for line in f:lines() do out[#out + 1] = line end
        f:close()
    end
    os.remove(tmp)
    return out
end

local function readJson(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return BeamNetCore.json.decode(data)
end

local function lastChat(pid)
    for i = #chatLog, 1, -1 do
        if pid == nil or chatLog[i].pid == pid then return chatLog[i].msg end
    end
    return ""
end
local function chatContains(pattern, pid)
    for _, c in ipairs(chatLog) do
        if (pid == nil or c.pid == pid) and c.msg:find(pattern) then return true end
    end
    return false
end

-- Server-Konfiguration im Arbeitsordner (wie bei BeamMP).
do
    local f = io.open("ServerConfig.toml", "w")
    f:write('[General]\nName = "^l^4BeamNet | Server 1"\nPort = 30814 # Kommentar\nAuthKey = "geheim"\nMaxPlayers = 8\nMap = "/levels/gridmap_v2/info.json"\n')
    f:close()
end

-- Feste Uhr
local clock = 1760000000          -- 2025-10-09, Donnerstag
BeamNetCore = { now = function() return clock end }

-- --- Laden ---------------------------------------------------------------------------------------------------------
dofile(PLUGIN)
local BN = BeamNetCore
local C = BN.config

check(events.onChatMessage == "BN_onChatMessage", "onChatMessage registriert")
check(events.BN_Tick == "BN_Tick" and timers.BN_Tick == 1000, "Takt registriert")
eq(BN.server.name, "BeamNet | Server 1", "Servername ohne Farbcodes")
eq(BN.server.port, 30814, "Port trotz Kommentar")
eq(BN.server.map, "gridmap_v2", "Map")
eq(BN.server.maxPlayers, 8, "MaxPlayers")
local st = readJson(SHARED .. "/servers/30814.json")
check(st and st.players == 0 and st.updated == clock, "Status beim Laden geschrieben")
check(st and st.api and st.api.positions == true and st.api.files == true, "Status meldet vorhandene BeamMP-Funktionen")
do
    local saved = MP.GetPositionRaw
    MP.GetPositionRaw = nil
    eq(BN.capabilities().positions, false, "Fehlende BeamMP-Funktion wird erkannt")
    MP.GetPositionRaw = saved
end

-- --- JSON ----------------------------------------------------------------------------------------------------------
local json = BN.json
local sample = { name = 'Sebi "der" \\ Fahrer\nä😀', km = 12.5, n = -3, big = 1e21, ok = true, no = false,
                 list = { 1, 2.25, "x" }, nested = { a = { b = { c = 1 } } } }
local back = json.decode(json.encode(sample))
check(back ~= nil, "JSON: Rundreise liefert Daten")
eq(back.name, sample.name, "JSON: Sonderzeichen und Umlaute")
eq(back.km, 12.5, "JSON: Kommazahl")
eq(back.n, -3, "JSON: negative Zahl")
eq(back.ok, true, "JSON: true")
eq(back.no, false, "JSON: false")
eq(back.list[2], 2.25, "JSON: Liste")
eq(back.list[3], "x", "JSON: Liste Text")
eq(back.nested.a.b.c, 1, "JSON: verschachtelt")
eq(json.decode('"\\ud83d\\ude00"'), "😀", "JSON: Ersatzpaar")
eq(json.decode('"\\u00e4"'), "ä", "JSON: \\u-Escape")
eq(json.decode('  {"a" : [ ] , "b":{}} ').b ~= nil, true, "JSON: Leerraum und leere Behaelter")
eq(json.encode({}), "{}", "JSON: leere Tabelle")
eq(json.encode(0 / 0), "0", "JSON: NaN wird 0")

-- Kaputte Eingaben: nie ein Lua-Fehler, immer nil.
local broken = { "", "{", "}", "[1,", '{"a":}', '{"a" 1}', '"abc', '{"a":1}x', "nul", "tru", "-", "01x", '"\\x"',
                 '"\\u12"', '{"a":1,}', "[1 2]", string.rep("[", 200), '"a\nb"', "\0", "{\"\\ud800\":1}" }
for _, text in ipairs(broken) do
    local ok, value = pcall(json.decode, text)
    check(ok, "JSON wirft keinen Fehler bei " .. string.format("%q", text))
    if text ~= "{\"\\ud800\":1}" then check(value == nil, "JSON lehnt ab: " .. string.format("%q", text)) end
end
-- Zufaellige Verfaelschungen (Fuzz)
math.randomseed(42)
local seed = json.encode(sample)
for _ = 1, 3000 do
    local s = seed
    for _ = 1, math.random(1, 4) do
        local pos = math.random(1, #s)
        local r = math.random(1, 3)
        if r == 1 then s = s:sub(1, pos - 1) .. string.char(math.random(0, 255)) .. s:sub(pos + 1)
        elseif r == 2 then s = s:sub(1, pos - 1) .. s:sub(pos + math.random(1, 5))
        else s = s:sub(1, pos) .. s:sub(math.random(1, #s), math.random(1, #s)) .. s:sub(pos + 1) end
    end
    local ok = pcall(json.decode, s)
    if not ok then check(false, "JSON-Fuzz: Fehler bei " .. string.format("%q", s)) break end
end
passed = passed + 1

-- --- Werte ---------------------------------------------------------------------------------------------------------
eq(BN.levelFor(0), 1, "Level 0 XP")
eq(BN.levelFor(24), 1, "Level 24 XP")
eq(BN.levelFor(25), 2, "Level 25 XP")
eq(BN.levelFor(2025), 10, "Level 2025 XP")
eq(BN.xpForLevel(10), 2025, "XP fuer Level 10")
eq(BN.xpFor(10, 600), 110, "XP aus km und Zeit")
eq(BN.leagueFor(499).name, "Bronze", "Liga 499")
eq(BN.leagueFor(500).name, "Silber", "Liga 500")
eq(BN.leagueFor(10 ^ 9).name, "Legende", "Liga hoch")
eq(BN.nextLeague(600).name, "Gold", "Naechste Liga")
eq(BN.nextLeague(10 ^ 9), nil, "Keine Liga ueber Legende")
check(BN.validLeagues({ { xp = 0, name = "A" }, { xp = 10, name = "B" } }), "Ligen gueltig")
check(not BN.validLeagues({ { xp = 5, name = "A" } }), "Ligen muessen bei 0 beginnen")
check(not BN.validLeagues({ { xp = 0, name = "A" }, { xp = 0, name = "B" } }), "Ligen aufsteigend")
check(not BN.validLeagues({ { xp = 0 } }), "Ligen brauchen Namen")

-- --- Spieler und Kilometer -----------------------------------------------------------------------------------------
local function tick(seconds)
    for _ = 1, seconds or 1 do
        clock = clock + 1
        for _, p in pairs(players) do
            for _, v in pairs(p.vehicles) do v.tim = (v.tim or 0) + 1 end
        end
        _G[events.BN_Tick]()
    end
end
local function move(pid, vid, dx, dy, dz)
    local v = players[pid].vehicles[vid]
    v.pos = { v.pos[1] + (dx or 0), v.pos[2] + (dy or 0), v.pos[3] + (dz or 0) }
end

players[1] = { name = "Sebi", ids = { beammp = "1001", ip = "1.2.3.4" }, vehicles = {} }
_G[events.onPlayerJoin](1)
check(chatContains("Willkommen auf BeamNet | Server 1 %(gridmap_v2%)", 1), "Begruessung")
check(chatContains("Level 1 · Liga Bronze · 0.0 km", 1), "Begruessung mit Stand")

players[1].vehicles[0] = { pos = { 0, 0, 0 }, tim = 0, vel = { 20, 0, 0 } }
tick(1)                                         -- erste Position: nichts zaehlt
for _ = 1, 100 do move(1, 0, 20); tick(1) end   -- 100 s mit 20 m/s = 2 km
local s1 = BN.players[1]
near(BN.totals(s1).km, 2.0, 1e-9, "2 km gezaehlt")
near(BN.totals(s1).topSpeedKmh, 72, 1e-6, "Spitze aus Geschwindigkeit")

move(1, 0, 5000); tick(1)                        -- Teleport: zaehlt nicht
near(BN.totals(s1).km, 2.0, 1e-9, "Teleport zaehlt nicht")
move(1, 0, 0.1); tick(1)                         -- Rauschen im Stand
near(BN.totals(s1).km, 2.0, 1e-9, "Rauschen zaehlt nicht")
_G[events.onVehicleReset](1, 0)
move(1, 0, 100); tick(1)                         -- nach Zuruecksetzen: erste Position neu
near(BN.totals(s1).km, 2.0, 1e-9, "Reset-Sprung zaehlt nicht")
move(1, 0, 0, 30, 40); tick(1)                   -- 50 m schraeg (3D)
near(BN.totals(s1).km, 2.05, 1e-9, "3D-Abstand")

-- Speichern nach 60 s; Datei enthaelt alles.
local file1 = SHARED .. "/players/1001.json"
tick(60)
local rec = readJson(file1)
check(rec ~= nil, "Spielerdatei geschrieben")
near(rec and rec.km or -1, 2.05, 1e-6, "Datei: km")
check(rec and rec.seconds >= 100, "Datei: Fahrzeit")
eq(rec and rec.id, "1001", "Datei: ID")
eq(rec and rec.lastServer, "BeamNet | Server 1", "Datei: letzter Server")
eq(BN.players[1].pendingKm, 0, "Nach dem Speichern nichts mehr offen")

-- Ein anderer Server hat zwischendurch etwas dazugeschrieben (schneller Serverwechsel): nichts geht verloren.
rec.km = rec.km + 10
rec.weekKm = rec.weekKm + 10
local f = io.open(file1, "w"); f:write(json.encode(rec)); f:close()
for _ = 1, 50 do move(1, 0, 20); tick(1) end     -- +1 km
BN.savePlayer(BN.players[1])
rec = readJson(file1)
near(rec.km, 13.05, 1e-6, "Zuwachs wird zur Datei addiert")

-- Level-Aufstieg wird verkuendet (13 km * 10 + Zeit => > 130 XP => Level 3).
check(chatContains("Sebi ist jetzt Level %d!"), "Level-Aufstieg verkuendet")

-- --- Befehle -------------------------------------------------------------------------------------------------------
eq(_G[events.onChatMessage](1, "Sebi", "/hilfe"), 1, "/hilfe abgefangen")
check(lastChat(1):find("/stats"), "/hilfe zeigt Befehle")
eq(_G[events.onChatMessage](1, "Sebi", "Hallo zusammen"), nil, "Normale Nachricht bleibt")
eq(_G[events.onChatMessage](1, "Sebi", "/xp"), nil, "Fremde Befehle bleiben fuer andere Plugins")
_G[events.onChatMessage](1, "Sebi", "/km")
check(lastChat(1):find("Du bist 13%.%d km gefahren"), "/km: " .. lastChat(1))
_G[events.onChatMessage](1, "Sebi", "/stats")
check(chatContains("Sebi: Level %d+ · Liga Bronze · %d+ XP · 13%.%d km", 1), "/stats eigene Werte")
check(chatContains("Rang 1 von 1", 1), "/stats Rang")

players[2] = { name = "Max Mustermann", ids = { beammp = "2002" }, vehicles = { [0] = { pos = { 0, 0, 0 }, tim = 0 } } }
_G[events.onPlayerJoin](2)
tick(1)
for _ = 1, 100 do move(2, 0, 50); tick(1) end    -- 5 km
_G[events.onChatMessage](1, "Sebi", "/stats max")
check(chatContains("Max Mustermann: Level", 1), "/stats anderer Spieler (Teilname, Gross/Klein)")
_G[events.onChatMessage](1, "Sebi", "/stats Niemand")
check(lastChat(1):find("Kein Spieler online"), "/stats unbekannt")

BN.refreshBoard(true)
_G[events.onChatMessage](1, "Sebi", "/top km")
check(chatContains("Bestenliste Kilometer:", 1), "/top km Kopf")
check(chatContains("1%. Sebi – 13", 1) and chatContains("2%. Max Mustermann – 5", 1), "/top km Reihenfolge")
_G[events.onChatMessage](1, "Sebi", "/top")
check(chatContains("Bestenliste XP:", 1), "/top XP")
_G[events.onChatMessage](1, "Sebi", "/top woche")
check(chatContains("Bestenliste Kilometer diese Woche:", 1), "/top woche")
_G[events.onChatMessage](2, "Max", "/liga")
check(chatContains("Ligen %(XP%): Bronze ab 0 · Silber ab 500", 2), "/liga Liste")
check(chatContains("noch %d+ XP bis Silber", 2), "/liga Fortschritt")

-- /server: eigener Status plus ein zweiter Server; veraltete werden ausgelassen.
tick(15)
local f2 = io.open(SHARED .. "/servers/30815.json", "w")
f2:write(json.encode({ name = "BeamNet | Server 2", port = 30815, map = "west_coast_usa", players = 3, max = 8, updated = clock }))
f2:close()
local f3 = io.open(SHARED .. "/servers/30816.json", "w")
f3:write(json.encode({ name = "BeamNet | Server 3", port = 30816, map = "italy", players = 1, max = 8, updated = clock - 600 }))
f3:close()
local f4 = io.open(SHARED .. "/servers/kaputt.json", "w"); f4:write("{nicht json"); f4:close()
_G[events.onChatMessage](1, "Sebi", "/server")
check(chatContains("BeamNet | Server 1 · gridmap_v2 · 2/8 · Port 30814  ← hier", 1), "/server eigener Server")
check(chatContains("BeamNet | Server 2 · west_coast_usa · 3/8 · Port 30815", 1), "/server zweiter Server")
check(not chatContains("Server 3 · italy", 1), "/server ohne veraltete Server")

-- --- Gast, unsichere ID, Abmelden, verschwundene Spieler -----------------------------------------------------------
players[3] = { name = "Gast123", ids = { ip = "5.6.7.8" }, vehicles = { [1] = { pos = { 0, 0, 0 }, tim = 0 } } }
players[4] = { name = "Boese", ids = { beammp = "../../etc/passwd" }, vehicles = {} }
_G[events.onPlayerJoin](3)
_G[events.onPlayerJoin](4)
tick(1)
for _ = 1, 10 do move(3, 1, 30); tick(1) end
check(BN.players[3].guest and BN.totals(BN.players[3]).km > 0.2, "Gast faehrt mit Zaehlung")
check(BN.players[4].guest, "Unsichere ID wird wie Gast behandelt")
_G[events.onChatMessage](3, "Gast123", "/stats")
check(chatContains("Gast%-Konto", 3), "Gast-Hinweis")
_G[events.onPlayerDisconnect](3)
check(io.open(SHARED .. "/players/.json") == nil, "Fuer Gaeste keine Datei")

_G[events.onPlayerDisconnect](2)
check(BN.players[2] == nil, "Abmelden entfernt Sitzung")
near(readJson(SHARED .. "/players/2002.json").km, 5, 1e-6, "Abmelden speichert")
st = readJson(SHARED .. "/servers/30814.json")
eq(st.players, 2, "Status nach Abmelden (Sebi und Boese)")

for _ = 1, 10 do move(1, 0, 20); tick(1) end
players[1] = nil                                   -- ohne Abmeldung verschwunden
tick(1)
check(BN.players[1] == nil, "Verschwundener Spieler wird aufgeraeumt")
near(readJson(file1).km, 13.25, 1e-6, "Verschwundener Spieler wird gespeichert")

-- --- Wochenwechsel -------------------------------------------------------------------------------------------------
players[1] = { name = "Sebi", ids = { beammp = "1001" }, vehicles = { [0] = { pos = { 0, 0, 0 }, tim = 0 } } }
_G[events.onPlayerJoin](1)
clock = clock + 8 * 86400
tick(1)
check(chatContains("Wochensieger KW %d+: 1%. Sebi %(13%.%d km%) · 2%. Max Mustermann %(5%.0 km%)"), "Wochensieger verkuendet")
for _ = 1, 10 do move(1, 0, 10); tick(1) end
BN.savePlayer(BN.players[1])
rec = readJson(file1)
near(rec.weekKm, 0.1, 1e-6, "Wochenkilometer neu begonnen")
near(rec.km, 13.35, 1e-6, "Gesamtkilometer bleiben")
near(rec.lastWeekKm, 13.25, 1e-6, "Vorwoche bleibt erhalten")
_G[events.onChatMessage](1, "Sebi", "/top vorwoche")
check(chatContains("Bestenliste Kilometer letzte Woche:", 1), "/top vorwoche Kopf")
check(chatContains("1%. Sebi – 13%.%d km", 1) and chatContains("2%. Max Mustermann – 5%.0 km", 1), "/top vorwoche Reihenfolge")

-- --- Anpassungen ueber config.json ---------------------------------------------------------------------------------
local cfg = io.open(SHARED .. "/config.json", "w")
cfg:write('{"xpPerKm": 20, "publicHost": "beamnet.example", "leagues": [{"xp":0,"name":"Anfänger"},{"xp":100,"name":"Profi"}], "sharedDir": "/tmp/nicht"}')
cfg:close()
BN.init()
eq(C.xpPerKm, 20, "config.json: xpPerKm")
eq(C.sharedDir, SHARED, "config.json darf den Datenordner nicht verlegen")
eq(BN.leagueFor(150).name, "Profi", "config.json: eigene Ligen")
_G[events.onChatMessage](1, "Sebi", "/server")
check(chatContains("beamnet.example:30814", 1), "config.json: publicHost in /server")
cfg = io.open(SHARED .. "/config.json", "w"); cfg:write('{"xpPerKm": "viel", "leagues": [{"xp":5}]'); cfg:close()
local okInit = pcall(BN.init)
check(okInit, "Kaputte config.json bricht nichts")

-- Kaputte Spielerdatei: Spieler startet sauber, nichts stuerzt ab.
local bad = io.open(SHARED .. "/players/3003.json", "w"); bad:write("{kaputt"); bad:close()
players[5] = { name = "Kaputt", ids = { beammp = "3003" }, vehicles = {} }
local okJoin = pcall(_G[events.onPlayerJoin], 5)
check(okJoin and BN.players[5] and BN.players[5].record.km == 0, "Kaputte Spielerdatei wird ersetzt")

-- --- Zeitrennen ----------------------------------------------------------------------------------------------------
C.admins = { "sebi" }                               -- Gross/Klein egal
local function at(pid, x, tim, y)
    return BN.track(pid, 0, { x, y or 0, 0 }, tim)
end
-- Faehrt in Schritten (m) von x0 nach x1, eine Messung je Sekunde Spielzeit; gibt die letzte Spielzeit zurueck.
local function drive(pid, x0, x1, step, tim)
    local x = x0
    while (step > 0 and x < x1) or (step < 0 and x > x1) do
        x = x + step
        if (step > 0 and x > x1) or (step < 0 and x < x1) then x = x1 end
        tim = tim + math.abs(x - (x - step)) / math.abs(step)
        at(pid, x, tim)
    end
    return tim
end
local function say(pid, text) return _G[events.onChatMessage](pid, "?", text) end

eq(BN.fmtRaceTime(65.26), "1:05.3", "Zeitformat Minuten")
eq(BN.fmtRaceTime(9.04), "0:09.0", "Zeitformat Sekunden")
check(BN.isAdmin(BN.players[1]) and not BN.isAdmin(BN.players[5]), "Admin-Erkennung")
check(not BN.isAdmin(BN.players[4]), "Gaeste sind nie Admin")

say(5, "/rennen neu sprint")
check(chatContains("nur Admins", 5), "Nicht-Admin darf keine Strecke anlegen")
at(1, 0, 5000)
say(1, "/rennen neu ../x")
check(chatContains("Streckenname: 1–24 Zeichen", 1), "Streckenname wird geprueft")
say(1, "/rennen neu Sprint")
check(chatContains("Start von sprint gesetzt", 1), "Start gesetzt (Name klein)")
check(readJson(SHARED .. "/races/gridmap_v2.json").tracks.sprint.start.x == 0, "Strecke gespeichert")
say(5, "/rennen sprint")
check(chatContains("hat noch kein Ziel", 5), "Ohne Ziel kein Start")
drive(1, 0, 1000, 50, 5000)
say(1, "/rennen ziel sprint")
check(chatContains("Ziel von sprint gesetzt %(1000 m Luftlinie%)", 1), "Ziel gesetzt")

-- Lauf von Kaputt: Start bei x=0 (Radius 12), Ziel bei x=1000.
players[5].vehicles[0] = { pos = { -30, 0, 0 }, tim = 0 }
say(5, "/rennen sprint")
check(chatContains("Rennen sprint: Fahr zum Start", 5), "Rennen vorbereitet")
at(5, -30, 100); at(5, -15, 101)
eq(BN.players[5].race.state, "armed", "Vor dem Start")
at(5, 10, 102)
check(chatContains("Am Start von sprint", 5), "Am Start erkannt")
at(5, 20, 103)                                        -- verlaesst den Start bei 102.2
check(chatContains("Zeit läuft! Ziel ist 980 m entfernt", 5), "Start erkannt")
local tim = drive(5, 20, 980, 20, 103)                -- bei 980: Spielzeit 151
at(5, 995, tim + 0.5)                                 -- Ziel bei 151.2667 ueberquert -> 49.0667 s
check(chatContains("Ziel! sprint: 0:49%.1", 5), "Zielzeit interpoliert")
check(chatContains("Neuer Streckenrekord auf sprint: Kaputt mit 0:49%.1!"), "Rekord verkuendet")
check(chatContains("%+75 XP", 5), "Bonus fuer Lauf, Bestzeit und Rekord")
eq(BN.totals(BN.players[5]).bonusXp, 75, "Bonus-XP in den Summen")
eq(BN.players[5].race.state, "armed", "Nach dem Ziel wieder bereit")
local records = readJson(SHARED .. "/races/gridmap_v2.json").tracks.sprint.records
check(records and #records == 1 and math.abs(records[1].time - 49.0667) < 0.01, "Rekord gespeichert")

-- Schnellerer Lauf von Sebi (40 m/s) -> neuer Rekord, Kaputt auf Platz 2.
say(1, "/rennen sprint")
tim = drive(1, 1000, 10, -50, 6000)
tim = drive(1, 10, 980, 40, tim)
at(1, 1000, tim + 1)
check(chatContains("Neuer Streckenrekord auf sprint: Sebi mit 0:2"), "Schnellerer Rekord")
say(1, "/rennen stop")
check(chatContains("Rennmodus beendet", 1), "Rennen beenden")
eq(BN.players[1].race, nil, "Kein Rennen mehr")
say(5, "/rekorde sprint")
check(chatContains("1%. Sebi – 0:2", 5) and chatContains("2%. Kaputt – 0:49%.1", 5), "Rekordliste")
say(5, "/rennen")
check(chatContains("Strecken auf gridmap_v2: sprint %(Rekord 0:2%d%.%d · Sebi%)", 5), "Streckenliste")

-- Langsamerer Lauf: kein neuer Eintrag.
tim = drive(5, 995, 0, -50, 300)
at(5, 20, tim + 1)
tim = drive(5, 20, 990, 10, tim + 1)
check(chatContains("Ziel! sprint: 1:", 5), "Langsamer Lauf gemessen")
eq(BN.totals(BN.players[5]).bonusXp, 90, "Langsamer Lauf: nur Bonus fuer den Lauf")
records = readJson(SHARED .. "/races/gridmap_v2.json").tracks.sprint.records
eq(#records, 2, "Langsamer Lauf ersetzt die Bestzeit nicht")
check(math.abs(records[2].time - 49.0667) < 0.01, "Bestzeit bleibt")

-- Zuruecksetzen und Teleport machen den Lauf ungueltig.
tim = drive(5, 990, 0, -50, 500)
at(5, 30, tim + 1)
_G[events.onVehicleReset](5, 0)
check(chatContains("Fahrzeug zurückgesetzt – Lauf ungültig", 5), "Reset ungueltig")
at(5, 0, tim + 2); at(5, 30, tim + 3)
at(5, 990, tim + 4)                                   -- 960 m in 1 s
check(chatContains("Sprung %(Teleport%) – Lauf ungültig", 5), "Teleport ungueltig")
records = readJson(SHARED .. "/races/gridmap_v2.json").tracks.sprint.records
eq(#records, 2, "Ungueltige Laeufe zaehlen nicht")

-- Gast: Zeit ja, Rekord nein.
players[4].vehicles[0] = { pos = { 0, 0, 0 }, tim = 0 }
say(4, "/rennen sprint")
at(4, 0, 10); at(4, 20, 11)
tim = drive(4, 20, 990, 50, 11)
at(4, 1000, tim + 0.2)
check(chatContains("Ziel! sprint:", 4), "Gast faehrt auf Zeit")
check(chatContains("%+15 XP %(nur für diese Sitzung%)", 4), "Gast-Bonus nur fuer die Sitzung")
eq(#readJson(SHARED .. "/races/gridmap_v2.json").tracks.sprint.records, 2, "Gast nicht in der Rekordliste")

-- Rundkurs: Start = Ziel.
at(1, 500, 7000, 500)
say(1, "/rennen neu runde")
say(1, "/rennen ziel runde")
check(chatContains("Rundkurs %(Start = Ziel%)", 1), "Rundkurs erkannt")
say(5, "/rennen runde")
at(5, 400, 900, 500); at(5, 495, 901, 500)          -- in den Startbereich
at(5, 520, 902, 500)                                  -- raus: Start
check(BN.players[5].race.state == "running", "Rundkurs gestartet")
tim = 902
for i = 1, 30 do tim = tim + 1; at(5, 520 + i * 10, tim, 500) end
for i = 29, 0, -1 do tim = tim + 1; at(5, 510 + i * 10, tim, 500) end
check(chatContains("Ziel! runde:", 5), "Rundkurs beendet")
say(5, "/rekorde")
check(chatContains("runde: Kaputt", 5) and chatContains("sprint: Sebi", 5), "Alle Rekorde der Map")
say(1, "/rennen loeschen runde")
check(BN.loadTracks().tracks.runde == nil, "Strecke geloescht")
say(5, "/rennen gibtsnicht")
check(chatContains("gibt es auf dieser Map nicht", 5), "Unbekannte Strecke")

-- Herunterfahren speichert alle.
tick(1)
_G[events.onShutdown]()
local saved = readJson(SHARED .. "/players/3003.json")
check(saved ~= nil, "Herunterfahren speichert")
check(saved and saved.bonusXp >= 90 and saved.xp >= 90, "Bonus-XP gespeichert und in XP enthalten")

print(string.format("%s: %d Prüfungen bestanden, %d fehlgeschlagen", _VERSION, passed, failed))
return failed
