-- BeamNetCore – Server-Plugin fuer das BeamNet-Netzwerk (BeamMP 3.x)
--
-- Kilometer, Fahrzeit, XP und Level, Ligen, Bestenliste und eine Liste aller Server im Chat.
-- Die Daten gelten fuer alle Server gemeinsam: jeder Spieler hat eine Datei im gemeinsamen Ordner
-- (Standard /srv/beammp/shared/beamnet/players/<BeamMP-ID>.json), jeder Server meldet seinen Stand
-- alle 15 s nach /srv/beammp/shared/beamnet/servers/<Port>.json.
--
-- Installation: beamnet install-core  (oder diese Datei nach Resources/Server/BeamNetCore/main.lua kopieren)
-- Anpassen ohne Code-Aenderung: <gemeinsamer Ordner>/config.json, z. B. {"publicHost": "1.2.3.4", "xpPerKm": 12}
--
-- Chat-Befehle: /hilfe  /stats [Name]  /top [km|xp|woche|vorwoche]  /liga  /server  /km  /lang de|en
-- (englisch: /help /stats /top [km|xp|week|lastweek] /league /server /km /race /records /lang)
--               /rennen [Name|stop]  /rekorde [Name]  /erfolge [Name]  /aufgabe  /saison   – Admins: /rennen neu|ziel|loeschen <Name>
-- Moderation (Admins): /kick <Name> [Grund]  /ban <Name> [30m|2h|7d] [Grund]  /unban <Name>  /bans
--                      /warn <Name> <Text>  /mute <Name> [Minuten]  /ansage <Text>

BeamNetCore = BeamNetCore or {}
local BN = BeamNetCore

BN.VERSION = "1.8"

local defaults = {
    sharedDir = os.getenv("BEAMNET_SHARED") or "/srv/beammp/shared/beamnet",
    serverConfig = "ServerConfig.toml",
    tickMs = 1000,
    statusEverySec = 15,
    saveEverySec = 60,
    leaderboardEverySec = 60,
    -- Schneller als das (m/s) gilt als Teleport oder Zuruecksetzen und zaehlt nicht (≈ 540 km/h).
    maxSpeedMps = 150,
    -- Kleinere Schritte (m) sind Messrauschen im Stand.
    minStepM = 0.3,
    xpPerKm = 10,
    xpPerMinute = 1,
    -- XP fuer Level L: levelBase * (L-1)^2  (Level 2 = 25 XP, Level 10 = 2025 XP, Level 30 = 21025 XP)
    levelBase = 25,
    leagues = {
        { xp = 0, name = "Bronze" },
        { xp = 500, name = "Silber" },
        { xp = 2000, name = "Gold" },
        { xp = 6000, name = "Platin" },
        { xp = 15000, name = "Diamant" },
        { xp = 40000, name = "Legende" },
    },
    -- Oeffentliche Adresse fuer /server (leer = nur Name und Port anzeigen).
    publicHost = "",
    announceLevelUps = true,
    -- Standardsprache fuer Spieler ohne eigene Wahl: "de" oder "en" (jeder kann mit /lang umstellen).
    language = "de",
    -- Erfolge an (true) oder aus (false).
    achievements = true,
    -- Tagesaufgaben: Belohnung und erlaubte Arten (km, speed, time, servers, races – Rennen nur, wenn es Strecken gibt).
    challengeXp = 40,
    challengeTypes = { "km", "speed", "time", "servers" },
    -- Spamschutz: mehr als spamMessages Nachrichten in spamWindowSec Sekunden -> spamMuteSec stumm (Admins nie).
    spamMessages = 5,
    spamWindowSec = 5,
    spamMuteSec = 30,
    -- Befehls-Bremse je Spieler (Admins ausgenommen).
    commandLimit = 6,
    commandWindowSec = 10,
    -- Wie oft Banns und Ansagen der anderen Server gelesen werden (s).
    syncEverySec = 3,
    -- Zeitrennen: Radius von Start- und Zielbereich (m), Abtastung waehrend eines Laufs (ms), Hoechstdauer (min).
    raceRadiusM = 12,
    raceTickMs = 250,
    raceMaxMinutes = 30,
    -- Bonus-XP fuer Rennen: gueltiger Lauf, persoenliche Bestzeit, Streckenrekord.
    raceFinishXp = 15,
    racePersonalBestXp = 10,
    raceRecordXp = 50,
    -- Wer Strecken anlegen darf: BeamMP-Namen oder -IDs (Gaeste nie).
    admins = {},
}

BN.config = BN.config or {}
for k, v in pairs(defaults) do
    if BN.config[k] == nil then BN.config[k] = v end
end
local C = BN.config

-- Uhr (in Tests ersetzbar).
BN.now = BN.now or function() return os.time() end

-- Zustand
BN.players = BN.players or {}     -- pid -> Sitzung
BN.server = BN.server or {}       -- Name, Port, Map, MaxPlayers
BN.board = BN.board or { at = -math.huge, list = {} }
BN.lastStatus = BN.lastStatus or -math.huge
BN.lastSave = BN.lastSave or -math.huge

-- ---------------------------------------------------------------------------------------------------------------------
-- JSON (eigene kleine Umsetzung: verhaelt sich auf jedem Server gleich und ist getestet)

