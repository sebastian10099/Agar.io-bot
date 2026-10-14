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
-- Chat-Befehle: /hilfe  /stats [Name]  /top [km|xp|woche]  /liga  /server  /km

BeamNetCore = BeamNetCore or {}
local BN = BeamNetCore

BN.VERSION = "1.0"

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
local function writeFileAtomic(path, data)
    local tmp = path .. ".tmp" .. tostring(math.random(100000, 999999))
    local f, err = io.open(tmp, "wb")
    if not f then return false, err end
    f:write(data)
    f:close()
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

local function loadOverrides()
    local data = readFile(C.sharedDir .. "/config.json")
    if not data then return end
    local cfg = json.decode(data)
    if type(cfg) ~= "table" then
        print("[BeamNetCore] config.json ist fehlerhaft und wird ignoriert")
        return
    end
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

local function identifiers(pid)
    if not (MP and MP.GetPlayerIdentifiers) then return {} end
    local ok, ids = pcall(MP.GetPlayerIdentifiers, pid)
    if ok and type(ids) == "table" then return ids end
    return {}
end

local function emptyRecord(id, name)
    return { id = id, name = name, km = 0, seconds = 0, weekKm = 0, week = weekKey(BN.now()), topSpeedKmh = 0,
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
    rec.week = rec.week or weekKey(BN.now())
    return rec
end

local function applyWeek(rec)
    local wk = weekKey(BN.now())
    if rec.week ~= wk then
        rec.week = wk
        rec.weekKm = 0
    end
end

-- Neue Sitzung (Join oder Plugin-Neustart mit Spielern online).
function BN.addPlayer(pid)
    local name = (MP and MP.GetPlayerName and MP.GetPlayerName(pid)) or ("Spieler " .. tostring(pid))
    local ids = identifiers(pid)
    local id = safeId(ids.beammp)
    local session = { pid = pid, name = name, id = id, guest = id == nil, vehicles = {},
                      pendingKm = 0, pendingSeconds = 0, pendingTop = 0 }
    session.record = id and loadRecord(id, name) or emptyRecord(nil, name)
    applyWeek(session.record)
    session.level = BN.levelFor(BN.xpFor(session.record.km, session.record.seconds))
    session.league = BN.leagueFor(BN.xpFor(session.record.km, session.record.seconds)).name
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
    if s.pendingKm == 0 and s.pendingSeconds == 0 and s.pendingTop == 0 and not s.dirty then return true end
    ensureDir(C.sharedDir)
    ensureDir(playersDir())
    local rec = loadRecord(s.id, s.name)
    applyWeek(rec)
    rec.km = rec.km + s.pendingKm
    rec.weekKm = rec.weekKm + s.pendingKm
    rec.seconds = rec.seconds + s.pendingSeconds
    rec.topSpeedKmh = math.max(rec.topSpeedKmh or 0, s.pendingTop)
    rec.lastSeen = BN.now()
    rec.lastServer = BN.server.name or ""
    rec.xp = BN.xpFor(rec.km, rec.seconds)
    rec.level = BN.levelFor(rec.xp)
    rec.league = BN.leagueFor(rec.xp).name
    local ok, err = writeFileAtomic(playersDir() .. "/" .. s.id .. ".json", json.encode(rec))
    if not ok then
        print("[BeamNetCore] Speichern fehlgeschlagen fuer " .. s.name .. ": " .. tostring(err))
        return false
    end
    s.record = rec
    s.pendingKm, s.pendingSeconds, s.pendingTop, s.dirty = 0, 0, 0, false
    return true
end

-- Aktuelle Werte einer Sitzung (gespeichert + noch nicht gespeichert).
function BN.totals(s)
    local rec = s.record
    local km = rec.km + s.pendingKm
    local seconds = rec.seconds + s.pendingSeconds
    local xp = BN.xpFor(km, seconds)
    return { km = km, seconds = seconds, weekKm = rec.weekKm + s.pendingKm, xp = xp, level = BN.levelFor(xp),
             league = BN.leagueFor(xp), topSpeedKmh = math.max(rec.topSpeedKmh or 0, s.pendingTop) }
end

local function checkProgress(s)
    local t = BN.totals(s)
    if t.level > (s.level or 1) then
        if C.announceLevelUps then chat(-1, string.format("%s ist jetzt Level %d!", s.name, t.level)) end
        s.level = t.level
    end
    if t.league.name ~= s.league then
        chat(-1, string.format("%s steigt in die Liga %s auf!", s.name, t.league.name))
        s.league = t.league.name
    end
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
    if v then
        local dt
        if tim and v.tim and tim > v.tim then dt = tim - v.tim else dt = math.max(1, now - v.at) end
        local dx, dy, dz = x - v.x, y - v.y, z - v.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d >= C.minStepM and dt > 0 and d / dt <= C.maxSpeedMps then
            counted = d
            s.pendingKm = s.pendingKm + d / 1000
        end
    end
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
    if s then s.vehicles[vid] = nil end
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
            if rec.week ~= weekKey(now) then rec.weekKm = 0 end
            rec.weekKm = tonumber(rec.weekKm) or 0
            byId[rec.id] = rec
        end
    end
    -- Spieler online mit ihren noch nicht gespeicherten Werten.
    for _, s in pairs(BN.players) do
        if not s.guest then
            local t = BN.totals(s)
            byId[s.id] = { id = s.id, name = s.name, km = t.km, seconds = t.seconds, weekKm = t.weekKm }
        end
    end
    local list = {}
    for _, rec in pairs(byId) do
        rec.xp = BN.xpFor(rec.km, rec.seconds)
        list[#list + 1] = rec
    end
    table.sort(list, function(a, b)
        if a.xp ~= b.xp then return a.xp > b.xp end
        return tostring(a.name) < tostring(b.name)
    end)
    BN.board = { at = now, list = list }
    return list
end

function BN.rankOf(id)
    for i, rec in ipairs(BN.refreshBoard(false)) do
        if rec.id == id then return i, #BN.board.list end
    end
    return nil, #BN.board.list
end

function BN.writeStatus()
    if not BN.server.port or BN.server.port == 0 then return end
    ensureDir(C.sharedDir)
    ensureDir(serversDir())
    local names = {}
    for _, s in pairs(BN.players) do names[#names + 1] = s.name end
    table.sort(names)
    local status = { name = BN.server.name, port = BN.server.port, map = BN.server.map, players = #names,
                     max = BN.server.maxPlayers, names = names, updated = BN.now(), version = BN.VERSION }
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
    chat(pid, "BeamNet-Befehle: /stats [Name] · /top [km|xp|woche] · /liga · /server · /km")
end
commands.help = commands.hilfe

function commands.km(pid)
    local s = session(pid)
    local t = BN.totals(s)
    chat(pid, string.format("Du bist %s gefahren (diese Woche %s).", fmtKm(t.km), fmtKm(t.weekKm)))
end

function commands.stats(pid, arg)
    local s = session(pid)
    if arg and arg ~= "" then
        s = findPlayerByName(arg)
        if not s then
            chat(pid, "Kein Spieler online mit dem Namen \"" .. arg .. "\".")
            return
        end
    end
    local t = BN.totals(s)
    local line = string.format("%s: Level %d · Liga %s · %d XP · %s · %s Fahrzeit · Spitze %.0f km/h",
        s.name, t.level, t.league.name, t.xp, fmtKm(t.km), fmtDuration(t.seconds), t.topSpeedKmh)
    chat(pid, line)
    if s.guest then
        chat(pid, "Gast-Konto: Werte gelten nur für diese Sitzung (mit BeamMP-Konto werden sie gespeichert).")
    else
        local rank, total = BN.rankOf(s.id)
        local nextLevel = BN.xpForLevel(t.level + 1)
        chat(pid, string.format("Rang %s von %d · noch %d XP bis Level %d", rank and tostring(rank) or "–", total,
            math.max(0, nextLevel - t.xp), t.level + 1))
    end
end

function commands.top(pid, arg)
    local mode = (arg or ""):lower()
    local list = {}
    for _, rec in ipairs(BN.refreshBoard(false)) do list[#list + 1] = rec end
    local label, value
    if mode == "km" then
        table.sort(list, function(a, b) return a.km > b.km end)
        label, value = "Kilometer", function(r) return fmtKm(r.km) end
    elseif mode == "woche" or mode == "week" then
        table.sort(list, function(a, b) return a.weekKm > b.weekKm end)
        label, value = "Kilometer diese Woche", function(r) return fmtKm(r.weekKm) end
    else
        label, value = "XP", function(r) return string.format("%d XP (Level %d)", r.xp, BN.levelFor(r.xp)) end
    end
    if #list == 0 then
        chat(pid, "Noch keine Bestenliste – einfach losfahren!")
        return
    end
    chat(pid, "Bestenliste " .. label .. ":")
    for i = 1, math.min(5, #list) do
        chat(pid, string.format("%d. %s – %s", i, list[i].name or "?", value(list[i])))
    end
end

function commands.liga(pid)
    local s = session(pid)
    local t = BN.totals(s)
    local parts = {}
    for _, league in ipairs(C.leagues) do parts[#parts + 1] = string.format("%s ab %d", league.name, league.xp) end
    chat(pid, "Ligen (XP): " .. table.concat(parts, " · "))
    local nextL = BN.nextLeague(t.xp)
    if nextL then
        chat(pid, string.format("Du: %s mit %d XP – noch %d XP bis %s.", t.league.name, t.xp, nextL.xp - t.xp, nextL.name))
    else
        chat(pid, string.format("Du: %s mit %d XP – höchste Liga erreicht!", t.league.name, t.xp))
    end
end

function commands.server(pid)
    local list = BN.serverList()
    if #list == 0 then
        chat(pid, "Keine Serverliste verfügbar.")
        return
    end
    chat(pid, "BeamNet-Server (wechseln im BeamMP-Launcher):")
    for _, st in ipairs(list) do
        local addr = C.publicHost ~= "" and (C.publicHost .. ":" .. tostring(st.port)) or ("Port " .. tostring(st.port))
        local here = tonumber(st.port) == tonumber(BN.server.port) and "  ← hier" or ""
        chat(pid, string.format("%s · %s · %d/%d · %s%s", st.name or "?", st.map or "?", tonumber(st.players) or 0,
            tonumber(st.max) or 0, addr, here))
    end
end
commands.servers = commands.server

BN.commands = commands

-- Gibt true zurueck, wenn die Nachricht ein BeamNet-Befehl war.
function BN.handleChat(pid, message)
    if type(message) ~= "string" then return false end
    local cmd, arg = message:match("^%s*/(%S+)%s*(.-)%s*$")
    if not cmd then return false end
    local handler = commands[cmd:lower()]
    if not handler then return false end      -- Befehle anderer Plugins nicht abfangen
    local ok, err = pcall(handler, pid, arg)
    if not ok then
        print("[BeamNetCore] Fehler in /" .. cmd .. ": " .. tostring(err))
        chat(pid, "Interner Fehler – bitte einem Admin melden.")
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
    if now - BN.lastStatus >= C.statusEverySec then BN.writeStatus() end
    if now - BN.lastSave >= C.saveEverySec then
        for _, s in pairs(BN.players) do BN.savePlayer(s) end
        BN.lastSave = now
    end
end

function BN.init()
    BN.initialized = true
    loadOverrides()
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
    print(string.format("[BeamNetCore] %s geladen · %s · Port %s · Map %s · Daten %s", BN.VERSION, BN.server.name,
        tostring(BN.server.port), BN.server.map, C.sharedDir))
end

-- ---------------------------------------------------------------------------------------------------------------------
-- BeamMP-Ereignisse (globale Funktionen, weil MP.RegisterEvent Funktionsnamen erwartet)

function BN_onInit()
    if not BN.initialized then BN.init() end
end

function BN_onPlayerJoin(pid)
    local s = BN.addPlayer(pid)
    local t = BN.totals(s)
    chat(pid, string.format("Willkommen auf %s (%s)! Level %d · Liga %s · %s gefahren. /hilfe für Befehle, /server für alle Server.",
        BN.server.name, BN.server.map, t.level, t.league.name, fmtKm(t.km)))
    BN.writeStatus()
end

function BN_onPlayerDisconnect(pid)
    local s = BN.players[pid]
    if s then BN.savePlayer(s) end
    BN.players[pid] = nil
    BN.writeStatus()
end

function BN_onChatMessage(pid, _, message)
    if BN.handleChat(pid, message) then return 1 end
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

if MP and MP.RegisterEvent then
    MP.RegisterEvent("onInit", "BN_onInit")
    MP.RegisterEvent("onPlayerJoin", "BN_onPlayerJoin")
    MP.RegisterEvent("onPlayerDisconnect", "BN_onPlayerDisconnect")
    MP.RegisterEvent("onChatMessage", "BN_onChatMessage")
    MP.RegisterEvent("onVehicleReset", "BN_onVehicleReset")
    MP.RegisterEvent("onVehicleDeleted", "BN_onVehicleDeleted")
    MP.RegisterEvent("onShutdown", "BN_onShutdown")
    MP.RegisterEvent("BN_Tick", "BN_Tick")
    if MP.CancelEventTimer then pcall(MP.CancelEventTimer, "BN_Tick") end
    MP.CreateEventTimer("BN_Tick", C.tickMs)
    -- Beim Neuladen des Plugins (Spieler schon online) sofort initialisieren; onInit kommt dann nicht erneut.
    BN.init()
end

return BN
