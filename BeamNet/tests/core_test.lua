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
local drops = {}
function MP.DropPlayer(pid, reason)
    drops[#drops + 1] = { pid = pid, reason = reason }
    players[pid] = nil
end
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
C.commandLimit = 100000            -- Befehls-Bremse fuer die allgemeinen Tests aus (eigener Test weiter unten)
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
near(rec and rec.mapKm and rec.mapKm.gridmap_v2 or -1, 2.05, 1e-6, "Datei: km je Map")
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

-- Kaputte Spielerdatei: Spieler startet sauber, nichts stuerzt ab; die alte Datei wird einmal beiseitegelegt.
local bad = io.open(SHARED .. "/players/3003.json", "w"); bad:write("{kaputt"); bad:close()
players[5] = { name = "Kaputt", ids = { beammp = "3003" }, vehicles = {} }
local okJoin = pcall(_G[events.onPlayerJoin], 5)
check(okJoin and BN.players[5] and BN.players[5].record.km == 0, "Kaputte Spielerdatei wird ersetzt")
do
    local f = io.open(SHARED .. "/players/3003.json.kaputt-" .. clock, "rb")
    local kept = f and f:read("*a")
    if f then f:close() end
    eq(kept, "{kaputt", "Kaputte Spielerdatei als Sicherung beiseitegelegt")
    check(io.open(SHARED .. "/players/3003.json", "rb") == nil, "Kaputte Datei nicht mehr unter dem alten Namen")
end

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
check(chatContains("Erfolg für Kaputt: Erstes Rennen %(%+10 XP%)") and chatContains("Erfolg für Kaputt: Streckenrekord %(%+50 XP%)"),
    "Erfolge fuer erstes Rennen und Rekord")
eq(BN.totals(BN.players[5]).bonusXp, 135, "Erfolgs-XP in den Summen")
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
eq(BN.totals(BN.players[5]).bonusXp, 150, "Langsamer Lauf: nur Bonus fuer den Lauf")
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

-- --- Zwischenzeiten ------------------------------------------------------------------------------------------------
eq(BN.fmtSplitDiff(1.26), "+1.3 s", "Abstand mit Plus")
eq(BN.fmtSplitDiff(-0.8), "-0.8 s", "Abstand mit Minus")
eq(BN.fmtSplitDiff(-0.04), "+0.0 s", "Kein -0.0")
eq(BN.tr("en", "Zwischenzeit %d: %s (%s)", 2, "0:13.1", "-1.0 s"), "Split 2: 0:13.1 (-1.0 s)", "Zwischenzeit auf Englisch")
eq(C.raceSplitM, 500, "Zwischenzeit alle 500 m")
-- Gerade Strecke 3000 -> 5000 (Start und Ziel per Sprung gesetzt, Sebi faehrt dabei nichts).
at(1, 3000, 7100)
say(1, "/rennen neu zwischen")
at(1, 5000, 7101)
say(1, "/rennen ziel zwischen")
check(chatContains("Ziel von zwischen gesetzt %(2000 m Luftlinie%)", 1), "Strecke fuer Zwischenzeiten")
players[8] = { name = "Splitter", ids = { beammp = "8008" }, vehicles = {} }
_G[events.onPlayerJoin](8)
local splitLogStart = #chatLog
local function splitCount(pid)
    local n = 0
    for _, c in ipairs(chatLog) do if c.pid == pid and c.msg:find("^Zwischenzeit") then n = n + 1 end end
    return n
end
local function mySplits()
    for _, r in ipairs(BN.loadTracks().tracks.zwischen.records or {}) do
        if r.id == "8008" then return r.splits end
    end
end
-- Startet einen Lauf ab x=3000: verlaesst den Startbereich (12 m) bei Spielzeit t0 + 1.2; Fahrstrecke = x - 3012.
local function startRun(t0)
    at(8, 3000, t0); at(8, 3010, t0 + 1); at(8, 3020, t0 + 2)
    return t0 + 2
end
say(8, "/rennen zwischen")
-- Lauf 1 mit 20 m/s: Marken bei 3512, 4012, 4512 -> 25.4 / 50.4 / 75.4 s; Ziel 99.2 s.
tim = startRun(100)
eq(BN.players[8].race.state, "running", "Lauf mit Zwischenzeiten gestartet")
near(BN.players[8].race.runDist, 8, 1e-9, "Fahrstrecke ab Verlassen des Startbereichs")
tim = drive(8, 3020, 4980, 20, tim)
at(8, 5000, tim + 1)
check(chatContains("Ziel! zwischen: 1:39%.2", 8), "Lauf 1 im Ziel")
eq(splitCount(8), 0, "Ohne Bestzeit keine Zwischenzeiten im Chat")
local sp = mySplits()
check(type(sp) == "table" and #sp == 3, "Drei Zwischenzeiten gespeichert")
near(sp and sp[1], 25.4, 1e-6, "Zwischenzeit 1 gespeichert")
near(sp and sp[2], 50.4, 1e-6, "Zwischenzeit 2 gespeichert")
near(sp and sp[3], 75.4, 1e-6, "Zwischenzeit 3 gespeichert")
eq(BN.players[8].race.splits, nil, "Nach dem Ziel kein Laufzustand mehr")
-- Lauf 2: erst schneller (25 m/s), dann langsamer (10 m/s); langsamer im Ziel -> Bestzeit und Zwischenzeiten bleiben.
tim = startRun(300)
tim = drive(8, 3020, 3520, 25, tim)                  -- Marke 1 bei 321.68 -> 20.48 s
check(chatContains("^Zwischenzeit 1: 0:20%.5 %(%-4%.9 s%)$", 8), "Zwischenzeit 1 schneller als Bestzeit")
eq(splitCount(8), 1, "Nur eine Zwischenzeit bis hier")
tim = drive(8, 3520, 4020, 10, tim)                  -- Marke 2 bei 371.2 -> 70.0 s
check(chatContains("^Zwischenzeit 2: 1:10%.0 %(%+19%.6 s%)$", 8), "Zwischenzeit 2 langsamer als Bestzeit")
do
    local others = 0
    for i = splitLogStart + 1, #chatLog do
        if chatLog[i].pid ~= 8 and chatLog[i].msg:find("Zwischenzeit") then others = others + 1 end
    end
    eq(others, 0, "Zwischenzeiten nur an den Fahrer")
end
tim = drive(8, 4020, 4980, 20, tim)
at(8, 5000, tim + 1)
check(chatContains("Ziel! zwischen: 1:59%.2", 8), "Lauf 2 langsamer im Ziel")
eq(splitCount(8), 3, "Drei Zwischenzeiten im Lauf 2")
sp = mySplits()
near(sp and sp[1], 25.4, 1e-6, "Langsamer Lauf aendert die Zwischenzeiten nicht")
-- Lauf 3 wird durch Zuruecksetzen ungueltig: Laufzustand weg, nichts gespeichert.
tim = startRun(600)
tim = drive(8, 3020, 3600, 40, tim)
eq(splitCount(8), 4, "Zwischenzeit im abgebrochenen Lauf")
_G[events.onVehicleReset](8, 0)
check(chatContains("Fahrzeug zurückgesetzt – Lauf ungültig", 8), "Lauf 3 ungueltig")
check(BN.players[8].race.runDist == nil and BN.players[8].race.splits == nil, "Ungueltiger Lauf setzt Zwischenzeiten zurueck")
near(mySplits()[1], 25.4, 1e-6, "Ungueltiger Lauf speichert nichts")
-- Lauf 4 mit 40 m/s: neue Bestzeit ersetzt die Zwischenzeiten.
tim = startRun(800)
tim = drive(8, 3020, 4980, 40, tim)                  -- Marke 1 nach 12.3 + 0.8 = 13.1 s
check(chatContains("^Zwischenzeit 1: 0:13%.1 %(%-12%.3 s%)$", 8), "Zwischenzeit gegen die alte Bestzeit")
at(8, 5000, tim + 1)
check(chatContains("Neuer Streckenrekord auf zwischen: Splitter mit 0:50%.2!", 8), "Lauf 4 ist Bestzeit")
sp = mySplits()
check(type(sp) == "table" and #sp == 3, "Neue Bestzeit mit drei Zwischenzeiten")
near(sp and sp[1], 13.1, 1e-6, "Zwischenzeiten der neuen Bestzeit")
-- Englisch
say(8, "/lang en")
tim = startRun(1000)
tim = drive(8, 3020, 3540, 40, tim)
check(chatContains("^Split 1: 0:13%.1 %(%+0%.0 s%)$", 8), "Zwischenzeit auf Englisch im Chat")
say(8, "/race stop")
say(8, "/lang de")
-- Hoechstens 60 Zwischenzeiten je Bestzeit.
C.raceSplitM = 10
say(8, "/rennen zwischen")
tim = startRun(1200)
tim = drive(8, 3020, 4980, 50, tim)
at(8, 5000, tim + 1)
sp = mySplits()
check(type(sp) == "table" and #sp == 60, "Hoechstens 60 Zwischenzeiten (" .. tostring(sp and #sp) .. ")")
C.raceSplitM = 500
say(8, "/rennen stop")
say(1, "/rennen loeschen zwischen")
_G[events.onPlayerDisconnect](8)
players[8] = nil

-- --- Moderation ---------------------------------------------------------------------------------------------------
local join = function(pid) _G[events.onPlayerJoin](pid) end
local function writeJson(path, value)
    local f = io.open(path, "w"); f:write(json.encode(value)); f:close()
end
local function countChat(pattern, pid)
    local n = 0
    for _, c in ipairs(chatLog) do if (pid == nil or c.pid == pid) and c.msg:find(pattern) then n = n + 1 end end
    return n
end

say(5, "/kick Sebi")
check(chatContains("Nur für Admins", 5), "Moderation nur fuer Admins")
check(chatContains("Admin: /kick", 1) == false, "Admin-Hilfe nicht ungefragt")
say(1, "/hilfe")
check(chatContains("Admin: /kick", 1), "Admins sehen ihre Befehle in /hilfe")

players[2] = { name = "Max Mustermann", ids = { beammp = "2002", ip = "9.9.9.9" }, vehicles = {} }
join(2)
say(1, "/warn max Bitte langsamer")
check(chatContains("Verwarnung von Sebi: Bitte langsamer", 2), "Verwarnung kommt an")
say(1, "/kick max Test")
check(drops[#drops].pid == 2 and drops[#drops].reason == "Vom Server geworfen: Test", "Kick mit Grund")
check(BN.players[2] == nil, "Kick entfernt Sitzung")
check(chatContains("Max Mustermann wurde vom Server geworfen"), "Kick verkuendet")

-- Mehrdeutiger Teilname: nichts passiert.
local dropsBefore = #drops
say(1, "/ban a")
check(chatContains("Mehrere Spieler passen zu \"a\"", 1) and #drops == dropsBefore, "Mehrdeutiger Name wird abgelehnt")

-- Zeitbann fuer einen Spieler, der offline ist (aus den gespeicherten Spielern).
say(1, "/ban max 2h Beleidigung")
local bans = readJson(SHARED .. "/bans.json").bans
check(#bans == 1 and bans[1].id == "2002" and bans[1]["until"] == clock + 7200 and bans[1].reason == "Beleidigung", "Bann gespeichert")
check(chatContains("Max Mustermann wurde für 2h gesperrt"), "Bann verkuendet")
local deny = _G[events.onPlayerAuth]("Max Mustermann", "USER", false, { beammp = "2002" })
check(type(deny) == "string" and deny:find("Gesperrt auf allen BeamNet%-Servern: Beleidigung %(bis "), "Gesperrter Spieler wird abgewiesen")
eq(_G[events.onPlayerAuth]("Sebi", "USER", false, { beammp = "1001" }), nil, "Andere kommen rein")
eq(_G[events.onPlayerAuth]("Alt", "USER", false, nil), nil, "Ohne Kennungen kein Fehler")
clock = clock + 7201
eq(_G[events.onPlayerAuth]("Max Mustermann", "USER", false, { beammp = "2002" }), nil, "Zeitbann laeuft ab")

-- Bann von einem anderen Server trifft einen Spieler, der hier online ist.
players[2] = { name = "Max Mustermann", ids = { beammp = "2002" }, vehicles = {} }
join(2)
writeJson(SHARED .. "/bans.json", { bans = { { id = "2002", name = "Max", reason = "anderer Server", by = "Admin7", at = clock } } })
tick(C.syncEverySec + 1)
check(drops[#drops].pid == 2 and drops[#drops].reason:find("anderer Server"), "Bann eines anderen Servers wirkt sofort")
say(1, "/unban max")
eq(#readJson(SHARED .. "/bans.json").bans, 0, "Bann aufgehoben")

-- Gaeste werden ueber die IP gesperrt; Admins nie.
players[6] = { name = "Gast42", ids = { ip = "7.7.7.7" }, vehicles = {} }
join(6)
say(1, "/ban gast42 Spam")
bans = readJson(SHARED .. "/bans.json").bans
check(bans[1].ip == "7.7.7.7" and bans[1].id == nil, "Gast-Bann ueber IP")
check(type(_G[events.onPlayerAuth]("Gast99", "GUEST", true, { ip = "7.7.7.7" })) == "string", "Gast mit gesperrter IP abgewiesen")
say(1, "/ban sebi")
check(chatContains("Admins können nicht gesperrt werden", 1), "Admins sind geschuetzt")
say(1, "/bans")
check(chatContains("1 aktive Banns:", 1) and chatContains("Gast42 – Spam · dauerhaft", 1), "Bannliste")

-- Ansagen an alle Server.
say(1, "/ansage Neustart in 5 Minuten")
check(chatContains("%[Ansage%] Neustart in 5 Minuten"), "Ansage auf diesem Server")
local ann = readJson(SHARED .. "/announcements.json").list
check(#ann == 1 and ann[1].text == "Neustart in 5 Minuten" and ann[1].by == "Sebi", "Ansage fuer alle Server gespeichert")
ann[#ann + 1] = { id = "x-1", text = "Gruss von Server 7", by = "Admin7", at = clock }
writeJson(SHARED .. "/announcements.json", { list = ann })
tick(C.syncEverySec + 1)
tick(C.syncEverySec + 1)
eq(countChat("%[Ansage%] Gruss von Server 7", 1), 1, "Ansage eines anderen Servers genau einmal")
eq(countChat("%[Ansage%] Neustart in 5 Minuten", 1), 1, "Eigene Ansage nicht doppelt")
BN.seenAnnouncements = {}
BN.init()
tick(C.syncEverySec + 1)
eq(countChat("%[Ansage%] Gruss von Server 7", 1), 1, "Nach Neustart keine alten Ansagen")

-- Spamschutz (Admins ausgenommen).
local results = {}
for i = 1, 6 do results[i] = say(5, "spam " .. i) end
check(results[5] == nil and results[6] == 1, "Sechste Nachricht in 5 s wird gestoppt")
check(chatContains("Bitte nicht spammen – du bist 30 s stummgeschaltet", 5), "Spam-Hinweis")
eq(say(5, "noch was"), 1, "Waehrend der Stummschaltung gesperrt")
eq(say(5, "/km"), 1, "Befehle gehen trotzdem")
clock = clock + 31
eq(say(5, "wieder da"), nil, "Nach Ablauf wieder frei")
for i = 1, 10 do say(1, "admin " .. i) end
eq(say(1, "admin x"), nil, "Admins ohne Spamschutz")
say(1, "/mute kaputt 2")
eq(say(5, "hallo"), 1, "Manuell stummgeschaltet")

-- Neue Admins wirken ohne Neustart (config.json wird jede Minute neu gelesen).
check(not BN.isAdmin(BN.players[5]), "Kaputt ist noch kein Admin")
writeJson(SHARED .. "/config.json", { admins = { "Sebi", "Kaputt" } })
tick(61)
check(BN.isAdmin(BN.players[5]), "Neuer Admin nach spaetestens einer Minute")
writeJson(SHARED .. "/config.json", { admins = { "Sebi" } })
tick(61)
check(not BN.isAdmin(BN.players[5]), "Admin entfernt nach spaetestens einer Minute")
C.admins = { "sebi" }

local logLines = 0
for line in io.lines(SHARED .. "/modlog.jsonl") do
    logLines = logLines + 1
    check(json.decode(line) ~= nil, "Protokollzeile ist JSON")
end
check(logLines >= 8, "Moderationsprotokoll fuehrt alles (" .. logLines .. " Eintraege)")
clock = clock + 200

-- --- Englisch -------------------------------------------------------------------------------------------------------
say(5, "/lang")
check(chatContains("Sprache: Deutsch%. English: /lang en", 5), "/lang zeigt Sprache")
say(5, "/lang en")
check(chatContains("Language set to English%.", 5), "/lang en")
say(5, "/km")
check(chatContains("You have driven %d+%.%d km %(this week", 5), "/km auf Englisch")
say(5, "/help")
check(chatContains("BeamNet commands: /stats %[name%]", 5), "/help auf Englisch")
say(5, "/league")
check(chatContains("Leagues %(XP%): .+ from 0", 5), "/league auf Englisch")
eq(BN.tr("en", "Silber"), "Silver", "Standard-Liga uebersetzt")
eq(BN.tr("en", "Anfänger"), "Anfänger", "Eigene Liga-Namen bleiben")
eq(BN.tr("de", "Silber"), "Silber", "Deutsch unveraendert")
say(5, "/records sprint")
check(chatContains("Records sprint:", 5), "/records auf Englisch")
say(5, "/race")
check(chatContains("Tracks on gridmap_v2: sprint %(record ", 5), "/race listet Strecken")
say(5, "/lang klingonisch")
check(chatContains("Languages: /lang de · /lang en", 5), "Unbekannte Sprache")
-- Rundmeldung: jeder in seiner Sprache.
say(1, "/ansage Gleich gibt es Pizza")
check(chatContains("%[Announcement%] Gleich gibt es Pizza", 5) and chatContains("%[Ansage%] Gleich gibt es Pizza", 1), "Ansage je Sprache")
say(1, "/announce Test2")
check(chatContains("%[Ansage%] Test2", 1), "/announce als Alias")
-- Admin auf Englisch: /race new|finish|delete
say(1, "/lang en")
at(1, 2000, 9000)
say(1, "/race new hill")
check(chatContains("Start of hill set%. Now drive to the finish and type /race finish hill%.", 1), "/race new")
drive(1, 2000, 2600, 50, 9000)
say(1, "/race finish hill")
check(chatContains("Finish of hill set %(600 m straight line%)", 1), "/race finish")
say(1, "/race delete hill")
check(chatContains("Track hill deleted%.", 1), "/race delete")
say(1, "/lang de")
-- Sprache wird gespeichert und beim naechsten Join verwendet.
BN.savePlayer(BN.players[5])
eq(readJson(SHARED .. "/players/3003.json").lang, "en", "Sprache gespeichert")
_G[events.onPlayerDisconnect](5)
players[5] = { name = "Kaputt", ids = { beammp = "3003" }, vehicles = {} }
join(5)
check(chatContains("Welcome to BeamNet | Server 1 %(gridmap_v2%)! Level %d+ · %a+ league", 5), "Begruessung auf Englisch")
-- Bann-Text in der Sprache des Gesperrten.
writeJson(SHARED .. "/bans.json", { bans = { { id = "3003", name = "Kaputt", reason = "Test", by = "Sebi", at = clock } } })
local denyEn = _G[events.onPlayerAuth]("Kaputt", "USER", false, { beammp = "3003" })
check(type(denyEn) == "string" and denyEn:find("^Banned on all BeamNet servers: Test"), "Bann-Text auf Englisch")
writeJson(SHARED .. "/bans.json", { bans = {} })
-- Standardsprache Englisch fuer neue Spieler.
C.language = "en"
players[7] = { name = "Newbie", ids = { beammp = "7007" }, vehicles = {} }
join(7)
check(chatContains("Welcome to BeamNet", 7), "Standardsprache Englisch")
C.language = "de"
players[7] = nil
_G[events.onPlayerDisconnect](7)
-- Alle englischen Texte haben dieselben Platzhalter wie die deutschen.
local function holes(text)
    local list = {}
    for h in text:gmatch("%%[%d%.]*[sdf]") do list[#list + 1] = h end
    return table.concat(list, ",")
end
local mismatch = {}
for de, en in pairs(BN.EN) do
    if holes(de) ~= holes(en) then mismatch[#mismatch + 1] = de end
end
check(#mismatch == 0, "Platzhalter stimmen ueberein: " .. table.concat(mismatch, " | "))

-- --- Funde aus der Code-Pruefung --------------------------------------------------------------------------------
-- (1) Platte voll: Schreibfehler -> alte Datei bleibt, savePlayer meldet false.
do
    local s5 = BN.players[5]
    s5.pendingKm = s5.pendingKm + 1
    local before = readJson(SHARED .. "/players/3003.json")
    local realOpen = io.open
    io.open = function(path, mode)
        if mode == "wb" then
            return { write = function() return nil, "No space left on device" end,
                     flush = function() return nil, "No space left on device" end,
                     close = function() return true end }
        end
        return realOpen(path, mode)
    end
    local ok = BN.savePlayer(s5)
    io.open = realOpen
    check(ok == false, "Schreibfehler wird gemeldet")
    local after = readJson(SHARED .. "/players/3003.json")
    check(after ~= nil and after.km == before.km, "Bei Schreibfehler bleibt die alte Datei erhalten")
    check(BN.players[5].pendingKm >= 1, "Unge­speicherte km gehen nicht verloren")
    check(BN.savePlayer(s5), "Danach normal gespeichert")
end
-- (11) Hilfsdateien tragen den Port und bleiben nicht liegen.
do
    local leftovers = 0
    for _, name in ipairs(FS.ListFiles(SHARED .. "/players")) do if name:find("%.tmp") then leftovers = leftovers + 1 end end
    eq(leftovers, 0, "Keine liegengebliebenen Hilfsdateien")
end
-- (2) Rundkurs: Wackeln an der Linie zaehlt nicht.
at(1, 5000, 20000, 5000)
say(1, "/rennen neu wackel")
say(1, "/rennen ziel wackel")
players[5].vehicles[0] = players[5].vehicles[0] or { pos = { 0, 0, 0 }, tim = 0 }
say(5, "/rennen wackel")
local wt = 30000
at(5, 5000, wt, 4990); at(5, 5000, wt + 1, 5000)          -- in den Startbereich
at(5, 5000, wt + 2, 5012.1)                                 -- knapp raus: Start
check(BN.players[5].race.state == "running", "Rundkurs gestartet (Wackeltest)")
for i = 1, 12 do at(5, 5000, wt + 2 + i, (i % 2 == 1) and 5011.9 or 5012.1) end
check(not chatContains("Ziel! wackel", 5) and not chatContains("Finish! wackel", 5), "Wackeln an der Linie ist keine Runde")
at(5, 5000, wt + 20, 5250); at(5, 5000, wt + 25, 5005)      -- echte Runde (250 m weg und zurueck)
check(chatContains("Ziel! wackel", 5) or chatContains("Finish! wackel", 5), "Echte Runde zaehlt")
say(5, "/rennen stop")
say(1, "/rennen loeschen wackel")
-- (3) Genauer Name (gespeichert) schlaegt Teilname (online).
do
    writeJson(SHARED .. "/players/8008.json", { id = "8008", name = "Maxi", km = 1, seconds = 1 })
    players[8] = { name = "Maximilian", ids = { beammp = "8009", ip = "8.8.8.8" }, vehicles = {} }
    join(8)
    local t = BN.findTarget("maxi")
    check(t and t.id == "8008" and not t.online, "Genauer gespeicherter Name vor Teilname online")
    local t2 = BN.findTarget("maximilian")
    check(t2 and t2.online and t2.id == "8009", "Genauer Name online")
end
-- (4) Bann sperrt auch die IP: kein Zurueckkommen als Gast.
say(1, "/ban maximilian 1h Test")
bans = readJson(SHARED .. "/bans.json").bans
check(bans[#bans].id == "8009" and bans[#bans].ip == "8.8.8.8", "Bann speichert ID und IP")
check(type(_G[events.onPlayerAuth]("Gast77", "GUEST", true, { ip = "8.8.8.8" })) == "string", "Gebannter kommt nicht als Gast zurueck")
writeJson(SHARED .. "/bans.json", { bans = {} })
-- (5) Stummschaltung: auch "/..." anderer Plugins, netzweit, ueber Neu-Verbinden hinweg.
players[9] = { name = "Laut", ids = { beammp = "9009", ip = "9.0.0.9" }, vehicles = {} }
join(9)
say(1, "/mute laut 5")
eq(say(9, "/ hallo alle"), 1, "Stumm: auch '/ ...' blockiert")
eq(say(9, "/g hallo global"), 1, "Stumm: Befehle anderer Plugins blockiert")
eq(say(9, "/km"), 1, "Stumm: eigene Befehle gehen (werden beantwortet)")
check(chatContains("Du bist %d+%.%d km gefahren", 9), "Eigene Befehle beantwortet")
_G[events.onPlayerDisconnect](9)
players[9] = { name = "Laut", ids = { beammp = "9009", ip = "9.0.0.9" }, vehicles = {} }
join(9)
eq(say(9, "wieder da"), 1, "Stummschaltung uebersteht Neu-Verbinden")
-- (9) /mute mit Kommazahl stuerzt nicht ab.
local okMute = pcall(say, 1, "/mute laut 0.33")
check(okMute, "/mute 0.33 ohne Absturz")
check(chatContains("Aufruf: /mute", 1), "/mute 0.33 wird abgelehnt (unter 1 min)")
local okChat, res = pcall(say, 9, "noch was")
check(okChat and res == 1, "Chat-Handler bleibt stabil")
-- (15) Befehls-Bremse.
C.commandLimit = 6
local blocked = 0
for i = 1, 10 do
    local before = #chatLog
    say(8, "/km")
    if chatContains("Bitte etwas langsamer", 8) then blocked = blocked + 1 end
end
check(chatContains("Bitte etwas langsamer mit den Befehlen", 8), "Befehls-Bremse greift")
clock = clock + 11
local n0 = countChat("Du bist", 8)
say(8, "/km")
eq(countChat("Du bist", 8), n0 + 1, "Nach der Pause wieder Befehle")
C.commandLimit = 100000
_G[events.onPlayerDisconnect](8); players[8] = nil
_G[events.onPlayerDisconnect](9); players[9] = nil

-- --- Erfolge -----------------------------------------------------------------------------------------------------
do
    -- Alter Hase: viele Erfolge auf einmal -> eine zusammenfassende Meldung.
    writeJson(SHARED .. "/players/4242.json", { id = "4242", name = "Veteran", km = 1500, seconds = 40000, topSpeedKmh = 310,
        maps = { italy = true, utah = true, derby = true } })
    players[10] = { name = "Veteran", ids = { beammp = "4242" }, vehicles = {} }
    join(10)
    tick(1)
    check(chatContains("Veteran hat %d+ Erfolge freigeschaltet %(%+%d+ XP%) – /erfolge"), "Mehrere Erfolge zusammengefasst")
    local v = BN.players[10]
    for _, id in ipairs({ "km10", "km100", "km1000", "hour1", "hours10", "speed200", "speed300", "maps3", "level10" }) do
        check(BN.hasAchievement(v, id), "Erfolg " .. id)
    end
    check(not BN.hasAchievement(v, "race1") and not BN.hasAchievement(v, "maps8"), "Nicht verdiente Erfolge fehlen")
    say(10, "/erfolge")
    check(chatContains("Erfolge von Veteran: 9 von 13", 10), "/erfolge zaehlt")
    check(chatContains("Als Nächstes: Erstes Rennen 0/1", 10), "/erfolge zeigt Fortschritt")
    BN.savePlayer(v)
    local saved = readJson(SHARED .. "/players/4242.json")
    check(saved.achievements and saved.achievements.km1000 and saved.maps.italy, "Erfolge gespeichert")
    check(saved.maps.gridmap_v2 == nil, "Map zaehlt nicht ohne zu fahren")
    -- Nachtraeglich vergebene Erfolge geben XP, zaehlen aber nicht fuer die Saison.
    check(saved.bonusXp >= 500 and (saved.monthXp or 0) < 50, "Nachtraegliche Erfolge nicht in der Saison (" .. tostring(saved.monthXp) .. ")")
    players[10].vehicles[0] = { pos = { 0, 0, 0 }, tim = 0 }
    tick(1)
    for _ = 1, 5 do move(10, 0, 30); tick(1) end                  -- 150 m
    BN.savePlayer(v)
    saved = readJson(SHARED .. "/players/4242.json")
    check(saved.maps.gridmap_v2 == true, "Map zaehlt nach dem Fahren")
    players[10].vehicles = {}
    -- Neu verbinden: keine doppelte Meldung.
    _G[events.onPlayerDisconnect](10)
    local before = countChat("Veteran hat")
    players[10] = { name = "Veteran", ids = { beammp = "4242" }, vehicles = {} }
    join(10)
    tick(1)
    eq(countChat("Veteran hat"), before, "Erfolge nach Neu-Verbinden nicht erneut gemeldet")
    -- Englisch.
    say(10, "/lang en")
    say(10, "/achievements")
    check(chatContains("Achievements of Veteran: 9 of 13", 10) and chatContains("Next: First race 0/1", 10), "/achievements auf Englisch")
    -- Abschaltbar.
    C.achievements = false
    players[11] = { name = "Ohne", ids = { beammp = "1111" }, vehicles = {} }
    writeJson(SHARED .. "/players/1111.json", { id = "1111", name = "Ohne", km = 50 })
    join(11)
    tick(1)
    check(not chatContains("Erfolg für Ohne"), "Erfolge abschaltbar")
    C.achievements = true
    _G[events.onPlayerDisconnect](10); players[10] = nil
    _G[events.onPlayerDisconnect](11); players[11] = nil
end

-- --- Tagesaufgaben ------------------------------------------------------------------------------------------------
do
    C.challengeTypes = { "km" }
    local ch = BN.challengeFor()
    check(ch and ch.kind == "km" and (ch.goal == 10 or ch.goal == 15 or ch.goal == 25), "Tagesaufgabe gewaehlt")
    eq(BN.challengeFor(BN.dayNumber()).goal, ch.goal, "Aufgabe ist am selben Tag gleich (alle Server)")
    players[12] = { name = "Daily", ids = { beammp = "1212" }, vehicles = { [0] = { pos = { 0, 0, 0 }, tim = 0 } } }
    join(12)
    check(chatContains("Heute: Fahre heute " .. ch.goal .. " km %(/aufgabe%)", 12), "Begruessung nennt die Tagesaufgabe")
    say(12, "/aufgabe")
    check(chatContains("Tagesaufgabe: Fahre heute " .. ch.goal .. " km – 0/" .. ch.goal, 12), "/aufgabe zeigt Fortschritt")
    tick(1)
    local steps = math.ceil(ch.goal * 1000 / 50)
    for _ = 1, steps - 1 do move(12, 0, 50); tick(1) end
    check(not chatContains("Tagesaufgabe geschafft", 12), "Noch nicht geschafft")
    local bonusBefore = BN.totals(BN.players[12]).bonusXp
    move(12, 0, 60); tick(1)
    check(chatContains("Tagesaufgabe geschafft: Fahre heute " .. ch.goal .. " km %(%+40 XP%)!", 12), "Tagesaufgabe geschafft")
    eq(BN.totals(BN.players[12]).bonusXp - bonusBefore >= 40, true, "Belohnung gutgeschrieben")
    for _ = 1, 5 do move(12, 0, 50); tick(1) end
    eq(countChat("Tagesaufgabe geschafft: Fahre heute %d+ km %(%+", 12), 1, "Belohnung nur einmal")
    say(12, "/aufgabe")
    check(chatContains("Die nächste kommt in", 12), "/aufgabe nach Erledigung")
    BN.savePlayer(BN.players[12])
    local rec = readJson(SHARED .. "/players/1212.json")
    check(rec.dayDone == true and rec.day == BN.dayNumber() and rec.dayKm >= ch.goal, "Tagesstand gespeichert")
    -- Neu verbinden am selben Tag: kein zweites Mal.
    _G[events.onPlayerDisconnect](12)
    players[12] = { name = "Daily", ids = { beammp = "1212" }, vehicles = { [0] = { pos = { 0, 0, 0 }, tim = 0 } } }
    join(12)
    for _ = 1, 3 do move(12, 0, 50); tick(1) end
    eq(countChat("Tagesaufgabe geschafft: Fahre heute %d+ km %(%+", 12), 1, "Nach Neu-Verbinden nicht erneut belohnt")
    -- Naechster Tag: neue Aufgabe, Zaehler bei 0.
    clock = (BN.dayNumber() + 1) * 86400 + 60
    tick(1)
    local d = BN.dayTotals(BN.players[12])
    check(not d.done and d.km < 1, "Neuer Tag: Zaehler zurueckgesetzt")
    -- Aufgabe "verschiedene Server": heute schon auf einer anderen Map gefahren.
    C.challengeTypes = { "servers" }
    local ch2 = BN.challengeFor()
    BN.players[12].record.day = BN.dayNumber()
    BN.players[12].record.dayDone = false
    BN.players[12].record.dayMaps = { italy = true, utah = true, derby = true }
    tick(1)
    check(chatContains("Tagesaufgabe geschafft: Fahre heute auf " .. ch2.goal .. " verschiedenen Servern", 12), "Aufgabe verschiedene Server")
    -- Englisch.
    say(12, "/lang en")
    say(12, "/daily")
    check(chatContains("Daily challenge done: Drive on " .. ch2.goal .. " different servers today%. The next one comes in", 12), "/daily auf Englisch")
    -- Keine Arten erlaubt: keine Aufgabe.
    C.challengeTypes = {}
    say(12, "/daily")
    check(chatContains("No daily challenge today%.", 12), "Ohne Arten keine Aufgabe")
    C.challengeTypes = { "km", "speed", "time", "servers" }
    _G[events.onPlayerDisconnect](12); players[12] = nil
end

-- --- Saisons (Monat) ----------------------------------------------------------------------------------------------
do
    eq(BN.monthKey(clock), "2025-10", "Testuhr steht im Oktober 2025")
    players[13] = { name = "Saisonfahrer", ids = { beammp = "1313" }, vehicles = { [0] = { pos = { 0, 0, 0 }, tim = 0 } } }
    join(13)
    tick(1)
    for _ = 1, 100 do move(13, 0, 50); tick(1) end                -- 5 km
    local mx = BN.totals(BN.players[13]).monthXp
    check(mx >= 50, "Saison-XP gezaehlt (" .. mx .. ")")
    say(13, "/saison")
    check(chatContains("Saison Oktober 2025 %(noch %d+ Tage%):", 13), "/saison Kopf")
    check(chatContains("Du: Platz %d+ mit %d+ XP in dieser Saison", 13), "/saison eigener Platz")
    BN.savePlayer(BN.players[13])
    local rec = readJson(SHARED .. "/players/1313.json")
    check(rec.month == "2025-10" and rec.monthXp >= 50 and rec.monthStartXp == nil, "Saison-XP als Zaehler gespeichert")
    near(rec.monthXp, mx, 1, "Gespeicherte Saison-XP = angezeigte")
    -- Vorhandene Spieler ohne Saisondaten starten bei ihrem jetzigen Stand (kein Riesenvorsprung).
    local vet = readJson(SHARED .. "/players/4242.json")
    check(vet.month == "2025-10" and vet.monthXp ~= nil and vet.monthXp < 100, "Alte Datensaetze starten mit wenig Saison-XP")
    local rank = BN.seasonRanking("2025-10")
    local found = false
    for _, e in ipairs(rank) do if e.id == "1313" and e.xp >= 50 then found = true end end
    check(found, "Saisonfahrer in der Saisonwertung")
    for _, e in ipairs(rank) do
        if e.id == "4242" then check(e.xp < 1000, "Veteran startet nicht mit seinen alten XP in die Saison (" .. e.xp .. ")") end
    end
    -- Monatswechsel: Sieger verkuenden, archivieren, neue Saison beginnt bei 0.
    clock = 1761955200 + 30
    tick(1)
    check(chatContains("Saison Oktober 2025 beendet! 1%. "), "Saisonende verkuendet")
    local archive = readJson(SHARED .. "/seasons/2025-10.json")
    check(archive and archive.top and archive.top[1] and archive.top[1].xp > 0, "Saison archiviert")
    for _ = 1, 10 do move(13, 0, 50); tick(1) end
    local mx2 = BN.totals(BN.players[13]).monthXp
    check(mx2 < mx, "Neue Saison beginnt neu (" .. mx2 .. " < " .. mx .. ")")
    say(13, "/saison")
    check(chatContains("Saison November 2025 %(noch %d+ Tage%):", 13), "/saison neue Saison")
    check(chatContains("Letzte Saison %(Oktober 2025%): 1%. ", 13), "/saison zeigt Vorsaison")
    BN.savePlayer(BN.players[13])
    rec = readJson(SHARED .. "/players/1313.json")
    check(rec.month == "2025-11" and rec.lastMonth == "2025-10" and rec.lastMonthXp >= 50, "Vorsaison im Datensatz")
    -- Englisch.
    say(13, "/lang en")
    say(13, "/season")
    check(chatContains("Season November 2025 %(%d+ days left%):", 13) and chatContains("Last season %(October 2025%)", 13), "/season auf Englisch")
    _G[events.onPlayerDisconnect](13); players[13] = nil
end

-- --- Funde der zweiten Code-Pruefung ------------------------------------------------------------------------------
do
    -- (1) Update im laufenden Betrieb: Sitzungen einer alten Version (ohne neue Felder) laufen nach BN.init() weiter.
    writeJson(SHARED .. "/players/3030.json", { id = "3030", name = "Altversion", km = 5, seconds = 60, week = "alt" })
    players[30] = { name = "Altversion", ids = { beammp = "3030" }, vehicles = { [0] = { pos = { 0, 0, 0 }, tim = 0 } } }
    BN.players[30] = { pid = 30, name = "Altversion", id = "3030", guest = false, vehicles = {},
                       pendingKm = 0.5, pendingSeconds = 10, pendingTop = 0,
                       unlocked = { km10 = clock - 5 }, challengeDoneDay = BN.dayNumber(),
                       record = { id = "3030", name = "Altversion", km = 5, seconds = 60, weekKm = 0, week = "alt" } }
    BN.init()
    local s30 = BN.players[30]
    check(s30 and s30.pendingRaces == 0 and s30.sessionKm == 0 and type(s30.unlocked.km10) == "table",
        "Alte Sitzung wird um neue Felder ergaenzt")
    check(s30.challengeReward and s30.challengeReward.day == BN.dayNumber() and s30.challengeDoneDay == nil,
        "Alte Tagesaufgabe wird uebernommen")
    BN.errorLog = {}
    tick(1)
    for _ = 1, 5 do move(30, 0, 40); tick(1) end
    check(next(BN.errorLog) == nil, "Takt laeuft nach dem Update ohne Fehler")
    check(BN.savePlayer(s30), "Alte Sitzung speichert nach dem Update")
    local r30 = readJson(SHARED .. "/players/3030.json")
    check(r30.km > 5.6 and r30.achievements.km10 and r30.lastChallengeDay == BN.dayNumber(), "Alte Sitzung: Werte gespeichert")

    -- Ein fehlerhafter Spieler legt den Takt fuer die anderen nicht lahm.
    players[31] = { name = "Defekt", ids = { beammp = "3131" }, vehicles = { [0] = { pos = { 0, 0, 0 }, tim = 0 } } }
    join(31)
    BN.players[31].vehicles = setmetatable({}, { __index = function() error("kaputt") end })
    local kmBefore = BN.totals(s30).km
    for _ = 1, 3 do move(30, 0, 40); tick(1) end
    check(BN.totals(s30).km > kmBefore + 0.1, "Andere Spieler zaehlen trotz Fehler weiter")
    check(BN.errorLog["Takt Spieler 31"] ~= nil, "Fehler wird (gedrosselt) protokolliert")
    _G[events.onPlayerDisconnect](31); players[31] = nil

    -- (2) Schneller Serverwechsel: Belohnungen, die ein anderer Server schon gutgeschrieben hat, gibt es nicht doppelt.
    writeJson(SHARED .. "/players/3232.json", { id = "3232", name = "Wechsler", km = 9.95, seconds = 0 })
    players[32] = { name = "Wechsler", ids = { beammp = "3232" }, vehicles = { [0] = { pos = { 0, 0, 0 }, tim = 0 } } }
    join(32)
    tick(1)
    for _ = 1, 4 do move(32, 0, 50); tick(1) end
    local s32 = BN.players[32]
    check(s32.unlocked.km10 and not s32.unlocked.km10.retro, "Erfolg waehrend der Fahrt (nicht nachtraeglich)")
    s32.challengeReward = { day = BN.dayNumber(), xp = 40 }
    local other = readJson(SHARED .. "/players/3232.json")    -- der andere Server hat schon gespeichert
    other.achievements = { km10 = clock }
    other.lastChallengeDay = BN.dayNumber()
    other.bonusXp = 60
    writeJson(SHARED .. "/players/3232.json", other)
    BN.savePlayer(s32)
    local r32 = readJson(SHARED .. "/players/3232.json")
    eq(r32.bonusXp, 60, "Erfolg und Tagesaufgabe nicht doppelt gutgeschrieben")
    eq(BN.totals(s32).bonusXp, 60, "Anzeige ohne doppelte Belohnung")
    -- Ohne Vorgaenger: genau einmal.
    s32.unlocked.speed200 = { at = clock, xp = 30 }
    BN.savePlayer(s32)
    BN.savePlayer(s32)
    eq(readJson(SHARED .. "/players/3232.json").bonusXp, 90, "Neuer Erfolg genau einmal gutgeschrieben")
    _G[events.onPlayerDisconnect](32); players[32] = nil

    -- (3) Saison-XP ist ein Zaehler: XP von frueher zaehlen nicht, Datensaetze von 1.8 werden umgestellt.
    local month = BN.monthKey()
    writeJson(SHARED .. "/players/3333.json", { id = "3333", name = "Zaehler", km = 500, seconds = 0, month = month, monthXp = 100 })
    writeJson(SHARED .. "/players/3434.json", { id = "3434", name = "Umsteiger", km = 500, seconds = 0, bonusXp = 0,
        xp = 5000, month = month, monthStartXp = 4930 })
    BN.seasonCache = {}
    local found = {}
    for _, e in ipairs(BN.seasonRanking(month)) do found[e.id] = e.xp end
    eq(found["3333"], 100, "Saisonwertung nutzt den Zaehler")
    eq(found["3434"], 70, "Saisonwertung versteht Datensaetze von 1.8")
    local legacy = BN.normalizeRecord({ km = 500, seconds = 0, bonusXp = 0, month = month, monthStartXp = BN.xpFor(500, 0) - 70 })
    BN.applyMonth(legacy)
    check(legacy.monthXp == 70 and legacy.monthStartXp == nil, "Startwert wird beim Laden in den Zaehler umgerechnet")
    local old = BN.normalizeRecord({ km = 500, seconds = 0, bonusXp = 0, month = "2000-01", monthXp = 33 })
    BN.applyMonth(old)
    check(old.lastMonth == "2000-01" and old.lastMonthXp == 33 and old.monthXp == 0 and old.month == month, "Monatswechsel rollt den Zaehler")

    -- (7) Saisonende verpasst (kein Server lief): das Archiv der Vorsaison wird still nachgeholt.
    local prev = BN.previousMonthKey()
    eq(prev, "2025-10", "Vorsaison")
    os.remove(SHARED .. "/seasons/" .. prev .. ".json")
    local announced = countChat("Saison Oktober 2025 beendet")
    BN.lastSeasonCheck = nil
    tick(1)
    local archive = readJson(SHARED .. "/seasons/" .. prev .. ".json")
    check(archive and archive.top and archive.top[1], "Fehlendes Saisonarchiv nachgeholt")
    eq(countChat("Saison Oktober 2025 beendet"), announced, "Nachholen ohne erneute Ansage")
    eq(BN.ensureSeasonArchive(), false, "Vorhandenes Archiv bleibt unangetastet")

    -- Kleinigkeit: Zahlen in config.json werden geprueft (ganze Zahlen fuer XP im Chat, sinnvolle Untergrenzen).
    writeJson(SHARED .. "/config.json", { challengeXp = 40.7, levelBase = 0, raceFinishXp = -5, xpPerKm = 12.5 })
    BN.loadOverrides()
    eq(C.challengeXp, 40, "challengeXp ganzzahlig")
    eq(C.levelBase, 1, "levelBase mindestens 1")
    eq(C.raceFinishXp, 0, "Keine negativen XP")
    eq(C.xpPerKm, 12.5, "Kommazahlen bleiben, wo sie erlaubt sind")
    check(pcall(string.format, "%d", C.challengeXp), "challengeXp laesst sich mit %d ausgeben")
    os.remove(SHARED .. "/config.json")
    C.challengeXp, C.levelBase, C.raceFinishXp, C.xpPerKm = 40, 25, 15, 20

    _G[events.onPlayerDisconnect](30); players[30] = nil
end

-- --- Map-Abstimmung ---------------------------------------------------------------------------------------------------
do
    for pid = 40, 42 do
        players[pid] = { name = "Waehler" .. pid, ids = { beammp = tostring(4000 + pid) }, vehicles = {} }
        join(pid)
    end
    say(41, "/lang en")
    os.remove(SHARED .. "/watch.json")
    say(40, "/vote map italy")
    check(chatContains("Map%-Abstimmung ist auf diesem Netzwerk nicht eingerichtet", 40), "Ohne Waechter keine Abstimmung")
    check(BN.vote == nil, "Ohne Waechter keine Abstimmung gestartet")
    local maps = { "gridmap_v2", "west_coast_usa", "east_coast_usa", "italy", "utah" }
    local function heartbeat() writeJson(SHARED .. "/watch.json", { at = clock, mapVote = true, maps = maps }) end
    heartbeat()
    eq(BN.findMap("Italy", maps), "italy", "Map: Name")
    eq(BN.findMap("utah, usa", maps), "utah", "Map: Anzeigename")
    eq(BN.findMap("west", maps), "west_coast_usa", "Map: eindeutiger Teil")
    local none, hits = BN.findMap("coast", maps)
    check(none == nil and #hits == 2, "Map: mehrdeutig")
    say(40, "/vote")
    check(chatContains("Map%-Abstimmung: /vote map <Name> – möglich: west_coast_usa, east_coast_usa, italy, utah", 40), "/vote zeigt Maps ohne die aktuelle")
    say(40, "/vote map gridmap")
    check(chatContains("Grid Map läuft hier bereits", 40), "Aktuelle Map nicht waehlbar")
    say(40, "/vote map mond")
    check(chatContains("Unbekannte Map: mond", 40), "Unbekannte Map")
    say(40, "/vote map coast")
    check(chatContains("Mehrdeutig: west_coast_usa, east_coast_usa", 40), "Mehrdeutige Map")
    say(40, "/vote ja")
    check(chatContains("Gerade läuft keine Abstimmung", 40), "Ja ohne Abstimmung")

    -- Abgelehnt: alle anderen sagen nein.
    say(40, "/vote map italy")
    check(BN.vote and BN.vote.map == "italy", "Abstimmung gestartet")
    check(chatContains("Waehler40 möchte auf Italy wechseln %(Neustart%)%. Abstimmen: /vote ja oder /vote nein %(60 s%)", 42), "Abstimmung angekuendigt")
    check(chatContains("Waehler40 wants to switch to Italy %(restart%)", 41), "Abstimmung auf Englisch")
    say(42, "/vote")
    check(chatContains("Abstimmung: Italy – 1 ja, 0 nein", 42), "/vote zeigt den Stand")
    for pid in pairs(players) do if pid ~= 40 then say(pid, "/vote nein") end end
    check(BN.vote == nil and chatContains("Abstimmung für Italy abgelehnt %(1:", 40), "Abstimmung abgelehnt")
    say(40, "/vote map utah")
    check(chatContains("Nächste Abstimmung in", 40), "Pause nach einer Abstimmung")

    -- Zeit abgelaufen.
    clock = clock + 11 * 60
    heartbeat()
    say(40, "/vote map utah")
    check(BN.vote and BN.vote.map == "utah", "Neue Abstimmung nach der Pause")
    tick(61)
    check(BN.vote == nil and chatContains("Abstimmung für Utah, USA abgelehnt", 40), "Abstimmung endet nach Ablauf der Zeit")

    -- Angenommen: Mehrheit sagt ja -> Auftrag fuer den Waechter, vorher wird gespeichert.
    clock = clock + 11 * 60
    heartbeat()
    os.remove(SHARED .. "/votes/30814.json")
    say(40, "/vote map west")
    BN.players[40].pendingKm = 1.5
    for pid in pairs(players) do if pid ~= 40 then say(pid, "/vote yes") end end
    check(BN.vote == nil and chatContains("Abstimmung angenommen %(%d+:0%): Wechsel auf West Coast, USA – der Server startet in etwa einer Minute neu%.", 40), "Abstimmung angenommen")
    local order = readJson(SHARED .. "/votes/30814.json")
    check(order and order.map == "west_coast_usa" and order.port == 30814 and order.from == "gridmap_v2" and order.at == clock, "Auftrag fuer den Waechter geschrieben")
    check(readJson(SHARED .. "/players/4040.json").km >= 1.5, "Vor dem Neustart gespeichert")
    say(42, "/vote map italy")
    check(chatContains("Die Map wird gleich gewechselt", 42), "Keine neue Abstimmung waehrend des Wechsels")
    -- Waechter laeuft nicht mehr (Lebenszeichen alt) oder Abstimmungen aus.
    clock = clock + 20 * 60
    say(42, "/vote map italy")
    check(chatContains("Map%-Abstimmung ist auf diesem Netzwerk nicht eingerichtet", 42), "Altes Lebenszeichen = kein Waechter")
    C.mapVote = false
    say(42, "/vote")
    check(chatContains("Map%-Abstimmungen sind ausgeschaltet", 42), "Abstimmungen abschaltbar")
    C.mapVote = true
    for pid = 40, 42 do _G[events.onPlayerDisconnect](pid); players[pid] = nil end
end

-- --- Abstimmung: Nachbesserungen -----------------------------------------------------------------------------------
do
    local maps = { "gridmap_v2", "west_coast_usa", "italy", "utah" }
    local function heartbeat() writeJson(SHARED .. "/watch.json", { at = clock, mapVote = true, maps = maps }) end
    local orderFile = SHARED .. "/votes/30814.json"
    local others = {}       -- Spieler aus frueheren Abschnitten, die noch online sind
    for pid in pairs(players) do others[#others + 1] = pid end
    -- Der Wechsel aus dem vorigen Abschnitt wurde nie umgesetzt: verfaellt, sein Auftrag wird entfernt.
    check(BN.mapChangePending ~= nil and readJson(orderFile) ~= nil, "Offener Wechsel aus dem vorigen Abschnitt")
    tick(1)
    check(BN.mapChangePending == nil, "Alter Wechsel verfaellt")
    check(readJson(orderFile) == nil, "Nicht umgesetzter Auftrag entfernt")

    local function enter(pid, name)
        players[pid] = { name = name or ("Waehler" .. pid), ids = { beammp = tostring(5000 + pid) }, vehicles = {} }
        join(pid)
    end
    local function leave(pid) _G[events.onPlayerDisconnect](pid); players[pid] = nil end
    for pid = 50, 53 do enter(pid) end
    say(53, "/lang en")
    clock = clock + 11 * 60
    heartbeat()

    -- Stimmen gehen beim Abmelden verloren; ein neuer Spieler mit derselben pid erbt sie nicht.
    say(50, "/vote map italy")
    say(51, "/vote ja")
    check(BN.vote and BN.vote.yes[51], "Stimme von 51 gezaehlt")
    leave(51)
    check(BN.vote and BN.vote.yes[51] == nil and BN.vote.no[51] == nil, "Stimme beim Abmelden verworfen")
    enter(51, "Neuling")
    check(BN.vote and BN.vote.yes[51] == nil, "Neuer Spieler mit alter pid erbt keine Stimme")
    say(52, "/vote")
    check(chatContains("Abstimmung: Italy – 1 ja, 0 nein", 52), "Stand ohne die alte Stimme")
    -- 8 online (4 fruehere Spieler), 3 Nein-Stimmen: reicht noch nicht zum Ablehnen, auch nicht ohne 51.
    eq(#others, 4, "Fruehere Spieler online")
    say(52, "/vote nein")
    say(others[1], "/vote nein")
    say(others[2], "/vote nein")
    local noVotes = 3
    leave(51)
    check(BN.vote ~= nil, "Abstimmung laeuft weiter, solange sie gewinnen kann")
    -- Der einzige Ja-Waehler geht: jetzt nicht mehr zu gewinnen, sofort beendet (ohne Takt).
    leave(50)
    check(BN.vote == nil and chatContains("Abstimmung für Italy abgelehnt %(0:" .. noVotes .. "%)", 52), "Abstimmung endet, wenn sie nach dem Abmelden nicht mehr gewinnen kann")
    check(chatContains("Vote for Italy failed %(0:" .. noVotes .. "%)", 53), "Ende der Abstimmung auf Englisch")

    -- Angenommen, aber der Waechter setzt den Auftrag nicht um: nach 3 Minuten einmal melden.
    enter(50)
    enter(51)
    clock = clock + 11 * 60
    heartbeat()
    os.remove(orderFile)
    say(50, "/vote map utah")
    for pid in pairs(players) do if pid ~= 50 then say(pid, "/vote ja") end end
    check(BN.vote == nil and BN.mapChangePending and BN.mapChangePending.map == "utah", "Abstimmung angenommen, Wechsel offen")
    check(readJson(orderFile) ~= nil, "Auftrag liegt bereit")
    local failDe = "Der Map%-Wechsel auf Utah, USA hat nicht geklappt – bitte einem Admin melden%."
    tick(170)
    check(BN.mapChangePending ~= nil and countChat(failDe, 50) == 0, "Vor Ablauf von 3 Minuten keine Meldung")
    say(52, "/vote map italy")
    check(chatContains("Die Map wird gleich gewechselt", 52), "Waehrend des Wechsels keine neue Abstimmung")
    tick(15)
    check(BN.mapChangePending == nil, "Offener Wechsel nach 3 Minuten aufgegeben")
    eq(countChat(failDe, 50), 1, "Fehlschlag gemeldet")
    check(chatContains("The switch to Utah, USA did not work – please tell an admin%.", 53), "Fehlschlag auf Englisch")
    check(readJson(orderFile) == nil, "Auftrag nach dem Fehlschlag entfernt")
    tick(5)
    eq(countChat(failDe, 50), 1, "Fehlschlag nur einmal gemeldet")
    -- Neue Abstimmungen wieder moeglich, die Pause gilt aber weiter.
    heartbeat()
    say(52, "/vote map italy")
    check(BN.vote == nil and chatContains("Nächste Abstimmung in", 52), "Pause gilt nach dem Fehlschlag weiter")
    clock = clock + 11 * 60
    heartbeat()
    say(52, "/vote map italy")
    check(BN.vote and BN.vote.map == "italy", "Nach der Pause wieder abstimmbar")
    for pid = 50, 53 do leave(pid) end
    tick(61)
    check(BN.vote == nil, "Abstimmung nach dem Abmelden beendet")
end

-- --- Kalenderwoche ohne %G/%V (Windows) -----------------------------------------------------------------------------
eq(BN.weekKey(1609632000), "2020-W53", "KW: So 3.1.2021 gehoert zu 2020")
eq(BN.weekKey(1609718400), "2021-W01", "KW: Mo 4.1.2021")
eq(BN.weekKey(1735516800), "2025-W01", "KW: Mo 30.12.2024 gehoert zu 2025")
eq(BN.weekKey(1792022400), "2026-W42", "KW: 15.10.2026")

-- --- Robustheit ---------------------------------------------------------------------------------------------------
do
    local function enter(pid, id, name)
        players[pid] = { name = name, ids = { beammp = id }, vehicles = {} }
        join(pid)
        return BN.players[pid]
    end
    local function leave(pid) _G[events.onPlayerDisconnect](pid); players[pid] = nil end

    -- Spielerdatei voruebergehend nicht lesbar (z. B. zu viele offene Dateien): nichts schreiben, Zuwaechse behalten.
    local file = SHARED .. "/players/9101.json"
    writeJson(file, { id = "9101", name = "Robust", km = 100, seconds = 0, lang = "en" })
    local s = enter(60, "9101", "Robust")
    eq(s.record.km, 100, "Spielerdatei geladen")
    s.pendingKm = 2
    local realOpen = io.open
    io.open = function(path, mode)
        if path == file and (mode == nil or mode:find("r")) then return nil, path .. ": Too many open files", 24 end
        return realOpen(path, mode)
    end
    local ok, saved = pcall(BN.savePlayer, s)
    io.open = realOpen
    check(ok and saved == false, "Nicht lesbare Spielerdatei: Speichern meldet Fehler")
    eq(readJson(file).km, 100, "Nicht lesbare Spielerdatei wird nicht ueberschrieben")
    eq(s.pendingKm, 2, "Zuwaechse bleiben bei nicht lesbarer Datei erhalten")
    check(BN.errorLog["Spielerdatei 9101"] ~= nil, "Lesefehler protokolliert")
    check(BN.savePlayer(s), "Wieder lesbar: Speichern klappt")
    eq(readJson(file).km, 102, "Zuwaechse nachgetragen")

    -- Sprache: ein anderer Server hat sie inzwischen umgestellt -> dieser Server schreibt die alte nicht zurueck.
    local rec = readJson(file); rec.lang = "de"; writeJson(file, rec)
    s.pendingKm = 1
    BN.savePlayer(s)
    eq(readJson(file).lang, "de", "Sprache vom anderen Server bleibt")
    say(60, "/lang en")
    BN.savePlayer(s)
    eq(readJson(file).lang, "en", "Eigene Sprachwahl gespeichert")
    rec = readJson(file); rec.lang = "de"; writeJson(file, rec)
    s.pendingKm = 1
    BN.savePlayer(s)
    eq(readJson(file).lang, "de", "Sprachwahl nur einmal geschrieben")

    -- Abstimmung: Sitzung verschwindet ohne Abmeldung -> Stimme verworfen, die neue pid erbt sie nicht.
    local maps = { "gridmap_v2", "italy", "utah" }
    local function heartbeat() writeJson(SHARED .. "/watch.json", { at = clock, mapVote = true, maps = maps }) end
    clock = clock + 11 * 60
    heartbeat()
    enter(61, "9102", "Robust2")
    enter(62, "9103", "Robust3")
    say(60, "/vote map italy")
    say(61, "/vote ja")
    check(BN.vote and BN.vote.yes[61], "Stimme von 61 gezaehlt")
    players[61] = nil
    tick(1)
    check(BN.players[61] == nil, "Sitzung ohne Abmeldung entfernt")
    check(BN.vote ~= nil, "Abstimmung laeuft weiter")
    enter(61, "9104", "Neuling2")
    check(BN.vote and BN.vote.yes[61] == nil, "Verschwundene Sitzung: neue pid erbt keine Stimme")
    tick(61)
    check(BN.vote == nil, "Abstimmung beendet")

    -- Offener Map-Wechsel sperrt neue Abstimmungen genau so lange, wie mapChangeCheck auf ihn wartet.
    clock = clock + 11 * 60
    heartbeat()
    local blocked = countChat("Die Map wird gleich gewechselt", 60)
    BN.mapChangePending = { map = "utah", at = clock - 190 }
    say(60, "/vote map italy")
    eq(countChat("Die Map wird gleich gewechselt", 60), blocked, "Abgelaufener Map-Wechsel sperrt nicht mehr")
    check(BN.vote and BN.vote.map == "italy", "Abstimmung nach Ablauf der Frist moeglich")
    eq(BN.MAP_CHANGE_TIMEOUT, 180, "Eine Frist fuer den Map-Wechsel")
    BN.mapChangePending = nil
    tick(61)
    check(BN.vote == nil, "Abstimmung beendet")

    -- Zwischenzeiten: Marke knapp hinter der Ziellinie wird nicht mehr gemeldet; Abstand der Marken wird gespeichert.
    C.admins = { "sebi", "9103" }
    say(60, "/lang de")
    at(62, 3000, 9100)
    say(62, "/rennen neu ziellinie")
    at(62, 5000, 9101)
    say(62, "/rennen ziel ziellinie")
    check(chatContains("Ziel von ziellinie gesetzt", 62), "Strecke ziellinie angelegt")
    C.raceSplitM = 495
    local tracksFile = SHARED .. "/races/gridmap_v2.json"
    local data = BN.loadTracks()
    data.tracks.ziellinie.records = { { id = "9101", name = "Robust", time = 200, at = clock, splits = { 20, 40, 60, 80 }, splitM = 495 } }
    writeJson(tracksFile, data)
    local function myRecord()
        for _, r in ipairs(BN.loadTracks().tracks.ziellinie.records or {}) do
            if r.id == "9101" then return r end
        end
    end
    -- Marken bei 3507, 4002, 4497 und 4992 (Start bei 3012 verlassen); Ziellinie bei 4988.
    local function run(t0, speed)
        say(60, "/rennen ziellinie")
        at(60, 3000, t0); at(60, 3010, t0 + 1); at(60, 3020, t0 + 2)
        local t = drive(60, 3020, 4980, speed, t0 + 2)
        at(60, 5000, t + 1)
        return t + 1
    end
    local before = #chatLog
    local tim = run(500, 20)
    local finishLine, split4, split3 = nil, nil, nil
    for i = before + 1, #chatLog do
        local c = chatLog[i]
        if c.pid == 60 then
            if c.msg:find("^Ziel! ziellinie") then finishLine = i end
            if c.msg:find("^Zwischenzeit 4") then split4 = i end
            if c.msg:find("^Zwischenzeit 3") then split3 = i end
        end
    end
    check(finishLine ~= nil, "Lauf auf ziellinie im Ziel")
    check(split3 ~= nil, "Zwischenzeit 3 vor dem Ziel gemeldet")
    eq(split4, nil, "Keine Zwischenzeit hinter der Ziellinie")
    local mine = myRecord()
    eq(mine and #mine.splits, 3, "Nur Marken vor dem Ziel gespeichert")
    -- Anderer Abstand: die gespeicherten Zwischenzeiten passen nicht mehr und werden nicht verglichen;
    -- die neue Bestzeit speichert ihren Abstand mit.
    C.raceSplitM = 250
    before = #chatLog
    run(tim + 100, 25)
    local splits = 0
    for i = before + 1, #chatLog do
        local c = chatLog[i]
        if c.pid == 60 and c.msg:find("^Zwischenzeit") then splits = splits + 1 end
    end
    eq(splits, 0, "Zwischenzeiten mit anderem Abstand werden nicht verglichen")
    mine = myRecord()
    check(mine and mine.time < 90, "Schnellerer Lauf ist Bestzeit")
    eq(mine and mine.splitM, 250, "Abstand der Marken mit der Bestzeit gespeichert")
    eq(mine and #mine.splits, 7, "Zwischenzeiten im neuen Abstand")
    C.raceSplitM = 500
    say(60, "/rennen stop")
    say(62, "/rennen loeschen ziellinie")
    C.admins = { "sebi" }
    for pid = 60, 62 do leave(pid) end
end

-- --- Schummelschutz: Rundkurs-Abkuerzung, mehrere Fahrzeuge, Fahrzeit im Stand -------------------------------------
do
    local savedAdmins = C.admins
    C.admins = { "bauer" }
    local function enter(pid, name, vehicles)
        players[pid] = { name = name, ids = { beammp = tostring(6000 + pid) }, vehicles = vehicles or {} }
        join(pid)
    end
    local function myRecords(name)
        local t = BN.loadTracks().tracks[name]
        return t and t.records or {}
    end
    enter(60, "Bauer")
    enter(61, "Schummler")

    -- Mindeststrecke: Rundkurs ohne Laenge 0.8 * 400 m, A nach B mindestens 0.8 * Luftlinie, jeweils ohne die Radien.
    check(type(BN.raceMinDist) == "function", "Mindeststrecke vorhanden")
    if type(BN.raceMinDist) == "function" then
        local a, b = { x = 0, y = 0, z = 0 }, { x = 1000, y = 0, z = 0 }
        near(BN.raceMinDist(a, a, nil), 0.8 * 400 - 24, 1e-9, "Rundkurs ohne Laenge: raceMinLapM")
        near(BN.raceMinDist(a, a, 600), 0.8 * 600 - 24, 1e-9, "Rundkurs mit Laenge")
        near(BN.raceMinDist(a, b, nil), 0.8 * 1000 - 24, 1e-9, "A nach B: Luftlinie")
        near(BN.raceMinDist(a, b, 2000), 0.8 * 2000 - 24, 1e-9, "A nach B: gefahrene Laenge")
    end

    -- Rundkurs ohne Fahrt angelegt: keine Laenge bekannt.
    at(60, 8000, 100)
    say(60, "/rennen neu kreis")
    say(60, "/rennen ziel kreis")
    check(chatContains("Streckenlänge unbekannt – der erste gültige Lauf legt sie fest%.", 60), "Rundkurs ohne Laenge gemeldet")
    eq(BN.loadTracks().tracks.kreis.lengthM, nil, "Ohne Fahrt keine Streckenlaenge")
    -- 40 m raus und zurueck ist keine Runde (vorher: Streckenrekord, XP, Erfolge).
    say(61, "/rennen kreis")
    at(61, 7950, 100); at(61, 7995, 101)                -- in den Startbereich
    at(61, 8020, 102)                                     -- raus: Start
    check(BN.players[61].race.state == "running", "Schummel-Runde gestartet")
    at(61, 8040, 103); at(61, 8005, 104)                  -- 40 m weg und zurueck
    check(not chatContains("Ziel! kreis", 61), "Abgekuerzte Runde kommt nicht ins Ziel")
    check(chatContains("Strecke abgekürzt – Lauf ungültig", 61), "Abgekuerzte Runde ungueltig")
    eq(#myRecords("kreis"), 0, "Abgekuerzte Runde ohne Rekord")
    eq(BN.players[61].pendingRaces, 0, "Abgekuerzte Runde zaehlt nicht als Rennen")
    eq(BN.players[61].pendingBonus, 0, "Abgekuerzte Runde ohne Bonus-XP")
    -- Echte Runde (260 m raus und zurueck) zaehlt und legt die Laenge fest.
    at(61, 8000, 105)
    local t = drive(61, 8000, 8260, 20, 105)
    t = drive(61, 8260, 8000, -20, t)
    check(chatContains("Ziel! kreis", 61), "Echte Runde im Ziel")
    eq(#myRecords("kreis"), 1, "Echte Runde mit Rekord")
    near(BN.loadTracks().tracks.kreis.lengthM, 532, 1, "Erster gueltiger Lauf legt die Laenge fest")
    -- Jetzt gilt die Laenge: 180 m raus und zurueck ist laenger als 0.8 * 400 m, aber zu kurz fuer diese Runde.
    at(61, 8000, t + 1)
    t = drive(61, 8000, 8180, 20, t + 1)
    t = drive(61, 8180, 8000, -20, t)
    eq(countChat("Strecke abgekürzt – Lauf ungültig", 61), 2, "Kuerzere Runde als die bekannte Laenge ungueltig")
    eq(countChat("Ziel! kreis", 61), 1, "Kuerzere Runde kommt nicht ins Ziel")
    say(61, "/lang en")
    at(61, 8000, t + 1); at(61, 8020, t + 2); at(61, 8040, t + 3); at(61, 8005, t + 4)
    check(chatContains("Track cut short – run invalid", 61), "Abgekuerzt auf Englisch")
    say(61, "/lang de")
    say(61, "/rennen stop")
    say(60, "/rennen loeschen kreis")

    -- Rundkurs, den der Admin abgefahren hat: seine Fahrstrecke ist die Laenge.
    at(60, 30000, 200)
    say(60, "/rennen neu oval")
    t = drive(60, 30000, 30300, 25, 200)
    t = drive(60, 30300, 30000, -25, t)
    say(60, "/rennen ziel oval")
    eq(BN.loadTracks().tracks.oval.lengthM, 600, "Gefahrene Laenge des Admins gespeichert")
    check(chatContains("Streckenlänge 600 m %(von dir gefahren%)", 60), "Gefahrene Laenge gemeldet")
    say(61, "/rennen oval")
    at(61, 30000, 1000)
    t = drive(61, 30000, 30210, 30, 1000)                -- 210 m raus und zurueck: ueber 0.8 * 400 m, unter 0.8 * 600 m
    t = drive(61, 30210, 30000, -30, t)
    eq(countChat("Strecke abgekürzt – Lauf ungültig", 61), 3, "Runde kuerzer als die Admin-Fahrt ungueltig")
    at(61, 30000, t + 1)
    t = drive(61, 30000, 30300, 30, t + 1)
    t = drive(61, 30300, 30000, -30, t)
    check(chatContains("Ziel! oval", 61), "Volle Runde zaehlt")
    eq(BN.loadTracks().tracks.oval.lengthM, 600, "Laenge des Admins bleibt")
    say(61, "/rennen stop")
    say(60, "/rennen loeschen oval")

    -- Lkw mit Anhaenger: zwei Fahrzeuge fahren dieselbe Strecke, gezaehlt wird sie einmal.
    enter(62, "Brummi", { [0] = { pos = { 0, 0, 0 }, tim = 0 }, [1] = { pos = { -10, 0, 0 }, tim = 0 } })
    tick(1)
    for _ = 1, 50 do move(62, 0, 20); move(62, 1, 20); tick(1) end    -- 50 s mit 20 m/s = 1 km
    near(BN.totals(BN.players[62]).km, 1.0, 1e-9, "Zwei Fahrzeuge: 1 km zaehlt einmal")
    near(BN.players[62].sessionKm, 1.0, 1e-9, "Zwei Fahrzeuge: Sitzungs-km einmal")
    -- Nur der Anhaenger bewegt sich weiter: die groesste Strecke zaehlt.
    move(62, 0, 5); move(62, 1, 30); tick(1)
    near(BN.totals(BN.players[62]).km, 1.03, 1e-9, "Groesste Strecke je Takt zaehlt")

    -- Fahrzeit nur in Bewegung: Parken (mit oder ohne Fahrzeug) bringt keine Zeit.
    enter(63, "Parker", { [0] = { pos = { 0, 0, 0 }, tim = 0 } })
    enter(64, "Zuschauer")
    tick(120)
    eq(BN.totals(BN.players[63]).seconds, 0, "Geparkt: keine Fahrzeit")
    eq(BN.totals(BN.players[64]).seconds, 0, "Ohne Fahrzeug: keine Fahrzeit")
    for _ = 1, 10 do move(63, 0, 20); tick(1) end
    eq(BN.totals(BN.players[63]).seconds, 10, "Fahrzeit beim Fahren")
    tick(60)
    eq(BN.totals(BN.players[63]).seconds, 39, "Nach dem Anhalten zaehlen nur noch knapp 30 s")
    near(BN.totals(BN.players[63]).km, 0.2, 1e-9, "Parker: km stimmen")

    for pid = 60, 64 do _G[events.onPlayerDisconnect](pid); players[pid] = nil end
    C.admins = savedAdmins
end

-- --- Last: volles Netzwerk (64 Spieler gleichzeitig) ---------------------------------------------------------------
do
    local first, count = 200, 64
    local errorsBefore = 0
    for _ in pairs(BN.errorLog) do errorsBefore = errorsBefore + 1 end
    for pid = first, first + count - 1 do
        players[pid] = { name = "Last" .. pid, ids = { beammp = tostring(7000 + pid) },
                         vehicles = { [0] = { pos = { pid * 100, 0, 0 }, tim = 0 } } }
        _G[events.onPlayerJoin](pid)
    end
    local t0 = os.clock()
    for _ = 1, 120 do
        for pid = first, first + count - 1 do move(pid, 0, 20) end
        tick(1)
    end
    local perTick = (os.clock() - t0) / 120
    print(string.format("  Last: %d Spieler fahren, %.1f ms je Takt (Takt = %d ms)", count, perTick * 1000, C.tickMs))
    check(perTick * 1000 < C.tickMs / 4, "64 Spieler: ein Takt braucht weniger als ein Viertel des Taktabstands")
    local kmOk, secOk, fileOk = 0, 0, 0
    for pid = first, first + count - 1 do
        local tot = BN.totals(BN.players[pid])
        -- Der erste Takt setzt nur den Ausgangspunkt: 119 Schritte zu 20 m.
        if math.abs(tot.km - 2.38) < 1e-9 then kmOk = kmOk + 1 end
        if tot.seconds == 119 then secOk = secOk + 1 end
        if readJson(SHARED .. "/players/" .. (7000 + pid) .. ".json") then fileOk = fileOk + 1 end
    end
    eq(kmOk, count, "64 Spieler: jeder hat genau seine 2,38 km")
    eq(secOk, count, "64 Spieler: jeder hat genau seine 119 s Fahrzeit")
    eq(fileOk, count, "64 Spieler: alle Dateien beim regelmaessigen Speichern geschrieben")
    local st = readJson(SHARED .. "/servers/30814.json")
    check(st and st.players >= count, "64 Spieler: Serverstatus zaehlt alle")
    local board = BN.refreshBoard(true)
    check(type(board) == "table" and #board >= 10, "64 Spieler: Bestenliste wird weiter berechnet")
    local t1 = os.clock()
    say(first, "/top")
    say(first + 1, "/stats")
    say(first + 2, "/server")
    print(string.format("  Last: drei Chatbefehle bei %d Spielern in %.1f ms", count, (os.clock() - t1) * 1000))
    check(os.clock() - t1 < 0.5, "64 Spieler: Chatbefehle bleiben schnell")
    for pid = first, first + count - 1 do _G[events.onPlayerDisconnect](pid); players[pid] = nil end
    local errorsAfter = 0
    for _ in pairs(BN.errorLog) do errorsAfter = errorsAfter + 1 end
    eq(errorsAfter, errorsBefore, "64 Spieler: keine neuen Fehler im Protokoll")
    check(next(BN.players) == nil or BN.players[first] == nil, "64 Spieler: Sitzungen nach Abmeldung weg")
end

-- Herunterfahren speichert alle.
tick(1)
_G[events.onShutdown]()
local saved = readJson(SHARED .. "/players/3003.json")
check(saved ~= nil, "Herunterfahren speichert")
check(saved and saved.bonusXp >= 90 and saved.xp >= 90, "Bonus-XP gespeichert und in XP enthalten")

print(string.format("%s: %d Prüfungen bestanden, %d fehlgeschlagen", _VERSION, passed, failed))
return failed