local json = {}

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encodeString(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function isArray(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    for i = 1, n do
        if t[i] == nil then return false end
    end
    return true, n
end

function json.encode(v)
    local t = type(v)
    if t == "nil" then return "null" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "0" end
        if v % 1 == 0 and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
        local text = string.format("%.6f", v):gsub("0+$", ""):gsub("%.$", "")
        return text
    end
    if t == "string" then return encodeString(v) end
    if t == "table" then
        local arr, n = isArray(v)
        local parts = {}
        if arr and n > 0 then
            for i = 1, n do parts[i] = json.encode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local value = v[k]
            if value == nil then value = v[tonumber(k)] end
            parts[#parts + 1] = encodeString(k) .. ":" .. json.encode(value)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function decodeError(pos, what)
    error(string.format("JSON-Fehler an Stelle %d: %s", pos, what), 0)
end

local function skip(s, i)
    return s:find("[^ \t\r\n]", i) or (#s + 1)
end

local decodeValue

-- UTF-8 ohne die utf8-Bibliothek (die es in Lua 5.1/LuaJIT nicht gibt).
local function utf8char(code)
    local floor = math.floor
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then return string.char(0xC0 + floor(code / 0x40), 0x80 + code % 0x40) end
    if code < 0x10000 then
        return string.char(0xE0 + floor(code / 0x1000), 0x80 + floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + floor(code / 0x40000), 0x80 + floor(code / 0x1000) % 0x40, 0x80 + floor(code / 0x40) % 0x40,
        0x80 + code % 0x40)
end

local function decodeString(s, i)
    local out = {}
    local j = i + 1
    while true do
        local c = s:sub(j, j)
        if c == "" then decodeError(j, "Zeichenkette nicht beendet") end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local e = s:sub(j + 1, j + 1)
            local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
            if map[e] then
                out[#out + 1] = map[e]
                j = j + 2
            elseif e == "u" then
                local hex = s:sub(j + 2, j + 5)
                if not hex:match("^%x%x%x%x$") then decodeError(j, "ungueltiges \\u") end
                local code = tonumber(hex, 16)
                j = j + 6
                if code >= 0xD800 and code <= 0xDBFF and s:sub(j, j + 1) == "\\u" then
                    local low = tonumber(s:sub(j + 2, j + 5), 16)
                    if low and low >= 0xDC00 and low <= 0xDFFF then
                        code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                        j = j + 6
                    end
                end
                if code >= 0xD800 and code <= 0xDFFF then code = 0xFFFD end
                out[#out + 1] = utf8char(code)
            else
                decodeError(j, "ungueltige Escape-Folge")
            end
        else
            if c:byte() < 0x20 then decodeError(j, "Steuerzeichen in Zeichenkette") end
            out[#out + 1] = c
            j = j + 1
        end
    end
end

function decodeValue(s, i, depth)
    if depth > 64 then decodeError(i, "zu tief verschachtelt") end
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            if s:sub(i, i) ~= '"' then decodeError(i, "Schluessel erwartet") end
            local key
            key, i = decodeString(s, i)
            i = skip(s, i)
            if s:sub(i, i) ~= ":" then decodeError(i, "':' erwartet") end
            local value
            value, i = decodeValue(s, i + 1, depth + 1)
            obj[key] = value
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "}" then return obj, i + 1 end
            if d ~= "," then decodeError(i, "',' oder '}' erwartet") end
            i = skip(s, i + 1)
        end
    elseif c == "[" then
        local arr = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local value
            value, i = decodeValue(s, i, depth + 1)
            arr[#arr + 1] = value
            i = skip(s, i)
            local d = s:sub(i, i)
            if d == "]" then return arr, i + 1 end
            if d ~= "," then decodeError(i, "',' oder ']' erwartet") end
            i = i + 1
        end
    elseif c == '"' then
        return decodeString(s, i)
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
        return nil, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not num or num == "" or num == "-" then decodeError(i, "Wert erwartet") end
        local n = tonumber(num)
        if not n then decodeError(i, "ungueltige Zahl") end
        return n, i + #num
    end
end

function json.decode(s)
    if type(s) ~= "string" then return nil, "keine Zeichenkette" end
    local ok, value, pos = pcall(decodeValue, s, 1, 0)
    if not ok then return nil, value end
    if skip(s, pos) <= #s then return nil, "Daten nach dem Ende" end
    return value
end

BN.json = json

-- ---------------------------------------------------------------------------------------------------------------------
-- Dateien

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

-- Schreibt erst in eine Hilfsdatei und benennt sie dann um: ein Absturz hinterlaesst nie eine halbe Datei.
-- Bei einem Fehler (z. B. Platte voll) bleibt die alte Datei unveraendert. Der Name der Hilfsdatei enthaelt den Port,
-- damit sich die 12 Server nie in dieselbe Hilfsdatei schreiben (math.random ist je Prozess gleich geseedet).
local tmpCounter = 0
local function writeFileAtomic(path, data)
    tmpCounter = tmpCounter + 1
    local tmp = string.format("%s.tmp-%s-%d-%d", path, tostring(BN.server and BN.server.port or 0), os.time(), tmpCounter)
    local f, err = io.open(tmp, "wb")
    if not f then return false, err end
    local wrote, writeErr = f:write(data)
    local flushed, flushErr = f:flush()
    local closed, closeErr = f:close()
    if not (wrote and flushed and closed) then
        os.remove(tmp)
        return false, writeErr or flushErr or closeErr or "Schreibfehler"
    end
    local ok, renameErr = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        return false, renameErr
    end
    return true
end

local function ensureDir(path)
    if FS and FS.CreateDirectory then
        if FS.Exists and FS.Exists(path) then return true end
        FS.CreateDirectory(path)
        return true
    end
    return false
end

local function listJsonFiles(dir)
    if not (FS and FS.ListFiles) then return {} end
    local ok, files = pcall(FS.ListFiles, dir)
    if not ok or type(files) ~= "table" then return {} end
    local out = {}
    for _, name in pairs(files) do
        name = tostring(name)
        name = name:match("([^/\\]+)$") or name
        if name:match("%.json$") then out[#out + 1] = dir .. "/" .. name end
    end
    table.sort(out)
    return out
end

local function playersDir() return C.sharedDir .. "/players" end
local function serversDir() return C.sharedDir .. "/servers" end
local function racesDir() return C.sharedDir .. "/races" end
local function bansFile() return C.sharedDir .. "/bans.json" end
local function mutesFile() return C.sharedDir .. "/mutes.json" end
local function announcementsFile() return C.sharedDir .. "/announcements.json" end
local function modlogFile() return C.sharedDir .. "/modlog.jsonl" end

-- Dateiname aus der BeamMP-ID (nur Ziffern und Buchstaben – nie Pfade aus Spielereingaben).
local function safeId(id)
    id = tostring(id or "")
    if id == "" or not id:match("^[%w_-]+$") or #id > 64 then return nil end
    return id
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Werte

function BN.xpFor(km, seconds)
    return math.floor((km or 0) * C.xpPerKm + (seconds or 0) / 60 * C.xpPerMinute)
end

function BN.levelFor(xp)
    if not xp or xp <= 0 then return 1 end
    return math.floor(math.sqrt(xp / C.levelBase)) + 1
end

function BN.xpForLevel(level)
    return C.levelBase * (level - 1) ^ 2
end

function BN.leagueFor(xp)
    local current = C.leagues[1]
    for _, league in ipairs(C.leagues) do
        if (xp or 0) >= league.xp then current = league end
    end
    return current
end

function BN.nextLeague(xp)
    for _, league in ipairs(C.leagues) do
        if (xp or 0) < league.xp then return league end
    end
    return nil
end

-- Saison = Kalendermonat (UTC), z. B. "2026-10".
local function monthKey(t)
    return os.date("!%Y-%m", t or BN.now())
end
BN.monthKey = monthKey

local function weekKey(t)
    return os.date("!%G-W%V", t)
end

local function fmtKm(km)
    if km >= 100 then return string.format("%.0f km", km) end
    return string.format("%.1f km", km)
end

local function fmtDuration(seconds)
    seconds = math.floor(seconds or 0)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then return string.format("%d h %02d min", h, m) end
    return string.format("%d min", m)
end

BN.fmtKm = fmtKm
BN.fmtDuration = fmtDuration

-- ---------------------------------------------------------------------------------------------------------------------
-- Server-Kennung aus ServerConfig.toml

function BN.readServerConfig(path)
    local info = { name = "BeamMP-Server", port = 0, map = "?", maxPlayers = 0 }
    local data = readFile(path or C.serverConfig)
    if not data then return info end
    for line in data:gmatch("[^\r\n]+") do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key then
            local quoted = value:match('^"(.-)"')
            if not quoted then value = value:gsub("%s*#.*$", "") end
            value = quoted or value
            if key == "Name" then info.name = value
            elseif key == "Port" then info.port = tonumber(value) or 0
            elseif key == "Map" then info.map = value:match("/levels/([^/]+)/") or value
            elseif key == "MaxPlayers" then info.maxPlayers = tonumber(value) or 0
            end
        end
    end
    -- BeamMP-Farbcodes (^1, ^l ...) aus dem Namen entfernen.
    info.name = info.name:gsub("%^%w", "")
    return info
end

function BN.loadOverrides()
    local data = readFile(C.sharedDir .. "/config.json")
    if not data then return end
    local cfg = json.decode(data)
    if type(cfg) ~= "table" then
        if not BN.configBroken then print("[BeamNetCore] config.json ist fehlerhaft und wird ignoriert") end
        BN.configBroken = true
        return
    end
    BN.configBroken = false
    for k, v in pairs(cfg) do
        if k == "leagues" then
            if BN.validLeagues(v) then C.leagues = v else print("[BeamNetCore] config.json: leagues ungueltig, Standard bleibt") end
        elseif defaults[k] ~= nil and type(v) == type(defaults[k]) and k ~= "sharedDir" then
            C[k] = v
        end
    end
end

-- Ligen: Liste aus {xp = Zahl, name = Text}, aufsteigend, die erste ab 0 XP.
function BN.validLeagues(list)
    if type(list) ~= "table" or #list == 0 then return false end
    local last = -1
    for i, league in ipairs(list) do
        if type(league) ~= "table" or type(league.name) ~= "string" or type(league.xp) ~= "number" then return false end
        if league.xp <= last or (i == 1 and league.xp ~= 0) then return false end
        last = league.xp
    end
    return true
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Spieler

local function chat(pid, text)
    if MP and MP.SendChatMessage then MP.SendChatMessage(pid, text) end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Sprachen: Deutsch (Standard) und Englisch. Schluessel ist der deutsche Formattext; fehlt eine Uebersetzung, bleibt
-- es Deutsch. Jeder Spieler waehlt mit /lang de|en, die Wahl wird gespeichert.

local unpack = table.unpack or unpack

local EN = {
    ["%s ist jetzt Level %d!"] = "%s reached level %d!",
    ["%s steigt in die Liga %s auf!"] = "%s moved up to the %s league!",
    ["Wochensieger %s: %s"] = "Winners of %s: %s",
    ["KW %s"] = "week %s",
    ["%s – Lauf ungültig. Neuer Versuch: zurück zum Start von %s."] = "%s – run invalid. Try again: back to the start of %s.",
    ["Fahrzeug zurückgesetzt"] = "Vehicle reset",
    ["Sprung (Teleport)"] = "Jump (teleport)",
    ["Zeitlimit überschritten"] = "Time limit exceeded",
    ["Ziel! %s: %s"] = "Finish! %s: %s",
    ["Neuer Streckenrekord auf %s: %s mit %s!"] = "New track record on %s: %s with %s!",
    ["Persönliche Bestzeit! Platz %d von %d."] = "Personal best! Rank %d of %d.",
    ["+%d XP (nur für diese Sitzung)"] = "+%d XP (this session only)",
    ["Für einen neuen Versuch zurück zum Start – beenden mit /rennen stop."] = "For another try drive back to the start – quit with /race stop.",
    ["Am Start von %s. Los geht's, sobald du den Startbereich verlässt!"] = "At the start of %s. The clock starts when you leave the start area!",
    ["Zeit läuft! Ziel ist %.0f m entfernt."] = "Clock is running! The finish is %.0f m away.",
    ["[Ansage] %s"] = "[Announcement] %s",
    ["Du bist noch %d s stummgeschaltet."] = "You are muted for another %d s.",
    ["Bitte nicht spammen – du bist %d s stummgeschaltet."] = "Please don't spam – you are muted for %d s.",
    ["BeamNet-Befehle: /stats [Name] · /top [km|xp|woche|vorwoche] · /liga · /saison · /server · /km · /rennen · /rekorde · /erfolge · /aufgabe · /lang"] =
        "BeamNet commands: /stats [name] · /top [km|xp|week|lastweek] · /league · /season · /server · /km · /race · /records · /achievements · /daily · /lang",
    ["Admin: /kick · /ban <Name> [30m|2h|7d] [Grund] · /unban · /bans · /warn · /mute · /ansage"] =
        "Admin: /kick · /ban <name> [30m|2h|7d] [reason] · /unban · /bans · /warn · /mute · /announce",
    ["Du bist %s gefahren (diese Woche %s)."] = "You have driven %s (this week %s).",
    ["Kein Spieler online mit dem Namen \"%s\"."] = "No player online named \"%s\".",
    ["%s: Level %d · Liga %s · %d XP · %s · %s Fahrzeit · Spitze %.0f km/h"] = "%s: level %d · %s league · %d XP · %s · %s driving · top speed %.0f km/h",
    ["Gast-Konto: Werte gelten nur für diese Sitzung (mit BeamMP-Konto werden sie gespeichert)."] =
        "Guest account: values only count for this session (they are saved with a BeamMP account).",
    ["Rang %s von %d · noch %d XP bis Level %d"] = "Rank %s of %d · %d XP to level %d",
    ["Noch keine Bestenliste – einfach losfahren!"] = "No leaderboard yet – just start driving!",
    ["Bestenliste %s:"] = "Leaderboard %s:",
    ["Kilometer"] = "kilometers",
    ["Kilometer diese Woche"] = "kilometers this week",
    ["Kilometer letzte Woche"] = "kilometers last week",
    ["%d XP (Level %d)"] = "%d XP (level %d)",
    ["Ligen (XP): %s"] = "Leagues (XP): %s",
    ["%s ab %d"] = "%s from %d",
    ["Du: %s mit %d XP – noch %d XP bis %s."] = "You: %s with %d XP – %d XP to %s.",
    ["Du: %s mit %d XP – höchste Liga erreicht!"] = "You: %s with %d XP – top league reached!",
    ["Keine Serverliste verfügbar."] = "No server list available.",
    ["BeamNet-Server (wechseln im BeamMP-Launcher):"] = "BeamNet servers (switch in the BeamMP launcher):",
    ["Port %s"] = "port %s",
    ["  ← hier"] = "  ← here",
    ["Auf %s gibt es noch keine Strecken."] = "No tracks on %s yet.",
    ["Strecken auf %s: %s"] = "Tracks on %s: %s",
    ["%s (ohne Ziel)"] = "%s (no finish)",
    ["%s (Rekord %s · %s)"] = "%s (record %s · %s)",
    ["%s (noch keine Zeit)"] = "%s (no time yet)",
    ["Starten: /rennen <Name> · beenden: /rennen stop · Rekorde: /rekorde <Name>"] =
        "Start: /race <name> · quit: /race stop · records: /records <name>",
    ["Admin: am Start /rennen neu <Name>, am Ziel /rennen ziel <Name>, entfernen /rennen loeschen <Name>"] =
        "Admin: at the start /race new <name>, at the finish /race finish <name>, remove /race delete <name>",
    ["Rennmodus beendet."] = "Race mode ended.",
    ["Du bist in keinem Rennen."] = "You are not in a race.",
    ["Strecken anlegen dürfen nur Admins (Eintrag \"admins\" in config.json)."] = "Only admins can create tracks (\"admins\" in config.json).",
    ["Streckenname: 1–24 Zeichen, nur Buchstaben, Ziffern, _ und -"] = "Track name: 1–24 characters, letters, digits, _ and - only",
    ["Strecke %s gibt es nicht."] = "Track %s does not exist.",
    ["Strecke %s gelöscht."] = "Track %s deleted.",
    ["Keine Position bekannt – setz dich in ein Fahrzeug und warte eine Sekunde."] = "No position known – get into a vehicle and wait a second.",
    ["Strecke %s gibt es schon."] = "Track %s already exists.",
    ["Start von %s gesetzt. Jetzt zum Ziel fahren und /rennen ziel %s schreiben."] = "Start of %s set. Now drive to the finish and type /race finish %s.",
    ["Strecke %s gibt es nicht – zuerst /rennen neu %s"] = "Track %s does not exist – first /race new %s",
    ["Ziel von %s gesetzt – Rundkurs (Start = Ziel). Starten: /rennen %s"] = "Finish of %s set – lap course (start = finish). Start: /race %s",
    ["Ziel von %s gesetzt (%.0f m Luftlinie). Starten: /rennen %s"] = "Finish of %s set (%.0f m straight line). Start: /race %s",
    ["Strecke \"%s\" gibt es auf dieser Map nicht. Liste: /rennen"] = "Track \"%s\" does not exist on this map. List: /race",
    ["Strecke %s hat noch kein Ziel."] = "Track %s has no finish yet.",
    ["Rennen %s: Fahr zum Start (%.0f m entfernt)."] = "Race %s: drive to the start (%.0f m away).",
    ["Rennen %s: Fahr zum Start."] = "Race %s: drive to the start.",
    ["Auf %s gibt es noch keine Zeiten."] = "No times on %s yet.",
    ["Rekorde %s:"] = "Records %s:",
    ["Noch keine Rekorde auf dieser Map."] = "No records on this map yet.",
    ["Nur für Admins."] = "Admins only.",
    ["Mehrere Spieler passen zu \"%s\" – bitte genauer."] = "Several players match \"%s\" – please be more specific.",
    ["Aufruf: /kick <Name> [Grund] – Spieler muss auf diesem Server online sein."] = "Usage: /kick <name> [reason] – player must be online on this server.",
    ["%s wurde vom Server geworfen."] = "%s was kicked from the server.",
    ["Vom Server geworfen"] = "Kicked from the server",
    ["Aufruf: /ban <Name> [30m|2h|7d] [Grund] – Name online, gespeichert oder BeamMP-ID."] =
        "Usage: /ban <name> [30m|2h|7d] [reason] – name online, saved or BeamMP ID.",
    ["Für diesen Spieler ist weder BeamMP-ID noch IP bekannt."] = "Neither BeamMP ID nor IP is known for this player.",
    ["Admins können nicht gesperrt werden."] = "Admins cannot be banned.",
    ["%s wurde für %s gesperrt."] = "%s was banned for %s.",
    ["%s wurde dauerhaft gesperrt."] = "%s was banned permanently.",
    ["Gesperrt auf allen BeamNet-Servern"] = "Banned on all BeamNet servers",
    [" (bis %s)"] = " (until %s)",
    ["Aufruf: /unban <Name oder BeamMP-ID>"] = "Usage: /unban <name or BeamMP ID>",
    ["Kein Bann für \"%s\" gefunden."] = "No ban found for \"%s\".",
    ["Bann für %s aufgehoben."] = "Ban for %s lifted.",
    ["Keine aktiven Banns."] = "No active bans.",
    ["%d aktive Banns:"] = "%d active bans:",
    ["ohne Grund"] = "no reason",
    [" · bis %s"] = " · until %s",
    [" · dauerhaft"] = " · permanent",
    ["Aufruf: /warn <Name> <Text> – Spieler muss auf diesem Server online sein."] = "Usage: /warn <name> <text> – player must be online on this server.",
    ["Verwarnung von %s: %s"] = "Warning from %s: %s",
    ["Verwarnung an %s gesendet."] = "Warning sent to %s.",
    ["Aufruf: /mute <Name> [Minuten]"] = "Usage: /mute <name> [minutes]",
    ["Du wurdest für %d min stummgeschaltet."] = "You have been muted for %d min.",
    ["%s ist %d min stumm."] = "%s is muted for %d min.",
    ["Aufruf: /ansage <Text> – erscheint auf allen BeamNet-Servern."] = "Usage: /announce <text> – shown on all BeamNet servers.",
    ["Interner Fehler – bitte einem Admin melden."] = "Internal error – please tell an admin.",
    ["Bitte etwas langsamer mit den Befehlen."] = "Please slow down with the commands.",
    ["Erfolg für %s: %s (+%d XP)"] = "Achievement for %s: %s (+%d XP)",
    ["Tagesaufgabe geschafft: %s (+%d XP)!"] = "Daily challenge done: %s (+%d XP)!",
    ["Saison %s beendet! %s"] = "Season %s is over! %s",
    ["Saison %s (noch %d Tage):"] = "Season %s (%d days left):",
    ["Noch keine Punkte in dieser Saison – einfach losfahren!"] = "No points in this season yet – just start driving!",
    ["Du: Platz %s mit %d XP in dieser Saison"] = "You: rank %s with %d XP this season",
    ["Letzte Saison (%s): %s"] = "Last season (%s): %s",
    ["Tagesaufgabe geschafft: %s. Die nächste kommt in %s."] = "Daily challenge done: %s. The next one comes in %s.",
    ["Tagesaufgabe: %s – %s/%s · noch %s · Belohnung %d XP"] = "Daily challenge: %s – %s/%s · %s left · reward %d XP",
    ["Heute gibt es keine Tagesaufgabe."] = "No daily challenge today.",
    ["Fahre heute %s km"] = "Drive %s km today",
    ["Erreiche heute %s km/h"] = "Reach %s km/h today",
    ["Sei heute %s Minuten unterwegs"] = "Spend %s minutes on the road today",
    ["Fahre heute auf %s verschiedenen Servern"] = "Drive on %s different servers today",
    ["Beende heute %s Rennen"] = "Finish %s races today",
    ["%s hat %d Erfolge freigeschaltet (+%d XP) – /erfolge"] = "%s unlocked %d achievements (+%d XP) – /achievements",
    ["Erfolge von %s: %d von %d"] = "Achievements of %s: %d of %d",
    ["Geschafft: %s"] = "Done: %s",
    ["Als Nächstes: %s"] = "Next: %s",
    ["Erste 10 km"] = "First 10 km",
    ["1 Stunde unterwegs"] = "1 hour on the road",
    ["10 Stunden unterwegs"] = "10 hours on the road",
    ["Erstes Rennen"] = "First race",
    ["10 Rennen"] = "10 races",
    ["Streckenrekord"] = "Track record",
    ["Weltenbummler (3 Maps)"] = "Globetrotter (3 maps)",
    ["Kenner aller Welten (8 Maps)"] = "World expert (8 maps)",
    ["Bann konnte nicht gespeichert werden (%s) – bitte beamnet doctor prüfen."] = "Could not save the ban (%s) – please check beamnet doctor.",
    ["Willkommen auf %s (%s)! Level %d · Liga %s · %s gefahren. /hilfe für Befehle, /server für alle Server. English: /lang en"] =
        "Welcome to %s (%s)! Level %d · %s league · %s driven. /help for commands, /server for all servers. Deutsch: /lang de",
    ["Heute: %s (/aufgabe)"] = "Today: %s (/daily)",
    ["Sprache: Deutsch. English: /lang en"] = "Language: English. Deutsch: /lang de",
    ["Sprache auf Deutsch gestellt."] = "Language set to English.",
    ["Sprachen: /lang de · /lang en"] = "Languages: /lang de · /lang en",
    -- Ligen (Standardnamen)
    ["Silber"] = "Silver", ["Platin"] = "Platinum", ["Diamant"] = "Diamond", ["Legende"] = "Legend",
}
BN.EN = EN

function BN.langOf(pid)
    local s = BN.players[pid]
    local lang = (s and s.lang) or C.language
    return lang == "en" and "en" or "de"
end

local function tr(lang, text, ...)
    local f = (lang == "en" and EN[text]) or text
    if select("#", ...) > 0 then return string.format(f, ...) end
    return f
end
BN.tr = tr

-- An einen Spieler, in seiner Sprache.
local function say(pid, text, ...)
    chat(pid, tr(BN.langOf(pid), text, ...))
end

-- An alle Spieler dieses Servers, jeweils in ihrer Sprache; build(lang) liefert den Text.
local function sayEach(build)
    local online = (MP and MP.GetPlayers and MP.GetPlayers()) or {}
    for pid in pairs(online) do chat(pid, build(BN.langOf(pid))) end
end

local function sayAll(text, ...)
    local args, n = { ... }, select("#", ...)
    sayEach(function(lang) return tr(lang, text, unpack(args, 1, n)) end)
end

local function identifiers(pid)
    if not (MP and MP.GetPlayerIdentifiers) then return {} end
    local ok, ids = pcall(MP.GetPlayerIdentifiers, pid)
    if ok and type(ids) == "table" then return ids end
    return {}
end

local function emptyRecord(id, name)
    return { id = id, name = name, km = 0, seconds = 0, weekKm = 0, week = weekKey(BN.now()), topSpeedKmh = 0,
             bonusXp = 0, racesFinished = 0, recordsSet = 0, maps = {}, achievements = {},
             firstSeen = BN.now(), lastSeen = BN.now(), lastServer = "" }
end

local function loadRecord(id, name)
    local data = readFile(playersDir() .. "/" .. id .. ".json")
    local rec = data and json.decode(data)
    if type(rec) ~= "table" then return emptyRecord(id, name) end
    rec.id = id
    rec.name = name or rec.name
    rec.km = tonumber(rec.km) or 0
    rec.seconds = tonumber(rec.seconds) or 0
    rec.weekKm = tonumber(rec.weekKm) or 0
    rec.topSpeedKmh = tonumber(rec.topSpeedKmh) or 0
    rec.bonusXp = tonumber(rec.bonusXp) or 0
    rec.racesFinished = tonumber(rec.racesFinished) or 0
    rec.recordsSet = tonumber(rec.recordsSet) or 0
    rec.maps = type(rec.maps) == "table" and rec.maps or {}
    rec.achievements = type(rec.achievements) == "table" and rec.achievements or {}
    rec.day = tonumber(rec.day)
    rec.dayKm = tonumber(rec.dayKm) or 0
    rec.daySeconds = tonumber(rec.daySeconds) or 0
    rec.dayRaces = tonumber(rec.dayRaces) or 0
    rec.dayTop = tonumber(rec.dayTop) or 0
    rec.dayMaps = type(rec.dayMaps) == "table" and rec.dayMaps or {}
    rec.dayDone = rec.dayDone == true
    rec.monthStartXp = tonumber(rec.monthStartXp)
    rec.lastMonthXp = tonumber(rec.lastMonthXp) or 0
    rec.lastWeekKm = tonumber(rec.lastWeekKm) or 0
    rec.week = rec.week or weekKey(BN.now())
    return rec
end

-- Neue Woche: die Kilometer der alten Woche bleiben als lastWeek/lastWeekKm erhalten (fuer die Wochensieger).
-- Tag seit 1970 (UTC) – fuer die Tagesaufgabe.
local function dayNumber(t)
    return math.floor((t or BN.now()) / 86400)
end
BN.dayNumber = dayNumber

-- Neue Saison (Monat): XP-Stand zu Beginn merken; die alte Saison bleibt als lastMonth/lastMonthXp erhalten.
-- Wird vor dem Addieren der neuen Werte aufgerufen, damit Start-XP = Stand vor diesem Speichern ist.
function BN.applyMonth(rec)
    local cur = monthKey()
    if rec.month == cur and rec.monthStartXp then return end
    local before = BN.xpFor(rec.km or 0, rec.seconds or 0) + (rec.bonusXp or 0)
    if rec.month and rec.month ~= cur and rec.monthStartXp then
        rec.lastMonth = rec.month
        rec.lastMonthXp = math.max(0, before - rec.monthStartXp)
    end
    rec.month = cur
    rec.monthStartXp = before
end

-- Neuer Tag: Tageszaehler zuruecksetzen.
local function applyDay(rec)
    local today = dayNumber()
    if rec.day ~= today then
        rec.day = today
        rec.dayKm, rec.daySeconds, rec.dayRaces, rec.dayTop = 0, 0, 0, 0
        rec.dayMaps = {}
        rec.dayDone = false
    end
end
BN.applyDay = applyDay

local function applyWeek(rec)
    local wk = weekKey(BN.now())
    if rec.week ~= wk then
        rec.lastWeek = rec.week
        rec.lastWeekKm = tonumber(rec.weekKm) or 0
        rec.week = wk
        rec.weekKm = 0
    end
end

-- Neue Sitzung (Join oder Plugin-Neustart mit Spielern online).
function BN.addPlayer(pid)
    local name = (MP and MP.GetPlayerName and MP.GetPlayerName(pid)) or ("Spieler " .. tostring(pid))
    local ids = identifiers(pid)
    local id = safeId(ids.beammp)
    local session = { pid = pid, name = name, id = id, ip = ids.ip, guest = id == nil, vehicles = {},
                      pendingKm = 0, pendingSeconds = 0, pendingTop = 0, pendingBonus = 0,
                      pendingRaces = 0, pendingRecords = 0, unlocked = {}, challengeDoneDay = nil }
    session.record = id and loadRecord(id, name) or emptyRecord(nil, name)
    if session.record.lang == "en" or session.record.lang == "de" then session.lang = session.record.lang end
    local mute = BN.findMute(id, ids.ip)
    if mute then session.mutedUntil = mute["until"] end
    applyWeek(session.record)
    local xp = BN.xpFor(session.record.km, session.record.seconds) + session.record.bonusXp
    session.level = BN.levelFor(xp)
    session.league = BN.leagueFor(xp).name
    BN.players[pid] = session
    return session
end

local function session(pid)
    return BN.players[pid] or BN.addPlayer(pid)
end

-- Speichert die Zuwaechse seit dem letzten Speichern. Die Datei wird dabei frisch gelesen und nur ergaenzt,
-- damit ein schneller Serverwechsel (alter Server speichert noch, neuer hat schon geladen) nichts verliert.
function BN.savePlayer(s)
    if not s or s.guest then return true end
    if s.pendingKm == 0 and s.pendingSeconds == 0 and s.pendingTop == 0 and s.pendingBonus == 0 and not s.dirty
        and s.pendingRaces == 0 and s.pendingRecords == 0 and next(s.unlocked) == nil
        and (s.challengeDoneDay == nil or s.challengeDoneDay == s.record.day and s.record.dayDone) then
        return true
    end
    ensureDir(C.sharedDir)
    ensureDir(playersDir())
    local rec = loadRecord(s.id, s.name)
    applyWeek(rec)
    applyDay(rec)
    BN.applyMonth(rec)
    rec.dayKm = rec.dayKm + s.pendingKm
    rec.daySeconds = rec.daySeconds + s.pendingSeconds
    rec.dayRaces = rec.dayRaces + s.pendingRaces
    rec.dayTop = math.max(rec.dayTop, s.pendingTop)
    if BN.server.map and BN.server.map ~= "?" then rec.dayMaps[BN.server.map] = true end
    if s.challengeDoneDay == rec.day then rec.dayDone = true end
    rec.km = rec.km + s.pendingKm
    rec.weekKm = rec.weekKm + s.pendingKm
    rec.seconds = rec.seconds + s.pendingSeconds
    rec.topSpeedKmh = math.max(rec.topSpeedKmh or 0, s.pendingTop)
    rec.bonusXp = rec.bonusXp + s.pendingBonus
    rec.racesFinished = rec.racesFinished + s.pendingRaces
    rec.recordsSet = rec.recordsSet + s.pendingRecords
    if BN.server.map and BN.server.map ~= "?" then rec.maps[BN.server.map] = true end
    for id, at in pairs(s.unlocked) do
        if not rec.achievements[id] then rec.achievements[id] = at end
    end
    if s.lang then rec.lang = s.lang end
    rec.lastSeen = BN.now()
    rec.lastServer = BN.server.name or ""
    rec.xp = BN.xpFor(rec.km, rec.seconds) + rec.bonusXp
    rec.level = BN.levelFor(rec.xp)
    rec.league = BN.leagueFor(rec.xp).name
    local ok, err = writeFileAtomic(playersDir() .. "/" .. s.id .. ".json", json.encode(rec))
    if not ok then
        print("[BeamNetCore] Speichern fehlgeschlagen fuer " .. s.name .. ": " .. tostring(err))
        return false
    end
    s.record = rec
    s.pendingKm, s.pendingSeconds, s.pendingTop, s.pendingBonus, s.dirty = 0, 0, 0, 0, false
    s.pendingRaces, s.pendingRecords, s.unlocked = 0, 0, {}
    return true
end

-- Aktuelle Werte einer Sitzung (gespeichert + noch nicht gespeichert).
function BN.totals(s)
    local rec = s.record
    local km = rec.km + s.pendingKm
    local seconds = rec.seconds + s.pendingSeconds
    local bonus = (rec.bonusXp or 0) + s.pendingBonus
    local xp = BN.xpFor(km, seconds) + bonus
    local weekKm = (rec.week == weekKey(BN.now()) and rec.weekKm or 0) + s.pendingKm
    local maps = 0
    for _ in pairs(rec.maps or {}) do maps = maps + 1 end
    if BN.server.map and BN.server.map ~= "?" and not (rec.maps or {})[BN.server.map] then maps = maps + 1 end
    return { km = km, seconds = seconds, weekKm = weekKm, xp = xp, bonusXp = bonus, level = BN.levelFor(xp),
             league = BN.leagueFor(xp), topSpeedKmh = math.max(rec.topSpeedKmh or 0, s.pendingTop),
             races = (rec.racesFinished or 0) + (s.pendingRaces or 0), records = (rec.recordsSet or 0) + (s.pendingRecords or 0),
             maps = maps, day = BN.dayTotals(s), monthXp = BN.monthXpOf(s, xp) }
end

-- In dieser Saison gesammelte XP einer Sitzung (gespeichert + noch nicht gespeichert).
function BN.monthXpOf(s, xpNow)
    local rec = s.record
    local saved = BN.xpFor(rec.km or 0, rec.seconds or 0) + (rec.bonusXp or 0)
    local start = (rec.month == monthKey() and rec.monthStartXp) or saved
    return math.max(0, (xpNow or saved) - start)
end

-- Heutige Werte (gespeichert + noch nicht gespeichert).
function BN.dayTotals(s)
    local rec, today = s.record, dayNumber()
    local same = rec.day == today
    local dayMaps = 0
    local seen = {}
    if same then for m in pairs(rec.dayMaps or {}) do seen[m] = true end end
    if BN.server.map and BN.server.map ~= "?" then seen[BN.server.map] = true end
    for _ in pairs(seen) do dayMaps = dayMaps + 1 end
    return {
        km = (same and rec.dayKm or 0) + s.pendingKm,
        seconds = (same and rec.daySeconds or 0) + s.pendingSeconds,
        races = (same and rec.dayRaces or 0) + (s.pendingRaces or 0),
        top = math.max(same and rec.dayTop or 0, s.pendingTop),
        servers = dayMaps,
        done = (same and rec.dayDone) or s.challengeDoneDay == today,
    }
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Tagesaufgabe: jeden Tag (UTC) eine neue, auf allen Servern dieselbe.

BN.CHALLENGES = {
    km = { text = "Fahre heute %s km", goals = { 10, 15, 25 }, value = function(d) return d.km end },
    speed = { text = "Erreiche heute %s km/h", goals = { 150, 180, 220 }, value = function(d) return d.top end },
    time = { text = "Sei heute %s Minuten unterwegs", goals = { 30, 45, 60 }, value = function(d) return d.seconds / 60 end },
    servers = { text = "Fahre heute auf %s verschiedenen Servern", goals = { 2, 3, 2 }, value = function(d) return d.servers end },
    races = { text = "Beende heute %s Rennen", goals = { 1, 2, 3 }, value = function(d) return d.races end },
}

function BN.challengeFor(day)
    local types = {}
    for _, name in ipairs(C.challengeTypes or {}) do
        if BN.CHALLENGES[name] then types[#types + 1] = name end
    end
    if #types == 0 then return nil end
    day = day or dayNumber()
    local kind = types[(day % #types) + 1]
    local def = BN.CHALLENGES[kind]
    local goal = def.goals[(math.floor(day / #types) % #def.goals) + 1]
    return { kind = kind, text = def.text, goal = goal, value = def.value }
end

function BN.checkChallenge(s)
    local ch = BN.challengeFor()
    if not ch then return end
    local d = BN.dayTotals(s)
    if d.done or ch.value(d) < ch.goal then return end
    s.challengeDoneDay = dayNumber()
    s.pendingBonus = s.pendingBonus + C.challengeXp
    local lang = BN.langOf(s.pid)
    chat(s.pid, tr(lang, "Tagesaufgabe geschafft: %s (+%d XP)!", tr(lang, ch.text, ch.goal), C.challengeXp))
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Erfolge: einmalig je Spieler, mit Bonus-XP. Wert und Ziel fuer die Fortschrittsanzeige in /erfolge.

BN.ACHIEVEMENTS = {
    { id = "km10", name = "Erste 10 km", xp = 20, value = function(t) return t.km end, goal = 10 },
    { id = "km100", name = "100 km", xp = 50, value = function(t) return t.km end, goal = 100 },
    { id = "km1000", name = "1000 km", xp = 200, value = function(t) return t.km end, goal = 1000 },
    { id = "hour1", name = "1 Stunde unterwegs", xp = 20, value = function(t) return t.seconds / 3600 end, goal = 1 },
    { id = "hours10", name = "10 Stunden unterwegs", xp = 100, value = function(t) return t.seconds / 3600 end, goal = 10 },
    { id = "speed200", name = "200 km/h", xp = 30, value = function(t) return t.topSpeedKmh end, goal = 200 },
    { id = "speed300", name = "300 km/h", xp = 60, value = function(t) return t.topSpeedKmh end, goal = 300 },
    { id = "race1", name = "Erstes Rennen", xp = 10, value = function(t) return t.races end, goal = 1 },
    { id = "race10", name = "10 Rennen", xp = 50, value = function(t) return t.races end, goal = 10 },
    { id = "record1", name = "Streckenrekord", xp = 50, value = function(t) return t.records end, goal = 1 },
    { id = "maps3", name = "Weltenbummler (3 Maps)", xp = 30, value = function(t) return t.maps end, goal = 3 },
    { id = "maps8", name = "Kenner aller Welten (8 Maps)", xp = 80, value = function(t) return t.maps end, goal = 8 },
    { id = "level10", name = "Level 10", xp = 0, value = function(t) return t.level end, goal = 10 },
}

function BN.hasAchievement(s, id)
    return (s.record.achievements or {})[id] ~= nil or s.unlocked[id] ~= nil
end

-- Prueft alle Erfolge; neue werden verkuendet (mehrere auf einmal zusammengefasst) und geben Bonus-XP.
function BN.checkAchievements(s)
    if C.achievements == false then return end
    local t = BN.totals(s)
    local new, xp = {}, 0
    for _, a in ipairs(BN.ACHIEVEMENTS) do
        if not BN.hasAchievement(s, a.id) and a.value(t) >= a.goal then
            s.unlocked[a.id] = BN.now()
            new[#new + 1] = a
            xp = xp + a.xp
        end
    end
    if #new == 0 then return end
    s.pendingBonus = s.pendingBonus + xp
    if #new <= 2 then
        for _, a in ipairs(new) do
            sayEach(function(lang) return tr(lang, "Erfolg für %s: %s (+%d XP)", s.name, tr(lang, a.name), a.xp) end)
        end
    else
        sayEach(function(lang) return tr(lang, "%s hat %d Erfolge freigeschaltet (+%d XP) – /erfolge", s.name, #new, xp) end)
    end
end

local function checkProgress(s)
    local t = BN.totals(s)
    if t.level > (s.level or 1) then
        if C.announceLevelUps then sayAll("%s ist jetzt Level %d!", s.name, t.level) end
        s.level = t.level
    end
    if t.league.name ~= s.league then
        local league = t.league.name
        sayEach(function(lang) return tr(lang, "%s steigt in die Liga %s auf!", s.name, tr(lang, league)) end)
        s.league = t.league.name
    end
    BN.checkAchievements(s)
    BN.checkChallenge(s)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Kilometer

-- Neue Position eines Fahrzeugs. Zaehlt nur plausible Bewegung (kein Teleport, kein Rauschen im Stand).
function BN.track(pid, vid, pos, tim, vel)
    local s = session(pid)
    if type(pos) ~= "table" then return 0 end
    local x, y, z = tonumber(pos[1] or pos.x), tonumber(pos[2] or pos.y), tonumber(pos[3] or pos.z)
    if not (x and y and z) then return 0 end
    local now = BN.now()
    local v = s.vehicles[vid]
    local counted = 0
    local jump = false
    if v then
        local dt
        if tim and v.tim and tim > v.tim then dt = tim - v.tim else dt = math.max(1, now - v.at) end
        local dx, dy, dz = x - v.x, y - v.y, z - v.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d >= C.minStepM and dt > 0 and d / dt <= C.maxSpeedMps then
            counted = d
            s.pendingKm = s.pendingKm + d / 1000
        elseif dt > 0 and d / dt > C.maxSpeedMps then
            jump = true
        end
    end
    if s.race then BN.raceUpdate(s, vid, v, { x = x, y = y, z = z, tim = tim, at = now }, jump) end
    local speed
    if type(vel) == "table" then
        local vx, vy, vz = tonumber(vel[1] or vel.x) or 0, tonumber(vel[2] or vel.y) or 0, tonumber(vel[3] or vel.z) or 0
        speed = math.sqrt(vx * vx + vy * vy + vz * vz)
    end
    if speed and speed <= C.maxSpeedMps then s.pendingTop = math.max(s.pendingTop, speed * 3.6) end
    s.vehicles[vid] = { x = x, y = y, z = z, tim = tim, at = now }
    return counted
end

function BN.forgetVehicle(pid, vid)
    local s = BN.players[pid]
    if not s then return end
    s.vehicles[vid] = nil
    local r = s.race
    if r and r.vid == vid and r.state ~= "armed" then
        BN.raceInvalid(s, "Fahrzeug zurückgesetzt")
    end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Bestenliste und Serverliste

function BN.refreshBoard(force)
    local now = BN.now()
    if not force and now - BN.board.at < C.leaderboardEverySec then return BN.board.list end
    local byId = {}
    for _, file in ipairs(listJsonFiles(playersDir())) do
        local rec = json.decode(readFile(file) or "")
        if type(rec) == "table" and rec.id then
            rec.km = tonumber(rec.km) or 0
            rec.seconds = tonumber(rec.seconds) or 0
            rec.bonusXp = tonumber(rec.bonusXp) or 0
            if rec.week ~= weekKey(now) then rec.weekKm = 0 end
            rec.weekKm = tonumber(rec.weekKm) or 0
            byId[rec.id] = rec
        end
    end
    -- Spieler online mit ihren noch nicht gespeicherten Werten.
    for _, s in pairs(BN.players) do
        if not s.guest then
            local t = BN.totals(s)
            byId[s.id] = { id = s.id, name = s.name, km = t.km, seconds = t.seconds, weekKm = t.weekKm, bonusXp = t.bonusXp }
        end
    end
    local list = {}
    for _, rec in pairs(byId) do
        rec.xp = BN.xpFor(rec.km, rec.seconds) + (rec.bonusXp or 0)
        list[#list + 1] = rec
    end
    table.sort(list, function(a, b)
        if a.xp ~= b.xp then return a.xp > b.xp end
        return tostring(a.name) < tostring(b.name)
    end)
    BN.board = { at = now, list = list }
    return list
end

-- Kilometer einer bestimmten Woche (aktuelle oder vergangene), absteigend.
BN.weekCache = BN.weekCache or {}

function BN.weekRanking(week)
    local cached = BN.weekCache[week]
    if cached and BN.now() - cached.at < C.leaderboardEverySec then return cached.list end
    local byId = {}
    for _, file in ipairs(listJsonFiles(playersDir())) do
        local rec = json.decode(readFile(file) or "")
        if type(rec) == "table" and rec.id then
            local km
            if rec.week == week then km = tonumber(rec.weekKm) elseif rec.lastWeek == week then km = tonumber(rec.lastWeekKm) end
            if km and km > 0 then byId[rec.id] = { name = rec.name, km = km } end
        end
    end
    for _, s in pairs(BN.players) do
        if not s.guest then
            local rec, km = s.record, nil
            if rec.week == week then km = (tonumber(rec.weekKm) or 0) + s.pendingKm
            elseif rec.lastWeek == week then km = tonumber(rec.lastWeekKm) end
            if km and km > 0 then byId[s.id] = { name = s.name, km = km } end
        end
    end
    local list = {}
    for _, e in pairs(byId) do list[#list + 1] = e end
    table.sort(list, function(a, b)
        if a.km ~= b.km then return a.km > b.km end
        return tostring(a.name) < tostring(b.name)
    end)
    BN.weekCache[week] = { at = BN.now(), list = list }
    return list
end

-- Saison-Rangliste (gesammelte XP im Monat), absteigend; zwischengespeichert wie die Bestenliste.
BN.seasonCache = BN.seasonCache or {}

function BN.seasonRanking(month)
    local cached = BN.seasonCache[month]
    if cached and BN.now() - cached.at < C.leaderboardEverySec then return cached.list end
    local byId = {}
    for _, file in ipairs(listJsonFiles(playersDir())) do
        local rec = json.decode(readFile(file) or "")
        if type(rec) == "table" and rec.id then
            local xp
            if rec.month == month and tonumber(rec.monthStartXp) then
                local total = tonumber(rec.xp) or (BN.xpFor(tonumber(rec.km) or 0, tonumber(rec.seconds) or 0) + (tonumber(rec.bonusXp) or 0))
                xp = total - rec.monthStartXp
            elseif rec.lastMonth == month then
                xp = tonumber(rec.lastMonthXp)
            end
            if xp and xp > 0 then byId[rec.id] = { name = rec.name, xp = math.floor(xp) } end
        end
    end
    if month == monthKey() then
        for _, s in pairs(BN.players) do
            if not s.guest then
                local xp = BN.totals(s).monthXp
                if xp > 0 then byId[s.id] = { name = s.name, xp = math.floor(xp) } end
            end
        end
    end
    local list = {}
    for id, e in pairs(byId) do e.id = id; list[#list + 1] = e end
    table.sort(list, function(a, b)
        if a.xp ~= b.xp then return a.xp > b.xp end
        return tostring(a.name) < tostring(b.name)
    end)
    BN.seasonCache[month] = { at = BN.now(), list = list }
    return list
end

local MONTHS_DE = { "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember" }
local MONTHS_EN = { "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }

function BN.seasonName(month, lang)
    local y, m = tostring(month):match("^(%d+)%-(%d+)$")
    m = tonumber(m)
    if not (y and m and m >= 1 and m <= 12) then return tostring(month) end
    return ((lang == "en") and MONTHS_EN or MONTHS_DE)[m] .. " " .. y
end

-- Saisonende: Sieger verkuenden und (einmal) archivieren.
function BN.endSeason(month)
    BN.seasonCache[month] = nil
    local list = BN.seasonRanking(month)
    if #list == 0 then return end
    local path = C.sharedDir .. "/seasons/" .. month .. ".json"
    if not readFile(path) then
        ensureDir(C.sharedDir)
        ensureDir(C.sharedDir .. "/seasons")
        local top = {}
        for i = 1, math.min(10, #list) do top[i] = list[i] end
        writeFileAtomic(path, json.encode({ month = month, top = top, at = BN.now() }))
    end
    local parts = {}
    for i = 1, math.min(3, #list) do parts[#parts + 1] = string.format("%d. %s (%d XP)", i, list[i].name, list[i].xp) end
    sayEach(function(lang) return tr(lang, "Saison %s beendet! %s", BN.seasonName(month, lang), table.concat(parts, " · ")) end)
end

function BN.announceWeek(week)
    local list = BN.weekRanking(week)
    if #list == 0 then return end
    local parts = {}
    for i = 1, math.min(3, #list) do parts[#parts + 1] = string.format("%d. %s (%s)", i, list[i].name, fmtKm(list[i].km)) end
    local number = tostring(week):match("W(%d+)$") or tostring(week)
    sayEach(function(lang) return tr(lang, "Wochensieger %s: %s", tr(lang, "KW %s", number), table.concat(parts, " · ")) end)
end

function BN.rankOf(id)
    for i, rec in ipairs(BN.refreshBoard(false)) do
        if rec.id == id then return i, #BN.board.list end
    end
    return nil, #BN.board.list
end

-- Welche BeamMP-Funktionen gibt es auf diesem Server? (Aeltere Server-Versionen haben nicht alles.)
function BN.capabilities()
    local function has(t, name) return type(t) == "table" and type(t[name]) == "function" end
    return {
        positions = has(MP, "GetPositionRaw"),
        vehicles = has(MP, "GetPlayerVehicles"),
        identifiers = has(MP, "GetPlayerIdentifiers"),
        timers = has(MP, "CreateEventTimer"),
        files = has(FS, "ListFiles"),
    }
end

local capabilityEffects = {
    positions = "keine Kilometer, keine Rennen (BeamMP-Server zu alt: MP.GetPositionRaw fehlt)",
    vehicles = "keine Kilometer, keine Rennen (MP.GetPlayerVehicles fehlt)",
    identifiers = "alle Spieler werden wie Gaeste behandelt, nichts wird gespeichert (MP.GetPlayerIdentifiers fehlt)",
    timers = "kein Takt: nichts wird gezaehlt (MP.CreateEventTimer fehlt)",
    files = "keine Bestenliste und keine Serverliste (FS.ListFiles fehlt)",
}

function BN.writeStatus()
    if not BN.server.port or BN.server.port == 0 then return end
    ensureDir(C.sharedDir)
    ensureDir(serversDir())
    local names = {}
    for _, s in pairs(BN.players) do names[#names + 1] = s.name end
    table.sort(names)
    local status = { name = BN.server.name, port = BN.server.port, map = BN.server.map, players = #names,
                     max = BN.server.maxPlayers, names = names, updated = BN.now(), version = BN.VERSION,
                     api = BN.capabilities(), lua = _VERSION }
    writeFileAtomic(serversDir() .. "/" .. tostring(BN.server.port) .. ".json", json.encode(status))
    BN.lastStatus = BN.now()
end

function BN.serverList()
    local now = BN.now()
    local list = {}
    for _, file in ipairs(listJsonFiles(serversDir())) do
        local st = json.decode(readFile(file) or "")
        if type(st) == "table" and tonumber(st.updated) and now - st.updated <= 90 then list[#list + 1] = st end
    end
    table.sort(list, function(a, b) return (tonumber(a.port) or 0) < (tonumber(b.port) or 0) end)
    return list
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Zeitrennen
--
-- Ein Admin legt eine Strecke an, indem er am Start "/rennen neu <Name>" und am Ziel "/rennen ziel <Name>" schreibt.
-- Spieler starten mit "/rennen <Name>": Die Zeit laeuft ab dem Verlassen des Startbereichs und endet beim Erreichen
-- des Zielbereichs. Gemessen wird mit der Spieluhr des Fahrzeugs; der Zeitpunkt des Ueberfahrens wird zwischen zwei
-- Messpunkten eingerechnet (Genauigkeit etwa eine Zehntelsekunde). Start = Ziel ergibt einen Rundkurs.
-- Strecken und Rekorde: <gemeinsamer Ordner>/races/<Map>.json

local function point(t)
    return { x = tonumber(t.x) or 0, y = tonumber(t.y) or 0, z = tonumber(t.z) or 0 }
end

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Zeitpunkt, an dem die Strecke p0 -> p1 die Grenze (Radius r um c) ueberquert (lineare Naeherung ueber den Abstand).
local function crossTime(p0, p1, t0, t1, c, r)
    local d0, d1 = dist(p0, c), dist(p1, c)
    if d1 == d0 then return t1 end
    local f = (r - d0) / (d1 - d0)
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    return t0 + (t1 - t0) * f
end

-- So weit muss man sich nach dem Start vom Ziel entfernt haben, bevor das Ziel zaehlt (verhindert, dass Hin-und-her-
-- Wackeln an der Linie eines Rundkurses als Runde gilt).
function BN.leaveDistance()
    return math.max(3 * C.raceRadiusM, 30)
end

function BN.fmtRaceTime(seconds)
    seconds = math.max(0, seconds or 0)
    local m = math.floor(seconds / 60)
    return string.format("%d:%04.1f", m, seconds - m * 60)
end

local function racesFile()
    local map = tostring(BN.server.map or "unbekannt"):gsub("[^%w_-]", "_")
    return racesDir() .. "/" .. map .. ".json"
end

function BN.loadTracks()
    local data = json.decode(readFile(racesFile()) or "")
    if type(data) ~= "table" or type(data.tracks) ~= "table" then return { tracks = {} } end
    return data
end

local function saveTracks(data)
    ensureDir(C.sharedDir)
    ensureDir(racesDir())
    return writeFileAtomic(racesFile(), json.encode(data))
end

local function trackName(name)
    name = tostring(name or ""):lower()
    if name == "" or #name > 24 or not name:match("^[%w_-]+$") then return nil end
    return name
end

function BN.isAdmin(s)
    if not s or s.guest then return false end
    for _, a in ipairs(C.admins or {}) do
        a = tostring(a)
        if a == s.id or a:lower() == s.name:lower() then return true end
    end
    return false
end

-- Letzte bekannte Position des Spielers (Fahrzeug mit der juengsten Messung).
local function currentPosition(s)
    local best
    for vid, v in pairs(s.vehicles) do
        if not best or v.at > best.at then best = { x = v.x, y = v.y, z = v.z, at = v.at, vid = vid } end
    end
    return best
end

function BN.raceInvalid(s, why)
    local r = s.race
    if not r then return end
    local lang = BN.langOf(s.pid)
    chat(s.pid, tr(lang, "%s – Lauf ungültig. Neuer Versuch: zurück zum Start von %s.", tr(lang, why), r.name))
    r.state, r.vid, r.startT, r.leftFinish = "armed", nil, nil, false
end

local function finishRace(s, time)
    local r = s.race
    say(s.pid, "Ziel! %s: %s", r.name, BN.fmtRaceTime(time))
    if not s.guest then
        local data = BN.loadTracks()
        local track = data.tracks[r.name]
        if track then
            track.records = type(track.records) == "table" and track.records or {}
            local previousBest = track.records[1] and tonumber(track.records[1].time)
            local mine
            for _, rec in ipairs(track.records) do
                if rec.id == s.id then mine = rec end
            end
            local improved, bonus = false, C.raceFinishXp
            if not mine then
                mine = { id = s.id, name = s.name, time = time, at = BN.now() }
                track.records[#track.records + 1] = mine
                improved = true
            elseif time < (tonumber(mine.time) or math.huge) then
                mine.time, mine.at, mine.name = time, BN.now(), s.name
                improved = true
            end
            table.sort(track.records, function(a, b) return (tonumber(a.time) or math.huge) < (tonumber(b.time) or math.huge) end)
            while #track.records > 50 do table.remove(track.records) end
            if improved then
                saveTracks(data)
                local rank
                for i, rec in ipairs(track.records) do if rec.id == s.id then rank = i end end
                bonus = bonus + C.racePersonalBestXp
                if rank == 1 and (not previousBest or time < previousBest) then
                    bonus = bonus + C.raceRecordXp
                    s.pendingRecords = s.pendingRecords + 1
                    sayAll("Neuer Streckenrekord auf %s: %s mit %s!", r.name, s.name, BN.fmtRaceTime(time))
                else
                    say(s.pid, "Persönliche Bestzeit! Platz %d von %d.", rank or 0, #track.records)
                end
            end
            s.pendingBonus = s.pendingBonus + bonus
            s.pendingRaces = s.pendingRaces + 1
            chat(s.pid, string.format("+%d XP", bonus))
            checkProgress(s)
        end
    else
        s.pendingBonus = s.pendingBonus + C.raceFinishXp
        say(s.pid, "+%d XP (nur für diese Sitzung)", C.raceFinishXp)
    end
    r.state, r.vid, r.startT, r.leftFinish = "armed", nil, nil, false
    say(s.pid, "Für einen neuen Versuch zurück zum Start – beenden mit /rennen stop.")
end

-- Wird bei jeder neuen Position eines Spielers mit laufendem Rennen aufgerufen.
function BN.raceUpdate(s, vid, prev, cur, jump)
    local r = s.race
    if r.vid and r.vid ~= vid then return end
    local radius = C.raceRadiusM
    if r.state == "armed" then
        if dist(cur, r.start) <= radius then
            r.state, r.vid = "ready", vid
            r.useTim = cur.tim ~= nil
            say(s.pid, "Am Start von %s. Los geht's, sobald du den Startbereich verlässt!", r.name)
        end
        return
    end
    if not prev then return end
    if jump then
        BN.raceInvalid(s, "Sprung (Teleport)")
        return
    end
    local t0, t1
    if r.useTim then t0, t1 = prev.tim, cur.tim else t0, t1 = prev.at, cur.at end
    if not (t0 and t1) or t1 < t0 then return end
    if r.state == "ready" then
        if dist(cur, r.start) > radius then
            r.startT = crossTime(prev, cur, t0, t1, r.start, radius)
            r.state = "running"
            r.leftFinish = dist(cur, r.finish) > BN.leaveDistance()
            say(s.pid, "Zeit läuft! Ziel ist %.0f m entfernt.", dist(cur, r.finish))
        end
        return
    end
    -- running
    if t1 - r.startT > C.raceMaxMinutes * 60 then
        BN.raceInvalid(s, "Zeitlimit überschritten")
        return
    end
    local d = dist(cur, r.finish)
    if not r.leftFinish then
        if d > BN.leaveDistance() then r.leftFinish = true end
        return
    end
    if d <= radius then
        finishRace(s, crossTime(prev, cur, t0, t1, r.finish, radius) - r.startT)
    end
end

-- Schnelle Abtastung nur fuer Spieler mit laufendem Rennen.
function BN.raceTick()
    if not (MP and MP.GetPositionRaw) then return end
    for pid, s in pairs(BN.players) do
        local vehicles = s.race and MP.GetPlayerVehicles and MP.GetPlayerVehicles(pid) or nil
        if type(vehicles) == "table" then
            for vid in pairs(vehicles) do
                if not s.race then break end
                if not s.race.vid or s.race.vid == vid then
                    local ok, raw = pcall(MP.GetPositionRaw, pid, vid)
                    if ok and type(raw) == "table" and raw.pos then BN.track(pid, vid, raw.pos, tonumber(raw.tim), raw.vel) end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Moderation: Banns (auf allen Servern), Ansagen an alle Server, Spamschutz, Protokoll

BN.seenAnnouncements = BN.seenAnnouncements or {}
BN.lastSync = BN.lastSync or -math.huge

local function modlog(entry)
    entry.at = BN.now()
    entry.server = BN.server.port
    ensureDir(C.sharedDir)
    local f = io.open(modlogFile(), "a")
    if f then
        f:write(json.encode(entry), "\n")
        f:close()
    end
end

function BN.loadBans()
    local data = json.decode(readFile(bansFile()) or "")
    if type(data) ~= "table" or type(data.bans) ~= "table" then return { bans = {} } end
    return data
end

local function saveBans(data)
    ensureDir(C.sharedDir)
    return writeFileAtomic(bansFile(), json.encode(data))
end

-- Stummschaltungen gelten auf allen Servern und ueberstehen Neu-Verbinden (mutes.json).
function BN.loadMutes()
    local data = json.decode(readFile(mutesFile()) or "")
    if type(data) ~= "table" or type(data.mutes) ~= "table" then return { mutes = {} } end
    return data
end

function BN.saveMute(s, untilTs)
    local data = BN.loadMutes()
    local now, kept = BN.now(), {}
    for _, m in ipairs(data.mutes) do
        local same = (s.id and m.id == s.id) or (not s.id and s.ip and m.ip == s.ip)
        if type(m) == "table" and not same and tonumber(m["until"]) and m["until"] > now then kept[#kept + 1] = m end
    end
    kept[#kept + 1] = { id = s.id, ip = (not s.id) and s.ip or nil, name = s.name, ["until"] = untilTs }
    data.mutes = kept
    ensureDir(C.sharedDir)
    return writeFileAtomic(mutesFile(), json.encode(data))
end

function BN.findMute(id, ip, mutes)
    local now = BN.now()
    for _, m in ipairs((mutes or BN.loadMutes()).mutes) do
        if type(m) == "table" and tonumber(m["until"]) and m["until"] > now
            and ((id and m.id == id) or (not id and ip and m.ip == ip)) then
            return m
        end
    end
    return nil
end

-- Aktiver Bann fuer BeamMP-ID oder IP-Adresse.
function BN.findBan(id, ip, data)
    local now = BN.now()
    for _, ban in ipairs((data or BN.loadBans()).bans) do
        local active = not ban["until"] or tonumber(ban["until"]) > now
        if active and ((id and ban.id == id) or (ip and ban.ip and ban.ip == ip)) then return ban end
    end
    return nil
end

local function banText(ban, lang)
    local text = tr(lang, "Gesperrt auf allen BeamNet-Servern")
    if ban.reason and ban.reason ~= "" then text = text .. ": " .. ban.reason end
    if ban["until"] then text = text .. tr(lang, " (bis %s)", os.date("%d.%m. %H:%M", ban["until"])) end
    return text
end
BN.banText = banText

-- "30m", "2h", "7d" -> Sekunden
function BN.parseDuration(text)
    local n, unit = tostring(text or ""):match("^(%d+)([mhd])$")
    if not n then return nil end
    local factor = ({ m = 60, h = 3600, d = 86400 })[unit]
    return tonumber(n) * factor
end

local function drop(pid, reason)
    if MP and MP.DropPlayer then pcall(MP.DropPlayer, pid, reason) end
end

-- Liest Banns und Ansagen der anderen Server (alle syncEverySec Sekunden).
function BN.sync(force)
    local now = BN.now()
    if not force and now - BN.lastSync < C.syncEverySec then return end
    BN.lastSync = now
    -- Einstellungen (z. B. neue Admins) ohne Neustart uebernehmen.
    if now - (BN.lastConfigLoad or -math.huge) >= 60 then
        BN.lastConfigLoad = now
        BN.loadOverrides()
    end
    local bans, mutes = BN.loadBans(), BN.loadMutes()
    for pid, s in pairs(BN.players) do
        local ban = BN.findBan(s.id, s.ip, bans)
        if ban then
            BN.savePlayer(s)
            drop(pid, banText(ban, BN.langOf(pid)))
            BN.players[pid] = nil
        else
            local mute = BN.findMute(s.id, s.ip, mutes)
            if mute and (not s.mutedUntil or s.mutedUntil < mute["until"]) then s.mutedUntil = mute["until"] end
        end
    end
    local data = json.decode(readFile(announcementsFile()) or "")
    if type(data) == "table" and type(data.list) == "table" then
        for _, a in ipairs(data.list) do
            if type(a) == "table" and a.id and not BN.seenAnnouncements[a.id] then
                BN.seenAnnouncements[a.id] = true
                if now - (tonumber(a.at) or 0) <= 120 then sayAll("[Ansage] %s", tostring(a.text)) end
            end
        end
    end
end

-- Beim Start: alte Ansagen nicht wiederholen.
function BN.markAnnouncementsSeen()
    local data = json.decode(readFile(announcementsFile()) or "")
    if type(data) == "table" and type(data.list) == "table" then
        for _, a in ipairs(data.list) do
            if type(a) == "table" and a.id then BN.seenAnnouncements[a.id] = true end
        end
    end
end

function BN.announce(text, by)
    local data = json.decode(readFile(announcementsFile()) or "")
    if type(data) ~= "table" or type(data.list) ~= "table" then data = { list = {} } end
    local id = string.format("%d-%s-%d", BN.now(), tostring(BN.server.port), math.random(100000, 999999))
    data.list[#data.list + 1] = { id = id, text = text, by = by, at = BN.now() }
    while #data.list > 20 do table.remove(data.list, 1) end
    ensureDir(C.sharedDir)
    writeFileAtomic(announcementsFile(), json.encode(data))
    BN.seenAnnouncements[id] = true
    sayAll("[Ansage] %s", text)
end

-- Spamschutz. Gibt true zurueck, wenn die Nachricht unterdrueckt werden soll.
function BN.spamCheck(s)
    if BN.isAdmin(s) then return false end
    local now = BN.now()
    if s.mutedUntil and now < s.mutedUntil then
        if not s.muteNoticeAt or now - s.muteNoticeAt >= 10 then
            s.muteNoticeAt = now
            say(s.pid, "Du bist noch %d s stummgeschaltet.", s.mutedUntil - now)
        end
        return true
    end
    s.chatTimes = s.chatTimes or {}
    local kept = {}
    for _, t in ipairs(s.chatTimes) do
        if now - t < C.spamWindowSec then kept[#kept + 1] = t end
    end
    kept[#kept + 1] = now
    s.chatTimes = kept
    if #kept > C.spamMessages then
        s.mutedUntil = now + C.spamMuteSec
        s.muteNoticeAt = now
        s.chatTimes = {}
        say(s.pid, "Bitte nicht spammen – du bist %d s stummgeschaltet.", C.spamMuteSec)
        modlog({ action = "spam-mute", target = s.name, targetId = s.id, seconds = C.spamMuteSec })
        return true
    end
    return false
end

-- Spieler zu einem Namen: online (genau, sonst eindeutiger Teilname), dann gespeicherte Spieler (ebenso),
-- zuletzt eine BeamMP-ID. Zweiter Rueckgabewert "mehrdeutig", wenn mehrere passen – dann wird nichts getan.
local function findTarget(query)
    query = tostring(query or "")
    if query == "" then return nil end
    local lower = query:lower()
    local function pick(candidates, nameOf, make)
        for _, c in ipairs(candidates) do
            if nameOf(c):lower() == lower then return make(c) end
        end
        local hit, count = nil, 0
        for _, c in ipairs(candidates) do
            if nameOf(c):lower():find(lower, 1, true) then hit, count = c, count + 1 end
        end
        if count == 1 then return make(hit) end
        if count > 1 then return nil, "mehrdeutig" end
        return nil
    end
    local online = {}
    for _, s in pairs(BN.players) do online[#online + 1] = s end
    local function onlineTarget(s)
        return { online = s, id = s.id, ip = s.ip, name = s.name }
    end
    local records = {}
    for _, file in ipairs(listJsonFiles(playersDir())) do
        local rec = json.decode(readFile(file) or "")
        if type(rec) == "table" and rec.id then records[#records + 1] = rec end
    end
    local function savedTarget(r)
        -- Ist der gespeicherte Spieler gerade online, die Sitzung verwenden (fuer Kick und IP).
        for _, s in ipairs(online) do if s.id and s.id == r.id then return onlineTarget(s) end end
        return { id = r.id, name = r.name }
    end
    -- 1. genauer Name, online oder gespeichert (vor jedem Teilnamen)
    for _, s in ipairs(online) do if s.name:lower() == lower then return onlineTarget(s) end end
    for _, r in ipairs(records) do if tostring(r.name):lower() == lower then return savedTarget(r) end end
    -- 2. eindeutiger Teilname, erst online, dann gespeichert
    local target, why = pick(online, function(s) return s.name end, onlineTarget)
    if target or why then return target, why end
    target, why = pick(records, function(r) return tostring(r.name) end, savedTarget)
    if target or why then return target, why end
    if safeId(query) and query:match("^%d+$") then return { id = query, name = query } end
    return nil
end
BN.findTarget = findTarget

-- ---------------------------------------------------------------------------------------------------------------------
-- Chat-Befehle

local commands = {}

local function findPlayerByName(query)
    query = query:lower()
    for _, s in pairs(BN.players) do
        if s.name:lower() == query then return s end
    end
    for _, s in pairs(BN.players) do
        if s.name:lower():find(query, 1, true) then return s end
    end
    return nil
end

function commands.hilfe(pid)
    say(pid, "BeamNet-Befehle: /stats [Name] · /top [km|xp|woche|vorwoche] · /liga · /saison · /server · /km · /rennen · /rekorde · /erfolge · /aufgabe · /lang")
    if BN.isAdmin(BN.players[pid]) then
        say(pid, "Admin: /kick · /ban <Name> [30m|2h|7d] [Grund] · /unban · /bans · /warn · /mute · /ansage")
    end
end
commands.help = commands.hilfe

function commands.km(pid)
    local s = session(pid)
    local t = BN.totals(s)
    say(pid, "Du bist %s gefahren (diese Woche %s).", fmtKm(t.km), fmtKm(t.weekKm))
end

function commands.stats(pid, arg)
    local s = session(pid)
    if arg and arg ~= "" then
        s = findPlayerByName(arg)
        if not s then
            say(pid, "Kein Spieler online mit dem Namen \"%s\".", arg)
            return
        end
    end
    local t = BN.totals(s)
    local lang = BN.langOf(pid)
    say(pid, "%s: Level %d · Liga %s · %d XP · %s · %s Fahrzeit · Spitze %.0f km/h",
        s.name, t.level, tr(lang, t.league.name), t.xp, fmtKm(t.km), fmtDuration(t.seconds), t.topSpeedKmh)
    if s.guest then
        say(pid, "Gast-Konto: Werte gelten nur für diese Sitzung (mit BeamMP-Konto werden sie gespeichert).")
    else
        local rank, total = BN.rankOf(s.id)
        local nextLevel = BN.xpForLevel(t.level + 1)
        say(pid, "Rang %s von %d · noch %d XP bis Level %d", rank and tostring(rank) or "–", total,
            math.max(0, nextLevel - t.xp), t.level + 1)
    end
end

function commands.top(pid, arg)
    local mode = (arg or ""):lower()
    local lang = BN.langOf(pid)
    local list = {}
    for _, rec in ipairs(BN.refreshBoard(false)) do list[#list + 1] = rec end
    local label, value
    if mode == "km" then
        table.sort(list, function(a, b) return a.km > b.km end)
        label, value = "Kilometer", function(r) return fmtKm(r.km) end
    elseif mode == "woche" or mode == "week" then
        table.sort(list, function(a, b) return a.weekKm > b.weekKm end)
        label, value = "Kilometer diese Woche", function(r) return fmtKm(r.weekKm) end
    elseif mode == "vorwoche" or mode == "lastweek" then
        list = BN.weekRanking(weekKey(BN.now() - 7 * 86400))
        label, value = "Kilometer letzte Woche", function(r) return fmtKm(r.km) end
    else
        label, value = "XP", function(r) return tr(lang, "%d XP (Level %d)", r.xp, BN.levelFor(r.xp)) end
    end
    if #list == 0 then
        say(pid, "Noch keine Bestenliste – einfach losfahren!")
        return
    end
    say(pid, "Bestenliste %s:", tr(lang, label))
    for i = 1, math.min(5, #list) do
        chat(pid, string.format("%d. %s – %s", i, list[i].name or "?", value(list[i])))
    end
end

function commands.liga(pid)
    local s = session(pid)
    local t = BN.totals(s)
    local parts = {}
    local lang = BN.langOf(pid)
    for _, league in ipairs(C.leagues) do parts[#parts + 1] = tr(lang, "%s ab %d", tr(lang, league.name), league.xp) end
    say(pid, "Ligen (XP): %s", table.concat(parts, " · "))
    local nextL = BN.nextLeague(t.xp)
    if nextL then
        say(pid, "Du: %s mit %d XP – noch %d XP bis %s.", tr(lang, t.league.name), t.xp, nextL.xp - t.xp, tr(lang, nextL.name))
    else
        say(pid, "Du: %s mit %d XP – höchste Liga erreicht!", tr(lang, t.league.name), t.xp)
    end
end

function commands.server(pid)
    local list = BN.serverList()
    local lang = BN.langOf(pid)
    if #list == 0 then
        say(pid, "Keine Serverliste verfügbar.")
        return
    end
    say(pid, "BeamNet-Server (wechseln im BeamMP-Launcher):")
    for _, st in ipairs(list) do
        local addr = C.publicHost ~= "" and (C.publicHost .. ":" .. tostring(st.port)) or tr(lang, "Port %s", tostring(st.port))
        local here = tonumber(st.port) == tonumber(BN.server.port) and tr(lang, "  ← hier") or ""
        chat(pid, string.format("%s · %s · %d/%d · %s%s", st.name or "?", st.map or "?", tonumber(st.players) or 0,
            tonumber(st.max) or 0, addr, here))
    end
end
commands.servers = commands.server

local function listTracks(pid, s)
    local data = BN.loadTracks()
    local names = {}
    for name in pairs(data.tracks) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then
        say(pid, "Auf %s gibt es noch keine Strecken.", tostring(BN.server.map))
    else
        local parts = {}
        for _, name in ipairs(names) do
            local t = data.tracks[name]
            local best = type(t.records) == "table" and t.records[1]
            local lang = BN.langOf(pid)
            if not t.finish then
                parts[#parts + 1] = tr(lang, "%s (ohne Ziel)", name)
            elseif best then
                parts[#parts + 1] = tr(lang, "%s (Rekord %s · %s)", name, BN.fmtRaceTime(tonumber(best.time)), tostring(best.name))
            else
                parts[#parts + 1] = tr(lang, "%s (noch keine Zeit)", name)
            end
        end
        say(pid, "Strecken auf %s: %s", tostring(BN.server.map), table.concat(parts, ", "))
        say(pid, "Starten: /rennen <Name> · beenden: /rennen stop · Rekorde: /rekorde <Name>")
    end
    if BN.isAdmin(s) then
        say(pid, "Admin: am Start /rennen neu <Name>, am Ziel /rennen ziel <Name>, entfernen /rennen loeschen <Name>")
    end
end

function commands.rennen(pid, arg)
    local s = session(pid)
    local words = {}
    for w in tostring(arg or ""):gmatch("%S+") do words[#words + 1] = w end
    local sub = (words[1] or ""):lower()
    -- Englische Unterbefehle
    local aliases = { new = "neu", finish = "ziel", delete = "loeschen", remove = "loeschen", ["end"] = "stop", quit = "stop" }
    sub = aliases[sub] or sub
    if sub == "" then
        listTracks(pid, s)
        return
    end
    if sub == "stop" or sub == "ende" then
        if s.race then
            say(pid, "Rennmodus beendet.")
            s.race = nil
        else
            say(pid, "Du bist in keinem Rennen.")
        end
        return
    end
    if sub == "neu" or sub == "ziel" or sub == "loeschen" or sub == "löschen" then
        if not BN.isAdmin(s) then
            say(pid, "Strecken anlegen dürfen nur Admins (Eintrag \"admins\" in config.json).")
            return
        end
        local name = trackName(words[2])
        if not name then
            say(pid, "Streckenname: 1–24 Zeichen, nur Buchstaben, Ziffern, _ und -")
            return
        end
        local data = BN.loadTracks()
        local track = data.tracks[name]
        if sub == "loeschen" or sub == "löschen" then
            if not track then say(pid, "Strecke %s gibt es nicht.", name) return end
            data.tracks[name] = nil
            saveTracks(data)
            say(pid, "Strecke %s gelöscht.", name)
            return
        end
        local pos = currentPosition(s)
        if not pos then
            say(pid, "Keine Position bekannt – setz dich in ein Fahrzeug und warte eine Sekunde.")
            return
        end
        if sub == "neu" then
            if track then say(pid, "Strecke %s gibt es schon.", name) return end
            data.tracks[name] = { start = point(pos), by = s.name, created = BN.now(), records = {} }
            saveTracks(data)
            say(pid, "Start von %s gesetzt. Jetzt zum Ziel fahren und /rennen ziel %s schreiben.", name, name)
        else
            if not track then say(pid, "Strecke %s gibt es nicht – zuerst /rennen neu %s", name, name) return end
            track.finish = point(pos)
            track.records = {}           -- neues Ziel: alte Zeiten passen nicht mehr
            saveTracks(data)
            local d = dist(point(pos), point(track.start))
            if d <= C.raceRadiusM then
                say(pid, "Ziel von %s gesetzt – Rundkurs (Start = Ziel). Starten: /rennen %s", name, name)
            else
                say(pid, "Ziel von %s gesetzt (%.0f m Luftlinie). Starten: /rennen %s", name, d, name)
            end
        end
        return
    end
    -- Lauf vorbereiten
    local name = trackName(sub)
    local track = name and BN.loadTracks().tracks[name]
    if not track then
        say(pid, "Strecke \"%s\" gibt es auf dieser Map nicht. Liste: /rennen", tostring(words[1]))
        return
    end
    if not track.finish then
        say(pid, "Strecke %s hat noch kein Ziel.", name)
        return
    end
    s.race = { name = name, start = point(track.start), finish = point(track.finish), state = "armed" }
    local pos = currentPosition(s)
    if pos then
        say(pid, "Rennen %s: Fahr zum Start (%.0f m entfernt).", name, dist(point(pos), s.race.start))
    else
        say(pid, "Rennen %s: Fahr zum Start.", name)
    end
end

function commands.rekorde(pid, arg)
    local data = BN.loadTracks()
    local name = trackName(arg)
    if name then
        local track = data.tracks[name]
        if not track then say(pid, "Strecke %s gibt es nicht.", name) return end
        local records = type(track.records) == "table" and track.records or {}
        if #records == 0 then say(pid, "Auf %s gibt es noch keine Zeiten.", name) return end
        say(pid, "Rekorde %s:", name)
        for i = 1, math.min(5, #records) do
            chat(pid, string.format("%d. %s – %s", i, tostring(records[i].name), BN.fmtRaceTime(tonumber(records[i].time))))
        end
        return
    end
    local names = {}
    for n, t in pairs(data.tracks) do
        if type(t.records) == "table" and t.records[1] then names[#names + 1] = n end
    end
    table.sort(names)
    if #names == 0 then say(pid, "Noch keine Rekorde auf dieser Map.") return end
    for _, n in ipairs(names) do
        local best = data.tracks[n].records[1]
        chat(pid, string.format("%s: %s – %s", n, tostring(best.name), BN.fmtRaceTime(tonumber(best.time))))
    end
end

local function adminOnly(pid)
    local s = session(pid)
    if BN.isAdmin(s) then return s end
    say(pid, "Nur für Admins.")
    return nil
end

local function splitArgs(arg)
    local words = {}
    for w in tostring(arg or ""):gmatch("%S+") do words[#words + 1] = w end
    return words
end

function commands.kick(pid, arg)
    local admin = adminOnly(pid)
    if not admin then return end
    local words = splitArgs(arg)
    local target, why = findTarget(words[1])
    if why then say(pid, "Mehrere Spieler passen zu \"%s\" – bitte genauer.", tostring(words[1])) return end
    if not target or not target.online then
        say(pid, "Aufruf: /kick <Name> [Grund] – Spieler muss auf diesem Server online sein.")
        return
    end
    local reason = table.concat(words, " ", 2)
    BN.savePlayer(target.online)
    drop(target.online.pid, tr(BN.langOf(target.online.pid), "Vom Server geworfen") .. (reason ~= "" and (": " .. reason) or ""))
    BN.players[target.online.pid] = nil
    sayAll("%s wurde vom Server geworfen.", target.name)
    modlog({ action = "kick", by = admin.name, target = target.name, targetId = target.id, reason = reason })
end

function commands.ban(pid, arg)
    local admin = adminOnly(pid)
    if not admin then return end
    local words = splitArgs(arg)
    local target, why = findTarget(words[1])
    if why then say(pid, "Mehrere Spieler passen zu \"%s\" – bitte genauer.", tostring(words[1])) return end
    if not target then
        say(pid, "Aufruf: /ban <Name> [30m|2h|7d] [Grund] – Name online, gespeichert oder BeamMP-ID.")
        return
    end
    if not target.id and not target.ip then
        say(pid, "Für diesen Spieler ist weder BeamMP-ID noch IP bekannt.")
        return
    end
    if target.online and BN.isAdmin(target.online) then
        say(pid, "Admins können nicht gesperrt werden.")
        return
    end
    local duration = BN.parseDuration(words[2])
    local reason = table.concat(words, " ", duration and 3 or 2)
    local data = BN.loadBans()
    local ban = { id = target.id, ip = target.ip, name = target.name, reason = reason, by = admin.name, at = BN.now() }
    if duration then ban["until"] = BN.now() + duration end
    data.bans[#data.bans + 1] = ban
    local saved, saveErr = saveBans(data)
    if not saved then
        say(pid, "Bann konnte nicht gespeichert werden (%s) – bitte beamnet doctor prüfen.", tostring(saveErr))
        print("[BeamNetCore] Fehler beim Speichern von bans.json: " .. tostring(saveErr))
        return
    end
    modlog({ action = "ban", by = admin.name, target = target.name, targetId = target.id, reason = reason, ["until"] = ban["until"] })
    if target.online then
        BN.savePlayer(target.online)
        drop(target.online.pid, banText(ban, BN.langOf(target.online.pid)))
        BN.players[target.online.pid] = nil
    end
    if duration then sayAll("%s wurde für %s gesperrt.", target.name, words[2]) else sayAll("%s wurde dauerhaft gesperrt.", target.name) end
end

function commands.unban(pid, arg)
    local admin = adminOnly(pid)
    if not admin then return end
    local query = tostring(arg or ""):lower()
    if query == "" then say(pid, "Aufruf: /unban <Name oder BeamMP-ID>") return end
    local data = BN.loadBans()
    local kept, removed = {}, 0
    for _, ban in ipairs(data.bans) do
        if tostring(ban.name):lower() == query or tostring(ban.id) == query then removed = removed + 1 else kept[#kept + 1] = ban end
    end
    if removed == 0 then say(pid, "Kein Bann für \"%s\" gefunden.", arg) return end
    data.bans = kept
    saveBans(data)
    modlog({ action = "unban", by = admin.name, target = arg })
    say(pid, "Bann für %s aufgehoben.", arg)
end

function commands.bans(pid)
    if not adminOnly(pid) then return end
    local now, active = BN.now(), {}
    for _, ban in ipairs(BN.loadBans().bans) do
        if not ban["until"] or tonumber(ban["until"]) > now then active[#active + 1] = ban end
    end
    local lang = BN.langOf(pid)
    if #active == 0 then say(pid, "Keine aktiven Banns.") return end
    say(pid, "%d aktive Banns:", #active)
    for i = math.max(1, #active - 4), #active do
        local b = active[i]
        chat(pid, string.format("%s – %s%s", tostring(b.name), (b.reason and b.reason ~= "") and tostring(b.reason) or tr(lang, "ohne Grund"),
            b["until"] and tr(lang, " · bis %s", os.date("%d.%m. %H:%M", b["until"])) or tr(lang, " · dauerhaft")))
    end
end

function commands.warn(pid, arg)
    local admin = adminOnly(pid)
    if not admin then return end
    local words = splitArgs(arg)
    local target = findTarget(words[1])
    local text = table.concat(words, " ", 2)
    if not target or not target.online or text == "" then
        say(pid, "Aufruf: /warn <Name> <Text> – Spieler muss auf diesem Server online sein.")
        return
    end
    say(target.online.pid, "Verwarnung von %s: %s", admin.name, text)
    say(pid, "Verwarnung an %s gesendet.", target.name)
    modlog({ action = "warn", by = admin.name, target = target.name, targetId = target.id, reason = text })
end

function commands.mute(pid, arg)
    local admin = adminOnly(pid)
    if not admin then return end
    local words = splitArgs(arg)
    local target = findTarget(words[1])
    if not target or not target.online then say(pid, "Aufruf: /mute <Name> [Minuten]") return end
    local minutes = math.floor(tonumber(words[2]) or 10)
    if minutes < 1 or minutes > 10080 then say(pid, "Aufruf: /mute <Name> [Minuten]") return end
    target.online.mutedUntil = BN.now() + minutes * 60
    BN.saveMute(target.online, target.online.mutedUntil)
    say(target.online.pid, "Du wurdest für %d min stummgeschaltet.", minutes)
    say(pid, "%s ist %d min stumm.", target.name, minutes)
    modlog({ action = "mute", by = admin.name, target = target.name, targetId = target.id, minutes = minutes })
end

function commands.ansage(pid, arg)
    local admin = adminOnly(pid)
    if not admin then return end
    if not arg or arg == "" then say(pid, "Aufruf: /ansage <Text> – erscheint auf allen BeamNet-Servern.") return end
    BN.announce(arg, admin.name)
    modlog({ action = "ansage", by = admin.name, reason = arg })
end

function commands.lang(pid, arg)
    local s = session(pid)
    local choice = tostring(arg or ""):lower()
    if choice == "en" or choice == "english" or choice == "englisch" then
        s.lang = "en"
    elseif choice == "de" or choice == "deutsch" or choice == "german" then
        s.lang = "de"
    elseif choice == "" then
        say(pid, "Sprache: Deutsch. English: /lang en")
        return
    else
        say(pid, "Sprachen: /lang de · /lang en")
        return
    end
    s.dirty = true
    say(pid, "Sprache auf Deutsch gestellt.")
end
commands.language = commands.lang
commands.sprache = commands.lang

-- Englische Befehlsnamen
commands.league = commands.liga
commands.race = commands.rennen
commands.records = commands.rekorde
commands.announce = commands.ansage

function commands.erfolge(pid, arg)
    local s = session(pid)
    if arg and arg ~= "" then
        s = findPlayerByName(arg)
        if not s then say(pid, "Kein Spieler online mit dem Namen \"%s\".", arg) return end
    end
    local lang = BN.langOf(pid)
    local t = BN.totals(s)
    local done, open = {}, {}
    for _, a in ipairs(BN.ACHIEVEMENTS) do
        if BN.hasAchievement(s, a.id) then
            done[#done + 1] = tr(lang, a.name)
        else
            open[#open + 1] = string.format("%s %s/%s", tr(lang, a.name), BN.fmtProgress(a.value(t)), BN.fmtProgress(a.goal))
        end
    end
    say(pid, "Erfolge von %s: %d von %d", s.name, #done, #BN.ACHIEVEMENTS)
    if #done > 0 then say(pid, "Geschafft: %s", table.concat(done, ", ")) end
    if #open > 0 then
        local next3 = {}
        for i = 1, math.min(3, #open) do next3[i] = open[i] end
        say(pid, "Als Nächstes: %s", table.concat(next3, " · "))
    end
end
commands.achievements = commands.erfolge

function commands.aufgabe(pid)
    local s = session(pid)
    local lang = BN.langOf(pid)
    local ch = BN.challengeFor()
    if not ch then say(pid, "Heute gibt es keine Tagesaufgabe.") return end
    local d = BN.dayTotals(s)
    local left = 86400 - (BN.now() % 86400)
    if d.done then
        say(pid, "Tagesaufgabe geschafft: %s. Die nächste kommt in %s.", tr(lang, ch.text, ch.goal), fmtDuration(left))
    else
        say(pid, "Tagesaufgabe: %s – %s/%s · noch %s · Belohnung %d XP", tr(lang, ch.text, ch.goal),
            BN.fmtProgress(ch.value(d)), BN.fmtProgress(ch.goal), fmtDuration(left), C.challengeXp)
    end
end
commands.daily = commands.aufgabe
commands.challenge = commands.aufgabe

function commands.saison(pid)
    local s = session(pid)
    local lang = BN.langOf(pid)
    local month = monthKey()
    local list = BN.seasonRanking(month)
    local now = BN.now()
    local y, m = month:match("^(%d+)%-(%d+)$")
    y, m = tonumber(y), tonumber(m)
    local nextStart = os.time({ year = m == 12 and y + 1 or y, month = m == 12 and 1 or m + 1, day = 1, hour = 0 })
    -- os.time rechnet in Ortszeit; fuer die Restzeit genuegt Tagesgenauigkeit.
    local daysLeft = math.max(0, math.ceil((nextStart - now) / 86400))
    say(pid, "Saison %s (noch %d Tage):", BN.seasonName(month, lang), daysLeft)
    if #list == 0 then
        say(pid, "Noch keine Punkte in dieser Saison – einfach losfahren!")
    else
        for i = 1, math.min(5, #list) do chat(pid, string.format("%d. %s – %d XP", i, tostring(list[i].name), list[i].xp)) end
    end
    if not s.guest then
        local mine, rank = BN.totals(s).monthXp, nil
        for i, e in ipairs(list) do if e.id == s.id then rank = i end end
        say(pid, "Du: Platz %s mit %d XP in dieser Saison", rank and tostring(rank) or "–", math.floor(mine))
    end
    local prev = monthKey(now - (tonumber(os.date("!%d", now)) + 1) * 86400)
    local archive = json.decode(readFile(C.sharedDir .. "/seasons/" .. prev .. ".json") or "")
    if type(archive) == "table" and type(archive.top) == "table" and archive.top[1] then
        local parts = {}
        for i = 1, math.min(3, #archive.top) do
            local e = archive.top[i]
            parts[#parts + 1] = string.format("%d. %s (%d XP)", i, tostring(e.name), tonumber(e.xp) or 0)
        end
        say(pid, "Letzte Saison (%s): %s", BN.seasonName(prev, lang), table.concat(parts, " · "))
    end
end
commands.season = commands.saison

function BN.fmtProgress(v)
    v = tonumber(v) or 0
    if v >= 100 or v == math.floor(v) then return string.format("%d", math.floor(v)) end
    return string.format("%.1f", v)
end

BN.commands = commands

-- Gibt true zurueck, wenn die Nachricht ein BeamNet-Befehl war.
function BN.handleChat(pid, message)
    if type(message) ~= "string" then return false end
    local cmd, arg = message:match("^%s*/(%S+)%s*(.-)%s*$")
    if not cmd then return false end
    local handler = commands[cmd:lower()]
    if not handler then return false end      -- Befehle anderer Plugins nicht abfangen
    -- Befehls-Bremse: hoechstens commandLimit Befehle in commandWindowSec Sekunden (Admins ausgenommen).
    local s = BN.players[pid]
    if s and not BN.isAdmin(s) then
        local now = BN.now()
        local kept = {}
        for _, t in ipairs(s.commandTimes or {}) do if now - t < C.commandWindowSec then kept[#kept + 1] = t end end
        if #kept >= C.commandLimit then
            if not s.commandNoticeAt or now - s.commandNoticeAt >= 5 then
                s.commandNoticeAt = now
                say(pid, "Bitte etwas langsamer mit den Befehlen.")
            end
            s.commandTimes = kept
            return true
        end
        kept[#kept + 1] = now
        s.commandTimes = kept
    end
    local ok, err = pcall(handler, pid, arg)
    if not ok then
        print("[BeamNetCore] Fehler in /" .. cmd .. ": " .. tostring(err))
        say(pid, "Interner Fehler – bitte einem Admin melden.")
    end
    return true
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Takt

function BN.tick()
    if not MP then return end
    local online = MP.GetPlayers and MP.GetPlayers() or {}
    for pid in pairs(online) do
        local s = session(pid)
        s.pendingSeconds = s.pendingSeconds + C.tickMs / 1000
        local vehicles = MP.GetPlayerVehicles and MP.GetPlayerVehicles(pid) or nil
        if type(vehicles) == "table" then
            for vid in pairs(vehicles) do
                local ok, raw = pcall(MP.GetPositionRaw, pid, vid)
                if ok and type(raw) == "table" and raw.pos then BN.track(pid, vid, raw.pos, tonumber(raw.tim), raw.vel) end
            end
        end
        checkProgress(s)
    end
    -- Sitzungen von Spielern entfernen, die ohne Abmeldung verschwunden sind.
    for pid, s in pairs(BN.players) do
        if online[pid] == nil then
            BN.savePlayer(s)
            BN.players[pid] = nil
        end
    end
    local now = BN.now()
    local wk = weekKey(now)
    if BN.currentWeek and BN.currentWeek ~= wk then BN.announceWeek(BN.currentWeek) end
    local mk = monthKey(now)
    if BN.currentMonth and BN.currentMonth ~= mk then BN.endSeason(BN.currentMonth) end
    BN.currentMonth = mk
    BN.currentWeek = wk
    BN.sync(false)
    if now - BN.lastStatus >= C.statusEverySec then BN.writeStatus() end
    if now - BN.lastSave >= C.saveEverySec then
        for _, s in pairs(BN.players) do BN.savePlayer(s) end
        BN.lastSave = now
    end
end

function BN.init()
    BN.initialized = true
    BN.loadOverrides()
    BN.lastConfigLoad = BN.now()
    BN.markAnnouncementsSeen()
    BN.server = BN.readServerConfig(C.serverConfig)
    ensureDir(C.sharedDir)
    ensureDir(playersDir())
    ensureDir(serversDir())
    if MP and MP.GetPlayers then
        for pid in pairs(MP.GetPlayers() or {}) do
            if not BN.players[pid] then BN.addPlayer(pid) end
        end
    end
    BN.writeStatus()
    print(string.format("[BeamNetCore] %s geladen · %s · Port %s · Map %s · Daten %s · %s", BN.VERSION, BN.server.name,
        tostring(BN.server.port), BN.server.map, C.sharedDir, _VERSION))
    local caps = BN.capabilities()
    for _, key in ipairs({ "positions", "vehicles", "identifiers", "timers", "files" }) do
        if not caps[key] then print("[BeamNetCore] Warnung: " .. capabilityEffects[key]) end
    end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- BeamMP-Ereignisse (globale Funktionen, weil MP.RegisterEvent Funktionsnamen erwartet)

function BN_onInit()
    if not BN.initialized then BN.init() end
end

function BN_onPlayerJoin(pid)
    local s = BN.addPlayer(pid)
    local t = BN.totals(s)
    say(pid, "Willkommen auf %s (%s)! Level %d · Liga %s · %s gefahren. /hilfe für Befehle, /server für alle Server. English: /lang en",
        BN.server.name, BN.server.map, t.level, tr(BN.langOf(pid), t.league.name), fmtKm(t.km))
    local ch = BN.challengeFor()
    if ch and not BN.dayTotals(s).done then
        local lang = BN.langOf(pid)
        say(pid, "Heute: %s (/aufgabe)", tr(lang, ch.text, ch.goal))
    end
    BN.writeStatus()
end

function BN_onPlayerDisconnect(pid)
    local s = BN.players[pid]
    if s then BN.savePlayer(s) end
    BN.players[pid] = nil
    BN.writeStatus()
end

function BN.onChat(pid, message)
    if BN.handleChat(pid, message) then return 1 end
    local s = BN.players[pid]
    -- Alles andere (auch "/..." anderer Plugins) unterliegt Spamschutz und Stummschaltung.
    if s and type(message) == "string" and BN.spamCheck(s) then return 1 end
end

function BN_onChatMessage(pid, _, message)
    local ok, result = pcall(BN.onChat, pid, message)
    if not ok then
        print("[BeamNetCore] Fehler im Chat: " .. tostring(result))
        return nil
    end
    return result
end

-- Gesperrte Spieler gar nicht erst hereinlassen (Rueckgabe eines Textes = Ablehnung mit diesem Grund).
function BN_onPlayerAuth(name, role, isGuest, identifiers)
    local ids = type(identifiers) == "table" and identifiers or {}
    local id = safeId(ids.beammp)
    local ban = BN.findBan(id, ids.ip)
    if ban then
        print("[BeamNetCore] Gesperrter Spieler abgewiesen: " .. tostring(name))
        local lang = C.language
        local rec = id and json.decode(readFile(playersDir() .. "/" .. id .. ".json") or "")
        if type(rec) == "table" and (rec.lang == "en" or rec.lang == "de") then lang = rec.lang end
        return banText(ban, lang)
    end
end

function BN_onVehicleReset(pid, vid)
    BN.forgetVehicle(pid, vid)
end

function BN_onVehicleDeleted(pid, vid)
    BN.forgetVehicle(pid, vid)
end

function BN_onShutdown()
    for _, s in pairs(BN.players) do BN.savePlayer(s) end
    BN.writeStatus()
end

function BN_Tick()
    local ok, err = pcall(BN.tick)
    if not ok then print("[BeamNetCore] Fehler im Takt: " .. tostring(err)) end
end

function BN_RaceTick()
    local ok, err = pcall(BN.raceTick)
    if not ok then print("[BeamNetCore] Fehler im Renntakt: " .. tostring(err)) end
end

if MP and MP.RegisterEvent then
    MP.RegisterEvent("onInit", "BN_onInit")
    MP.RegisterEvent("onPlayerJoin", "BN_onPlayerJoin")
    MP.RegisterEvent("onPlayerAuth", "BN_onPlayerAuth")
    MP.RegisterEvent("onPlayerDisconnect", "BN_onPlayerDisconnect")
    MP.RegisterEvent("onChatMessage", "BN_onChatMessage")
    MP.RegisterEvent("onVehicleReset", "BN_onVehicleReset")
    MP.RegisterEvent("onVehicleDeleted", "BN_onVehicleDeleted")
    MP.RegisterEvent("onShutdown", "BN_onShutdown")
    MP.RegisterEvent("BN_Tick", "BN_Tick")
    if MP.CancelEventTimer then pcall(MP.CancelEventTimer, "BN_Tick") end
    MP.CreateEventTimer("BN_Tick", C.tickMs)
    MP.RegisterEvent("BN_RaceTick", "BN_RaceTick")
    if MP.CancelEventTimer then pcall(MP.CancelEventTimer, "BN_RaceTick") end
    MP.CreateEventTimer("BN_RaceTick", C.raceTickMs)
    -- Beim Neuladen des Plugins (Spieler schon online) sofort initialisieren; onInit kommt dann nicht erneut.
    BN.init()
end

return BN
