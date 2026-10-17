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
-- Chat-Befehle: /hilfe  /stats [Name]  /top [km|xp|woche|vorwoche]  /liga  /server  /wo <Name>  /km  /lang de|en
-- (englisch: /help /stats /top [km|xp|week|lastweek] /league /server /where <name> /km /race /records /lang)
--               /rennen [Name|stop]  /rekorde [Name]  /erfolge [Name]  /aufgabe  /saison  /vote map <Name>|ja|nein
--               – Admins: /rennen neu|ziel|loeschen <Name>
-- Moderation (Admins): /kick <Name> [Grund]  /ban <Name> [30m|2h|7d] [Grund]  /unban <Name>  /bans
--                      /warn <Name> <Text>  /mute <Name> [Minuten]  /ansage <Text>

BeamNetCore = BeamNetCore or {}
local BN = BeamNetCore

BN.VERSION = "1.93"

local defaults = {
    sharedDir = os.getenv("BEAMNET_SHARED") or "/srv/beammp/shared/beamnet",
    serverConfig = "ServerConfig.toml",
    -- Regeln fuer /regeln und die Begruessung neuer Spieler (hoechstens 10 Zeilen zu je 200 Zeichen).
    rules = {
        "Fair fahren: kein absichtliches Rammen oder Blockieren.",
        "Freundlich im Chat – keine Beleidigungen, kein Spam.",
        "Den Anweisungen der Admins folgen.",
    },
    -- Neue Spieler (erster Besuch im Netzwerk) begruessen und allen auf dem Server vorstellen.
    welcomeNew = true,
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
    -- Map-Abstimmung (/vote map <Name>): an/aus, Dauer (s), Pause danach (min). Braucht den Waechter (beamnet watch).
    mapVote = true,
    mapVoteSec = 60,
    mapVoteCooldownMin = 10,
    -- Eine Map zaehlt (Erfolge, Tagesaufgabe "verschiedene Server") erst ab so vielen km in der Sitzung.
    mapMinKm = 0.1,
    -- Tagesaufgaben: Belohnung und erlaubte Arten (km, speed, time, servers, races – Rennen nur, wenn es Strecken gibt).
    challengeXp = 40,
    challengeTypes = { "km", "speed", "time", "servers" },
    -- Spamschutz: mehr als spamMessages Nachrichten in spamWindowSec Sekunden -> spamMuteSec stumm (Admins nie).
    spamMessages = 5,
    spamWindowSec = 5,
    spamMuteSec = 30,
    -- Schutz gegen Verbindungs-Spam: mehr als joinLimit Versuche in joinWindowSec Sekunden (je IP bzw. Konto)
    -- -> joinBlockSec Sekunden abgewiesen. Admins sind ausgenommen.
    joinLimit = 6,
    joinWindowSec = 60,
    joinBlockSec = 120,
    -- Wortfilter: Nachrichten mit diesen Woertern werden nicht gesendet (ganze Woerter, Gross/Klein egal; Woerter ab
    -- 6 Buchstaben auch in Zusammensetzungen). Beim filterStrikes-ten Mal in 10 Minuten filterMuteSec stumm.
    badWords = { "arschloch", "hurensohn", "wichser", "fotze", "missgeburt", "spast", "schlampe", "nutte",
                 "asshole", "motherfucker", "cunt", "bitch" },
    filterStrikes = 3,
    filterMuteSec = 300,
    -- Strecke der Woche: Bonus-XP fuer den ersten gueltigen Lauf je Woche (0 = aus).
    weeklyTrackXp = 50,
    -- Gruppenrennen (/rennen gruppe <Strecke>): Start nach groupRaceDelaySec, Ende spaetestens nach groupRaceMaxSec.
    groupRaceDelaySec = 30,
    groupRaceMaxSec = 900,
    -- Freundesliste (/freund): hoechstens maxFriends Eintraege; alle friendCheckSec Sekunden wird geprueft, wer neu
    -- im Netzwerk ist (andere Server ueber ihre Lebenszeichen).
    maxFriends = 20,
    -- Tages-Serie: Wer an aufeinanderfolgenden Tagen mindestens streakMinKm faehrt, bekommt ab dem zweiten Tag
    -- streakXp Bonus-XP je Serientag (hoechstens streakMaxDays Tage gezaehlt; 0 = aus).
    streakXp = 10,
    streakMaxDays = 7,
    streakMinKm = 1,
    -- Fahrauftraege (/auftrag): Ziele sind Orte, die Admins mit /ort neu <Typ> <Name> anlegen (Krankenhaus, Schule ...).
    -- XP = jobXp + jobXpPerKm je km Luftlinie (Notfaelle das 1,5-Fache), +50 % fuer schnelle Fahrer, hoechstens 250.
    jobXp = 20,
    jobXpPerKm = 25,
    jobRadiusM = 25,
    jobMinDistM = 300,
    jobCooldownSec = 45,
    jobXpPerHour = 600,
    -- Wochenziel fuer alle (/ziel): Zusammen communityKm km pro Woche (0 = automatisch: 10 % mehr als letzte Woche,
    -- mindestens 200). Ist es geschafft, bekommt jeder mit mindestens communityMinKm eigenen km communityXp Bonus-XP.
    communityKm = 0,
    communityXp = 100,
    communityMinKm = 5,
    -- Team der Woche: jedes Mitglied, das in der Woche mitgefahren ist, bekommt beim naechsten Besuch einmal teamWeekXp.
    teamWeekXp = 50,
    -- Verfolgungsjagd (/fangen): Anmeldung chaseJoinSec, Vorsprung chaseHeadStartSec, Dauer hoechstens chaseMaxSec.
    -- Gefangen bei chaseCatchM Abstand; XP fuer den Faenger, den Fluechtigen (je Minute, mehr wenn er durchkommt).
    chaseJoinSec = 30,
    chaseHeadStartSec = 20,
    chaseMaxSec = 300,
    chaseCatchM = 15,
    chaseXpCatch = 60,
    chaseXpSurvive = 100,
    chaseXpPerMin = 10,
    chaseXpPerDay = 300,
    chaseCooldownSec = 180,
    -- Tipps im Chat: alle tipEverySec Sekunden der naechste Tipp an alle auf diesem Server (0 = aus).
    tipEverySec = 900,
    -- Einsteiger-Pfad (/start): Bonus-XP je Schritt und fuer alle zusammen (0 = aus).
    tutorialXp = 25,
    tutorialDoneXp = 50,
    -- Rennserien (/serie): Bonus-XP fuer eine ganze Serie (und fuer einen Serienrekord zusaetzlich raceRecordXp).
    seriesXp = 40,
    -- Einsatz-Alarm: etwa alle alertEverySec Sekunden (mit Zufall) ein Ziel fuer alle; wer zuerst da ist, bekommt
    -- alertXp. Nur mit mindestens alertMinPlayers Spielern und Orten auf der Map (0 = aus).
    alertEverySec = 1800,
    alertXp = 50,
    alertMinPlayers = 2,
    -- Konvoi: wer mit einem anderen Spieler (Konto, andere IP) hoechstens convoyRadiusM entfernt faehrt, sammelt
    -- Konvoi-Kilometer; je convoyKm km gemeinsam gibt es convoyXp, hoechstens convoyXpPerHour je Stunde (convoyXp 0 = aus).
    convoyKm = 3,
    convoyXp = 20,
    convoyXpPerHour = 80,
    convoyRadiusM = 150,
    -- Wo ist was los? Faehrt hier hoechstens crowdMaxHere Spieler, kommt alle crowdHintSec Sekunden ein Hinweis auf den
    -- vollsten anderen Server (mindestens crowdMinPlayers Spieler, nicht voll). crowdHintSec 0 = aus.
    crowdHintSec = 900,
    crowdMinPlayers = 3,
    crowdMaxHere = 2,
    -- Lieferpunkte: Wo Spieler mit Konto fahren, merkt sich das Plugin alle roadPointSec Sekunden einen Punkt (mindestens
    -- roadPointSpacingM von den anderen entfernt, hoechstens roadPointsMax je Map, gemeinsam fuer alle Server). Gibt es
    -- keine passenden Orte, liefert /auftrag zu einem dieser Punkte (roadPointsMax 0 = aus).
    -- Rueckkehrer: Wer mindestens comebackDays Tage nicht da war, bekommt beim Wiederkommen einmal comebackXp
    -- (hoechstens alle 30 Tage, nur mit Konto; 0 = aus).
    comebackDays = 14,
    comebackXp = 50,
    roadPointsMax = 300,
    roadPointSpacingM = 250,
    roadPointSec = 20,
    friendCheckSec = 15,
    -- Befehls-Bremse je Spieler (Admins ausgenommen).
    commandLimit = 6,
    commandWindowSec = 10,
    -- Wie oft Banns und Ansagen der anderen Server gelesen werden (s).
    syncEverySec = 3,
    -- Zeitrennen: Radius von Start- und Zielbereich (m), Abtastung waehrend eines Laufs (ms), Hoechstdauer (min).
    raceRadiusM = 12,
    raceTickMs = 250,
    raceMaxMinutes = 30,
    -- Mindest-Fahrstrecke (m) einer Runde auf einem Rundkurs, solange die Strecke noch keine bekannte Laenge hat.
    raceMinLapM = 400,
    -- Zwischenzeiten alle raceSplitM Meter Fahrstrecke eines Laufs (0 = aus).
    raceSplitM = 500,
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
    -- Feste Byte-Klasse statt %c: %c haengt von der Spracheinstellung ab (macOS zaehlt dort Bytes von Emojis mit).
    return '"' .. s:gsub('[%z\1-\31\127"\\]', function(c)
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
local function placesDir() return C.sharedDir .. "/places" end
local function bansFile() return C.sharedDir .. "/bans.json" end
local function mutesFile() return C.sharedDir .. "/mutes.json" end
local function announcementsFile() return C.sharedDir .. "/announcements.json" end
local function eventFile() return C.sharedDir .. "/event.json" end
local function teamsFile() return C.sharedDir .. "/teams.json" end
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

-- ISO-Kalenderwoche (UTC), z. B. "2026-W42". Selbst berechnet: %G/%V gibt es unter Windows nicht.
local function weekKey(t)
    t = t or BN.now()
    local wday = (os.date("!*t", t).wday + 5) % 7 + 1          -- Montag = 1 … Sonntag = 7
    local thursday = os.date("!*t", t + (4 - wday) * 86400)    -- der Donnerstag bestimmt Jahr und Woche
    return string.format("%04d-W%02d", thursday.year, math.floor((thursday.yday - 1) / 7) + 1)
end
BN.weekKey = weekKey

-- Beginn (Montag 00:00 UTC) der ISO-Woche, in der t liegt.
local function weekStartAt(t)
    local day = math.floor(t / 86400)
    return (day - (day + 3) % 7) * 86400
end
BN.weekStartAt = weekStartAt

-- Beginn der Woche mit dem Schluessel week ("2026-W42"), gesucht rueckwaerts ab jetzt (hoechstens ein Jahr), sonst nil.
function BN.weekStartOf(week)
    local t = BN.now()
    for _ = 0, 53 do
        if weekKey(t) == week then return weekStartAt(t) end
        t = t - 7 * 86400
    end
    return nil
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

-- Werte, die ganze Zahlen sein muessen (z. B. "+40 XP" im Chat).
local INTEGER_KEYS = { challengeXp = true, raceFinishXp = true, racePersonalBestXp = true, raceRecordXp = true,
                       spamMessages = true, commandLimit = true, tickMs = true, raceTickMs = true, levelBase = true,
                       mapVoteSec = true, joinLimit = true, filterStrikes = true, weeklyTrackXp = true,
                       groupRaceDelaySec = true, maxFriends = true, friendCheckSec = true,
                       streakXp = true, streakMaxDays = true, jobXp = true, jobXpPerKm = true, jobCooldownSec = true, jobXpPerHour = true,
                       communityKm = true, communityXp = true, teamWeekXp = true, chaseJoinSec = true, chaseHeadStartSec = true,
                       chaseMaxSec = true, chaseXpCatch = true, chaseXpSurvive = true, chaseXpPerMin = true, chaseXpPerDay = true, chaseCooldownSec = true,
                       tipEverySec = true, tutorialXp = true, tutorialDoneXp = true, seriesXp = true,
                       alertEverySec = true, alertXp = true, alertMinPlayers = true, convoyXp = true,
                       convoyXpPerHour = true, convoyRadiusM = true, crowdHintSec = true, crowdMinPlayers = true,
                       crowdMaxHere = true, comebackDays = true, comebackXp = true, roadPointsMax = true, roadPointSpacingM = true, roadPointSec = true }
-- Untergrenzen, ohne die das Plugin nicht sinnvoll laeuft (Division durch 0, Dauertakt).
local MIN_VALUES = { roadPointSpacingM = 50, roadPointSec = 5, convoyKm = 0.5, convoyRadiusM = 20, levelBase = 1, tickMs = 100, raceTickMs = 50, maxSpeedMps = 1, saveEverySec = 5, commandWindowSec = 1,
                     spamWindowSec = 1, mapVoteSec = 15, joinLimit = 2, joinWindowSec = 10, joinBlockSec = 10,
                     filterStrikes = 1, filterMuteSec = 10, maxFriends = 1, friendCheckSec = 5,
                     streakMaxDays = 2, streakMinKm = 0.1, jobRadiusM = 5, jobMinDistM = 50,
                     chaseJoinSec = 5, chaseMaxSec = 30, chaseCatchM = 3 }

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
        elseif k == "badWords" then
            local ok = type(v) == "table" and #v <= 500
            if ok then for _, w in ipairs(v) do if type(w) ~= "string" or #w < 2 or #w > 40 then ok = false end end end
            if ok then C.badWords = v else print("[BeamNetCore] config.json: badWords ungueltig (Liste aus Woertern), Standard bleibt") end
        elseif k == "rules" then
            local ok = type(v) == "table" and #v <= 10
            if ok then for _, line in ipairs(v) do if type(line) ~= "string" or #line > 200 then ok = false end end end
            if ok then C.rules = v else print("[BeamNetCore] config.json: rules ungueltig (Liste aus Texten), Standard bleibt") end
        elseif defaults[k] ~= nil and type(v) == type(defaults[k]) and k ~= "sharedDir" then
            if type(v) == "number" then
                -- Keine negativen Werte; ganze Zahlen dort, wo sie im Chat mit %d ausgegeben werden.
                if v ~= v or v == math.huge or v == -math.huge then v = defaults[k] end
                v = math.max(MIN_VALUES[k] or 0, v)
                if INTEGER_KEYS[k] then v = math.floor(v) end
            end
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
    ["🏅 Team der Woche: %s (%s)"] = "🏅 Team of the week: %s (%s)",
    ["🏅 Dein Team %s war Team der Woche – danke fürs Mitfahren: +%d XP!"] = "🏅 Your team %s was team of the week – thanks for driving: +%d XP!",
    ["Wochensieger %s: %s"] = "Winners of %s: %s",
    ["KW %s"] = "week %s",
    ["%s – Lauf ungültig. Neuer Versuch: zurück zum Start von %s."] = "%s – run invalid. Try again: back to the start of %s.",
    ["Fahrzeug zurückgesetzt"] = "Vehicle reset",
    ["Sprung (Teleport)"] = "Jump (teleport)",
    ["Zeitlimit überschritten"] = "Time limit exceeded",
    ["Strecke abgekürzt"] = "Track cut short",
    ["Ziel! %s: %s"] = "Finish! %s: %s",
    ["Neuer Streckenrekord auf %s: %s mit %s!"] = "New track record on %s: %s with %s!",
    ["Persönliche Bestzeit! Platz %d von %d."] = "Personal best! Rank %d of %d.",
    ["+%d XP (nur für diese Sitzung)"] = "+%d XP (this session only)",
    ["Für einen neuen Versuch zurück zum Start – beenden mit /rennen stop."] = "For another try drive back to the start – quit with /race stop.",
    ["Am Start von %s. Los geht's, sobald du den Startbereich verlässt!"] = "At the start of %s. The clock starts when you leave the start area!",
    ["Zeit läuft! Ziel ist %.0f m entfernt."] = "Clock is running! The finish is %.0f m away.",
    ["Zwischenzeit %d: %s (%s)"] = "Split %d: %s (%s)",
    ["Zwischenzeit %d: %s (%s, Rekord %s)"] = "Split %d: %s (%s, record %s)",
    ["Zwischenzeit %d: %s (Rekord %s)"] = "Split %d: %s (record %s)",
    ["[Ansage] %s"] = "[Announcement] %s",
    ["Du bist noch %d s stummgeschaltet."] = "You are muted for another %d s.",
    ["Bitte nicht spammen – du bist %d s stummgeschaltet."] = "Please don't spam – you are muted for %d s.",
    ["BeamNet-Befehle:"] = "BeamNet commands:",
    ["Spielen: /heute · /auftrag · /rennen · /serie · /duell <Name> <Strecke> · /fangen · /konvoi · /aufgabe · /ziel · /vote"] =
        "Play: /today · /job · /race · /series · /duel <name> <track> · /chase · /convoy · /daily · /goal · /vote",
    ["☀️ Heute im BeamNet:"] = "☀️ Today on BeamNet:",
    ["👥 Team %s: %s diese Woche · Platz %s (/team woche)"] = "👥 Team %s: %s this week · rank %s (/team week)",
    ["Neue Erfolge: Entdecker und Pionier – fahr auf der Bonus-Map des Tages (/heute)"] =
        "New achievements: Explorer and Pioneer – drive on today's bonus map (/today)",
    ["Team der Woche: wer im besten Team mitfährt, bekommt +50 XP – /team woche"] =
        "Team of the week: drive for the best team and get +50 XP – /team week",
    ["Alles für heute auf einen Blick: /heute – Tagesaufgabe, XP-Abend, Bonus-Map, Wochenziel"] =
        "Everything for today at a glance: /today – daily challenge, XP evening, bonus map, weekly goal",
    -- Konvoi
    ["🚗🚗 Konvoi mit %s: %s zusammen gefahren – +%d XP"] = "🚗🚗 Convoy with %s: %s driven together – +%d XP",
    ["Konvoi: Stundenlimit für Konvoi-XP erreicht – zusammen fahren macht trotzdem Spaß!"] =
        "Convoy: hourly limit for convoy XP reached – driving together is still fun!",
    ["Der Konvoi-Bonus ist auf diesem Server aus."] = "The convoy bonus is off on this server.",
    ["Konvoi: fahr mit anderen Spielern (höchstens %d m Abstand) – je %s zusammen gibt es +%d XP (bis %d XP je Stunde)."] =
        "Convoy: drive with other players (at most %d m apart) – every %s together gives +%d XP (up to %d XP per hour).",
    ["Du: %s im Konvoi gefahren, nächster Bonus in %s."] = "You: %s driven in convoys, next bonus in %s.",
    ["In der Nähe: %s"] = "Nearby: %s",
    ["Gerade niemand in deiner Nähe – /server zeigt, wo was los ist."] = "Nobody near you right now – /server shows where players are.",
    ["Tipp: /konvoi – fahrt zusammen! Wer nah beieinander fährt, bekommt Bonus-XP."] =
        "Tip: /convoy – drive together! Driving close to each other gives bonus XP.",
    ["Konvoi: zusammen fahren gibt Bonus-XP – /konvoi"] = "Convoy: driving together gives bonus XP – /convoy",
    ["Schicht: mehrere Aufträge hintereinander bringen Bonus-XP – /auftrag"] =
        "Shift: several jobs in a row give bonus XP – /job",
    ["Aufträge auf jeder Map (Lieferpunkte) und Richtungshinweise unterwegs – /auftrag"] =
        "Jobs on every map (drop-off points) and direction hints on the way – /job",
    ["Neue Erfolge für Vielfahrer: 5000 km, 50 Stunden, 50 Rennen, 5 Streckenrekorde"] =
        "New achievements for regulars: 5000 km, 50 hours, 50 races, 5 track records",
    ["7 neue Erfolge für Aufträge, Verfolgungsjagden und Konvois – /erfolge"] =
        "7 new achievements for jobs, chases and convoys – /achievements",
    -- Serien
    ["Serie %s abgebrochen – mehr als 30 Minuten. Neuer Versuch: /serie %s"] = "Series %s cancelled – more than 30 minutes. Try again: /series %s",
    ["Serie %s: Teil %d von %d geschafft (bisher %s). Weiter: %s"] = "Series %s: part %d of %d done (so far %s). Next: %s",
    ["🏆 Neuer Serienrekord %s: %s in %s!"] = "🏆 New series record %s: %s in %s!",
    ["🏁 Serie %s geschafft: %s gesamt – +%d XP"] = "🏁 Series %s done: %s total – +%d XP",
    ["🏁 Serie %s geschafft: %s gesamt (deine Bestzeit: %s – Serien-XP gibt es einmal am Tag für eine deutlich bessere Bestzeit)"] =
        "🏁 Series %s done: %s total (your best: %s – series XP once a day for a clearly better personal best)",
    ["%s ist ein Befehl und kein Serienname – bitte einen anderen Namen."] = "%s is a command, not a series name – please pick another name.",
    ["Jede Strecke nur einmal pro Serie (%s doppelt)."] = "Each track only once per series (%s twice).",
    ["Mit gelöscht (Serien mit dieser Strecke): %s"] = "Also deleted (series using this track): %s",
    ["Noch keine Serien auf dieser Map. Admins: /serie neu <Name> <Strecke1> <Strecke2> …"] = "No series on this map yet. Admins: /series new <name> <track1> <track2> …",
    ["Serien auf dieser Map – starten mit /serie <Name>:"] = "Series on this map – start with /series <name>:",
    ["Du fährst gerade keine Serie."] = "You are not driving a series.",
    ["Serie abgebrochen."] = "Series cancelled.",
    ["Serien anlegen dürfen nur Admins."] = "Only admins can create series.",
    ["Aufruf: /serie neu <Name> <Strecke1> <Strecke2> … · /serie weg <Name>"] = "Usage: /series new <name> <track1> <track2> … · /series delete <name>",
    ["Die Serie %s gibt es nicht."] = "The series %s does not exist.",
    ["Serie %s gelöscht."] = "Series %s deleted.",
    ["Strecke \"%s\" gibt es auf dieser Map nicht (oder sie hat kein Ziel)."] = "Track \"%s\" does not exist on this map (or has no finish).",
    ["Eine Serie hat 2 bis 5 Strecken."] = "A series has 2 to 5 tracks.",
    ["Auf dieser Map gibt es schon 20 Serien."] = "This map already has 20 series.",
    ["Serie %s angelegt: %s"] = "Series %s created: %s",
    ["Die Serie \"%s\" gibt es auf dieser Map nicht. Liste: /serie"] = "The series \"%s\" does not exist on this map. List: /series",
    ["Erst das Gruppenrennen beenden."] = "Finish the group race first.",
    ["Serie %s: %s – Zeiten werden addiert, 30 Minuten Zeit."] = "Series %s: %s – times are added up, 30 minutes.",
    ["Du: /stats [Name] · /km · /erfolge · /liga · /saison · /top [km|xp|speed|auftraege|konvoi|jagd|woche]"] =
        "You: /stats [name] · /km · /achievements · /league · /season · /top [km|xp|speed|jobs|convoy|chase|week]",
    ["Netzwerk: /server · /wo <Name> · /freund <Name> · /team · /orte · /rekorde · /event"] =
        "Network: /server · /where <name> · /friend <name> · /team · /places · /records · /event",
    ["Sonst: /start · /regeln · /melden <Name> <Grund> · /lang en"] = "Other: /start · /rules · /report <name> <reason> · /lang de",
    ["Map-Abstimmungen sind ausgeschaltet."] = "Map votes are turned off.",
    ["Gerade läuft keine Abstimmung."] = "There is no vote right now.",
    ["Stimme gezählt."] = "Vote counted.",
    ["Abstimmung: %s – %d ja, %d nein, noch %d s. /vote ja oder /vote nein"] = "Vote: %s – %d yes, %d no, %d s left. /vote yes or /vote no",
    ["Map-Abstimmung ist auf diesem Netzwerk nicht eingerichtet (Admin: beamnet watch install)."] =
        "Map voting is not set up on this network (admin: beamnet watch install).",
    ["Map-Abstimmung: /vote map <Name> – möglich: %s"] = "Map vote: /vote map <name> – available: %s",
    ["Es läuft schon eine Abstimmung (%s)."] = "A vote is already running (%s).",
    ["Die Map wird gleich gewechselt."] = "The map is about to change.",
    ["Nächste Abstimmung in %s."] = "Next vote possible in %s.",
    ["Mehrdeutig: %s"] = "Ambiguous: %s",
    ["Unbekannte Map: %s. Möglich: %s"] = "Unknown map: %s. Available: %s",
    ["%s läuft hier bereits."] = "%s is already running here.",
    ["%s möchte auf %s wechseln (Neustart). Abstimmen: /vote ja oder /vote nein (%d s)"] =
        "%s wants to switch to %s (restart). Vote: /vote yes or /vote no (%d s)",
    ["Abstimmung angenommen (%d:%d): Wechsel auf %s – der Server startet in etwa einer Minute neu."] =
        "Vote passed (%d:%d): switching to %s – the server restarts in about a minute.",
    ["Abstimmung angenommen, aber der Auftrag konnte nicht gespeichert werden – bitte einem Admin melden."] =
        "Vote passed, but the request could not be saved – please tell an admin.",
    ["Abstimmung für %s abgelehnt (%d:%d)."] = "Vote for %s failed (%d:%d).",
    ["Der Map-Wechsel auf %s hat nicht geklappt – bitte einem Admin melden."] =
        "The switch to %s did not work – please tell an admin.",
    ["Admin: /kick · /ban <Name> [30m|2h|7d] [Grund] · /unban · /bans · /warn · /mute · /ansage · /ort neu <Typ> <Name> · /resetspeed"] =
        "Admin: /kick · /ban <name> [30m|2h|7d] [reason] · /unban · /bans · /warn · /mute · /announce · /place new <type> <name> · /resetspeed",
    ["Du bist %s gefahren (diese Woche %s)."] = "You have driven %s (this week %s).",
    ["Kein Spieler online mit dem Namen \"%s\"."] = "No player online named \"%s\".",
    ["%s: Level %d · Liga %s · %d XP · %s · %s Fahrzeit · Spitze %.0f km/h"] = "%s: level %d · %s league · %d XP · %s · %s driving · top speed %.0f km/h",
    ["Gast-Konto: Werte gelten nur für diese Sitzung (mit BeamMP-Konto werden sie gespeichert)."] =
        "Guest account: values only count for this session (they are saved with a BeamMP account).",
    ["Rang %s von %d · noch %d XP bis Level %d"] = "Rank %s of %d · %d XP to level %d",
    ["Noch keine Bestenliste – einfach losfahren!"] = "No leaderboard yet – just start driving!",
    ["Bestenliste %s:"] = "Leaderboard %s:",
    ["Kilometer"] = "kilometers",
    ["Höchstgeschwindigkeit"] = "top speed",
    ["Aufträge"] = "jobs",
    ["Kilometer im Konvoi"] = "kilometers in convoys",
    ["Gewonnene Verfolgungsjagden"] = "chases won",
    ["Kilometer diese Woche"] = "kilometers this week",
    ["Kilometer letzte Woche"] = "kilometers last week",
    ["%d XP (Level %d)"] = "%d XP (level %d)",
    ["Ligen (XP): %s"] = "Leagues (XP): %s",
    ["%s ab %d"] = "%s from %d",
    ["Du: %s mit %d XP – noch %d XP bis %s."] = "You: %s with %d XP – %d XP to %s.",
    ["Du: %s mit %d XP – höchste Liga erreicht!"] = "You: %s with %d XP – top league reached!",
    ["Keine Serverliste verfügbar."] = "No server list available.",
    ["BeamNet-Server (wechseln im BeamMP-Launcher):"] = "BeamNet servers (switch in the BeamMP launcher):",
    ["XP-Event: %s-fache XP bis %s Uhr! (gestartet von %s)"] = "XP event: %sx XP until %s! (started by %s)",
    ["Schön, dass du da bist, %s! Deine Kilometer und XP zählen auf allen BeamNet-Servern."] =
        "Great to have you, %s! Your kilometres and XP count on every BeamNet server.",
    ["%s ist zum ersten Mal im BeamNet – herzlich willkommen!"] = "%s is new to BeamNet – welcome!",
    ["Regeln:"] = "Rules:",
    ["Noch keine Teams. Gründen: /team gründen <Name>"] = "No teams yet. Create one: /team create <name>",
    ["Teams nach Kilometern:"] = "Teams by kilometres:",
    ["Teams gibt es nur mit BeamMP-Konto."] = "Teams need a BeamMP account.",
    ["Du bist in keinem Team. /team gründen <Name> · /team beitreten <Name> · /team liste"] =
        "You are not in a team. /team create <name> · /team join <name> · /team list",
    ["Team %s: %d Mitglieder · Platz %s · /team verlassen"] = "Team %s: %d members · rank %s · /team leave",
    ["Diese Woche: %s · Platz %s unter den Teams (/team woche)"] = "This week: %s · rank %s among the teams (/team week)",
    ["Teams diese Woche:"] = "Teams this week:",
    ["Diese Woche ist noch kein Team gefahren."] = "No team has driven this week yet.",
    ["Du bist in keinem Team."] = "You are not in a team.",
    ["Du hast das Team %s verlassen."] = "You left the team %s.",
    ["Du bist schon im Team %s – erst /team verlassen."] = "You are already in team %s – /team leave first.",
    ["Teamname: 3–20 Zeichen, Buchstaben, Ziffern, Leerzeichen, _ und -"] =
        "Team name: 3–20 characters, letters, digits, spaces, _ and -",
    ["Das Team %s gibt es schon – /team beitreten %s"] = "Team %s already exists – /team join %s",
    ["Es gibt schon zu viele Teams."] = "There are already too many teams.",
    ["%s hat das Team %s gegründet – mitmachen: /team beitreten %s"] = "%s founded the team %s – join: /team join %s",
    ["Das Team %s gibt es nicht. Liste: /team liste"] = "Team %s does not exist. List: /team list",
    ["Das Team %s ist voll (%d Mitglieder)."] = "Team %s is full (%d members).",
    ["Willkommen im Team %s!"] = "Welcome to team %s!",
    ["Aufruf: /team · /team gründen <Name> · /team beitreten <Name> · /team verlassen · /team liste"] =
        "Usage: /team · /team create <name> · /team join <name> · /team leave · /team list",
    ["Gruppenrennen auf %s beendet – niemand im Ziel."] = "Group race on %s over – nobody finished.",
    ["Gruppenrennen auf %s – Ergebnis: %s"] = "Group race on %s – result: %s",
    ["Platz %d im Gruppenrennen: +%d Bonus-XP!"] = "Place %d in the group race: +%d bonus XP!",
    ["Gruppenrennen %s: Start in %d s"] = "Group race %s: start in %d s",
    ["LOS! Gruppenrennen auf %s – die Zeit läuft ab dem Verlassen des Startbereichs."] =
        "GO! Group race on %s – your time starts when you leave the start area.",
    ["Du fährst mit! Fahr zum Start von %s – Start in %d s."] = "You're in! Drive to the start of %s – start in %d s.",
    ["Gruppenrennen: %s im Ziel – %s (vorläufig Platz %d)"] = "Group race: %s finished – %s (provisional place %d)",
    ["Fehlstart! Zurück in den Startbereich – Start in %d s."] = "False start! Back to the start area – start in %d s.",
    ["Aufruf: /rennen gruppe <Strecke> – die Strecke braucht ein Ziel. Liste: /rennen"] =
        "Usage: /race group <track> – the track needs a finish. List: /race",
    ["Es läuft schon ein Gruppenrennen auf %s – mitmachen: /rennen mit"] = "A group race on %s is already on – join: /race join",
    ["Gruppenrennen auf %s in %d s, gestartet von %s! Mitmachen: /rennen mit"] =
        "Group race on %s in %d s, started by %s! Join: /race join",
    ["Gerade kann man keinem Gruppenrennen beitreten. Neues: /rennen gruppe <Strecke>"] =
        "There is no group race to join right now. New one: /race group <track>",
    ["Strecke der Woche: %s auf %s – %d Bonus-XP für den ersten Lauf der Woche"] =
        "Track of the week: %s on %s – %d bonus XP for your first run this week",
    ["Strecke der Woche geschafft: +%d Bonus-XP!"] = "Track of the week done: +%d bonus XP!",
    ["Strecke der Woche auf dieser Map: %s – %d Bonus-XP (/rennen %s)"] = "Track of the week on this map: %s – %d bonus XP (/race %s)",
    ["Titel: %s"] = "Titles: %s",
    ["Saisonsieger %s"] = "Season champion %s",
    ["Saison-Zweiter %s"] = "Season runner-up %s",
    ["Saison-Dritter %s"] = "Season 3rd place %s",
    ["Bitte freundlich bleiben – du bist %d Minuten stummgeschaltet."] = "Please stay friendly – you are muted for %d minutes.",
    ["Bitte freundlich bleiben – deine Nachricht wurde nicht gesendet (%d/%d)."] =
        "Please stay friendly – your message was not sent (%d/%d).",
    ["Zu viele Verbindungsversuche – bitte in %d Minuten erneut versuchen."] =
        "Too many connection attempts – please try again in %d minutes.",
    ["Für dieses Netzwerk sind keine Regeln eingetragen."] = "No rules have been set for this network.",
    ["Fair fahren: kein absichtliches Rammen oder Blockieren."] = "Drive fair: no deliberate ramming or blocking.",
    ["Freundlich im Chat – keine Beleidigungen, kein Spam."] = "Be friendly in chat – no insults, no spam.",
    ["Den Anweisungen der Admins folgen."] = "Follow the admins' instructions.",
    ["Das XP-Event ist vorbei – danke fürs Mitfahren!"] = "The XP event is over – thanks for driving!",
    ["XP-Event läuft: %s-fache XP bis %s Uhr."] = "XP event running: %sx XP until %s.",
    ["Gerade läuft kein XP-Event."] = "No XP event right now.",
    ["Fahre heute %s km auf der Bonus-Map (/server)"] = "Drive %s km on today's bonus map (/server)",
    ["🗺️ Diese Map ist heute Bonus-Map: +%d %% XP beim Fahren!"] = "🗺️ This map is today's bonus map: +%d %% XP while driving!",
    ["🗺️ Bonus-Map heute: %s – +%d %% XP beim Fahren auf den Servern mit dieser Map (/server)."] =
        "🗺️ Bonus map today: %s – +%d %% XP while driving on servers with this map (/server).",
    ["Bonus-Map heute: %s (+%d %% XP beim Fahren)."] = "Bonus map today: %s (+%d %% XP while driving).",
    ["👋 Willkommen zurück! Du warst %d Tage weg – hier sind +%d XP zum Wiedereinstieg."] =
        "👋 Welcome back! You were away for %d days – here are +%d XP to get going again.",
    ["Nächster XP-Abend: %s %s–%s Uhr (%s-fache XP)"] = "Next XP evening: %s %s–%s (%sx XP)",
    ["heute"] = "today",
    ["Sonntag"] = "Sunday", ["Montag"] = "Monday", ["Dienstag"] = "Tuesday", ["Mittwoch"] = "Wednesday",
    ["Donnerstag"] = "Thursday", ["Freitag"] = "Friday", ["Samstag"] = "Saturday",
    ["XP-Event beendet."] = "XP event ended.",
    ["Event konnte nicht gespeichert werden."] = "Event could not be saved.",
    ["Aufruf: /event <Faktor 1,5–5> <Dauer, z. B. 2h oder 90m, höchstens 24h> · /event stop"] =
        "Usage: /event <factor 1.5–5> <duration, e.g. 2h or 90m, at most 24h> · /event stop",
    ["Aufruf: /melden <Name> <Grund> – geht an die Admins."] = "Usage: /report <name> <reason> – goes to the admins.",
    ["Bitte warte noch %d s bis zur nächsten Meldung."] = "Please wait %d s before your next report.",
    ["Meldung konnte nicht gespeichert werden – bitte einem Admin direkt schreiben."] =
        "Report could not be saved – please message an admin directly.",
    ["Meldung von %s über %s: %s"] = "Report from %s about %s: %s",
    ["Danke – deine Meldung über %s ist bei den Admins."] = "Thanks – your report about %s has been sent to the admins.",
    ["Aufruf: /wo <Name> – zeigt, auf welchem Server jemand gerade fährt."] =
        "Usage: /where <name> – shows which server someone is driving on.",
    ["Niemand mit „%s“ gerade im Netzwerk."] = "Nobody matching \"%s\" is in the network right now.",
    ["%s ist hier auf diesem Server."] = "%s is here on this server.",
    ["%s fährt auf %s (%s) · %s"] = "%s is driving on %s (%s) · %s",
    ["… und %d weitere – bitte genauer schreiben."] = "… and %d more – please be more specific.",
    ["Port %s"] = "port %s",
    [" (voll)"] = " (full)",
    [" ⭐ Bonus-Map"] = " ⭐ bonus map",
    ["👋 Auf %s (%s) fahren gerade %d Spieler – komm rüber! %s"] = "👋 %s (%s) has %d players right now – come over! %s",
    ["  ← hier"] = "  ← here",
    ["Auf %s gibt es noch keine Strecken."] = "No tracks on %s yet.",
    ["Strecken auf %s: %s"] = "Tracks on %s: %s",
    ["%s (ohne Ziel)"] = "%s (no finish)",
    ["%s (Rekord %s · %s)"] = "%s (record %s · %s)",
    ["%s (noch keine Zeit)"] = "%s (no time yet)",
    ["Starten: /rennen <Name> · gemeinsam: /rennen gruppe <Name> · beenden: /rennen stop · Rekorde: /rekorde <Name>"] =
        "Start: /race <name> · together: /race group <name> · quit: /race stop · records: /records <name>",
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
    ["Streckenlänge %.0f m (von dir gefahren) – deutlich kürzere Läufe sind ungültig."] =
        "Track length %.0f m (as you drove it) – runs that are much shorter are invalid.",
    ["Streckenlänge unbekannt – der erste gültige Lauf legt sie fest."] =
        "Track length unknown – the first valid run sets it.",
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
    ["Aufruf: /ansage [HH:MM] <Text> – erscheint auf allen BeamNet-Servern (mit Uhrzeit: dann)."] = "Usage: /announce [HH:MM] <text> – shown on all BeamNet servers (with a time: then).",
    ["Ansage geplant für %s Uhr: %s"] = "Announcement scheduled for %s: %s",
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
    ["50 Stunden unterwegs"] = "50 hours on the road",
    ["Fahre heute %s km auf einer Map"] = "Drive %s km on one map today",
    ["Erledige heute %s Aufträge (/auftrag)"] = "Finish %s jobs today (/job)",
    ["50 Rennen"] = "50 races",
    ["5 Streckenrekorde"] = "5 track records",
    ["Erster Auftrag"] = "First job",
    ["25 Aufträge"] = "25 jobs",
    ["Profi-Fahrer (100 Aufträge)"] = "Pro driver (100 jobs)",
    ["Erste Jagd gewonnen"] = "First chase won",
    ["Jagd-Legende (10 Jagden gewonnen)"] = "Chase legend (10 chases won)",
    ["Konvoi-Fahrer (10 km)"] = "Convoy driver (10 km)",
    ["Kolonnenführer (100 km im Konvoi)"] = "Convoy leader (100 km in convoys)",
    ["Entdecker (25 km auf Bonus-Maps)"] = "Explorer (25 km on bonus maps)",
    ["Pionier (100 km auf Bonus-Maps)"] = "Pioneer (100 km on bonus maps)",
    ["Bann konnte nicht gespeichert werden (%s) – bitte beamnet doctor prüfen."] = "Could not save the ban (%s) – please check beamnet doctor.",
    ["Willkommen auf %s (%s)! Level %d · Liga %s · %s gefahren. /hilfe für Befehle, /server für alle Server. English: /lang en"] =
        "Welcome to %s (%s)! Level %d · %s league · %s driven. /help for commands, /server for all servers. Deutsch: /lang de",
    ["Heute: %s (/aufgabe)"] = "Today: %s (/daily)",
    ["Sprache: Deutsch. English: /lang en"] = "Language: English. Deutsch: /lang de",
    ["Sprache auf Deutsch gestellt."] = "Language set to English.",
    ["Sprachen: /lang de · /lang en"] = "Languages: /lang de · /lang en",
    ["Dieser Teamname ist nicht erlaubt."] = "This team name is not allowed.",
    ["Ein neues Team kannst du erst in %d min gründen."] = "You can found a new team in %d min.",
    ["Teams gerade nicht verfügbar – bitte später noch einmal."] = "Teams are not available right now – please try again later.",
    ["Nur Admins können Teams löschen."] = "Only admins can delete teams.",
    ["Team %s gelöscht."] = "Team %s deleted.",
    ["Bitte warte noch %d s, bevor du wieder ein Gruppenrennen startest."] = "Please wait %d s before starting another group race.",
    ["Aufruf: /resetspeed <Name> – Spieler muss auf diesem Server online sein."] = "Usage: /resetspeed <name> – the player must be online on this server.",
    ["Höchstgeschwindigkeit von %s zurückgesetzt (war %d km/h)."] = "Top speed of %s reset (was %d km/h).",
    ["Deine Höchstgeschwindigkeit wurde von %s zurückgesetzt."] = "Your top speed was reset by %s.",
    -- Duell
    ["Duell auf %s beendet – nicht beide im Ziel, kein Sieger."] = "Duel on %s over – not both finished, no winner.",
    ["⚔️ Duell auf %s: %s gewinnt (%s) gegen %s (%s)!"] = "⚔️ Duel on %s: %s wins (%s) against %s (%s)!",
    ["Duell gewonnen: +%d Bonus-XP!"] = "Duel won: +%d bonus XP!",
    ["Gerade läuft ein Duell – da kann man nicht mitfahren."] = "A duel is running – you can't join it.",
    ["Keine offene Herausforderung."] = "No open challenge.",
    ["Gerade läuft schon ein Gruppenrennen – bitte gleich noch einmal herausfordern."] = "A group race is already running – please challenge again shortly.",
    ["Die Strecke %s gibt es nicht mehr."] = "The track %s no longer exists.",
    ["⚔️ %s nimmt dein Duell an! Strecke %s, Start in 15 s."] = "⚔️ %s accepts your duel! Track %s, start in 15 s.",
    ["⚔️ Duell gegen %s auf %s – Start in 15 s."] = "⚔️ Duel against %s on %s – start in 15 s.",
    ["%s hat dein Duell abgelehnt."] = "%s declined your duel.",
    ["Herausforderung abgelehnt."] = "Challenge declined.",
    ["Aufruf: /duell <Name> <Strecke> · annehmen: /duell ja · ablehnen: /duell nein"] = "Usage: /duel <name> <track> · accept: /duel yes · decline: /duel no",
    ["Gegen dich selbst geht kein Duell."] = "You can't duel yourself.",
    ["Bitte warte noch %d s vor der nächsten Herausforderung."] = "Please wait %d s before the next challenge.",
    ["Gerade läuft ein Gruppenrennen – danach geht's."] = "A group race is running – try again afterwards.",
    ["⚔️ %s fordert dich zum Duell auf %s heraus! Annehmen: /duell ja · ablehnen: /duell nein (60 s)"] =
        "⚔️ %s challenges you to a duel on %s! Accept: /duel yes · decline: /duel no (60 s)",
    ["Herausforderung an %s gesendet."] = "Challenge sent to %s.",
    ["Erst das laufende Rennen beenden (/rennen stop)."] = "Finish the current race first (/race stop).",
    ["Bitte warte noch %d s, bevor ihr wieder ein Rennen startet."] = "Please wait %d s before you start another race.",
    ["📅 Dein Rückblick %s: %d XP%s – neue Saison, neues Glück!"] = "📅 Your %s recap: %d XP%s – new season, new chances!",
    [" · Platz %d"] = " · rank %d",
    ["📅 Deine letzte Woche: %s%s – neue Woche, neue Kilometer! (/top vorwoche)"] =
        "📅 Your last week: %s%s – new week, new kilometres! (/top lastweek)",
    [" · Platz %d von %d"] = " · rank %d of %d",
    ["👑 %s ist jetzt Platz 1 der Bestenliste!"] = "👑 %s is now number 1 on the leaderboard!",
    ["📈 Du bist jetzt Platz %d der Bestenliste (vorher %d)!"] = "📈 You are now rank %d on the leaderboard (before %d)!",
    ["✨ Neu seit deinem letzten Besuch:"] = "✨ New since your last visit:",
    ["Freundesliste: /freund <Name> – Nachricht, wenn ein Freund online kommt"] = "Friend list: /friend <name> – get a message when a friend comes online",
    ["Fahraufträge: /auftrag – Patienten ins Krankenhaus, Kinder zur Schule, Taxi …"] = "Driving jobs: /job – patients to hospital, children to school, taxi …",
    ["Wochenziel für alle: /ziel – zusammen Kilometer sammeln, alle bekommen Bonus-XP"] = "Weekly goal for everyone: /goal – collect kilometers together, everyone gets bonus XP",
    ["Verfolgungsjagd: /fangen – einer flüchtet, alle jagen ihn"] = "Chase: /chase – one runs, everyone hunts them",
    ["Duell: /duell <Name> <Strecke> – Zeitrennen gegen einen Freund"] = "Duel: /duel <name> <track> – time trial against a friend",
    ["Rennserien: /serie – mehrere Strecken nacheinander, die Zeiten zählen zusammen"] = "Race series: /series – several tracks in a row, the times add up",
    ["Orte vorschlagen: /ort vorschlag krankenhaus <Name> – für neue Fahraufträge"] = "Suggest places: /place suggest hospital <name> – for new driving jobs",
    ["Einsatz-Alarm: ab und zu ein Ziel für alle – wer zuerst da ist, bekommt Bonus-XP"] = "Call-outs: now and then a target for everyone – first one there gets bonus XP",
    -- Einsteiger-Pfad
    ["Fahr deinen ersten Kilometer"] = "Drive your first kilometer",
    ["Erledige einen Auftrag: /auftrag"] = "Finish a job: /job",
    ["Beende ein Rennen: /rennen"] = "Finish a race: /race",
    ["Füge einen Freund hinzu: /freund <Name>"] = "Add a friend: /friend <name>",
    ["Erreiche Level 3"] = "Reach level 3",
    ["✅ Einsteiger-Schritt %d/%d geschafft (+%d XP). Nächster: %s"] = "✅ Starter step %d/%d done (+%d XP). Next: %s",
    ["🎓 Einsteiger-Pfad geschafft! +%d XP und noch einmal +%d XP obendrauf. Viel Spaß im BeamNet!"] =
        "🎓 Starter path complete! +%d XP and another +%d XP on top. Have fun in BeamNet!",
    ["Den Einsteiger-Pfad gibt es mit BeamMP-Konto."] = "The starter path needs a BeamMP account.",
    ["Du kennst dich schon aus – /hilfe zeigt alle Befehle."] = "You already know your way around – /help shows all commands.",
    ["Einsteiger-Pfad: %d von %d geschafft (je +%d XP, alle zusammen +%d XP extra)"] =
        "Starter path: %d of %d done (+%d XP each, +%d XP extra for all)",
    ["Einsteiger-Pfad %d/%d: %s (/start)"] = "Starter path %d/%d: %s (/start)",
    -- Einsatz-Alarm
    ["🚨 Notfall! Ein Patient muss sofort ins Krankenhaus %s"] = "🚨 Emergency! A patient has to get to %s hospital right now",
    ["🚨 Schulbus kaputt – die Kinder warten an der Schule %s"] = "🚨 School bus broke down – the children are waiting at %s school",
    ["🚨 Großeinsatz! Die Feuerwache %s braucht Verstärkung"] = "🚨 Major incident! %s fire station needs backup",
    ["🚨 Verfolgung! Die Polizei %s braucht Hilfe"] = "🚨 Pursuit! %s police need help",
    ["🚨 Brand an der Tankstelle %s!"] = "🚨 Fire at %s gas station!",
    ["🚨 Abschleppen! Ein Auto ist liegen geblieben bei der Werkstatt %s"] = "🚨 Tow job! A car broke down at %s garage",
    ["🚨 Einsatz bei %s!"] = "🚨 Call-out at %s!",
    [" – wer zuerst da ist, bekommt +%d XP (5 min)"] = " – first one there gets +%d XP (5 min)",
    ["Einsatz bei %s vorbei – niemand war schnell genug."] = "Call-out at %s over – nobody was fast enough.",
    ["🏆 %s war zuerst beim Einsatz %s (%s) – +%d XP!"] = "🏆 %s was first at the call-out %s (%s) – +%d XP!",
    -- Tipps
    ["Tipp: /auftrag – fahr einen Patienten ins Krankenhaus oder Kinder zur Schule und sammle XP."] =
        "Tip: /job – drive a patient to hospital or children to school and earn XP.",
    ["Tipp: /fangen – Verfolgungsjagd! Einer flüchtet, alle anderen jagen ihn."] = "Tip: /chase – one player runs, everyone else hunts them.",
    ["Tipp: /ziel – das Wochenziel für alle. Wer mitfährt, bekommt Bonus-XP."] = "Tip: /goal – the weekly goal for everyone. Join in for bonus XP.",
    ["Tipp: /freund <Name> – du bekommst Bescheid, sobald ein Freund online kommt."] = "Tip: /friend <name> – get a message when a friend comes online.",
    ["Tipp: /rennen – Zeitrennen auf dieser Map, gemeinsam mit /rennen gruppe <Strecke>."] = "Tip: /race – time trials on this map, together with /race group <track>.",
    ["Tipp: Jeden Tag ein Stück fahren lohnt sich – ab dem zweiten Tag in Folge gibt es Bonus-XP."] =
        "Tip: drive a little every day – from the second day in a row you get bonus XP.",
    ["Tipp: /aufgabe – die Tagesaufgabe mit Bonus-XP."] = "Tip: /daily – today's challenge with bonus XP.",
    ["Tipp: /vote map <Name> – stimmt für eine andere Map ab."] = "Tip: /vote map <name> – vote for another map.",
    ["Tipp: /team gründen <Name> – fahrt zusammen Kilometer für euer Team."] = "Tip: /team create <name> – drive kilometers together for your team.",
    -- Verfolgungsjagd
    ["🚓 Gefangen! (keine XP: zu kurz, zu wenig gefahren oder zu wenige Spieler mit Konto)"] =
        "🚓 Caught! (no XP: too short, too little driving or not enough players with an account)",
    ["🏁 Entkommen! (keine XP: zu wenig gefahren oder zu wenige Spieler mit Konto)"] =
        "🏁 Escaped! (no XP: too little driving or not enough players with an account)",
    ["Diese Jagd bringt keine XP (mindestens 2 Spieler mit BeamMP-Konto nötig)."] =
        "This chase gives no XP (at least 2 players with a BeamMP account needed).",
    ["Die nächste Verfolgungsjagd geht in %d s."] = "The next chase can start in %d s.",
    ["Verfolgungsjagd abgesagt – %s"] = "Chase cancelled – %s",
    ["🚓 Gefangen! +%d XP"] = "🚓 Caught! +%d XP",
    ["Du hast %d min durchgehalten: +%d XP"] = "You lasted %d min: +%d XP",
    ["🚓 Verfolgungsjagd vorbei: %s hat %s nach %s gefangen!"] = "🚓 Chase over: %s caught %s after %s!",
    ["🏁 Entkommen! +%d XP"] = "🏁 Escaped! +%d XP",
    ["🏁 Verfolgungsjagd vorbei: %s ist entkommen!"] = "🏁 Chase over: %s escaped!",
    ["Verfolgungsjagd beendet – %s"] = "Chase ended – %s",
    ["zu wenige Mitspieler"] = "not enough players",
    ["der Flüchtige ist weg"] = "the runner left",
    ["keine Jäger mehr"] = "no chasers left",
    ["von %s gestoppt"] = "stopped by %s",
    ["🏃 Du bist der Flüchtige! %d s Vorsprung – halte %s durch."] = "🏃 You are the runner! %d s head start – survive %s.",
    ["🚓 %s ist der Flüchtige! Los geht's in %d s – fang ihn (näher als %d m)."] =
        "🚓 %s is the runner! Go in %d s – catch them (closer than %d m).",
    ["Nächster Jäger: %s · noch %s"] = "Nearest chaser: %s · %s left",
    ["Flüchtiger %s: %s entfernt · noch %s"] = "Runner %s: %s away · %s left",
    ["Gerade läuft keine Verfolgungsjagd."] = "No chase running right now.",
    ["Nur der Starter oder ein Admin kann die Jagd beenden."] = "Only the starter or an admin can end the chase.",
    ["Gerade kann man keiner Verfolgungsjagd beitreten. Neue: /fangen"] = "You can't join a chase right now. New one: /chase",
    ["%s macht bei der Verfolgungsjagd mit."] = "%s joins the chase.",
    ["Anmeldung läuft noch %d s – mitmachen: /fangen mit"] = "Sign-up open for %d s – join: /chase join",
    ["Verfolgungsjagd läuft: Flüchtiger ist %s."] = "Chase running: the runner is %s.",
    ["Erst Rennen oder Auftrag beenden, dann gibt es eine Verfolgungsjagd."] = "Finish your race or job first, then start a chase.",
    ["Bitte warte noch %d s, bevor du wieder eine Verfolgungsjagd startest."] = "Please wait %d s before starting another chase.",
    ["🚓 Verfolgungsjagd! %s startet in %d s – mitmachen: /fangen mit"] = "🚓 Chase! %s starts in %d s – join: /chase join",
    -- Wochenziel
    ["🎉 Wochenziel geschafft: zusammen %s! Alle mit mindestens %s diese Woche bekommen +%d XP."] =
        "🎉 Weekly goal reached: %s together! Everyone with at least %s this week gets +%d XP.",
    ["🎉 Danke fürs Mitfahren beim Wochenziel: +%d XP!"] = "🎉 Thanks for helping with the weekly goal: +%d XP!",
    ["Wochenziel für alle: %s von %s %s (%d %%)"] = "Weekly goal for everyone: %s of %s %s (%d %%)",
    ["Dein Beitrag: %s – Belohnung schon bekommen."] = "Your share: %s – reward already received.",
    ["Dein Beitrag: %s – du bist dabei: +%d XP, sobald das Ziel erreicht ist."] = "Your share: %s – you're in: +%d XP once the goal is reached.",
    ["Dein Beitrag: %s – ab %s bist du dabei (+%d XP, wenn das Ziel erreicht ist)."] =
        "Your share: %s – from %s you're in (+%d XP when the goal is reached).",
    ["Wochenziel für alle: %s von %s – fahr mit! (/ziel)"] = "Weekly goal for everyone: %s of %s – join in! (/goal)",
    -- Auftraege
    ["Notfall bei %s! Hol den Patienten ab und bring ihn ins Krankenhaus %s"] = "Emergency at %s! Pick up the patient and take them to %s hospital",
    ["Schulbus: Hol die Kinder bei %s ab und bring sie zur Schule %s"] = "School bus: pick up the children at %s and take them to %s school",
    ["Taxi: Ein Fahrgast wartet bei %s und muss zum Bahnhof %s"] = "Taxi: a passenger is waiting at %s and needs to get to %s station",
    ["Taxi: Ein Fahrgast wartet bei %s und muss zum Flughafen %s"] = "Taxi: a passenger is waiting at %s and needs to get to %s airport",
    ["Taxi: Ein Gast wartet bei %s und möchte zum Hotel %s"] = "Taxi: a guest is waiting at %s and wants to go to %s hotel",
    ["Eingestiegen! Weiter nach %s – %s, noch %s"] = "Picked up! Now on to %s – %s, %s left",
    ["Nächster Auftrag in %d s."] = "Next job in %d s.",
    ["Sprung erkannt – der Auftrag nach %s ist abgebrochen. Neuer: /auftrag"] = "Jump detected – the job to %s is cancelled. New one: /job",
    ["Stundenlimit für Auftrags-XP erreicht – weitere Aufträge zählen, bringen aber erst später wieder XP."] =
        "Hourly job XP limit reached – further jobs count but only give XP again later.",
    ["Notfall! Bring den Patienten ins Krankenhaus %s"] = "Emergency! Take the patient to %s hospital",
    ["Schulbus: Bring die Kinder zur Schule %s"] = "School bus: take the children to %s school",
    ["Alarm! Bring die Ausrüstung zur Feuerwache %s"] = "Alarm! Take the equipment to %s fire station",
    ["Bring den Verdächtigen zur Polizei %s"] = "Take the suspect to %s police station",
    ["Liefere Benzin an die Tankstelle %s"] = "Deliver fuel to %s gas station",
    ["Bring die Ersatzteile zur Werkstatt %s"] = "Take the spare parts to %s garage",
    ["Liefere die Ware an den Supermarkt %s"] = "Deliver the goods to %s supermarket",
    ["Taxi: Bring den Fahrgast zum Bahnhof %s"] = "Taxi: take the passenger to %s station",
    ["Taxi: Der Fahrgast muss zum Flughafen %s"] = "Taxi: the passenger needs to get to %s airport",
    ["Bring die Fracht zum Hafen %s"] = "Take the cargo to %s harbor",
    ["Taxi: Bring den Gast zum Hotel %s"] = "Taxi: take the guest to %s hotel",
    ["Liefere das Paket nach %s"] = "Deliver the parcel to %s",
    ["Nur Admins legen Orte an – du kannst einen vorschlagen: /ort vorschlag <Typ> <Name>"] =
        "Only admins create places – you can suggest one: /place suggest <type> <name>",
    ["Vorschläge gibt es nur mit BeamMP-Konto."] = "Suggestions need a BeamMP account.",
    ["Aufruf: /ort vorschlag <Typ> <Name> – z. B. /ort vorschlag krankenhaus St. Marien"] = "Usage: /place suggest <type> <name> – e.g. /place suggest hospital St. Mary",
    ["Bitte warte noch %d min mit dem nächsten Vorschlag."] = "Please wait %d min before your next suggestion.",
    ["Es gibt schon viele offene Vorschläge – die Admins schauen sie sich an."] = "There are already many open suggestions – the admins will look at them.",
    ["Danke! Dein Vorschlag %s (%s) ist bei den Admins."] = "Thanks! Your suggestion %s (%s) went to the admins.",
    ["📍 %s schlägt einen Ort vor: %s %s – /ort vorschlaege"] = "📍 %s suggests a place: %s %s – /place suggestions",
    ["Keine offenen Vorschläge."] = "No open suggestions.",
    ["Vorschläge (annehmen: /ort annehmen <Nr> · ablehnen: /ort ablehnen <Nr>):"] = "Suggestions (accept: /place accept <no> · reject: /place reject <no>):",
    ["Aufruf: /ort %s <Nr> – Liste: /ort vorschlaege"] = "Usage: /place %s <no> – list: /place suggestions",
    ["Den Ort %s gibt es schon – Vorschlag entfernt."] = "The place %s already exists – suggestion removed.",
    ["%s %s ist jetzt ein Ort für Aufträge."] = "%s %s is now a place for jobs.",
    ["Dein Vorschlag %s wurde angenommen – danke!"] = "Your suggestion %s was accepted – thanks!",
    ["Vorschlag %s abgelehnt."] = "Suggestion %s rejected.",
    ["Die Orte-Datei dieser Map ist kaputt oder nicht lesbar – nichts geändert (beamnet doctor)."] =
        "The places file of this map is broken or unreadable – nothing changed (beamnet doctor).",
    ["Die Vorschlags-Datei dieser Map ist kaputt oder nicht lesbar – nichts geändert (beamnet doctor)."] =
        "The suggestions file of this map is broken or unreadable – nothing changed (beamnet doctor).",
    ["Aufruf: /ort neu <Typ> <Name> – Typen: %s"] = "Usage: /place new <type> <name> – types: %s",
    ["Keine Position – bitte erst mit einem Fahrzeug an den Ort fahren."] = "No position – please drive to the place with a vehicle first.",
    ["Den Ort %s gibt es schon (löschen: /ort weg %s)."] = "The place %s already exists (delete: /place remove %s).",
    ["Auf dieser Map gibt es schon %d Orte."] = "This map already has %d places.",
    ["Speichern fehlgeschlagen – bitte beamnet doctor prüfen."] = "Saving failed – please check beamnet doctor.",
    ["%s %s angelegt (%s). Spieler fahren jetzt mit /auftrag hierher."] = "%s %s created (%s). Players now drive here with /job.",
    ["Ort %s gelöscht."] = "Place %s deleted.",
    ["Den Ort „%s“ gibt es auf dieser Map nicht."] = "There is no place \"%s\" on this map.",
    ["Aufruf: /ort neu <Typ> <Name> · /ort weg <Name> · /orte"] = "Usage: /place new <type> <name> · /place remove <name> · /places",
    ["Noch keine Orte auf dieser Map. Admins legen sie an: /ort neu krankenhaus <Name> – oder schlag einen vor: /ort vorschlag krankenhaus <Name>"] =
        "No places on this map yet. Admins create them: /place new hospital <name> – or suggest one: /place suggest hospital <name>",
    ["Orte auf dieser Map (%d) – Auftrag holen: /auftrag"] = "Places on this map (%d) – get a job: /job",
    ["… und %d weitere"] = "… and %d more",
    ["Steig erst in ein Fahrzeug, dann gibt es einen Auftrag."] = "Get into a vehicle first, then you get a job.",
    ["Gerade kein Auftrag frei – auf dieser Map fehlen Orte (Admins: /ort neu krankenhaus <Name>)."] =
        "No job available – this map has no places yet (admins: /place new hospital <name>).",
    ["Angekommen – aber ohne die Strecke zu fahren zählt der Auftrag nicht."] = "Arrived – but the job only counts if you actually drive there.",
    ["✅ Auftrag erledigt: %s in %s – +%d XP%s. Nächster: /auftrag"] = "✅ Job done: %s in %s – +%d XP%s. Next: /job",
    [" (Blitzschnell! +50 %)"] = " (lightning fast! +50 %)",
    ["⌛ Zu spät – der Auftrag nach %s ist verfallen. Neuer Versuch: /auftrag"] = "⌛ Too late – the job to %s has expired. Try again: /job",
    ["Noch %s bis %s · %s übrig"] = "%s to %s · %s left",
    ["Noch %s bis %s (%s) · %s übrig"] = "%s to %s (%s) · %s left",
    ["Lieferpunkt %d"] = "drop-off point %d",
    ["geradeaus"] = "straight ahead",
    ["hinter dir"] = "behind you",
    ["halb links"] = "half left",
    ["halb rechts"] = "half right",
    ["links"] = "left",
    ["rechts"] = "right",
    ["hinten links"] = "behind left",
    ["hinten rechts"] = "behind right",
    ["Du hast gerade keinen Auftrag."] = "You don't have a job right now.",
    ["Auftrag abgebrochen. Neuer: /auftrag"] = "Job cancelled. New one: /job",
    ["Dein Auftrag: %s · noch %s · %s übrig"] = "Your job: %s · %s to go · %s left",
    ["🔥 Schicht: %d Aufträge in Folge – +%d Bonus-XP!"] = "🔥 Shift: %d jobs in a row – +%d bonus XP!",
    ["Schicht läuft: 2 Aufträge in Folge – beim 3. gibt es Bonus-XP (nächsten innerhalb von 3 min annehmen)."] =
        "Shift running: 2 jobs in a row – the 3rd gives bonus XP (take the next one within 3 min).",
    ["Schicht: %d Aufträge in Folge – dieser wäre der %d."] = "Shift: %d jobs in a row – this one would be number %d.",
    ["Erst das Rennen beenden (/rennen stop), dann gibt es einen Auftrag."] = "Finish the race first (/race stop), then you get a job.",
    ["Aufträge erledigt: %d"] = "Jobs done: %d",
    -- Freunde
    ["hier"] = "here",
    [" · und %d weitere"] = " · and %d more",
    ["👋 Dein Freund %s ist jetzt online: %s · %s"] = "👋 Your friend %s is now online: %s · %s",
    ["👥 Dein Teamkollege %s ist jetzt online: %s · %s"] = "👥 Your teammate %s is now online: %s · %s",
    ["👥 Dein Teamkollege %s ist gerade auf diesen Server gekommen."] = "👥 Your teammate %s just joined this server.",
    ["👋 Dein Freund %s ist gerade auf diesen Server gekommen."] = "👋 Your friend %s just joined this server.",
    ["Freunde gibt es nur mit BeamMP-Konto."] = "Friends need a BeamMP account.",
    ["Noch keine Freunde. /freund <Name> fügt jemanden hinzu – du bekommst dann Bescheid, wenn er online kommt."] =
        "No friends yet. /friend <name> adds someone – you get a message when they come online.",
    ["Deine Freunde: %d · online: %d"] = "Your friends: %d · online: %d",
    ["Offline: %s"] = "Offline: %s",
    ["Aufruf: /freund weg <Name>"] = "Usage: /friend remove <name>",
    ["Mehrere Freunde passen zu „%s“ – bitte genauer schreiben."] = "Several friends match \"%s\" – please be more specific.",
    ["„%s“ ist nicht in deiner Freundesliste."] = "\"%s\" is not on your friend list.",
    ["%s ist nicht mehr in deiner Freundesliste."] = "%s is no longer on your friend list.",
    ["Aufruf: /freund <Name> · /freund weg <Name> · /freund"] = "Usage: /friend <name> · /friend remove <name> · /friend",
    ["Deine Freundesliste ist voll (%d). Entferne erst jemanden mit /freund weg <Name>."] =
        "Your friend list is full (%d). Remove someone first with /friend remove <name>.",
    ["Mehrere Spieler passen zu „%s“ – bitte genauer schreiben."] = "Several players match \"%s\" – please be more specific.",
    ["Keinen Spieler „%s“ gefunden (er muss online sein oder schon einmal gefahren sein)."] =
        "No player \"%s\" found (they must be online or have driven here before).",
    ["Dich selbst brauchst du nicht als Freund. 😉"] = "You don't need to add yourself. 😉",
    ["%s ist schon in deiner Freundesliste."] = "%s is already on your friend list.",
    ["%s ist jetzt in deiner Freundesliste – du bekommst Bescheid, wenn er online kommt."] =
        "%s is now on your friend list – you get a message when they come online.",
    ["Freunde online: %s"] = "Friends online: %s",
    ["🔥 %d Tage in Folge gefahren – +%d Bonus-XP! Morgen wieder fahren hält die Serie."] =
        "🔥 %d days in a row – +%d bonus XP! Drive again tomorrow to keep the streak.",
    ["Serie: %d Tage in Folge (beste: %d)"] = "Streak: %d days in a row (best: %d)",
    ["🔥 Deine Serie: %d Tage – fahr heute %s, dann gibt es +%d Bonus-XP."] =
        "🔥 Your streak: %d days – drive %s today for +%d bonus XP.",
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
             dayKm = 0, daySeconds = 0, dayRaces = 0, dayTop = 0, dayMaps = {}, mapKm = {}, lastMonthXp = 0, lastWeekKm = 0,
             firstSeen = BN.now(), lastSeen = BN.now(), lastServer = "" }
end

-- Ergaenzt fehlende oder kaputte Felder: alte Dateien und Sitzungen aus einer aelteren Plugin-Version
-- (Update im laufenden Betrieb) bekommen so alles, was die neue Version erwartet.
local function normalizeRecord(rec, id, name)
    rec.id = id or rec.id
    rec.name = name or rec.name
    for _, k in ipairs({ "km", "seconds", "weekKm", "topSpeedKmh", "bonusXp", "racesFinished", "recordsSet",
                         "dayKm", "daySeconds", "dayRaces", "dayTop", "lastMonthXp", "lastWeekKm", "streak", "bestStreak", "jobsDone", "dayJobs", "weekJobs",
                         "convoyKm", "chaseWins", "bonusMapKm" }) do
        rec[k] = tonumber(rec[k]) or 0
    end
    for _, k in ipairs({ "maps", "achievements", "dayMaps", "mapKm", "dayMapKm" }) do
        if type(rec[k]) ~= "table" then rec[k] = {} end
    end
    for m, v in pairs(rec.mapKm) do rec.mapKm[m] = tonumber(v) or nil end
    rec.day = tonumber(rec.day)
    rec.lastChallengeDay = tonumber(rec.lastChallengeDay)
    rec.streakDay = tonumber(rec.streakDay)
    -- Bis 1.8 gab es nur dayDone (bezogen auf rec.day).
    if rec.lastChallengeDay == nil and rec.dayDone == true and rec.day then rec.lastChallengeDay = rec.day end
    rec.dayDone = rec.day ~= nil and rec.lastChallengeDay == rec.day
    rec.monthXp = tonumber(rec.monthXp)
    rec.monthStartXp = tonumber(rec.monthStartXp)
    rec.week = rec.week or weekKey(BN.now())
    -- Freunde: Liste aus { id, name }; alles andere (auch aus einer manipulierten Datei) faellt weg.
    local friends, seen = {}, {}
    if type(rec.friends) == "table" then
        for _, f in ipairs(rec.friends) do
            local fid = type(f) == "table" and safeId(f.id)
            if fid and not seen[fid] and fid ~= rec.id and #friends < 100 then
                seen[fid] = true
                friends[#friends + 1] = { id = fid, name = tostring(f.name or "?"):sub(1, 64) }
            end
        end
    end
    rec.friends = friends
    return rec
end
BN.normalizeRecord = normalizeRecord

-- Liest die Spielerdatei. Fehlt sie, beginnt ein neuer Datensatz. Kann sie nicht gelesen werden (Rechte, zu viele
-- offene Dateien ...), gibt es nil und den Fehler: dann darf nichts gespeichert werden, sonst wuerde die echte Datei
-- mit einem leeren Datensatz ueberschrieben. Ist sie kein gueltiges JSON, wird sie einmal als <id>.json.kaputt-<Zeit>
-- beiseitegelegt (endet nicht auf .json, taucht also in keiner Liste auf) und neu begonnen – sonst kaeme der Spieler
-- nie wieder zum Speichern.
local ENOENT = 2
local function loadRecord(id, name)
    local path = playersDir() .. "/" .. id .. ".json"
    local f, openErr, code = io.open(path, "rb")
    if not f then
        if code == ENOENT then
            local rec = normalizeRecord(emptyRecord(id, name), id, name)
            BN.lastLoadWasNew = true            -- erster Besuch im Netzwerk (fuer die Begruessung)
            return rec
        end
        return nil, openErr or "nicht lesbar"
    end
    local data, readErr = f:read("*a")
    f:close()
    if not data then return nil, readErr or "Lesefehler" end
    local rec = json.decode(data)
    if type(rec) ~= "table" then
        local backup = path .. ".kaputt-" .. tostring(BN.now())
        local moved, moveErr = os.rename(path, backup)
        if not moved then return nil, "kaputte Datei nicht beiseitegelegt: " .. tostring(moveErr) end
        print("[BeamNetCore] Kaputte Spielerdatei beiseitegelegt: " .. backup)
        rec = emptyRecord(id, name)
    end
    return normalizeRecord(rec, id, name)
end

-- Datensatz fuer eine Sitzung: ist die Datei gerade nicht lesbar, zunaechst ein leerer (savePlayer liest ohnehin neu
-- und speichert erst, wenn die Datei wieder lesbar ist).
local function sessionRecord(id, name)
    if not id then return emptyRecord(nil, name) end
    local rec, err = loadRecord(id, name)
    if rec then return rec end
    BN.logError("Spielerdatei " .. id, err)
    return emptyRecord(id, name)
end

local function xpOf(rec)
    return BN.xpFor(rec.km or 0, rec.seconds or 0) + (rec.bonusXp or 0)
end

-- Tag seit 1970 (UTC) – fuer die Tagesaufgabe.
local function dayNumber(t)
    return math.floor((t or BN.now()) / 86400)
end
BN.dayNumber = dayNumber

-- Neue Saison (Monat): die XP der alten Saison bleiben als lastMonth/lastMonthXp erhalten, der Zaehler monthXp
-- beginnt bei 0. monthXp waechst nur um echte Zuwaechse (siehe savePlayer). Bis 1.8 gab es stattdessen den
-- Startwert monthStartXp – solche Datensaetze werden hier umgestellt.
function BN.applyMonth(rec)
    local cur = monthKey()
    if rec.month == cur and rec.monthXp then return end
    local gained = tonumber(rec.monthXp)
    if not gained and tonumber(rec.monthStartXp) then gained = math.max(0, xpOf(rec) - rec.monthStartXp) end
    if rec.month == cur then
        rec.monthXp = gained or 0
    else
        if rec.month then
            rec.lastMonth = rec.month
            rec.lastMonthXp = gained or 0
        end
        rec.month = cur
        rec.monthXp = 0
    end
    rec.monthStartXp = nil
end

-- Neuer Tag: Tageszaehler zuruecksetzen.
local function applyDay(rec)
    local today = dayNumber()
    if rec.day ~= today then
        rec.day = today
        rec.dayKm, rec.daySeconds, rec.dayRaces, rec.dayTop, rec.dayJobs = 0, 0, 0, 0, 0
        rec.dayMaps = {}
        rec.dayMapKm = {}
    end
    rec.dayDone = rec.lastChallengeDay == rec.day
end
BN.applyDay = applyDay

-- Wochenwechsel: Kilometer der alten Woche bleiben als lastWeek/lastWeekKm erhalten (fuer die Wochensieger) und kommen
-- in den Verlauf weeks (hoechstens 12 Wochen, fuer das Diagramm auf der Profilseite; nur Wochen mit Kilometern).
local function applyWeek(rec)
    local wk = weekKey(BN.now())
    if rec.week ~= wk then
        local km = tonumber(rec.weekKm) or 0
        if type(rec.week) == "string" and rec.week ~= "" and km > 0 then
            if type(rec.weeks) ~= "table" then rec.weeks = {} end
            rec.weeks[#rec.weeks + 1] = { week = rec.week, km = math.floor(km * 10 + 0.5) / 10 }
            while #rec.weeks > 12 do table.remove(rec.weeks, 1) end
        end
        rec.lastWeek = rec.week
        rec.lastWeekKm = km
        rec.lastWeekJobs = tonumber(rec.weekJobs) or 0
        rec.week = wk
        rec.weekKm = 0
        rec.weekJobs = 0
    end
end
BN.applyWeek = applyWeek

-- Hat der Spieler in dieser Sitzung auf dieser Map wirklich etwas gefahren? (Nur dann zaehlt die Map –
-- kurz vorbeischauen reicht nicht fuer Erfolge und die Tagesaufgabe "verschiedene Server".)
local function currentMap(s)
    local map = BN.server.map
    if map and map ~= "?" and (s.sessionKm or 0) >= C.mapMinKm then return map end
    return nil
end

-- Ergaenzt Felder, die eine aeltere Plugin-Version in laufenden Sitzungen noch nicht angelegt hat.
function BN.normalizeSession(s)
    if type(s.vehicles) ~= "table" then s.vehicles = {} end
    if type(s.moved) ~= "table" then s.moved = {} end
    for _, k in ipairs({ "pendingKm", "pendingSeconds", "pendingTop", "pendingBonus", "pendingRaces", "pendingRecords",
                         "sessionKm", "pendingJobs", "pendingEventXp", "pendingChaseWins", "pendingConvoyKm",
                         "pendingBonusMapKm" }) do
        s[k] = tonumber(s[k]) or 0
    end
    if type(s.unlocked) ~= "table" then s.unlocked = {} end
    for id, u in pairs(s.unlocked) do
        -- Bis 1.8 stand hier nur der Zeitpunkt; die XP steckten schon in pendingBonus.
        if type(u) ~= "table" then s.unlocked[id] = { at = tonumber(u) or BN.now(), xp = 0 } end
    end
    if s.challengeDoneDay and not s.challengeReward then
        s.challengeReward = { day = s.challengeDoneDay, xp = 0 }     -- XP stecken ebenfalls schon in pendingBonus
    end
    s.challengeDoneDay = nil
    if s.achChecked == nil then s.achChecked = true end
    -- Update im laufenden Betrieb: neue Erfolge fuer frueheren Fortschritt gelten als nachtraeglich (keine Saison-XP).
    if s.achVersion ~= BN.VERSION then s.achChecked, s.achVersion = false, BN.VERSION end
    if type(s.record) ~= "table" then s.record = sessionRecord(s.id, s.name) end
    normalizeRecord(s.record, s.id, s.name)
    applyWeek(s.record)
    BN.applyMonth(s.record)
    return s
end

-- Laufende Tages-Serie: zaehlt nur, wenn zuletzt heute oder gestern gefahren wurde.
function BN.streakOf(rec)
    local day = tonumber(rec and rec.streakDay)
    if not day or day < dayNumber() - 1 then return 0 end
    return tonumber(rec.streak) or 0
end

-- Neue Sitzung (Join oder Plugin-Neustart mit Spielern online).
function BN.addPlayer(pid)
    local name = (MP and MP.GetPlayerName and MP.GetPlayerName(pid)) or ("Spieler " .. tostring(pid))
    local ids = identifiers(pid)
    local id = safeId(ids.beammp)
    -- achChecked = false: was bei der ersten Pruefung schon erreicht ist, wird nachtraeglich vergeben.
    local session = { pid = pid, name = name, id = id, ip = ids.ip, guest = id == nil, achChecked = false,
                      achVersion = BN.VERSION }
    BN.lastLoadWasNew = false
    session.record = sessionRecord(id, name)
    session.isNew = id ~= nil and BN.lastLoadWasNew
    BN.lastLoadWasNew = false
    if session.isNew then session.dirty = true end      -- Datei sofort anlegen: beim naechsten Mal nicht mehr "neu"
    BN.normalizeSession(session)
    if session.record.lang == "en" or session.record.lang == "de" then session.lang = session.record.lang end
    local mute = BN.findMute(id, ids.ip)
    if mute then session.mutedUntil = mute["until"] end
    local xp = xpOf(session.record)
    session.level = BN.levelFor(xp)
    session.league = BN.leagueFor(xp).name
    session.leagueXp = tonumber(BN.leagueFor(xp).xp) or 0
    BN.players[pid] = session
    return session
end

local function session(pid)
    return BN.players[pid] or BN.addPlayer(pid)
end

-- Uebernimmt die seit dem letzten Aufruf gefahrene Strecke (BN.track sammelt sie je Fahrzeug in s.moved). Gezaehlt
-- wird nur das Fahrzeug mit der groessten Strecke: Lkw mit Anhaenger oder mehrere Fahrzeuge zaehlen nicht mehrfach.
-- XP-Event: Zusatz-XP genau fuer das, was waehrend des Events gefahren wird (nicht erst beim Speichern berechnet).
-- Bonus-Map des Tages (bonusmap.json vom Waechter): { map, factor, until } oder nil; hoechstens einmal je Minute gelesen.
function BN.bonusMap()
    local now = BN.now()
    if not BN.bonusMapAt or now - BN.bonusMapAt >= 60 then
        BN.bonusMapAt = now
        local d = json.decode(readFile(C.sharedDir .. "/bonusmap.json") or "")
        local f, u = type(d) == "table" and tonumber(d.factor), type(d) == "table" and tonumber(d["until"])
        BN.bonusMapData = (type(d) == "table" and type(d.map) == "string" and d.map:match("^[%w_.-]+$") and f and f > 1
            and f <= 3 and u) and { map = d.map, factor = f, ["until"] = u } or nil
    end
    local b = BN.bonusMapData
    if b and b["until"] > now then return b end
    return nil
end

-- Faktor der Bonus-Map, wenn dieser Server sie gerade faehrt (sonst nil).
function BN.bonusMapFactorHere()
    local b = BN.bonusMap()
    if b and BN.server.map == b.map then return b.factor end
    return nil
end

function BN.eventGain(s, xp)
    local ev = BN.activeEvent and BN.activeEvent()
    if ev then s.pendingEventXp = (tonumber(s.pendingEventXp) or 0) + xp * (ev.factor - 1) end
    local bf = BN.bonusMapFactorHere()
    if bf then s.pendingEventXp = (tonumber(s.pendingEventXp) or 0) + xp * (bf - 1) end
end

local function flushMoved(s)
    if type(s.moved) ~= "table" then s.moved = {} return 0 end
    local best, bestVid = 0, nil
    for vid, d in pairs(s.moved) do
        if d > best then best, bestVid = d, vid end
    end
    s.moved = {}
    s.tickVid = bestVid
    if best > 0 then
        BN.eventGain(s, best / 1000 * C.xpPerKm)
        -- Kilometer auf der Bonus-Map des Tages (Erfolge "Entdecker"/"Pionier").
        if BN.bonusMapFactorHere() then s.pendingBonusMapKm = (tonumber(s.pendingBonusMapKm) or 0) + best / 1000 end
        s.pendingKm = s.pendingKm + best / 1000
        s.sessionKm = s.sessionKm + best / 1000
        s.lastMoveAt = BN.now()
        -- Neue Strecke eines Admins: gefahrene Laenge zwischen /rennen neu und /rennen ziel
        if s.trackDraft then s.trackDraft.dist = s.trackDraft.dist + best end
    end
    return best
end
BN.flushMoved = flushMoved

-- Erfolge und Tagesaufgabe, die die Datei noch nicht kennt: XP gesamt und davon nachtraeglich vergebene XP.
local function pendingRewards(s)
    local rec, xp, retro = s.record, 0, 0
    for id, u in pairs(s.unlocked) do
        if not rec.achievements[id] then
            xp = xp + (u.xp or 0)
            if u.retro then retro = retro + (u.xp or 0) end
        end
    end
    local cr = s.challengeReward
    if cr and (rec.lastChallengeDay or -1) < cr.day then xp = xp + (cr.xp or 0) end
    return xp, retro
end

-- Meilensteine fuer Discord/Telegram (beim Speichern erkannt, siehe BN.savePlayer).
BN.LEVEL_MILESTONES = { 25, 50, 75, 100 }
BN.KM_MILESTONES = { 1000, 5000, 10000, 25000 }

-- Speichert die Zuwaechse seit dem letzten Speichern. Die Datei wird dabei frisch gelesen und nur ergaenzt,
-- damit ein schneller Serverwechsel (alter Server speichert noch, neuer hat schon geladen) nichts verliert.
-- Belohnungen (Erfolge, Tagesaufgabe) zaehlen nur, wenn die Datei sie noch nicht kennt – sonst gaebe es sie bei
-- einem schnellen Wechsel auf beiden Servern.
function BN.savePlayer(s)
    if not s or s.guest then return true end
    flushMoved(s)
    if s.pendingKm == 0 and s.pendingSeconds == 0 and s.pendingTop == 0 and s.pendingBonus == 0 and not s.dirty
        and s.pendingRaces == 0 and s.pendingRecords == 0 and next(s.unlocked) == nil and not s.challengeReward
        and s.pendingJobs == 0 and (s.pendingChaseWins or 0) == 0 then
        return true
    end
    ensureDir(C.sharedDir)
    ensureDir(playersDir())
    -- Datei nicht lesbar: nichts schreiben, die Zuwaechse bleiben fuer den naechsten Versuch erhalten.
    BN.lastLoadWasNew = false
    local rec, loadErr = loadRecord(s.id, s.name)
    local fileWasNew = BN.lastLoadWasNew
    BN.lastLoadWasNew = false
    if not rec then
        BN.logError("Spielerdatei " .. s.id, loadErr)
        return false
    end
    applyWeek(rec)
    applyDay(rec)
    BN.applyMonth(rec)
    local xpBefore = xpOf(rec)
    local fileKm = rec.km
    local tutorialSkipped = false
    local map = currentMap(s)
    rec.dayKm = rec.dayKm + s.pendingKm
    rec.daySeconds = rec.daySeconds + s.pendingSeconds
    rec.dayRaces = rec.dayRaces + s.pendingRaces
    rec.dayTop = math.max(rec.dayTop, s.pendingTop)
    if map then
        rec.dayMaps[map] = true
        rec.maps[map] = true
    end
    -- XP-Event (/event): Zusatz-XP, die waehrend des Events beim Fahren gesammelt wurden (BN.eventGain), als Bonus-XP.
    local eventExtra = math.floor(s.pendingEventXp or 0)
    if eventExtra > 0 then
        rec.bonusXp = rec.bonusXp + eventExtra
        rec.eventXp = (tonumber(rec.eventXp) or 0) + eventExtra
    end
    rec.km = rec.km + s.pendingKm
    rec.weekKm = rec.weekKm + s.pendingKm
    -- Kilometer je Map (fuer "Beliebteste Maps" auf der Statusseite).
    local here = BN.server.map
    if here and here ~= "?" and s.pendingKm > 0 then rec.mapKm[here] = (rec.mapKm[here] or 0) + s.pendingKm end
    if here and here ~= "?" and s.pendingKm > 0 then rec.dayMapKm[here] = (tonumber(rec.dayMapKm[here]) or 0) + s.pendingKm end
    rec.seconds = rec.seconds + s.pendingSeconds
    rec.topSpeedKmh = s.resetTop and s.pendingTop or math.max(rec.topSpeedKmh, s.pendingTop)
    rec.bonusXp = rec.bonusXp + s.pendingBonus
    rec.racesFinished = rec.racesFinished + s.pendingRaces
    rec.recordsSet = rec.recordsSet + s.pendingRecords
    rec.jobsDone = rec.jobsDone + s.pendingJobs
    rec.convoyKm = rec.convoyKm + (s.pendingConvoyKm or 0)
    rec.bonusMapKm = rec.bonusMapKm + (s.pendingBonusMapKm or 0)
    rec.chaseWins = rec.chaseWins + (s.pendingChaseWins or 0)
    rec.dayJobs = rec.dayJobs + s.pendingJobs
    rec.weekJobs = rec.weekJobs + s.pendingJobs
    -- Tages-Serie: der erste Tag zaehlt, Bonus-XP gibt es ab dem zweiten Tag in Folge.
    if C.streakXp > 0 and rec.dayKm >= C.streakMinKm and rec.streakDay ~= rec.day then
        rec.streak = rec.streakDay == rec.day - 1 and rec.streak + 1 or 1
        rec.streakDay = rec.day
        rec.bestStreak = math.max(rec.bestStreak, rec.streak)
        if rec.streak >= 2 then
            local bonus = C.streakXp * (math.min(rec.streak, C.streakMaxDays) - 1)
            rec.bonusXp = rec.bonusXp + bonus
            if not s.leaving then say(s.pid, "🔥 %d Tage in Folge gefahren – +%d Bonus-XP! Morgen wieder fahren hält die Serie.", rec.streak, bonus) end
        end
    end
    local retroXp = 0
    for id, u in pairs(s.unlocked) do
        if not rec.achievements[id] then
            rec.achievements[id] = u.at or BN.now()
            rec.bonusXp = rec.bonusXp + (u.xp or 0)
            if u.retro then retroXp = retroXp + (u.xp or 0) end
        end
    end
    local cr = s.challengeReward
    if cr and (rec.lastChallengeDay or -1) < cr.day then
        rec.lastChallengeDay = cr.day
        rec.bonusXp = rec.bonusXp + (cr.xp or 0)
    end
    rec.dayDone = rec.lastChallengeDay == rec.day
    -- Sprache nur, wenn sie in dieser Sitzung mit /lang geaendert wurde: sonst ueberschreibt ein Server nach einem
    -- schnellen Wechsel die Wahl, die der Spieler inzwischen auf dem anderen Server getroffen hat.
    if s.langChanged and s.lang then rec.lang = s.lang end
    if s.pendingWeeklyTrack then rec.weeklyTrackWeek = s.pendingWeeklyTrack end
    if s.pendingCommunity then
        -- Schon auf einem anderen Server bekommen (Datei kennt die Woche): nicht doppelt.
        if rec.communityWeek == s.pendingCommunity then rec.bonusXp = rec.bonusXp - (s.pendingCommunityXp or 0) end
        rec.communityWeek = s.pendingCommunity
    end
    if s.friendsChanged then rec.friends = s.record.friends end
    if s.pendingRecap then rec.recapMonth = s.pendingRecap end
    if s.pendingWeekRecap then rec.recapWeek = s.pendingWeekRecap end
    if s.pendingTeamWeek then
        -- Schon auf einem anderen Server bekommen (Datei kennt die Woche): nicht doppelt.
        if rec.teamWeek == s.pendingTeamWeek then rec.bonusXp = rec.bonusXp - (s.pendingTeamWeekXp or 0) end
        rec.teamWeek = s.pendingTeamWeek
    end
    rec.jobHour = BN.mergeHour(rec.jobHour, BN.jobLimits and BN.jobLimits[s.id])
    rec.convoyHour = BN.mergeHour(rec.convoyHour, BN.convoyLimits and BN.convoyLimits[s.id])
    if s.pendingComeback then
        -- Schon auf einem anderen Server bekommen (Datei kennt einen Bonus der letzten 30 Tage): nicht doppelt.
        local last = tonumber(rec.comebackAt)
        if last and s.pendingComeback.at - last < 30 * 86400 then
            rec.bonusXp = rec.bonusXp - s.pendingComeback.xp
        else
            rec.comebackAt = s.pendingComeback.at
        end
    end
    if s.pendingSeenVersion then rec.seenVersion = s.pendingSeenVersion end
    if s.tutorialStarted and rec.tutorial == nil and fileKm >= 5 then
        -- Beim Beitritt war die Datei nicht lesbar (oder ein anderer Server hat inzwischen viel gespeichert): wer laut
        -- Datei schon faehrt, bekommt keinen Einsteiger-Pfad – auch nicht die schon gutgeschriebenen Schritt-XP.
        for _, xp in pairs(s.pendingTutorial or {}) do rec.bonusXp = rec.bonusXp - xp end
        rec.tutorial = false
        tutorialSkipped = true          -- Sitzung erst nach erfolgreichem Schreiben aendern (sonst beim naechsten Versuch)
    end
    if s.tutorialStarted and type(rec.tutorial) ~= "table" and rec.tutorial ~= false then rec.tutorial = {} end
    if s.pendingTutorial and type(rec.tutorial) == "table" then
        -- Schon auf einem anderen Server bekommen: nicht doppelt.
        for id, xp in pairs(s.pendingTutorial) do
            if rec.tutorial[id] then rec.bonusXp = rec.bonusXp - xp else rec.tutorial[id] = true end
        end
    end
    rec.lastSeen = BN.now()
    rec.lastServer = BN.server.name or ""
    rec.xp = xpOf(rec)
    rec.level = BN.levelFor(rec.xp)
    rec.league = BN.leagueFor(rec.xp).name
    -- Saison: nur echte Zuwaechse, keine nachtraeglich vergebenen Erfolge fuer fruehere Fahrten.
    rec.monthXp = rec.monthXp + math.max(0, rec.xp - xpBefore - retroXp)
    local ok, err = writeFileAtomic(playersDir() .. "/" .. s.id .. ".json", json.encode(rec))
    if not ok then
        print("[BeamNetCore] Speichern fehlgeschlagen fuer " .. s.name .. ": " .. tostring(err))
        return false
    end
    s.record = rec
    -- Neuer Spieler: wer die Datei als Erster anlegt, meldet ihn (einmal im Netzwerk, auch bei schnellem Serverwechsel).
    if fileWasNew and BN.modlog then BN.modlog({ action = "neu", target = s.name }) end
    -- Meilensteine fuer Discord/Telegram (ueber das Moderationsprotokoll, wie Liga-Aufstiege): verglichen wird die Datei
    -- vor und nach diesem Speichern – sie ist der gemeinsame Stand aller Server, so kommt jeder Meilenstein nur einmal,
    -- auch bei schnellem Serverwechsel.
    if not s.guest and BN.modlog then
        local lv, km
        for _, m in ipairs(BN.LEVEL_MILESTONES) do
            if BN.levelFor(xpBefore) < m and rec.level >= m then lv = m end
        end
        for _, m in ipairs(BN.KM_MILESTONES) do
            if fileKm < m and rec.km >= m then km = m end
        end
        if lv then BN.modlog({ action = "level", target = s.name, level = lv }) end
        if km then BN.modlog({ action = "km", target = s.name, km = km }) end
    end
    if eventExtra > 0 then s.pendingEventXp = s.pendingEventXp - eventExtra end   -- Bruchteile bleiben
    BN.savedRecently[s.id] = { at = BN.now(), rec = BN.slimRecord(rec) }
    s.pendingKm, s.pendingSeconds, s.pendingTop, s.pendingBonus, s.dirty = 0, 0, 0, 0, false
    s.pendingRaces, s.pendingRecords, s.unlocked, s.challengeReward = 0, 0, {}, nil
    s.pendingJobs = 0
    s.pendingConvoyKm = 0
    s.pendingBonusMapKm = 0
    s.pendingChaseWins = 0
    s.langChanged = nil
    s.friendsChanged = nil
    s.resetTop = nil
    s.pendingRecap = nil
    s.pendingWeekRecap = nil
    s.pendingTeamWeek, s.pendingTeamWeekXp = nil, nil
    s.pendingComeback = nil
    s.pendingSeenVersion = nil
    s.pendingTutorial, s.tutorialStarted = nil, nil
    if tutorialSkipped then s.tutorialFinished = true end
    s.pendingWeeklyTrack = nil
    s.pendingCommunity, s.pendingCommunityXp = nil, nil
    return true
end

-- Aktuelle Werte einer Sitzung (gespeichert + noch nicht gespeichert).
function BN.totals(s)
    local rec = s.record
    local km = rec.km + s.pendingKm
    local seconds = rec.seconds + s.pendingSeconds
    local rewards, retro = pendingRewards(s)
    local bonus = rec.bonusXp + s.pendingBonus + rewards
    local xp = BN.xpFor(km, seconds) + bonus
    local weekKm = (rec.week == weekKey(BN.now()) and rec.weekKm or 0) + s.pendingKm
    local maps = 0
    for _ in pairs(rec.maps) do maps = maps + 1 end
    local map = currentMap(s)
    if map and not rec.maps[map] then maps = maps + 1 end
    return { km = km, seconds = seconds, weekKm = weekKm, xp = xp, bonusXp = bonus, level = BN.levelFor(xp),
             league = BN.leagueFor(xp), topSpeedKmh = math.max(rec.topSpeedKmh, s.pendingTop),
             races = rec.racesFinished + s.pendingRaces, records = rec.recordsSet + s.pendingRecords,
             maps = maps, day = BN.dayTotals(s), monthXp = BN.monthXpOf(s, xp, retro),
             jobs = rec.jobsDone + (s.pendingJobs or 0), chaseWins = rec.chaseWins + (s.pendingChaseWins or 0),
             convoyKm = rec.convoyKm + (s.pendingConvoyKm or 0),
             bonusMapKm = rec.bonusMapKm + (s.pendingBonusMapKm or 0) }
end

-- In dieser Saison gesammelte XP einer Sitzung (gespeichert + noch nicht gespeichert, ohne nachtraegliche Erfolge).
function BN.monthXpOf(s, xpNow, retro)
    local rec = s.record
    local saved = xpOf(rec)
    if retro == nil then retro = select(2, pendingRewards(s)) end
    local base = (rec.month == monthKey() and rec.monthXp) or 0
    return math.max(0, base + (xpNow or saved) - saved - retro)
end

-- Heutige Werte (gespeichert + noch nicht gespeichert).
function BN.dayTotals(s)
    local rec, today = s.record, dayNumber()
    local same = rec.day == today
    local dayMaps = 0
    local seen = {}
    if same then for m in pairs(rec.dayMaps) do seen[m] = true end end
    local map = currentMap(s)
    if map then seen[map] = true end
    for _ in pairs(seen) do dayMaps = dayMaps + 1 end
    local cr = s.challengeReward
    local bm = BN.bonusMap and BN.bonusMap()
    return {
        km = (same and rec.dayKm or 0) + s.pendingKm,
        seconds = (same and rec.daySeconds or 0) + s.pendingSeconds,
        races = (same and rec.dayRaces or 0) + s.pendingRaces,
        top = math.max(same and rec.dayTop or 0, s.pendingTop),
        servers = dayMaps,
        jobs = (same and tonumber(rec.dayJobs) or 0) + (s.pendingJobs or 0),
        -- Kilometer heute auf der Map dieses Servers (fuer die Tagesaufgabe "mapkm").
        mapKm = BN.server.map and ((same and type(rec.dayMapKm) == "table" and tonumber(rec.dayMapKm[BN.server.map]) or 0)
            + s.pendingKm) or 0,
        -- Kilometer heute auf der Bonus-Map des Tages, egal auf welchem Server (fuer die Tagesaufgabe "bonus").
        bonusKm = bm and ((same and type(rec.dayMapKm) == "table" and tonumber(rec.dayMapKm[bm.map]) or 0)
            + (BN.server.map == bm.map and s.pendingKm or 0)) or 0,
        done = rec.lastChallengeDay == today or (cr ~= nil and cr.day == today),
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
    -- Nicht in der Standardliste challengeTypes: Admins schalten sie in config.json ein.
    mapkm = { text = "Fahre heute %s km auf einer Map", goals = { 5, 8, 12 }, value = function(d) return d.mapKm end },
    jobs = { text = "Erledige heute %s Aufträge (/auftrag)", goals = { 2, 3, 5 }, value = function(d) return d.jobs end },
    -- Ohne Bonus-Map heute (aus, nur eine Map) gilt stattdessen "mapkm".
    bonus = { text = "Fahre heute %s km auf der Bonus-Map (/server)", goals = { 3, 5, 8 }, value = function(d) return d.bonusKm end },
}

function BN.challengeFor(day)
    local types = {}
    for _, name in ipairs(C.challengeTypes or {}) do
        if BN.CHALLENGES[name] then types[#types + 1] = name end
    end
    if #types == 0 then return nil end
    day = day or dayNumber()
    local kind = types[(day % #types) + 1]
    if kind == "bonus" and not BN.bonusMap() then kind = "mapkm" end
    local def = BN.CHALLENGES[kind]
    local goal = def.goals[(math.floor(day / #types) % #def.goals) + 1]
    return { kind = kind, text = def.text, goal = goal, value = def.value }
end

function BN.checkChallenge(s)
    local ch = BN.challengeFor()
    if not ch then return end
    local d = BN.dayTotals(s)
    if d.done or ch.value(d) < ch.goal then return end
    -- Belohnung von gestern noch nicht gespeichert (kurz nach Mitternacht)? Erst sichern, dann die neue merken.
    if s.challengeReward then BN.savePlayer(s) end
    s.challengeReward = { day = dayNumber(), xp = C.challengeXp }
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
    { id = "km5000", name = "5000 km", xp = 400, value = function(t) return t.km end, goal = 5000 },
    { id = "hours50", name = "50 Stunden unterwegs", xp = 250, value = function(t) return t.seconds / 3600 end, goal = 50 },
    { id = "race50", name = "50 Rennen", xp = 150, value = function(t) return t.races end, goal = 50 },
    { id = "record5", name = "5 Streckenrekorde", xp = 150, value = function(t) return t.records end, goal = 5 },
    { id = "job1", name = "Erster Auftrag", xp = 10, value = function(t) return t.jobs end, goal = 1 },
    { id = "job25", name = "25 Aufträge", xp = 60, value = function(t) return t.jobs end, goal = 25 },
    { id = "job100", name = "Profi-Fahrer (100 Aufträge)", xp = 150, value = function(t) return t.jobs end, goal = 100 },
    { id = "chase1", name = "Erste Jagd gewonnen", xp = 20, value = function(t) return t.chaseWins end, goal = 1 },
    { id = "chase10", name = "Jagd-Legende (10 Jagden gewonnen)", xp = 80, value = function(t) return t.chaseWins end, goal = 10 },
    { id = "convoy10", name = "Konvoi-Fahrer (10 km)", xp = 30, value = function(t) return t.convoyKm end, goal = 10 },
    { id = "convoy100", name = "Kolonnenführer (100 km im Konvoi)", xp = 100, value = function(t) return t.convoyKm end, goal = 100 },
    { id = "explorer25", name = "Entdecker (25 km auf Bonus-Maps)", xp = 40, value = function(t) return t.bonusMapKm end, goal = 25 },
    { id = "explorer100", name = "Pionier (100 km auf Bonus-Maps)", xp = 120, value = function(t) return t.bonusMapKm end, goal = 100 },
}

function BN.hasAchievement(s, id)
    return s.record.achievements[id] ~= nil or s.unlocked[id] ~= nil
end

-- Prueft alle Erfolge; neue werden verkuendet (mehrere auf einmal zusammengefasst) und geben Bonus-XP.
function BN.checkAchievements(s)
    if C.achievements == false then return end
    local t = BN.totals(s)
    -- Erste Pruefung nach dem Betreten: was jetzt schon erreicht ist, stammt aus frueheren Fahrten. Diese Erfolge
    -- gibt es nachtraeglich (mit XP), sie zaehlen aber nicht fuer die laufende Saison.
    local retro = not s.achChecked
    s.achChecked = true
    local new, xp = {}, 0
    for _, a in ipairs(BN.ACHIEVEMENTS) do
        if not BN.hasAchievement(s, a.id) and a.value(t) >= a.goal then
            -- Gutgeschrieben wird beim Speichern (nur wenn die Datei den Erfolg noch nicht kennt).
            s.unlocked[a.id] = { at = BN.now(), xp = a.xp, retro = retro }
            new[#new + 1] = a
            xp = xp + a.xp
        end
    end
    if #new == 0 then return end
    if retro then
        -- Nachtraeglich (frueherer Fortschritt, z. B. nach einem Update): nur dem Spieler sagen, sonst flutet bei vielen
        -- Spielern der Chat.
        if #new <= 2 then
            for _, a in ipairs(new) do say(s.pid, "Erfolg für %s: %s (+%d XP)", s.name, tr(BN.langOf(s.pid), a.name), a.xp) end
        else
            say(s.pid, "%s hat %d Erfolge freigeschaltet (+%d XP) – /erfolge", s.name, #new, xp)
        end
        return
    end
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
        -- Nur ein echter Aufstieg wird angesagt (eine XP-Korrektur beim Speichern kann auch in eine niedrigere Liga fuehren).
        local up = (tonumber(t.league.xp) or 0) > (tonumber(s.leagueXp) or -1)
        if up then
            sayEach(function(lang) return tr(lang, "%s steigt in die Liga %s auf!", s.name, tr(lang, league)) end)
            -- Fuer den Waechter (Discord/Telegram): nur mit Konto, nicht der erste Blick nach dem Betreten.
            if s.league and not s.guest and BN.modlog then
                BN.modlog({ action = "liga", target = s.name, league = league, xp = t.xp })
            end
        end
        s.league = t.league.name
    end
    s.leagueXp = tonumber(t.league.xp) or 0
    BN.checkAchievements(s)
    BN.checkChallenge(s)
    BN.checkTutorial(s, t)
end

-- Einsteiger-Pfad: fuenf kleine Schritte fuer neue Spieler, in beliebiger Reihenfolge. Wer schon vorher gefahren ist
-- (ab 5 km beim ersten Blick), bekommt ihn nicht – sonst gaebe es XP fuer laengst Erledigtes.
BN.TUTORIAL = {
    { id = "km", text = "Fahr deinen ersten Kilometer", done = function(s, t) return t.km >= 1 end },
    { id = "job", text = "Erledige einen Auftrag: /auftrag",
      done = function(s) return (tonumber(s.record.jobsDone) or 0) + (s.pendingJobs or 0) >= 1 end },
    { id = "race", text = "Beende ein Rennen: /rennen", done = function(s, t) return t.races >= 1 end },
    { id = "friend", text = "Füge einen Freund hinzu: /freund <Name>",
      done = function(s) return #(s.record.friends or {}) >= 1 end },
    { id = "level", text = "Erreiche Level 3", done = function(s, t) return t.level >= 3 end },
}

local function tutorialState(s)
    if type(s.record.tutorial) ~= "table" then return nil end
    s.tutorialDone = s.tutorialDone or {}
    local done, nextStep = 0, nil
    for _, step in ipairs(BN.TUTORIAL) do
        if s.record.tutorial[step.id] or s.tutorialDone[step.id] then done = done + 1 elseif not nextStep then nextStep = step end
    end
    return done, nextStep
end

function BN.checkTutorial(s, t)
    if s.guest or C.tutorialXp <= 0 or s.tutorialFinished then return end
    local rec = s.record
    if rec.tutorial == nil then
        if t.km >= 5 and not s.isNew then
            s.tutorialFinished = true            -- alter Hase: kein Einsteiger-Pfad
            return
        end
        rec.tutorial = {}
        s.tutorialStarted, s.dirty = true, true
    end
    if type(rec.tutorial) ~= "table" then s.tutorialFinished = true return end
    s.tutorialDone = s.tutorialDone or {}
    s.pendingTutorial = s.pendingTutorial or {}
    local lang = BN.langOf(s.pid)
    for _, step in ipairs(BN.TUTORIAL) do
        if not rec.tutorial[step.id] and not s.tutorialDone[step.id] and step.done(s, t) then
            s.tutorialDone[step.id] = true
            s.pendingTutorial[step.id] = C.tutorialXp
            s.pendingBonus = s.pendingBonus + C.tutorialXp
            local done, nextStep = tutorialState(s)
            if nextStep then
                say(s.pid, "✅ Einsteiger-Schritt %d/%d geschafft (+%d XP). Nächster: %s", done, #BN.TUTORIAL, C.tutorialXp,
                    tr(lang, nextStep.text))
            else
                s.pendingTutorial.all = C.tutorialDoneXp
                s.pendingBonus = s.pendingBonus + C.tutorialDoneXp
                say(s.pid, "🎓 Einsteiger-Pfad geschafft! +%d XP und noch einmal +%d XP obendrauf. Viel Spaß im BeamNet!",
                    C.tutorialXp, C.tutorialDoneXp)
                s.tutorialFinished = true
            end
        end
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
    local jump = false
    local d, dt
    if not v then s.roadDriven = 0 end         -- neues Fahrzeug (auch an beliebiger Stelle gespawnt): Lieferpunkte erst nach Fahrt
    if v then
        if tim and v.tim and tim > v.tim then dt = tim - v.tim else dt = math.max(1, now - v.at) end
        local dx, dy, dz = x - v.x, y - v.y, z - v.z
        d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d >= C.minStepM and dt > 0 and d / dt <= C.maxSpeedMps then
            -- Zaehlt erst ueber flushMoved (nur das Fahrzeug mit der groessten Strecke je Takt)
            counted = d
            s.moved[vid] = (s.moved[vid] or 0) + d
        elseif dt > 0 and d / dt > C.maxSpeedMps then
            jump = true
        end
        -- Lieferpunkte: zaehlt nur echte Fahrt am Boden seit dem letzten Sprung (kein Fallen aus der Luft).
        if jump or (dt > 0 and math.abs(dz) / dt > BN.ROAD_MAX_VERTICAL_MPS) then s.roadDriven = 0
        else s.roadDriven = (tonumber(s.roadDriven) or 0) + counted end
    end
    -- Neue Position sofort merken: bricht einer der folgenden Schritte ab, bleibt sonst die alte stehen und jede weitere
    -- Messung zaehlte die ganze Strecke ab dort noch einmal.
    local cur = { x = x, y = y, z = z, tim = tim, at = now }
    s.vehicles[vid] = cur
    if s.race then BN.raceUpdate(s, vid, v, { x = x, y = y, z = z, tim = tim, at = now }, jump) end
    -- Fahrauftrag: nur die Strecke des Auftragsfahrzeugs zaehlt, ein Sprung beendet den Auftrag.
    local j = s.job
    if j and j.vid == vid then
        if jump then j.jumped = true else j.legDriven = (j.legDriven or 0) + counted end
    end
    -- Einsatz-Alarm: genauso – nur Fahrzeuge vom Alarmbeginn, ein Sprung scheidet das Fahrzeug aus.
    local e = BN.alert and BN.alert.entries[s.id]
    local ev = e and e.pid == pid and type(e.vids) == "table" and e.vids[vid]
    if ev then
        if jump then ev.out = true else ev.driven = ev.driven + counted end
    end
    local speed
    if type(vel) == "table" then
        local vx, vy, vz = tonumber(vel[1] or vel.x) or 0, tonumber(vel[2] or vel.y) or 0, tonumber(vel[3] or vel.z) or 0
        speed = math.sqrt(vx * vx + vy * vy + vz * vz)
    end
    -- Hoechstgeschwindigkeit nur, wenn sie zur Bewegung passt (hoechstens 10 % ueber der Geschwindigkeit aus der
    -- Positionsaenderung) und zwei Messungen hintereinander haelt: ein einzelner Physik-Ausreisser ("Kraken") oder ein
    -- gemeldeter Wert ohne Bewegung zaehlt nicht.
    local cand
    if speed and d and dt and dt > 0 and dt <= 5 and not jump then
        cand = math.min(speed, d / dt * 1.1)
        local sustained = math.min(cand, v.cand or 0)
        if sustained <= C.maxSpeedMps then s.pendingTop = math.max(s.pendingTop, sustained * 3.6) end
    end
    cur.cand = cand
    return counted
end

function BN.forgetVehicle(pid, vid)
    local s = BN.players[pid]
    if not s then return end
    s.roadDriven = 0
    s.vehicles[vid] = nil
    if s.job and s.job.vid == vid then s.job.reset = true end   -- danach: weiter nur ohne Sprung (siehe jobTick)
    local e = BN.alert and BN.alert.entries[s.id]
    if e and e.pid == pid and type(e.vids) == "table" and e.vids[vid] then e.vids[vid].out = true end   -- Zuruecksetzen/Fahrzeug weg: scheidet aus
    local r = s.race
    if r and r.vid == vid and r.state ~= "armed" then
        BN.raceInvalid(s, "Fahrzeug zurückgesetzt")
    end
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Bestenliste und Serverliste

-- Alle gespeicherten Spieler in schlanker Form (fuer Bestenliste, Woche und Saison). Quelle ist der Index, den der
-- Waechter jede Minute schreibt (players-index.tsv, eine Zeile je Spieler: 10 000 Spieler in etwa 0,07 s statt 1,4 s
-- je Liste). Fehlt er oder ist er aelter als BN.INDEX_MAX_AGE, werden wie frueher alle Spielerdateien gelesen.
-- Was dieser Server nach dem Index gespeichert hat, ersetzt die Index-Zeile (sonst fehlten die letzten Zuwaechse von
-- Spielern, die gerade gegangen sind). Die Liste wird geteilt: nie veraendern.
BN.INDEX_MAX_AGE = 180
-- Format 1: die ersten 13 Felder; Format 2 (Werkzeug ab 1.39): dazu topSpeedKmh; Format 3 (ab 1.57): jobsDone;
-- Format 4 (Werkzeug ab 1.84): convoyKm und chaseWins.
BN.INDEX_FIELDS = { "id", "name", "km", "seconds", "bonusXp", "week", "weekKm", "lastWeek", "lastWeekKm",
                    "month", "monthXp", "lastMonth", "lastMonthXp", "topSpeedKmh", "jobsDone", "convoyKm", "chaseWins" }
local INDEX_COUNT = { [1] = 13, [2] = 14, [3] = 15, [4] = 17 }
local INDEX_NUMBERS = { km = true, seconds = true, bonusXp = true, weekKm = true, lastWeekKm = true, monthXp = true,
                        lastMonthXp = true, topSpeedKmh = true, jobsDone = true, convoyKm = true, chaseWins = true }
BN.savedRecently = BN.savedRecently or {}
BN.recordsCache = BN.recordsCache or { at = -math.huge, list = {} }

local function indexFile() return C.sharedDir .. "/players-index.tsv" end

function BN.slimRecord(rec)
    local out = {}
    for _, key in ipairs(BN.INDEX_FIELDS) do out[key] = rec[key] end
    out.xp, out.monthStartXp = rec.xp, rec.monthStartXp      -- Saison fuer Datensaetze von 1.8
    return out
end

-- Liest den Index; nil, wenn er fehlt, ein unbekanntes Format hat oder veraltet ist.
function BN.readIndex(now)
    local data = readFile(indexFile())
    if not data then return nil end
    local version, updated = data:match("^# beamnet%-index (%d+) (%d+)")
    local count = INDEX_COUNT[tonumber(version)]
    updated = tonumber(updated)
    if not count or not updated or now - updated > BN.INDEX_MAX_AGE or updated > now + 300 then return nil end
    local list = {}
    for line in data:gmatch("[^\n]+") do
        if line:sub(1, 1) ~= "#" then
            local rec, i = {}, 0
            for field in (line .. "\t"):gmatch("([^\t]*)\t") do
                i = i + 1
                local key = i <= count and BN.INDEX_FIELDS[i] or nil
                if not key then i = count + 1; break end
                if INDEX_NUMBERS[key] then rec[key] = tonumber(field) elseif field ~= "" then rec[key] = field end
            end
            if i == count and rec.id and safeId(rec.id) then list[#list + 1] = rec end
        end
    end
    return list, updated
end

function BN.playerRecords(force)
    local now = BN.now()
    local cache = BN.recordsCache
    if not force and now - cache.at < C.leaderboardEverySec then return cache.list end
    local list, updated = BN.readIndex(now)
    if list then
        local pos = {}
        for i, rec in ipairs(list) do pos[rec.id] = i end
        for id, e in pairs(BN.savedRecently) do
            if now - e.at > 900 then
                BN.savedRecently[id] = nil
            elseif e.at >= updated - 2 then
                if pos[id] then list[pos[id]] = e.rec else list[#list + 1] = e.rec end
            end
        end
        BN.boardSource = "index"
    else
        list = {}
        for _, file in ipairs(listJsonFiles(playersDir())) do
            local rec = json.decode(readFile(file) or "")
            if type(rec) == "table" and rec.id then list[#list + 1] = BN.slimRecord(rec) end
        end
        BN.boardSource = "files"
    end
    BN.recordsCache = { at = now, list = list }
    return list
end

function BN.refreshBoard(force)
    local now = BN.now()
    if not force and now - BN.board.at < C.leaderboardEverySec then return BN.board.list end
    local byId = {}
    local wk = weekKey(now)
    for _, rec in ipairs(BN.playerRecords(force)) do
        if rec.id then
            byId[rec.id] = { id = rec.id, name = rec.name, km = tonumber(rec.km) or 0, seconds = tonumber(rec.seconds) or 0,
                             bonusXp = tonumber(rec.bonusXp) or 0, topSpeedKmh = tonumber(rec.topSpeedKmh) or 0,
                             weekKm = rec.week == wk and (tonumber(rec.weekKm) or 0) or 0, jobsDone = tonumber(rec.jobsDone) or 0,
                             convoyKm = tonumber(rec.convoyKm) or 0, chaseWins = tonumber(rec.chaseWins) or 0 }
        end
    end
    -- Spieler online mit ihren noch nicht gespeicherten Werten.
    for _, s in pairs(BN.players) do
        if not s.guest then
            local t = BN.totals(s)
            byId[s.id] = { id = s.id, name = s.name, km = t.km, seconds = t.seconds, weekKm = t.weekKm, bonusXp = t.bonusXp,
                           topSpeedKmh = t.topSpeedKmh, jobsDone = (tonumber(s.record.jobsDone) or 0) + (s.pendingJobs or 0),
                           convoyKm = t.convoyKm, chaseWins = t.chaseWins }
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
    for _, rec in ipairs(BN.playerRecords(false)) do
        if rec.id then
            local km
            if rec.week == week then km = tonumber(rec.weekKm) elseif rec.lastWeek == week then km = tonumber(rec.lastWeekKm) end
            if km and km > 0 then byId[rec.id] = { id = rec.id, name = rec.name, km = km } end
        end
    end
    for _, s in pairs(BN.players) do
        if not s.guest then
            local rec, km = s.record, nil
            if rec.week == week then km = (tonumber(rec.weekKm) or 0) + s.pendingKm
            elseif rec.lastWeek == week then km = tonumber(rec.lastWeekKm) end
            if km and km > 0 then byId[s.id] = { id = s.id, name = s.name, km = km } end
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
    for _, rec in ipairs(BN.playerRecords(false)) do
        if rec.id then
            local xp
            if rec.month == month then
                xp = tonumber(rec.monthXp)
                if not xp and tonumber(rec.monthStartXp) then
                    -- Datensatz von 1.8 (Startwert statt Zaehler)
                    local total = tonumber(rec.xp) or (BN.xpFor(tonumber(rec.km) or 0, tonumber(rec.seconds) or 0) + (tonumber(rec.bonusXp) or 0))
                    xp = total - tonumber(rec.monthStartXp)
                end
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

-- Vorsaison (Vormonat) zu einem Zeitpunkt: Tag des Monats zurueck landet sicher im Vormonat.
local function previousMonthKey(t)
    t = t or BN.now()
    return monthKey(t - tonumber(os.date("!%d", t)) * 86400)
end
BN.previousMonthKey = previousMonthKey

local function seasonFile(month)
    return C.sharedDir .. "/seasons/" .. month .. ".json"
end

-- Saisonende: Sieger verkuenden (ausser quiet) und einmal archivieren. true, wenn es eine Wertung gab.
function BN.endSeason(month, quiet)
    BN.seasonCache[month] = nil
    local list = BN.seasonRanking(month)
    if #list == 0 then return false end
    local path = seasonFile(month)
    if not readFile(path) then
        ensureDir(C.sharedDir)
        ensureDir(C.sharedDir .. "/seasons")
        local top = {}
        for i = 1, math.min(10, #list) do top[i] = list[i] end
        writeFileAtomic(path, json.encode({ month = month, top = top, at = BN.now() }))
    end
    if quiet then return true end
    local parts = {}
    for i = 1, math.min(3, #list) do parts[#parts + 1] = string.format("%d. %s (%d XP)", i, list[i].name, list[i].xp) end
    sayEach(function(lang) return tr(lang, "Saison %s beendet! %s", BN.seasonName(month, lang), table.concat(parts, " · ")) end)
    return true
end

-- Saison-Titel: Platz 1–3 jeder archivierten Saison (seasons/*.json), neueste zuerst; zwischengespeichert (10 min).
BN.titleCache = BN.titleCache or {}
local TITLE_TEXT = { "Saisonsieger %s", "Saison-Zweiter %s", "Saison-Dritter %s" }

function BN.titlesFor(id)
    if not id then return {} end
    local now = BN.now()
    if not BN.titleCache.at or now - BN.titleCache.at >= 600 then
        local map = {}
        for _, file in ipairs(listJsonFiles(C.sharedDir .. "/seasons")) do
            local a = json.decode(readFile(file) or "")
            if type(a) == "table" and type(a.month) == "string" and a.month:match("^%d%d%d%d%-%d%d$") and type(a.top) == "table" then
                for i = 1, math.min(3, #a.top) do
                    local e = a.top[i]
                    if type(e) == "table" and e.id then
                        local key = tostring(e.id)
                        map[key] = map[key] or {}
                        map[key][#map[key] + 1] = { month = a.month, place = i }
                    end
                end
            end
        end
        for _, list in pairs(map) do table.sort(list, function(x, y) return x.month > y.month end) end
        BN.titleCache = { at = now, map = map }
    end
    return BN.titleCache.map[tostring(id)] or {}
end

function BN.titleText(t, lang)
    return tr(lang, TITLE_TEXT[t.place], BN.seasonName(t.month, lang))
end

-- Neu seit dem letzten Besuch: die (hoechstens 3) neuesten Neuheiten seit der Plugin-Version, die der Spieler zuletzt
-- gesehen hat. Neue Spieler bekommen stattdessen die Begruessung; wer vor dieser Funktion schon da war, gilt als 1.29.
BN.NEWS = {
    { "1.30", "Freundesliste: /freund <Name> – Nachricht, wenn ein Freund online kommt" },
    { "1.33", "Fahraufträge: /auftrag – Patienten ins Krankenhaus, Kinder zur Schule, Taxi …" },
    { "1.34", "Wochenziel für alle: /ziel – zusammen Kilometer sammeln, alle bekommen Bonus-XP" },
    { "1.38", "Verfolgungsjagd: /fangen – einer flüchtet, alle jagen ihn" },
    { "1.44", "Duell: /duell <Name> <Strecke> – Zeitrennen gegen einen Freund" },
    { "1.51", "Rennserien: /serie – mehrere Strecken nacheinander, die Zeiten zählen zusammen" },
    { "1.52", "Orte vorschlagen: /ort vorschlag krankenhaus <Name> – für neue Fahraufträge" },
    { "1.53", "Einsatz-Alarm: ab und zu ein Ziel für alle – wer zuerst da ist, bekommt Bonus-XP" },
    { "1.56", "Konvoi: zusammen fahren gibt Bonus-XP – /konvoi" },
    { "1.57", "7 neue Erfolge für Aufträge, Verfolgungsjagden und Konvois – /erfolge" },
    { "1.60", "Neue Erfolge für Vielfahrer: 5000 km, 50 Stunden, 50 Rennen, 5 Streckenrekorde" },
    { "1.62", "Aufträge auf jeder Map (Lieferpunkte) und Richtungshinweise unterwegs – /auftrag" },
    { "1.64", "Schicht: mehrere Aufträge hintereinander bringen Bonus-XP – /auftrag" },
    { "1.79", "Alles für heute auf einen Blick: /heute – Tagesaufgabe, XP-Abend, Bonus-Map, Wochenziel" },
    { "1.81", "Neue Erfolge: Entdecker und Pionier – fahr auf der Bonus-Map des Tages (/heute)" },
    { "1.88", "Team der Woche: wer im besten Team mitfährt, bekommt +50 XP – /team woche" },
}

local function versionNum(v)
    local a, b = tostring(v or ""):match("^(%d+)%.(%d+)$")
    return a and (tonumber(a) * 1000 + tonumber(b)) or 0
end

function BN.showNews(s)
    if s.guest then return 0 end
    local seen = s.record.seenVersion
    if versionNum(seen) >= versionNum(BN.VERSION) then return 0 end
    s.pendingSeenVersion, s.dirty = BN.VERSION, true
    if s.isNew then return 0 end
    local from = versionNum(seen ~= nil and seen or "1.29")
    local lang, items = BN.langOf(s.pid), {}
    for i = #BN.NEWS, 1, -1 do
        if versionNum(BN.NEWS[i][1]) > from and #items < 3 then items[#items + 1] = BN.NEWS[i][2] end
    end
    if #items == 0 then return 0 end
    say(s.pid, "✨ Neu seit deinem letzten Besuch:")
    for _, text in ipairs(items) do chat(s.pid, "  " .. tr(lang, text)) end
    return #items
end

-- Saison-Rueckblick: beim ersten Besuch im neuen Monat die eigene Bilanz des Vormonats (XP, Platz aus dem Archiv).
function BN.seasonRecap(s)
    local rec = s.record
    if s.guest or type(rec.lastMonth) ~= "string" or rec.recapMonth == rec.lastMonth then return false end
    local y, m = monthKey():match("^(%d+)%-(%d+)$")
    y, m = tonumber(y), tonumber(m) - 1
    if m == 0 then y, m = y - 1, 12 end
    if rec.lastMonth ~= string.format("%04d-%02d", y, m) then return false end
    s.pendingRecap, s.dirty = rec.lastMonth, true
    local xp = math.floor(tonumber(rec.lastMonthXp) or 0)
    if xp <= 0 then return false end
    local rank
    local a = json.decode(readFile(seasonFile(rec.lastMonth)) or "")
    if type(a) == "table" and type(a.top) == "table" then
        for i, e in ipairs(a.top) do if type(e) == "table" and tostring(e.id) == s.id then rank = i end end
    end
    local lang = BN.langOf(s.pid)
    say(s.pid, "📅 Dein Rückblick %s: %d XP%s – neue Saison, neues Glück!", BN.seasonName(rec.lastMonth, lang), xp,
        rank and tr(lang, " · Platz %d", rank) or "")
    return true
end

-- Wochen-Rueckblick: beim ersten Besuch in einer neuen Woche Kilometer und Platz der Vorwoche (einmal je Woche).
function BN.weekRecap(s)
    local rec = s.record
    local prev = weekKey(BN.now() - 7 * 86400)
    if s.guest or rec.lastWeek ~= prev or rec.recapWeek == prev then return false end
    s.pendingWeekRecap, s.dirty = prev, true
    local km = tonumber(rec.lastWeekKm) or 0
    if km < 1 then return false end
    local list, rank = BN.weekRanking(prev), nil
    for i, e in ipairs(list) do
        if e.id == s.id then rank = i break end
    end
    local lang = BN.langOf(s.pid)
    say(s.pid, "📅 Deine letzte Woche: %s%s – neue Woche, neue Kilometer! (/top vorwoche)", fmtKm(km),
        rank and tr(lang, " · Platz %d von %d", rank, #list) or "")
    return true
end

-- Nachholen, falls beim Monatswechsel kein Server lief: fehlt das Archiv der Vorsaison, wird es jetzt still geschrieben.
function BN.ensureSeasonArchive()
    local prev = previousMonthKey()
    if readFile(seasonFile(prev)) then return false end
    return BN.endSeason(prev, true)
end

function BN.announceWeek(week)
    local list = BN.weekRanking(week)
    if #list == 0 then return end
    local parts = {}
    for i = 1, math.min(3, #list) do parts[#parts + 1] = string.format("%d. %s (%s)", i, list[i].name, fmtKm(list[i].km)) end
    local number = tostring(week):match("W(%d+)$") or tostring(week)
    sayEach(function(lang) return tr(lang, "Wochensieger %s: %s", tr(lang, "KW %s", number), table.concat(parts, " · ")) end)
    local team = BN.teamWeekSnapshot and BN.teamWeekSnapshot(week)
    if team then sayEach(function(lang) return tr(lang, "🏅 Team der Woche: %s (%s)", team.name, fmtKm(tonumber(team.km) or 0)) end) end
end

function BN.rankOf(id)
    for i, rec in ipairs(BN.refreshBoard(false)) do
        if rec.id == id then return i, #BN.board.list end
    end
    return nil, #BN.board.list
end

-- Aufstieg in der Bestenliste: einmal je Minute die Plaetze der Spieler hier; wer in den Top 10 einen Platz gutmacht,
-- bekommt es gesagt, und Platz 1 hoeren alle. Der erste Blick nach dem Betreten merkt sich nur den Platz.
function BN.rankTick()
    local now = BN.now()
    if now - (BN.lastRankCheck or -math.huge) < 60 then return end
    BN.lastRankCheck = now
    local here = {}
    for _, s in pairs(BN.players) do if not s.guest and s.id then here[s.id] = s end end
    if next(here) == nil then return end
    for i, rec in ipairs(BN.refreshBoard(false)) do
        local s = here[rec.id]
        if s then
            -- Nur ein neuer bester Platz dieser Sitzung (Kopf-an-Kopf-Rennen ueber zwei Server flattert sonst).
            if s.lastRank and i < s.lastRank and i <= 10 and i < (s.bestRankSaid or math.huge) then
                if i == 1 and now - (s.firstSaidAt or -math.huge) >= 1800 then
                    s.firstSaidAt = now
                    sayAll("👑 %s ist jetzt Platz 1 der Bestenliste!", s.name)
                elseif i > 1 then
                    say(s.pid, "📈 Du bist jetzt Platz %d der Bestenliste (vorher %d)!", i, s.lastRank)
                end
                s.bestRankSaid = i
            end
            s.lastRank = i
        end
    end
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
    -- Namen alphabetisch; ids an derselben Stelle (Gaeste: "") fuer die Profil-Links der Statusseite.
    local list = {}
    for _, s in pairs(BN.players) do list[#list + 1] = s end
    table.sort(list, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return tostring(a.pid) < tostring(b.pid)
    end)
    local names, ids = {}, {}
    for i, s in ipairs(list) do
        names[i] = s.name
        ids[i] = (not s.guest and s.id) or ""
    end
    local status = { name = BN.server.name, port = BN.server.port, map = BN.server.map, players = #names,
                     max = BN.server.maxPlayers, names = names, ids = ids, updated = BN.now(), version = BN.VERSION,
                     board = BN.boardSource,
                     api = BN.capabilities(), lua = _VERSION }
    -- Tagesaufgabe (fuer /heute im Telegram-Chat): Text mit Ziel, auf Deutsch.
    local ok, ch = pcall(BN.challengeFor)
    if ok and ch then status.challenge = tr("de", ch.text, ch.goal) end
    writeFileAtomic(serversDir() .. "/" .. tostring(BN.server.port) .. ".json", json.encode(status))
    BN.lastStatus = BN.now()
end

function BN.serverList()
    local now = BN.now()
    local list = {}
    for _, file in ipairs(listJsonFiles(serversDir())) do
        local st = json.decode(readFile(file) or "")
        -- Die Dateien kann jeder Dienst schreiben: nur ganze Ports, frische (nicht zukuenftige) Zeitstempel und
        -- ganzzahlige Spielerzahlen; Name und Karte gekuerzt.
        local port, upd = type(st) == "table" and tonumber(st.port), type(st) == "table" and tonumber(st.updated)
        if port and upd and port == math.floor(port) and port >= 1 and port <= 65535 and now - upd <= 90 and upd - now <= 60 then
            local function count(v)
                v = tonumber(v) or 0
                if v ~= v or v < 0 then return 0 end
                return math.floor(math.min(v, 1000))
            end
            st.port, st.players, st.max = math.floor(port), count(st.players), count(st.max)
            st.name = type(st.name) == "string" and st.name:sub(1, 64) or nil
            st.map = type(st.map) == "string" and st.map:sub(1, 48) or nil
            list[#list + 1] = st
        end
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
-- Was der Admin zwischen "neu" und "ziel" faehrt, ist die Streckenlaenge (sonst legt sie der erste gueltige Lauf fest);
-- ein Lauf mit deutlich kuerzerer Fahrstrecke ist ungueltig (siehe BN.raceMinDist).
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

-- Abstand zur eigenen Zwischenzeit mit Vorzeichen und einer Nachkommastelle ("+1.3 s", "-0.8 s").
function BN.fmtSplitDiff(seconds)
    local v = math.floor((seconds or 0) * 10 + 0.5) / 10
    if v == 0 then v = 0 end                -- kein "-0.0"
    return string.format("%+.1f s", v)
end

-- Hoechstens so viele Zwischenzeiten je Lauf.
local MAX_SPLITS = 60

-- Map als Dateiname (so heissen races/<Map>.json und places/<Map>.json).
function BN.mapKey(map)
    return (tostring(map or BN.server.map or "unbekannt"):gsub("[^%w_-]", "_"))
end

local function racesFile()
    return racesDir() .. "/" .. BN.mapKey() .. ".json"
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

-- Text fuer Meldungen: ohne Steuerzeichen, hoechstens maxBytes Bytes, nie mitten in einem UTF-8-Zeichen getrennt.
local function clipText(text, maxBytes)
    text = tostring(text or ""):gsub("[%z\1-\31\127]", " ")
    if #text <= maxBytes then return text end
    local cut = maxBytes
    while cut > 0 do
        local b = text:byte(cut + 1) or 0
        if b < 0x80 or b >= 0xC0 then break end       -- naechstes Byte beginnt ein Zeichen: hier trennen
        cut = cut - 1
    end
    return text:sub(1, cut) .. "…"
end
BN.clipText = clipText

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
    r.runDist, r.splits, r.bestSplits, r.recordSplits = nil, nil, nil, nil
end

-- Zwischenzeiten der eigenen Bestzeit auf einer Strecke (nil fuer Gaeste oder ohne Bestzeit).
local function bestSplits(s, name)
    if s.guest then return nil end
    local track = BN.loadTracks().tracks[name]
    if type(track) ~= "table" or type(track.records) ~= "table" then return nil end
    for _, rec in ipairs(track.records) do
        if type(rec) == "table" and rec.id == s.id then
            -- Nur Zwischenzeiten mit demselben Abstand der Marken sind vergleichbar.
            if type(rec.splits) ~= "table" or tonumber(rec.splitM) ~= tonumber(C.raceSplitM) then return nil end
            return rec.splits
        end
    end
    return nil
end

-- Zwischenzeiten des Streckenrekords, wenn er von jemand anderem ist (sonst ist die eigene Bestzeit der Rekord).
local function recordSplits(s, name)
    local track = BN.loadTracks().tracks[name]
    if type(track) ~= "table" or type(track.records) ~= "table" then return nil end
    local best = track.records[1]
    if type(best) ~= "table" or (best.id and best.id == s.id) then return nil end
    if type(best.splits) ~= "table" or tonumber(best.splitM) ~= tonumber(C.raceSplitM) then return nil end
    return best.splits
end

-- Mindest-Fahrstrecke eines Laufs (m). Ein Rundkurs braucht die bekannte Laenge (track.lengthM) oder sonst
-- C.raceMinLapM, eine Strecke von A nach B zusaetzlich die Luftlinie; jeweils 80 %, damit Ideallinie und Messung
-- Spielraum haben. Gemessen wird erst ab dem Verlassen des Startbereichs bis zum Zielbereich, daher ohne die Radien.
function BN.raceMinDist(start, finish, lengthM)
    local radius = C.raceRadiusM
    local straight = dist(start, finish)
    lengthM = tonumber(lengthM)
    local need
    if straight <= radius then
        need = lengthM or C.raceMinLapM
    else
        need = math.max(straight, lengthM or 0)
    end
    return math.max(0, 0.8 * need - 2 * radius)
end

-- Waehrend eines Laufs: Fahrstrecke aufsummieren, an jeder Marke (alle C.raceSplitM Meter) die Laufzeit merken und
-- mit der Zwischenzeit der eigenen Bestzeit vergleichen. Der Zeitpunkt wird wie beim Ziel im Abschnitt eingerechnet.
-- finishT: Laufzeit im Ziel, falls der Lauf in diesem Abschnitt endet – Marken ab dort zaehlen nicht mehr.
local function raceSplits(s, prev, cur, t0, t1, finishT)
    local r = s.race
    local seg = dist(prev, cur)
    local d0 = r.runDist or 0
    r.runDist = d0 + seg               -- auch ohne Zwischenzeiten: Mindeststrecke im Ziel
    local step = tonumber(C.raceSplitM) or 0
    if step <= 0 then return end
    r.splits = r.splits or {}
    while #r.splits < MAX_SPLITS and (#r.splits + 1) * step <= r.runDist do
        local n = #r.splits + 1
        local f = seg > 0 and (n * step - d0) / seg or 1
        if f < 0 then f = 0 elseif f > 1 then f = 1 end
        local t = t0 + (t1 - t0) * f - r.startT
        if finishT and t >= finishT then break end
        r.splits[n] = t
        local best = r.bestSplits and tonumber(r.bestSplits[n])
        local rec = r.recordSplits and tonumber(r.recordSplits[n])
        if best and rec then
            say(s.pid, "Zwischenzeit %d: %s (%s, Rekord %s)", n, BN.fmtRaceTime(t), BN.fmtSplitDiff(t - best), BN.fmtSplitDiff(t - rec))
        elseif best then
            say(s.pid, "Zwischenzeit %d: %s (%s)", n, BN.fmtRaceTime(t), BN.fmtSplitDiff(t - best))
        elseif rec then
            say(s.pid, "Zwischenzeit %d: %s (Rekord %s)", n, BN.fmtRaceTime(t), BN.fmtSplitDiff(t - rec))
        end
    end
end

-- Gruppenrennen: alle Teilnehmer fahren dieselbe Strecke ab einem gemeinsamen Startsignal. Gemessen wird wie
-- sonst ab dem Verlassen des Startbereichs – wer ihn vor dem Signal verlaesst, hat einen Fehlstart und muss zurueck.
-- Gewertet wird der erste gueltige Lauf je Teilnehmer; Plaetze 1–3 bekommen Bonus-XP (ab 2 Teilnehmern im Ziel).
BN.GROUP_XP = { 30, 20, 10 }

local function groupSay(text, ...)
    local g = BN.group
    if not g then return end
    for pid in pairs(g.members) do if BN.players[pid] then say(pid, text, ...) end end
end

function BN.endGroup()
    local g = BN.group
    if not g then return end
    BN.group = nil
    table.sort(g.results, function(a, b) return a.time < b.time end)
    for pid in pairs(g.members) do
        local m = BN.players[pid]
        if m and m.race then m.race.group = nil end
    end
    if g.duel then
        -- Duell: Ergebnis nur an die beiden, XP nur fuer den Sieger (mit Konto) und nur, wenn beide im Ziel sind.
        local function tell(text, ...) for pid in pairs(g.members) do if BN.players[pid] then say(pid, text, ...) end end end
        if #g.results < 2 then
            tell("Duell auf %s beendet – nicht beide im Ziel, kein Sieger.", g.name)
            return
        end
        local w, l = g.results[1], g.results[2]
        tell("⚔️ Duell auf %s: %s gewinnt (%s) gegen %s (%s)!", g.name, w.name, BN.fmtRaceTime(w.time), l.name, BN.fmtRaceTime(l.time))
        local m = BN.players[w.pid]
        if m and m.id and m.id == w.id then
            m.pendingBonus = m.pendingBonus + BN.GROUP_XP[1]
            say(m.pid, "Duell gewonnen: +%d Bonus-XP!", BN.GROUP_XP[1])
        end
        return
    end
    if #g.results == 0 then
        sayAll("Gruppenrennen auf %s beendet – niemand im Ziel.", g.name)
        return
    end
    local parts = {}
    for i, e in ipairs(g.results) do
        if i <= 10 then parts[#parts + 1] = string.format("%d. %s %s", i, e.name, BN.fmtRaceTime(e.time)) end
    end
    sayAll("Gruppenrennen auf %s – Ergebnis: %s", g.name, table.concat(parts, " · "))
    if #g.results >= 2 then
        for i = 1, math.min(3, #g.results) do
            local m = BN.players[g.results[i].pid]
            if m and m.id == g.results[i].id then
                m.pendingBonus = m.pendingBonus + BN.GROUP_XP[i]
                say(m.pid, "Platz %d im Gruppenrennen: +%d Bonus-XP!", i, BN.GROUP_XP[i])
            end
        end
    end
end

BN.groupStarts = BN.groupStarts or {}

function BN.groupTick()
    local g = BN.group
    if not g then return end
    local now = BN.now()
    local left = g.startAt - now
    if left > 0 then
        if (left == 10 or left <= 3) and g.lastCount ~= left then
            g.lastCount = left
            groupSay("Gruppenrennen %s: Start in %d s", g.name, left)
        end
        return
    end
    if not g.started then
        g.started = true
        groupSay("LOS! Gruppenrennen auf %s – die Zeit läuft ab dem Verlassen des Startbereichs.", g.name)
        return
    end
    local waiting = 0
    for pid in pairs(g.members) do
        local m = BN.players[pid]
        if m and m.race and m.race.group and not g.done[pid] then waiting = waiting + 1 end
    end
    -- Faehrt eine Minute nach dem Start niemand los (alle stehen noch im Startbereich), ist die Gruppe vorbei: so
    -- blockiert niemand die Gruppenrennen, indem er einfach stehen bleibt.
    local moving = #g.results > 0
    for pid in pairs(g.members) do
        local m = BN.players[pid]
        if m and m.race and m.race.group and m.race.state == "running" then moving = true end
    end
    if waiting == 0 or now - g.startAt > C.groupRaceMaxSec or (not moving and now - g.startAt > 60) then BN.endGroup() end
end

function BN.joinGroup(pid)
    local g = BN.group
    local s = session(pid)
    s.series = nil
    local track = BN.loadTracks().tracks[g.name]
    if type(track) ~= "table" or not track.finish then return false end
    g.members[pid] = true
    s.race = { name = g.name, start = point(track.start), finish = point(track.finish), state = "armed", group = true }
    say(pid, "Du fährst mit! Fahr zum Start von %s – Start in %d s.", g.name, math.max(0, g.startAt - BN.now()))
    return true
end

local function groupFinish(s, time)
    local g, r = BN.group, s.race
    if not (g and r and r.group and g.started and g.members[s.pid] and not g.done[s.pid]) then return end
    g.done[s.pid] = true
    g.results[#g.results + 1] = { pid = s.pid, id = s.id, name = s.name, time = time }
    local place = 1
    for _, e in ipairs(g.results) do if e.time < time then place = place + 1 end end
    groupSay("Gruppenrennen: %s im Ziel – %s (vorläufig Platz %d)", s.name, BN.fmtRaceTime(time), place)
end

local function finishRace(s, time)
    local r = s.race
    say(s.pid, "Ziel! %s: %s", r.name, BN.fmtRaceTime(time))
    groupFinish(s, time)
    if not s.guest then
        local data = BN.loadTracks()
        local track = data.tracks[r.name]
        if track then
            -- Strecke ohne bekannte Laenge (aeltere Strecke, Ziel ohne Fahrt gesetzt): der erste gueltige Lauf legt sie fest.
            local changed = false
            if not tonumber(track.lengthM) then
                track.lengthM = math.floor((r.runDist or 0) + 2 * C.raceRadiusM + 0.5)
                changed = true
            end
            track.records = type(track.records) == "table" and track.records or {}
            local previousBest = track.records[1] and tonumber(track.records[1].time)
            local mine
            for _, rec in ipairs(track.records) do
                if rec.id == s.id then mine = rec end
            end
            local improved, bonus = false, C.raceFinishXp
            -- Strecke der Woche: einmal je Woche Bonus-XP.
            local wk = weekKey(BN.now())
            if BN.isTrackOfWeek(r.name) and s.record.weeklyTrackWeek ~= wk and s.pendingWeeklyTrack ~= wk then
                s.pendingWeeklyTrack = wk
                bonus = bonus + C.weeklyTrackXp
                say(s.pid, "Strecke der Woche geschafft: +%d Bonus-XP!", C.weeklyTrackXp)
            end
            if not mine then
                mine = { id = s.id, name = s.name, time = time, at = BN.now() }
                track.records[#track.records + 1] = mine
                improved = true
            elseif time < (tonumber(mine.time) or math.huge) then
                mine.time, mine.at, mine.name = time, BN.now(), s.name
                improved = true
            end
            if improved then
                -- Zwischenzeiten der neuen Bestzeit (nur Marken vor dem Ziel)
                local splits = {}
                for _, t in ipairs(r.splits or {}) do
                    if t < time and #splits < MAX_SPLITS then splits[#splits + 1] = t end
                end
                mine.splits, mine.splitM = splits, C.raceSplitM
            end
            table.sort(track.records, function(a, b) return (tonumber(a.time) or math.huge) < (tonumber(b.time) or math.huge) end)
            while #track.records > 50 do table.remove(track.records) end
            if improved or changed then saveTracks(data) end
            if improved then
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
    r.runDist, r.splits, r.bestSplits, r.recordSplits = nil, nil, nil, nil
    if s.series and not r.group and BN.seriesNext(s, r.name, time) then return end
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
        if dist(cur, r.start) > radius and r.group and BN.group and BN.now() < BN.group.startAt then
            r.state, r.vid = "armed", nil
            say(s.pid, "Fehlstart! Zurück in den Startbereich – Start in %d s.", BN.group.startAt - BN.now())
            return
        end
        if dist(cur, r.start) > radius then
            r.startT = crossTime(prev, cur, t0, t1, r.start, radius)
            r.state = "running"
            -- Fahrstrecke ab dem Verlassen des Startbereichs (Anteil des Abschnitts nach dem Start)
            r.runDist = t1 > t0 and dist(prev, cur) * (t1 - r.startT) / (t1 - t0) or 0
            r.splits, r.bestSplits, r.recordSplits = {}, bestSplits(s, r.name), recordSplits(s, r.name)
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
    -- Erst das Ziel pruefen: eine Marke kurz hinter der Ziellinie darf nicht mehr als Zwischenzeit erscheinen.
    local finishT
    if r.leftFinish and d <= radius then finishT = crossTime(prev, cur, t0, t1, r.finish, radius) - r.startT end
    raceSplits(s, prev, cur, t0, t1, finishT)
    if not r.leftFinish then
        if d > BN.leaveDistance() then r.leftFinish = true end
        return
    end
    if finishT then
        -- Zu kurz gefahren (z. B. auf einem Rundkurs nur kurz raus und zurueck): kein gueltiger Lauf.
        local track = BN.loadTracks().tracks[r.name]
        local lengthM = type(track) == "table" and track.lengthM or nil
        if (r.runDist or 0) < BN.raceMinDist(r.start, r.finish, lengthM) then
            BN.raceInvalid(s, "Strecke abgekürzt")
            return
        end
        finishRace(s, finishT)
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
BN.modlog = modlog

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
        local same = type(m) == "table" and ((s.id and m.id == s.id) or (not s.id and s.ip and m.ip == s.ip))
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
    BN.loadEvent(now)
    local data = json.decode(readFile(announcementsFile()) or "")
    if type(data) == "table" and type(data.list) == "table" then
        for _, a in ipairs(data.list) do
            -- Geplante Ansagen (Zeit in der Zukunft) warten; verpasste (Server war aus) nach 2 Minuten nicht mehr.
            local at = type(a) == "table" and tonumber(a.at) or 0
            if type(a) == "table" and a.id and not BN.seenAnnouncements[a.id] and at <= now then
                BN.seenAnnouncements[a.id] = true
                if now - at <= 120 then sayAll("[Ansage] %s", tostring(a.text)) end
            end
        end
    end
end

-- XP-Event (netzweit): event.json im gemeinsamen Ordner, von /event geschrieben, von allen Servern beim Abgleich
-- gelesen. Faktor 1,5 bis 5, hoechstens 24 Stunden. Start und Ende werden auf jedem Server einmal angesagt.
BN.EVENT_MAX_SEC = 24 * 3600

local function fmtFactor(f)
    if f == math.floor(f) then return string.format("%d", f) end
    return (string.format("%.1f", f):gsub("%.", ","))
end

function BN.activeEvent()
    local ev = BN.event
    if ev and ev["until"] > BN.now() then return ev end
    return nil
end

function BN.loadEvent(now)
    local data = json.decode(readFile(eventFile()) or "")
    local ev = nil
    if type(data) == "table" then
        local factor, untilAt = tonumber(data.factor), tonumber(data["until"])
        if factor and untilAt and factor >= 1.5 and factor <= 5 and untilAt > now and untilAt - now <= BN.EVENT_MAX_SEC then
            ev = { factor = factor, ["until"] = untilAt, by = tostring(data.by or "?"), id = tostring(data.id or untilAt) }
        end
    end
    local before = BN.event
    if ev and (not before or before.id ~= ev.id) then
        BN.event = ev
        if not BN.eventSeen[ev.id] then
            BN.eventSeen[ev.id] = true
            sayAll("XP-Event: %s-fache XP bis %s Uhr! (gestartet von %s)", fmtFactor(ev.factor), os.date("%H:%M", ev["until"]), ev.by)
        end
    elseif not ev and before then
        BN.event = nil
        sayAll("Das XP-Event ist vorbei – danke fürs Mitfahren!")
    end
end
BN.eventSeen = BN.eventSeen or {}

-- Beim Start: alte Ansagen nicht wiederholen.
function BN.markAnnouncementsSeen()
    local data = json.decode(readFile(announcementsFile()) or "")
    if type(data) == "table" and type(data.list) == "table" then
        for _, a in ipairs(data.list) do
            -- Geplante (noch kommende) Ansagen nicht als gesehen markieren.
            if type(a) == "table" and a.id and (tonumber(a.at) or 0) <= BN.now() then BN.seenAnnouncements[a.id] = true end
        end
    end
end

-- at: Zeitpunkt (Standard jetzt); liegt er in der Zukunft, sagen alle Server die Ansage dann an.
function BN.announce(text, by, at)
    local now = BN.now()
    at = at or now
    local data = json.decode(readFile(announcementsFile()) or "")
    if type(data) ~= "table" or type(data.list) ~= "table" then data = { list = {} } end
    local id = string.format("%d-%s-%d", now, tostring(BN.server.port), math.random(100000, 999999))
    -- Nur gueltige Eintraege behalten; beim Kuerzen zuerst die laengst angesagten, geplante bleiben moeglichst.
    local kept = {}
    for _, a in ipairs(data.list) do
        if type(a) == "table" and tonumber(a.at) then kept[#kept + 1] = a end
    end
    kept[#kept + 1] = { id = id, text = text, by = by, at = at }
    while #kept > 20 do
        local drop = 1
        for i, a in ipairs(kept) do
            if tonumber(a.at) < now - 120 then drop = i break end     -- schon von allen Servern angesagt
        end
        table.remove(kept, drop)
    end
    data.list = kept
    ensureDir(C.sharedDir)
    writeFileAtomic(announcementsFile(), json.encode(data))
    if at <= now then
        BN.seenAnnouncements[id] = true
        sayAll("[Ansage] %s", text)
    end
end

-- Naechster Zeitpunkt fuer "HH:MM" (heute oder, wenn schon vorbei, morgen) in Ortszeit des Servers.
function BN.nextClockTime(hhmm)
    local h, m = tostring(hhmm or ""):match("^(%d%d?):(%d%d)$")
    h, m = tonumber(h), tonumber(m)
    if not h or h > 23 or m > 59 then return nil end
    local now = BN.now()
    local t = os.date("*t", now)
    -- isdst offen lassen: sonst uebernimmt os.time die Sommer-/Winterzeit von jetzt (Ansage ueber die Zeitumstellung
    -- hinweg eine Stunde daneben).
    t.hour, t.min, t.sec, t.isdst = h, m, 0, nil
    local at = os.time(t)
    if at <= now then
        t = os.date("*t", now)
        t.day, t.hour, t.min, t.sec, t.isdst = t.day + 1, h, m, 0, nil
        at = os.time(t)
    end
    return at
end

-- Spamschutz. Gibt true zurueck, wenn die Nachricht unterdrueckt werden soll.
-- Wortfilter: true, wenn die Nachricht ein Wort aus C.badWords enthaelt (dann wird sie nicht gesendet).
function BN.filterHit(message)
    if type(C.badWords) ~= "table" or #C.badWords == 0 then return false end
    local text = tostring(message):lower()
    -- Woerter: Buchstaben, Ziffern und UTF-8-Zeichen (Umlaute); Satzzeichen trennen. Haeufige Ersatzzeichen zaehlen
    -- als Buchstaben (4 -> a, 3 -> e, 1 -> i, 0 -> o, $ -> s, @ -> a).
    text = text:gsub("[4@]", "a"):gsub("3", "e"):gsub("1", "i"):gsub("0", "o"):gsub("%$", "s")
    for word in text:gmatch("[%w\128-\255]+") do
        for _, bad in ipairs(C.badWords) do
            bad = bad:lower()
            if word == bad or (#bad >= 6 and word:find(bad, 1, true)) then return true end
        end
    end
    return false
end

function BN.filterCheck(s, message)
    if BN.isAdmin(s) or not BN.filterHit(message) then return false end
    local now = BN.now()
    local kept = {}
    for _, t in ipairs(s.filterTimes or {}) do if now - t < 600 then kept[#kept + 1] = t end end
    kept[#kept + 1] = now
    s.filterTimes = kept
    if #kept >= C.filterStrikes then
        s.filterTimes = {}
        s.mutedUntil = now + C.filterMuteSec
        s.muteNoticeAt = now
        BN.saveMute(s, s.mutedUntil)          -- gilt auch nach dem Neuverbinden und auf den anderen Servern
        say(s.pid, "Bitte freundlich bleiben – du bist %d Minuten stummgeschaltet.", math.ceil(C.filterMuteSec / 60))
        modlog({ action = "filter-mute", target = s.name, targetId = s.id, seconds = C.filterMuteSec })
    else
        say(s.pid, "Bitte freundlich bleiben – deine Nachricht wurde nicht gesendet (%d/%d).", #kept, C.filterStrikes)
    end
    return true
end

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

function commands.start(pid)
    local s = session(pid)
    local lang = BN.langOf(pid)
    if s.guest then say(pid, "Den Einsteiger-Pfad gibt es mit BeamMP-Konto.") return end
    local done = tutorialState(s)
    if not done then say(pid, "Du kennst dich schon aus – /hilfe zeigt alle Befehle.") return end
    say(pid, "Einsteiger-Pfad: %d von %d geschafft (je +%d XP, alle zusammen +%d XP extra)", done, #BN.TUTORIAL, C.tutorialXp, C.tutorialDoneXp)
    for _, step in ipairs(BN.TUTORIAL) do
        local ok = s.record.tutorial[step.id] or (s.tutorialDone and s.tutorialDone[step.id])
        chat(pid, (ok and "✔ " or "✘ ") .. tr(lang, step.text))
    end
end
commands.einsteiger = commands.start

function commands.hilfe(pid)
    -- In Gruppen: eine einzige lange Zeile wird im BeamNG-Chat schlecht lesbar oder abgeschnitten.
    say(pid, "BeamNet-Befehle:")
    say(pid, "Spielen: /heute · /auftrag · /rennen · /serie · /duell <Name> <Strecke> · /fangen · /konvoi · /aufgabe · /ziel · /vote")
    say(pid, "Du: /stats [Name] · /km · /erfolge · /liga · /saison · /top [km|xp|speed|auftraege|konvoi|jagd|woche]")
    say(pid, "Netzwerk: /server · /wo <Name> · /freund <Name> · /team · /orte · /rekorde · /event")
    say(pid, "Sonst: /start · /regeln · /melden <Name> <Grund> · /lang en")
    if BN.isAdmin(BN.players[pid]) then
        say(pid, "Admin: /kick · /ban <Name> [30m|2h|7d] [Grund] · /unban · /bans · /warn · /mute · /ansage · /ort neu <Typ> <Name> · /resetspeed")
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
        local titles, parts = BN.titlesFor(s.id), {}
        for i = 1, math.min(3, #titles) do parts[#parts + 1] = BN.titleText(titles[i], lang) end
        if #parts > 0 then say(pid, "Titel: %s", table.concat(parts, " · ")) end
        local jobs = (tonumber(s.record.jobsDone) or 0) + (s.pendingJobs or 0)
        if jobs > 0 then say(pid, "Aufträge erledigt: %d", jobs) end
        local streak = BN.streakOf(s.record)
        if streak >= 2 or (tonumber(s.record.bestStreak) or 0) >= 2 then
            say(pid, "Serie: %d Tage in Folge (beste: %d)", streak, math.max(streak, tonumber(s.record.bestStreak) or 0))
        end
        local team = BN.teamNameOf and BN.teamNameOf(s.id)
        if team then say(pid, "Team: %s (/team)", team) end
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
    elseif mode == "speed" or mode == "tempo" or mode == "kmh" then
        local fast = {}
        for _, r in ipairs(list) do if (r.topSpeedKmh or 0) > 0 then fast[#fast + 1] = r end end
        table.sort(fast, function(a, b)
            if a.topSpeedKmh ~= b.topSpeedKmh then return a.topSpeedKmh > b.topSpeedKmh end
            return tostring(a.name) < tostring(b.name)
        end)
        list = fast
        label, value = "Höchstgeschwindigkeit", function(r) return string.format("%d km/h", math.floor(r.topSpeedKmh + 0.5)) end
    elseif mode == "auftraege" or mode == "aufträge" or mode == "jobs" or mode == "auftrag" then
        local workers = {}
        for _, r in ipairs(list) do if (r.jobsDone or 0) > 0 then workers[#workers + 1] = r end end
        table.sort(workers, function(a, b)
            if a.jobsDone ~= b.jobsDone then return a.jobsDone > b.jobsDone end
            return tostring(a.name) < tostring(b.name)
        end)
        list = workers
        label, value = "Aufträge", function(r) return tostring(math.floor(r.jobsDone)) end
    elseif mode == "konvoi" or mode == "convoy" or mode == "jagd" or mode == "fangen" or mode == "chase" then
        local field = (mode == "konvoi" or mode == "convoy") and "convoyKm" or "chaseWins"
        local some = {}
        for _, r in ipairs(list) do if (r[field] or 0) > 0 then some[#some + 1] = r end end
        table.sort(some, function(a, b)
            if a[field] ~= b[field] then return a[field] > b[field] end
            return tostring(a.name) < tostring(b.name)
        end)
        list = some
        if field == "convoyKm" then
            label, value = "Kilometer im Konvoi", function(r) return fmtKm(r.convoyKm) end
        else
            label, value = "Gewonnene Verfolgungsjagden", function(r) return tostring(math.floor(r.chaseWins)) end
        end
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
    local bm = BN.bonusMap()
    for _, st in ipairs(list) do
        local addr = C.publicHost ~= "" and (C.publicHost .. ":" .. tostring(st.port)) or tr(lang, "Port %s", tostring(st.port))
        local here = tonumber(st.port) == tonumber(BN.server.port) and tr(lang, "  ← hier") or ""
        local full = (tonumber(st.max) or 0) > 0 and (tonumber(st.players) or 0) >= (tonumber(st.max) or 0)
        local bonus = bm and st.map == bm.map and tr(lang, " ⭐ Bonus-Map") or ""
        chat(pid, string.format("%s · %s · %d/%d%s%s · %s%s", st.name or "?", st.map or "?", tonumber(st.players) or 0,
            tonumber(st.max) or 0, full and tr(lang, " (voll)") or "", bonus, addr, here))
    end
end
commands.servers = commands.server

-- Wo ist was los? Wer hier (fast) allein faehrt, bekommt ab und zu den vollsten anderen Server genannt – so finden die
-- Spieler zueinander. Zuerst 2 Minuten nach dem ersten Spieler, danach alle crowdHintSec Sekunden.
function BN.crowdTick()
    if C.crowdHintSec <= 0 then return end
    local here = 0
    for _ in pairs(BN.players) do here = here + 1 end
    local now = BN.now()
    if here == 0 or here > C.crowdMaxHere then BN.nextCrowdAt = nil return end
    if not BN.nextCrowdAt then BN.nextCrowdAt = now + 120 return end
    if now < BN.nextCrowdAt then return end
    local best
    for _, st in ipairs(BN.serverList()) do
        local n, mx = tonumber(st.players) or 0, tonumber(st.max) or 0
        if tonumber(st.port) ~= tonumber(BN.server.port) and n >= math.max(C.crowdMinPlayers, here + 2)
            and (mx <= 0 or n < mx) and (not best or n > (tonumber(best.players) or 0)) then
            best = st
        end
    end
    if not best then BN.nextCrowdAt = now + 60 return end
    BN.nextCrowdAt = now + C.crowdHintSec
    local name, map = clipText(best.name or "?", 48), clipText(best.map or "?", 32)
    sayEach(function(lang)
        local addr = C.publicHost ~= "" and (C.publicHost .. ":" .. tostring(best.port)) or tr(lang, "Port %s", tostring(best.port))
        return tr(lang, "👋 Auf %s (%s) fahren gerade %d Spieler – komm rüber! %s", name, map,
            tonumber(best.players) or 0, addr)
    end)
end

-- /wo <Name>: Auf welchem Server faehrt jemand gerade? Dieser Server live, die anderen aus ihren Lebenszeichen.
function commands.wo(pid, arg)
    local query = tostring(arg or ""):match("^%s*(.-)%s*$")
    if query == "" then
        say(pid, "Aufruf: /wo <Name> – zeigt, auf welchem Server jemand gerade fährt.")
        return
    end
    local lower, lang, hits = query:lower(), BN.langOf(pid), {}
    for _, s in pairs(BN.players) do
        if s.name:lower():find(lower, 1, true) then hits[#hits + 1] = { name = s.name } end
    end
    for _, st in ipairs(BN.serverList()) do
        if tonumber(st.port) ~= tonumber(BN.server.port) and type(st.names) == "table" then
            for _, n in ipairs(st.names) do
                n = tostring(n)
                if n:lower():find(lower, 1, true) then hits[#hits + 1] = { name = n, st = st } end
            end
        end
    end
    if #hits == 0 then
        say(pid, "Niemand mit „%s“ gerade im Netzwerk.", query)
        return
    end
    table.sort(hits, function(a, b) return a.name:lower() < b.name:lower() end)
    for i = 1, math.min(5, #hits) do
        local h = hits[i]
        if not h.st then
            say(pid, "%s ist hier auf diesem Server.", h.name)
        else
            local addr = C.publicHost ~= "" and (C.publicHost .. ":" .. tostring(h.st.port)) or tr(lang, "Port %s", tostring(h.st.port))
            say(pid, "%s fährt auf %s (%s) · %s", h.name, tostring(h.st.name or "?"), tostring(h.st.map or "?"), addr)
        end
    end
    if #hits > 5 then say(pid, "… und %d weitere – bitte genauer schreiben.", #hits - 5) end
end
commands.where = commands.wo

-- /duell <Name> <Strecke>: einen Spieler auf diesem Server zu einem Zeitrennen herausfordern; er nimmt mit /duell ja an
-- (60 s Zeit). Das Duell ist ein Gruppenrennen nur fuer die beiden (Start nach 15 s, Fehlstart wie dort).
BN.duelInvites = BN.duelInvites or {}

function commands.duell(pid, arg)
    local s = session(pid)
    local words = {}
    for w in tostring(arg or ""):gmatch("%S+") do words[#words + 1] = w end
    local sub = (words[1] or ""):lower()
    local now = BN.now()
    if sub == "ja" or sub == "yes" or sub == "annehmen" or sub == "accept" then
        local inv = BN.duelInvites[pid]
        BN.duelInvites[pid] = nil
        local from = inv and BN.players[inv.from]
        -- Die Einladung gilt nur fuer genau diese beiden Sitzungen (Spielernummern werden neu vergeben).
        if not inv or not from or now - inv.at > 60 or from.id ~= inv.fromId or s.id ~= inv.toId
            or from.name ~= inv.fromName or s.name ~= inv.toName then
            say(pid, "Keine offene Herausforderung.")
            return
        end
        -- Ein laufender Lauf wird nicht einfach ueberschrieben (eine nur vorbereitete Strecke schon).
        if (from.race and from.race.state == "running") or (s.race and s.race.state == "running") then
            say(pid, "Erst das laufende Rennen beenden (/rennen stop).")
            return
        end
        -- Wie beim Gruppenrennen: hoechstens alle 3 Minuten je Spieler (beide), auch ueber Neuverbinden hinweg.
        for _, p in ipairs({ from, s }) do
            local last = BN.groupStarts[p.id or ("ip:" .. tostring(p.ip or p.pid))]
            if last and now - last < 180 then
                say(pid, "Bitte warte noch %d s, bevor ihr wieder ein Rennen startet.", 180 - (now - last))
                return
            end
        end
        for _, p in ipairs({ from, s }) do BN.groupStarts[p.id or ("ip:" .. tostring(p.ip or p.pid))] = now end
        if BN.group then
            say(pid, "Gerade läuft schon ein Gruppenrennen – bitte gleich noch einmal herausfordern.")
            return
        end
        local track = BN.loadTracks().tracks[inv.track]
        if type(track) ~= "table" or not track.finish then
            say(pid, "Die Strecke %s gibt es nicht mehr.", inv.track)
            return
        end
        BN.group = { name = inv.track, startAt = now + 15, by = from.name, members = {}, results = {}, done = {}, duel = true }
        BN.joinGroup(inv.from)
        BN.joinGroup(pid)
        say(inv.from, "⚔️ %s nimmt dein Duell an! Strecke %s, Start in 15 s.", s.name, inv.track)
        say(pid, "⚔️ Duell gegen %s auf %s – Start in 15 s.", from.name, inv.track)
        return
    end
    if sub == "nein" or sub == "no" or sub == "ablehnen" then
        local inv = BN.duelInvites[pid]
        BN.duelInvites[pid] = nil
        if inv and BN.players[inv.from] then say(inv.from, "%s hat dein Duell abgelehnt.", s.name) end
        say(pid, "Herausforderung abgelehnt.")
        return
    end
    local name = trackName(words[2])
    local target = sub ~= "" and findPlayerByName(words[1])
    if not target or not name then
        say(pid, "Aufruf: /duell <Name> <Strecke> · annehmen: /duell ja · ablehnen: /duell nein")
        return
    end
    if target.pid == pid then say(pid, "Gegen dich selbst geht kein Duell.") return end
    local track = BN.loadTracks().tracks[name]
    if type(track) ~= "table" or not track.finish then
        say(pid, "Strecke \"%s\" gibt es auf dieser Map nicht. Liste: /rennen", name)
        return
    end
    if s.mutedUntil and now < s.mutedUntil then
        say(pid, "Du bist noch %d s stummgeschaltet.", s.mutedUntil - now)
        return
    end
    if s.lastDuelAt and now - s.lastDuelAt < 60 then
        say(pid, "Bitte warte noch %d s vor der nächsten Herausforderung.", 60 - (now - s.lastDuelAt))
        return
    end
    if BN.group then say(pid, "Gerade läuft ein Gruppenrennen – danach geht's.") return end
    s.lastDuelAt = now
    BN.duelInvites[target.pid] = { from = pid, fromId = s.id, fromName = s.name, toId = target.id, toName = target.name,
                                   track = name, at = now }
    say(target.pid, "⚔️ %s fordert dich zum Duell auf %s heraus! Annehmen: /duell ja · ablehnen: /duell nein (60 s)", s.name, name)
    say(pid, "Herausforderung an %s gesendet.", target.name)
end
commands.duel = commands.duell

-- Strecke der Woche: aus allen Strecken mit Ziel auf allen Maps (races/*.json), nach Map und Name sortiert, je
-- Kalenderwoche eine – auf allen Servern dieselbe. Die Wahl steht in weekly-track.json (fuer die Statusseite).
BN.weeklyCache = BN.weeklyCache or {}

function BN.trackOfWeek()
    if C.weeklyTrackXp <= 0 then return nil end
    local now = BN.now()
    local wk = weekKey(now)
    local c = BN.weeklyCache
    if c.week == wk and now - (c.at or 0) < 3600 then return c.pick end
    local all = {}
    for _, file in ipairs(listJsonFiles(racesDir())) do
        local map = file:match("([^/\\]+)%.json$")
        local data = json.decode(readFile(file) or "")
        if map and type(data) == "table" and type(data.tracks) == "table" then
            for name, t in pairs(data.tracks) do
                if type(t) == "table" and t.finish then all[#all + 1] = { map = map, name = tostring(name) } end
            end
        end
    end
    table.sort(all, function(a, b) if a.map ~= b.map then return a.map < b.map end return a.name < b.name end)
    local pick = nil
    -- Die Wahl der Woche gilt die ganze Woche (wer zuerst waehlt, legt sie fest), solange es die Strecke noch gibt –
    -- neue oder geloeschte Strecken aendern sie nicht mehr mitten in der Woche.
    local saved = json.decode(readFile(C.sharedDir .. "/weekly-track.json") or "")
    if type(saved) == "table" and saved.week == wk then
        for _, t in ipairs(all) do
            if t.map == saved.map and t.name == saved.name then pick = { map = t.map, name = t.name, week = wk } end
        end
    end
    if not pick and #all > 0 then
        -- Nur Maps, die gerade ein Server faehrt (sonst ist der Bonus nicht zu holen); ohne Serverliste alle.
        local running, active = { [BN.mapKey()] = true }, {}
        for _, st in ipairs(BN.serverList()) do running[BN.mapKey(st.map)] = true end
        for _, t in ipairs(all) do if running[t.map] then active[#active + 1] = t end end
        if #active == 0 then active = all end
        local year, num = wk:match("^(%d+)%-W(%d+)$")
        local n = (tonumber(year) or 0) * 53 + (tonumber(num) or 0)
        local t = active[(n % #active) + 1]
        pick = { map = t.map, name = t.name, week = wk }
        writeFileAtomic(C.sharedDir .. "/weekly-track.json", json.encode({ week = wk, map = pick.map, name = pick.name, xp = C.weeklyTrackXp }))
    end
    BN.weeklyCache = { week = wk, at = now, pick = pick }
    return pick
end

function BN.isTrackOfWeek(name)
    local w = BN.trackOfWeek()
    return w ~= nil and w.map == BN.mapKey() and w.name == name
end

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
        local w = BN.trackOfWeek()
        if w then say(pid, "Strecke der Woche: %s auf %s – %d Bonus-XP für den ersten Lauf der Woche", w.name, w.map, C.weeklyTrackXp) end
        say(pid, "Starten: /rennen <Name> · gemeinsam: /rennen gruppe <Name> · beenden: /rennen stop · Rekorde: /rekorde <Name>")
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
            s.race, s.series = nil, nil
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
            -- Serien mit dieser Strecke liessen sich nicht mehr fahren: mit entfernen.
            local gone = {}
            if type(data.series) == "table" then
                for n, d in pairs(data.series) do
                    local uses = type(d) ~= "table" or type(d.tracks) ~= "table"
                    if not uses then for _, t in ipairs(d.tracks) do if t == name then uses = true end end end
                    if uses then gone[#gone + 1] = n end
                end
                for _, n in ipairs(gone) do data.series[n] = nil end
            end
            saveTracks(data)
            say(pid, "Strecke %s gelöscht.", name)
            if #gone > 0 then
                table.sort(gone)
                say(pid, "Mit gelöscht (Serien mit dieser Strecke): %s", table.concat(gone, ", "))
            end
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
            -- Ab jetzt die gefahrene Strecke bis /rennen ziel mitzaehlen (Streckenlaenge)
            flushMoved(s)
            s.trackDraft = { name = name, dist = 0 }
            say(pid, "Start von %s gesetzt. Jetzt zum Ziel fahren und /rennen ziel %s schreiben.", name, name)
        else
            if not track then say(pid, "Strecke %s gibt es nicht – zuerst /rennen neu %s", name, name) return end
            track.finish = point(pos)
            track.records = {}           -- neues Ziel: alte Zeiten passen nicht mehr
            local d = dist(point(pos), point(track.start))
            -- Streckenlaenge: was der Admin seit /rennen neu gefahren ist, wenn das plausibel ist (Rundkurs: weiter als
            -- hin und zurueck aus dem Zielbereich, sonst etwa die Luftlinie); sonst legt der erste gueltige Lauf sie fest.
            flushMoved(s)
            local draft = s.trackDraft
            s.trackDraft = nil
            local driven = draft and draft.name == name and draft.dist or 0
            local lap = d <= C.raceRadiusM
            if driven > 0 and driven >= (lap and 2 * BN.leaveDistance() or 0.9 * d) then
                track.lengthM = math.floor(driven + 0.5)
            else
                track.lengthM = nil
            end
            saveTracks(data)
            if lap then
                say(pid, "Ziel von %s gesetzt – Rundkurs (Start = Ziel). Starten: /rennen %s", name, name)
            else
                say(pid, "Ziel von %s gesetzt (%.0f m Luftlinie). Starten: /rennen %s", name, d, name)
            end
            if track.lengthM then
                say(pid, "Streckenlänge %.0f m (von dir gefahren) – deutlich kürzere Läufe sind ungültig.", track.lengthM)
            else
                say(pid, "Streckenlänge unbekannt – der erste gültige Lauf legt sie fest.")
            end
        end
        return
    end
    if sub == "gruppe" or sub == "group" then
        local name = trackName(words[2])
        local track = name and BN.loadTracks().tracks[name]
        if not track or not track.finish then
            say(pid, "Aufruf: /rennen gruppe <Strecke> – die Strecke braucht ein Ziel. Liste: /rennen")
            return
        end
        if BN.group then
            say(pid, "Es läuft schon ein Gruppenrennen auf %s – mitmachen: /rennen mit", BN.group.name)
            return
        end
        if not BN.isAdmin(s) then
            if s.mutedUntil and BN.now() < s.mutedUntil then
                say(pid, "Du bist noch %d s stummgeschaltet.", s.mutedUntil - BN.now())
                return
            end
            -- Hoechstens ein Gruppenrennen je Spieler alle 3 Minuten (auch ueber Neuverbinden hinweg).
            local key = s.id or ("ip:" .. tostring(s.ip or s.pid))
            local last = BN.groupStarts[key]
            if last and BN.now() - last < 180 then
                say(pid, "Bitte warte noch %d s, bevor du wieder ein Gruppenrennen startest.", 180 - (BN.now() - last))
                return
            end
            for k, t in pairs(BN.groupStarts) do if BN.now() - t >= 180 then BN.groupStarts[k] = nil end end
            BN.groupStarts[key] = BN.now()
        end
        BN.group = { name = name, startAt = BN.now() + C.groupRaceDelaySec, by = s.name, members = {}, results = {}, done = {} }
        sayAll("Gruppenrennen auf %s in %d s, gestartet von %s! Mitmachen: /rennen mit", name, C.groupRaceDelaySec, s.name)
        BN.joinGroup(pid)
        return
    end
    if sub == "mit" or sub == "join" then
        if not BN.group or BN.now() >= BN.group.startAt then
            say(pid, "Gerade kann man keinem Gruppenrennen beitreten. Neues: /rennen gruppe <Strecke>")
            return
        end
        if BN.group.duel then
            say(pid, "Gerade läuft ein Duell – da kann man nicht mitfahren.")
            return
        end
        BN.joinGroup(pid)
        return
    end
    -- Lauf vorbereiten
    s.series = nil
    BN.prepareRace(s, trackName(sub), words[1])
end

-- Bereitet einen Lauf auf der Strecke vor (Spieler faehrt dann zum Start). false, wenn es die Strecke nicht gibt.
function BN.prepareRace(s, name, shown)
    local pid = s.pid
    local track = name and BN.loadTracks().tracks[name]
    if not track then
        say(pid, "Strecke \"%s\" gibt es auf dieser Map nicht. Liste: /rennen", tostring(shown or name))
        return false
    end
    if not track.finish then
        say(pid, "Strecke %s hat noch kein Ziel.", name)
        return false
    end
    s.race = { name = name, start = point(track.start), finish = point(track.finish), state = "armed" }
    local pos = currentPosition(s)
    if pos then
        say(pid, "Rennen %s: Fahr zum Start (%.0f m entfernt).", name, dist(point(pos), s.race.start))
    else
        say(pid, "Rennen %s: Fahr zum Start.", name)
    end
    return true
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Rennserien: mehrere Strecken einer Map nacheinander; es zaehlt die Summe der Zeiten (die Anfahrt zum naechsten
-- Start nicht), innerhalb von 30 Minuten. Serien stehen in races/<Map>.json unter "series".

BN.SERIES_MAX_SEC = 1800
-- Unterbefehle von /serie: als Serienname nicht startbar.
BN.SERIES_RESERVED = { stop = true, liste = true, list = true, neu = true, new = true, weg = true, loeschen = true,
                       ["löschen"] = true, delete = true }

-- Naechster Teil nach einem Zieleinlauf; true, wenn die Serie weitergeht oder gerade fertig wurde.
function BN.seriesNext(s, trackDone, time)
    local se = s.series
    if not se or se.tracks[se.idx] ~= trackDone then return false end
    local now = BN.now()
    if now - se.startAt > BN.SERIES_MAX_SEC then
        s.series = nil
        say(s.pid, "Serie %s abgebrochen – mehr als 30 Minuten. Neuer Versuch: /serie %s", se.name, se.name)
        return false
    end
    se.total = se.total + time
    se.idx = se.idx + 1
    if se.idx <= #se.tracks then
        say(s.pid, "Serie %s: Teil %d von %d geschafft (bisher %s). Weiter: %s", se.name, se.idx - 1, #se.tracks,
            BN.fmtRaceTime(se.total), se.tracks[se.idx])
        if not BN.prepareRace(s, se.tracks[se.idx]) then s.series = nil end
        return true
    end
    s.series, s.race = nil, nil
    local total = se.total
    -- XP nur fuer eine neue eigene Bestzeit (die erste Runde ist immer eine): sonst liesse sich eine kurze Serie
    -- endlos fuer XP wiederholen.
    local bonus, record, best = s.guest and C.seriesXp or 0, false, nil
    if not s.guest then
        local data = BN.loadTracks()
        local def = type(data.series) == "table" and data.series[se.name]
        if type(def) == "table" then
            local records = {}
            if type(def.records) == "table" then
                for _, e in ipairs(def.records) do
                    if type(e) == "table" and tonumber(e.time) and type(e.id) == "string" then records[#records + 1] = e end
                end
            end
            def.records = records
            table.sort(records, function(a, b) return tonumber(a.time) < tonumber(b.time) end)
            local prevBest = records[1] and tonumber(records[1].time)
            local mine
            for _, e in ipairs(records) do if e.id == s.id then mine = e end end
            -- Serien-XP: fuer die erste Runde oder eine deutlich bessere Bestzeit (mindestens 2 % schneller), und je
            -- Serie hoechstens einmal am Tag – sonst liesse sich mit einer absichtlich langsamen ersten Runde (oder
            -- ausserhalb der 50 gespeicherten Zeiten) endlos XP sammeln.
            local earn = not mine or total <= tonumber(mine.time) * 0.98
            if not mine then
                records[#records + 1] = { id = s.id, name = s.name, time = total, at = now }
            elseif total < tonumber(mine.time) then
                mine.time, mine.name, mine.at = total, s.name, now
            end
            if not earn then best = tonumber(mine.time) end
            local today = dayNumber()
            if BN.seriesPaidDay ~= today then BN.seriesPaid, BN.seriesPaidDay = {}, today end
            local key = s.id .. "|" .. BN.mapKey() .. "|" .. se.name
            if earn and BN.seriesPaid[key] then earn, best = false, tonumber(mine and mine.time or total) end
            if earn then
                bonus = C.seriesXp
                BN.seriesPaid[key] = true
            end
            table.sort(records, function(a, b) return tonumber(a.time) < tonumber(b.time) end)
            while #records > 50 do table.remove(records) end
            if not prevBest or total < prevBest then
                record = true
                if earn then bonus = bonus + C.raceRecordXp end   -- gleiche Regeln wie die Serien-XP
            end
            saveTracks(data)
        end
    end
    s.pendingBonus = s.pendingBonus + bonus
    if record then
        sayAll("🏆 Neuer Serienrekord %s: %s in %s!", se.name, s.name, BN.fmtRaceTime(total))
    end
    if best then
        say(s.pid, "🏁 Serie %s geschafft: %s gesamt (deine Bestzeit: %s – Serien-XP gibt es einmal am Tag für eine deutlich bessere Bestzeit)", se.name,
            BN.fmtRaceTime(total), BN.fmtRaceTime(best))
    else
        say(s.pid, "🏁 Serie %s geschafft: %s gesamt – +%d XP", se.name, BN.fmtRaceTime(total), bonus)
    end
    return true
end

function commands.serie(pid, arg)
    local s = session(pid)
    local words = {}
    for w in tostring(arg or ""):gmatch("%S+") do words[#words + 1] = w end
    local sub = (words[1] or ""):lower()
    local data = BN.loadTracks()
    local series = type(data.series) == "table" and data.series or {}
    if sub == "" or sub == "liste" or sub == "list" then
        local names = {}
        for n, d in pairs(series) do if type(n) == "string" and type(d) == "table" and type(d.tracks) == "table" then names[#names + 1] = n end end
        table.sort(names)
        if #names == 0 then
            say(pid, "Noch keine Serien auf dieser Map. Admins: /serie neu <Name> <Strecke1> <Strecke2> …")
            return
        end
        say(pid, "Serien auf dieser Map – starten mit /serie <Name>:")
        for _, n in ipairs(names) do
            local d = series[n]
            local best = type(d.records) == "table" and type(d.records[1]) == "table" and tonumber(d.records[1].time)
                and d.records[1] or nil
            local tracks = {}
            for i, t in ipairs(d.tracks) do if i <= 5 then tracks[i] = tostring(t) end end
            chat(pid, string.format("%s: %s%s", n, table.concat(tracks, " → "),
                best and (" · " .. clipText(best.name, 32) .. " " .. BN.fmtRaceTime(tonumber(best.time))) or ""))
        end
        return
    end
    if sub == "stop" then
        if not s.series then say(pid, "Du fährst gerade keine Serie.") return end
        s.series, s.race = nil, nil
        say(pid, "Serie abgebrochen.")
        return
    end
    if sub == "neu" or sub == "new" or sub == "weg" or sub == "loeschen" or sub == "löschen" or sub == "delete" then
        if not BN.isAdmin(s) then say(pid, "Serien anlegen dürfen nur Admins.") return end
        local name = trackName(words[2])
        if not name then say(pid, "Aufruf: /serie neu <Name> <Strecke1> <Strecke2> … · /serie weg <Name>") return end
        if sub ~= "neu" and sub ~= "new" then
            if not series[name] then say(pid, "Die Serie %s gibt es nicht.", name) return end
            series[name] = nil
            data.series = series
            saveTracks(data)
            say(pid, "Serie %s gelöscht.", name)
            return
        end
        if BN.SERIES_RESERVED[name] then say(pid, "%s ist ein Befehl und kein Serienname – bitte einen anderen Namen.", name) return end
        local tracks, seen = {}, {}
        for i = 3, #words do
            local t = trackName(words[i])
            local def = t and data.tracks[t]
            if type(def) ~= "table" or not def.finish then
                say(pid, "Strecke \"%s\" gibt es auf dieser Map nicht (oder sie hat kein Ziel).", tostring(words[i]))
                return
            end
            if seen[t] then say(pid, "Jede Strecke nur einmal pro Serie (%s doppelt).", t) return end
            seen[t] = true
            tracks[#tracks + 1] = t
        end
        if #tracks < 2 or #tracks > 5 then say(pid, "Eine Serie hat 2 bis 5 Strecken.") return end
        local count = 0
        for _ in pairs(series) do count = count + 1 end
        if not series[name] and count >= 20 then say(pid, "Auf dieser Map gibt es schon 20 Serien.") return end
        series[name] = { tracks = tracks, by = s.name, records = {} }
        data.series = series
        if not saveTracks(data) then say(pid, "Speichern fehlgeschlagen – bitte beamnet doctor prüfen.") return end
        say(pid, "Serie %s angelegt: %s", name, table.concat(tracks, " → "))
        return
    end
    local name = trackName(sub)
    local def = name and series[name]
    if type(def) ~= "table" or type(def.tracks) ~= "table" or #def.tracks < 2 then
        say(pid, "Die Serie \"%s\" gibt es auf dieser Map nicht. Liste: /serie", tostring(words[1]))
        return
    end
    if BN.group and BN.group.members[pid] then say(pid, "Erst das Gruppenrennen beenden.") return end
    local tracks = {}
    for i, t in ipairs(def.tracks) do if i <= 5 then tracks[i] = tostring(t) end end
    s.series = { name = name, tracks = tracks, idx = 1, total = 0, startAt = BN.now() }
    say(pid, "Serie %s: %s – Zeiten werden addiert, 30 Minuten Zeit.", name, table.concat(tracks, " → "))
    if not BN.prepareRace(s, tracks[1]) then s.series = nil end
end
commands.series = commands.serie

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

-- /resetspeed <Name>: falsche Hoechstgeschwindigkeit (Physik-Ausreisser, Mod-Fahrzeug) eines Spielers hier auf 0.
function commands.resetspeed(pid, arg)
    local admin = adminOnly(pid)
    if not admin then return end
    local target = findTarget(splitArgs(arg)[1])
    if not target or not target.online or target.online.guest then
        say(pid, "Aufruf: /resetspeed <Name> – Spieler muss auf diesem Server online sein.")
        return
    end
    local t = target.online
    local old = math.max(tonumber(t.record.topSpeedKmh) or 0, t.pendingTop or 0)
    t.resetTop, t.pendingTop, t.dirty = true, 0, true
    t.record.topSpeedKmh = 0
    for _, v in pairs(t.vehicles) do v.cand = nil end
    say(pid, "Höchstgeschwindigkeit von %s zurückgesetzt (war %d km/h).", t.name, math.floor(old + 0.5))
    say(t.pid, "Deine Höchstgeschwindigkeit wurde von %s zurückgesetzt.", admin.name)
    modlog({ action = "speed-reset", by = admin.name, target = t.name, targetId = t.id, kmh = math.floor(old + 0.5) })
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
    if not arg or arg == "" then say(pid, "Aufruf: /ansage [HH:MM] <Text> – erscheint auf allen BeamNet-Servern (mit Uhrzeit: dann).") return end
    local hhmm, rest = tostring(arg):match("^(%d%d?:%d%d)%s+(.+)$")
    local at = hhmm and BN.nextClockTime(hhmm)
    if at then
        BN.announce(rest, admin.name, at)
        say(pid, "Ansage geplant für %s Uhr: %s", os.date("%H:%M", at), rest)
        modlog({ action = "ansage", by = admin.name, reason = rest, ["until"] = at })
        return
    end
    BN.announce(arg, admin.name)
    modlog({ action = "ansage", by = admin.name, reason = arg })
end

-- /event (alle): laufendes Event zeigen. /event <Faktor> <Dauer> (Admins): starten, z. B. /event 2 2h oder
-- /event 1.5 90m. /event stop (Admins): beenden.
-- Naechster geplanter XP-Abend (xpabend.json, schreibt der Waechter aus AUTO_EVENT): { at, factor, sec } oder nil.
-- Hoechstens einmal je Minute gelesen.
BN.WEEKDAYS = { "Sonntag", "Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag" }
function BN.nextXpEvening()
    local now = BN.now()
    if not BN.xpEveningAt or now - BN.xpEveningAt >= 60 then
        BN.xpEveningAt = now
        local d = json.decode(readFile(C.sharedDir .. "/xpabend.json") or "")
        local at, f, sec = type(d) == "table" and tonumber(d.next), type(d) == "table" and tonumber(d.factor),
            type(d) == "table" and tonumber(d.sec)
        BN.xpEvening = (at and f and sec and f >= 1.5 and f <= 5 and sec > 0 and sec <= 6 * 3600)
            and { at = at, factor = f, sec = sec } or nil
    end
    local e = BN.xpEvening
    if e and e.at > now and e.at - now <= 8 * 86400 then return e end
    return nil
end

local function xpEveningText(lang, e)
    local day = tr(lang, BN.WEEKDAYS[tonumber(os.date("%w", e.at)) + 1])
    if os.date("%Y-%m-%d", e.at) == os.date("%Y-%m-%d", BN.now()) then day = tr(lang, "heute") end
    return tr(lang, "Nächster XP-Abend: %s %s–%s Uhr (%s-fache XP)", day, os.date("%H:%M", e.at),
        os.date("%H:%M", e.at + e.sec), fmtFactor(e.factor))
end

function commands.event(pid, arg)
    local words = {}
    for w in tostring(arg or ""):gmatch("%S+") do words[#words + 1] = w end
    if #words == 0 then
        local ev = BN.activeEvent()
        if ev then
            say(pid, "XP-Event läuft: %s-fache XP bis %s Uhr.", fmtFactor(ev.factor), os.date("%H:%M", ev["until"]))
        else
            say(pid, "Gerade läuft kein XP-Event.")
            local e = BN.nextXpEvening()
            if e then chat(pid, xpEveningText(BN.langOf(pid), e)) end
        end
        local bm = BN.bonusMap()
        if bm then say(pid, "Bonus-Map heute: %s (+%d %% XP beim Fahren).", bm.map, math.floor((bm.factor - 1) * 100 + 0.5)) end
        return
    end
    local s = session(pid)
    if not BN.isAdmin(s) then say(pid, "Nur für Admins.") return end
    local now = BN.now()
    if words[1]:lower() == "stop" or words[1]:lower() == "aus" then
        writeFileAtomic(eventFile(), json.encode({ factor = 1, ["until"] = now, by = s.name, id = "stop-" .. now }))
        modlog({ action = "event-stop", by = s.name })
        BN.loadEvent(now)
        say(pid, "XP-Event beendet.")
        return
    end
    local factor = tonumber((words[1]:gsub(",", ".")))
    local amount, unit = tostring(words[2] or ""):lower():match("^(%d+)([mh]?)$")
    local seconds = amount and tonumber(amount) * ((unit == "m") and 60 or 3600) or nil
    if not factor or factor < 1.5 or factor > 5 or not seconds or seconds < 60 or seconds > BN.EVENT_MAX_SEC then
        say(pid, "Aufruf: /event <Faktor 1,5–5> <Dauer, z. B. 2h oder 90m, höchstens 24h> · /event stop")
        return
    end
    factor = math.floor(factor * 10 + 0.5) / 10
    local ev = { factor = factor, ["until"] = now + seconds, by = s.name, at = now, id = tostring(now) .. "-" .. tostring(pid) }
    if not writeFileAtomic(eventFile(), json.encode(ev)) then
        say(pid, "Event konnte nicht gespeichert werden.")
        return
    end
    modlog({ action = "event", by = s.name, factor = factor, ["until"] = ev["until"] })
    BN.loadEvent(now)
end

-- Regeln (C.rules): nummeriert, eigene Texte unveraendert, die Standardregeln uebersetzt.
function BN.sayRules(pid)
    if type(C.rules) ~= "table" or #C.rules == 0 then return end
    say(pid, "Regeln:")
    for i, line in ipairs(C.rules) do chat(pid, string.format("%d. %s", i, tr(BN.langOf(pid), line))) end
end

function commands.regeln(pid)
    if type(C.rules) ~= "table" or #C.rules == 0 then say(pid, "Für dieses Netzwerk sind keine Regeln eingetragen.") return end
    BN.sayRules(pid)
end
commands.rules = commands.regeln

-- Teams (netzweit, teams.json): offen zum Beitreten, hoechstens BN.TEAM_MAX Mitglieder; Team-Kilometer = Summe der
-- Kilometer der Mitglieder (aus der Bestenliste, also inklusive der Spieler online).
BN.TEAM_MAX = 20

-- strict: Lesefehler (ausser "Datei fehlt") ergeben nil und den Fehler – dann darf nichts geschrieben werden. Eine
-- kaputte Datei wird beiseitegelegt (teams.json.kaputt-<Zeit>) und neu begonnen. Ohne strict immer eine Tabelle.
function BN.loadTeams(strict)
    local f, err, code = io.open(teamsFile(), "rb")
    if not f then
        if code == ENOENT or not strict then return { teams = {} } end
        return nil, err
    end
    local raw, readErr = f:read("*a")
    f:close()
    if raw == nil and strict then return nil, readErr or "teams.json nicht lesbar" end
    local data = json.decode(raw or "")
    if type(data) ~= "table" or type(data.teams) ~= "table" then
        if strict and raw and raw ~= "" then os.rename(teamsFile(), teamsFile() .. ".kaputt-" .. tostring(BN.now())) end
        return { teams = {} }
    end
    return data
end
BN.teamFounded = BN.teamFounded or {}

local function saveTeams(data)
    ensureDir(C.sharedDir)
    return writeFileAtomic(teamsFile(), json.encode(data))
end

local function teamOf(data, id)
    for key, t in pairs(data.teams) do
        if type(t) == "table" and type(t.members) == "table" and t.members[id] then return key, t end
    end
end

local function teamKey(name) return tostring(name):lower() end

-- Name des Teams eines Spielers (oder nil), fuer /stats.
function BN.teamNameOf(id)
    local _, t = teamOf(BN.loadTeams(), id)
    return t and tostring(t.name) or nil
end

local function memberCount(t)
    local n = 0
    for _ in pairs(t.members or {}) do n = n + 1 end
    return n
end

-- Teams nach Kilometern einer Wochenwertung (BN.weekRanking): { {name, km, team, counted}, ... }, nur Teams mit
-- Kilometern. Mit since (Wochenbeginn) zaehlen nur Mitglieder, die vorher beigetreten sind (joined[id], aeltere Teams:
-- Gruendung) – wer erst waehrend der Woche dazukommt, zaehlt ab der naechsten. counted = gezaehlte Mitglieder.
function BN.teamWeekRanking(list, teams, since)
    local byId = {}
    for _, e in ipairs(list or {}) do
        local km = tonumber(e.km) or 0
        if e.id and km > 0 and km < 1e6 then byId[tostring(e.id)] = km end
    end
    local out = {}
    for _, t in pairs(teams or BN.loadTeams().teams) do
        if type(t) == "table" and type(t.members) == "table" then
            local km, counted = 0, {}
            local joined = type(t.joined) == "table" and t.joined or {}
            for id in pairs(t.members) do
                local at = tonumber(joined[id]) or tonumber(t.created) or 0
                local k = byId[tostring(id)] or 0
                if k > 0 and (not since or at < since) then km, counted[tostring(id)] = km + k, true end
            end
            if km > 0 then out[#out + 1] = { name = clipText(tostring(t.name or "?"), 32), km = km, team = t, counted = counted } end
        end
    end
    table.sort(out, function(a, b) if a.km ~= b.km then return a.km > b.km end return a.name < b.name end)
    return out
end

-- Team der Woche aus einer Wochenwertung: meiste Kilometer seiner Mitglieder, sonst nil.
function BN.teamOfWeek(list, since)
    return BN.teamWeekRanking(list, nil, since)[1]
end

-- Team einer abgeschlossenen Woche als Momentaufnahme (teamweek-<Woche>.json, einmal je Woche, gemeinsam fuer alle
-- Server): { week, name, km, members = { [id] = true } } oder nil. Ansage und Belohnung beruhen darauf – spaetere
-- Wechsel in ein Team aendern nichts mehr.
local function teamWeekFile(week) return C.sharedDir .. "/teamweek-" .. tostring(week):gsub("[^%w-]", "") .. ".json" end
function BN.teamWeekSnapshot(week)
    local snap = json.decode(readFile(teamWeekFile(week)) or "")
    if type(snap) == "table" and snap.week == week then
        return (type(snap.name) == "string" and type(snap.members) == "table") and snap or nil
    end
    local since = BN.weekStartOf(week)
    if not since or week == weekKey(BN.now()) then return nil end      -- nur abgeschlossene Wochen
    local best = BN.teamWeekRanking(BN.weekRanking(week), nil, since)[1]
    snap = { week = week, at = BN.now() }
    if best then snap.name, snap.km, snap.members = best.name, math.floor(best.km * 10 + 0.5) / 10, best.counted end
    ensureDir(C.sharedDir)
    writeFileAtomic(teamWeekFile(week), json.encode(snap))
    return best and snap or nil
end

-- Belohnung fuer das Team der Vorwoche: wer laut Momentaufnahme dafuer gezaehlt hat (Mitglied seit vor Wochenbeginn,
-- mindestens communityMinKm gefahren), bekommt beim naechsten Besuch einmal teamWeekXp (gemerkt als teamWeek; doppelt auf zwei Servern wird beim Speichern abgezogen).
function BN.teamWeekReward(s)
    if s.guest or C.teamWeekXp <= 0 then return false end
    local rec, prev = s.record, weekKey(BN.now() - 7 * 86400)
    if rec.lastWeek ~= prev or (tonumber(rec.lastWeekKm) or 0) < C.communityMinKm then return false end
    if rec.teamWeek == prev or s.pendingTeamWeek == prev then return false end
    local team = BN.teamWeekSnapshot(prev)
    if not (team and team.members[s.id]) then return false end
    s.pendingTeamWeek, s.pendingTeamWeekXp = prev, C.teamWeekXp
    s.pendingBonus = s.pendingBonus + C.teamWeekXp
    s.dirty = true
    say(s.pid, "🏅 Dein Team %s war Team der Woche – danke fürs Mitfahren: +%d XP!", team.name, C.teamWeekXp)
    return true
end

-- Teams nach Kilometern: { {name, members, km}, ... }
function BN.teamRanking()
    local km = {}
    for _, rec in ipairs(BN.refreshBoard(false)) do km[rec.id] = rec.km end
    local list = {}
    for _, t in pairs(BN.loadTeams().teams) do
        if type(t) == "table" and type(t.members) == "table" then
            local sum = 0
            for id in pairs(t.members) do sum = sum + (km[id] or 0) end
            list[#list + 1] = { name = tostring(t.name), members = memberCount(t), km = sum }
        end
    end
    table.sort(list, function(a, b) if a.km ~= b.km then return a.km > b.km end return a.name < b.name end)
    return list
end

function commands.team(pid, arg)
    local s = session(pid)
    local words = {}
    for w in tostring(arg or ""):gmatch("%S+") do words[#words + 1] = w end
    local sub = (words[1] or ""):lower()
    local aliases = { gruenden = "gründen", create = "gründen", found = "gründen", join = "beitreten",
                      leave = "verlassen", list = "liste", top = "liste", loeschen = "löschen", delete = "löschen",
                      week = "woche" }
    sub = aliases[sub] or sub
    if sub == "woche" then
        local list = BN.teamWeekRanking(BN.weekRanking(weekKey(BN.now())), nil, weekStartAt(BN.now()))
        if #list == 0 then say(pid, "Diese Woche ist noch kein Team gefahren.") return end
        say(pid, "Teams diese Woche:")
        for i = 1, math.min(5, #list) do chat(pid, string.format("%d. %s – %s", i, list[i].name, fmtKm(list[i].km))) end
        return
    end
    if sub == "liste" then
        local list = BN.teamRanking()
        if #list == 0 then say(pid, "Noch keine Teams. Gründen: /team gründen <Name>") return end
        say(pid, "Teams nach Kilometern:")
        for i = 1, math.min(5, #list) do
            chat(pid, string.format("%d. %s – %s · %d", i, list[i].name, fmtKm(list[i].km), list[i].members))
        end
        return
    end
    if s.guest then say(pid, "Teams gibt es nur mit BeamMP-Konto.") return end
    -- Streng lesen: Kann teams.json gerade nicht gelesen werden, wird nichts geschrieben (sonst waeren alle Teams weg).
    local data, loadErr = BN.loadTeams(true)
    if not data then
        BN.logError("teams.json", loadErr)
        say(pid, "Teams gerade nicht verfügbar – bitte später noch einmal.")
        return
    end
    if sub == "löschen" then
        if not BN.isAdmin(s) then say(pid, "Nur Admins können Teams löschen.") return end
        local name = table.concat(words, " ", 2)
        local t = data.teams[teamKey(name)]
        if not t then say(pid, "Das Team %s gibt es nicht. Liste: /team liste", name) return end
        data.teams[teamKey(name)] = nil
        if not saveTeams(data) then say(pid, "Teams gerade nicht verfügbar – bitte später noch einmal.") return end
        modlog({ action = "team-loeschen", by = s.name, target = t.name })
        say(pid, "Team %s gelöscht.", t.name)
        return
    end
    local key, mine = teamOf(data, s.id)
    if sub == "" then
        if not mine then say(pid, "Du bist in keinem Team. /team gründen <Name> · /team beitreten <Name> · /team liste") return end
        local rank
        for i, t in ipairs(BN.teamRanking()) do if t.name == mine.name then rank = i end end
        say(pid, "Team %s: %d Mitglieder · Platz %s · /team verlassen", mine.name, memberCount(mine), rank and tostring(rank) or "–")
        -- Wochenwertung der Teams (Kilometer der Mitglieder in dieser Woche, wie "Team der Woche").
        local mineKm, wrank = 0, nil
        for i, e in ipairs(BN.teamWeekRanking(BN.weekRanking(weekKey(BN.now())), data.teams, weekStartAt(BN.now()))) do
            if e.team == mine then mineKm, wrank = e.km, i end
        end
        say(pid, "Diese Woche: %s · Platz %s unter den Teams (/team woche)", fmtKm(mineKm), wrank and tostring(wrank) or "–")
        return
    end
    if sub == "verlassen" then
        if not mine then say(pid, "Du bist in keinem Team.") return end
        mine.members[s.id] = nil
        if type(mine.joined) == "table" then mine.joined[s.id] = nil end
        if memberCount(mine) == 0 then data.teams[key] = nil end
        saveTeams(data)
        say(pid, "Du hast das Team %s verlassen.", mine.name)
        return
    end
    local name = table.concat(words, " ", 2)
    if sub == "gründen" or sub == "beitreten" then
        if mine then say(pid, "Du bist schon im Team %s – erst /team verlassen.", mine.name) return end
        if not name:match("^[%w _%-]+$") or #name < 3 or #name > 20 or name:match("^%s") or name:match("%s$") then
            say(pid, "Teamname: 3–20 Zeichen, Buchstaben, Ziffern, Leerzeichen, _ und -")
            return
        end
        local existing = data.teams[teamKey(name)]
        if sub == "gründen" then
            if not BN.isAdmin(s) then
                local now = BN.now()
                if s.mutedUntil and now < s.mutedUntil then
                    say(pid, "Du bist noch %d s stummgeschaltet.", s.mutedUntil - now)
                    return
                end
                if BN.filterHit(name) then
                    say(pid, "Dieser Teamname ist nicht erlaubt.")
                    return
                end
                local last = BN.teamFounded[s.id]
                if last and now - last < 600 then
                    say(pid, "Ein neues Team kannst du erst in %d min gründen.", math.ceil((600 - (now - last)) / 60))
                    return
                end
            end
            if existing then say(pid, "Das Team %s gibt es schon – /team beitreten %s", existing.name, existing.name) return end
            local count = 0
            for _ in pairs(data.teams) do count = count + 1 end
            if count >= 500 then say(pid, "Es gibt schon zu viele Teams.") return end
            data.teams[teamKey(name)] = { name = name, by = s.name, created = BN.now(), members = { [s.id] = s.name },
                                          joined = { [s.id] = BN.now() } }
            if not saveTeams(data) then say(pid, "Teams gerade nicht verfügbar – bitte später noch einmal.") return end
            for k, t in pairs(BN.teamFounded) do if BN.now() - t >= 600 then BN.teamFounded[k] = nil end end
            BN.teamFounded[s.id] = BN.now()
            sayAll("%s hat das Team %s gegründet – mitmachen: /team beitreten %s", s.name, name, name)
            return
        end
        if not existing then say(pid, "Das Team %s gibt es nicht. Liste: /team liste", name) return end
        if memberCount(existing) >= BN.TEAM_MAX then say(pid, "Das Team %s ist voll (%d Mitglieder).", existing.name, BN.TEAM_MAX) return end
        existing.members[s.id] = s.name
        if type(existing.joined) ~= "table" then existing.joined = {} end
        existing.joined[s.id] = BN.now()        -- zaehlt fuer die Wochenwertung ab der naechsten Woche
        saveTeams(data)
        say(pid, "Willkommen im Team %s!", existing.name)
        return
    end
    say(pid, "Aufruf: /team · /team gründen <Name> · /team beitreten <Name> · /team verlassen · /team liste")
end

-- /melden <Name> <Grund> (englisch /report): an die Admins – sofort im Chat an Admins auf diesem Server und ueber
-- den Waechter (reports/*.json) an Discord/Telegram. Hoechstens eine Meldung je Spieler in BN.REPORT_COOLDOWN s.
BN.REPORT_COOLDOWN = 120
function commands.melden(pid, arg)
    local s = session(pid)
    local words = splitArgs(arg)
    local reason = table.concat(words, " ", 2)
    if not words[1] or reason == "" then
        say(pid, "Aufruf: /melden <Name> <Grund> – geht an die Admins.")
        return
    end
    local now = BN.now()
    if s.lastReportAt and now - s.lastReportAt < BN.REPORT_COOLDOWN then
        say(pid, "Bitte warte noch %d s bis zur nächsten Meldung.", BN.REPORT_COOLDOWN - (now - s.lastReportAt))
        return
    end
    local target = findTarget(words[1])
    local targetName = clipText(target and target.name or words[1], 40)
    reason = clipText(reason, 200)
    local report = { at = now, port = BN.server.port, server = BN.server.name, by = s.name, byId = s.id,
                     target = targetName, targetId = target and target.id or nil, reason = reason }
    ensureDir(C.sharedDir .. "/reports")
    local ok = writeFileAtomic(string.format("%s/reports/%s-%d-%s.json", C.sharedDir, tostring(BN.server.port), now,
        tostring(pid)), json.encode(report))
    if not ok then
        say(pid, "Meldung konnte nicht gespeichert werden – bitte einem Admin direkt schreiben.")
        return
    end
    s.lastReportAt = now
    for _, a in pairs(BN.players) do
        if a.pid ~= pid and BN.isAdmin(a) then say(a.pid, "Meldung von %s über %s: %s", s.name, targetName, reason) end
    end
    modlog({ action = "melden", by = s.name, byId = s.id or ("ip:" .. tostring(s.ip or "?")), target = targetName, targetId = target and target.id or nil, reason = reason })
    say(pid, "Danke – deine Meldung über %s ist bei den Admins.", targetName)
end
commands.report = commands.melden

-- ---------------------------------------------------------------------------------------------------------------------
-- Fahrauftraege: Admins legen Orte an (/ort neu <Typ> <Name> an der eigenen Position, je Map in places/<Map>.json).
-- Spieler holen sich mit /auftrag einen Auftrag zu einem zufaelligen Ort (mindestens jobMinDistM entfernt), z. B.
-- "Bring den Patienten ins Krankenhaus". Zeitlimit aus der Entfernung; gezaehlt wird nur, wer wirklich faehrt
-- (mindestens 70 % der Luftlinie als gefahrene Strecke – Sprunge und Zuruecksetzen zaehlen nicht).

BN.PLACE_TYPES = {
    krankenhaus = { icon = "🚑", text = "Notfall! Bring den Patienten ins Krankenhaus %s", urgent = true,
                    pickup = "Notfall bei %s! Hol den Patienten ab und bring ihn ins Krankenhaus %s" },
    schule = { icon = "🚌", text = "Schulbus: Bring die Kinder zur Schule %s",
               pickup = "Schulbus: Hol die Kinder bei %s ab und bring sie zur Schule %s" },
    feuerwehr = { icon = "🚒", text = "Alarm! Bring die Ausrüstung zur Feuerwache %s", urgent = true },
    polizei = { icon = "🚓", text = "Bring den Verdächtigen zur Polizei %s", urgent = true },
    tankstelle = { icon = "⛽", text = "Liefere Benzin an die Tankstelle %s" },
    werkstatt = { icon = "🔧", text = "Bring die Ersatzteile zur Werkstatt %s" },
    supermarkt = { icon = "🛒", text = "Liefere die Ware an den Supermarkt %s" },
    bahnhof = { icon = "🚕", text = "Taxi: Bring den Fahrgast zum Bahnhof %s",
                pickup = "Taxi: Ein Fahrgast wartet bei %s und muss zum Bahnhof %s" },
    flughafen = { icon = "✈️", text = "Taxi: Der Fahrgast muss zum Flughafen %s",
                  pickup = "Taxi: Ein Fahrgast wartet bei %s und muss zum Flughafen %s" },
    hafen = { icon = "⚓", text = "Bring die Fracht zum Hafen %s" },
    hotel = { icon = "🏨", text = "Taxi: Bring den Gast zum Hotel %s",
              pickup = "Taxi: Ein Gast wartet bei %s und möchte zum Hotel %s" },
    ort = { icon = "📦", text = "Liefere das Paket nach %s" },
}
local PLACE_ALIASES = { hospital = "krankenhaus", school = "schule", fire = "feuerwehr", police = "polizei",
                        gas = "tankstelle", garage = "werkstatt", shop = "supermarkt", station = "bahnhof",
                        airport = "flughafen", harbor = "hafen", port = "hafen", place = "ort" }
BN.MAX_PLACES = 100

local function placesFile()
    local map = tostring(BN.server.map or "unbekannt"):gsub("[^%w_-]", "_")
    return placesDir() .. "/" .. map .. ".json"
end

-- Orte (places/<Map>.json, nur Admins schreiben) und Vorschlaege von Spielern (placesuggest/<Map>.json, getrennt –
-- so beruehren Spieler die Orte-Datei nie). Lesen streng: "fehlt" ist leer, "kaputt/unlesbar" ist nil – dann wird
-- nichts geschrieben (sonst waeren alle Orte weg). Beim Schreiben bleiben unbekannte Eintraege roh erhalten.
local function suggestDir() return C.sharedDir .. "/placesuggest" end
local function suggestFile() return suggestDir() .. "/" .. BN.mapKey() .. ".json" end

local function readListFile(path, key)
    local f, err, code = io.open(path, "rb")
    if not f then
        if code == ENOENT then return {} end
        return nil, err
    end
    local raw = f:read("*a")
    f:close()
    if raw == nil then return nil, "nicht lesbar" end
    local data = json.decode(raw)
    if type(data) ~= "table" then return nil, "kaputt" end
    if data[key] == nil then return {} end
    if type(data[key]) ~= "table" then return nil, "kaputt" end
    return data[key]
end

local function cleanPlaces(src, max)
    local list = {}
    for _, p in ipairs(src or {}) do
        if type(p) == "table" and type(p.type) == "string" and BN.PLACE_TYPES[p.type] and tonumber(p.x)
            and tonumber(p.y) and tonumber(p.z) and #list < max then
            list[#list + 1] = { type = p.type, name = clipText(p.name, 40), x = tonumber(p.x), y = tonumber(p.y),
                                z = tonumber(p.z), by = clipText(p.by, 32), byId = safeId(p.byId),
                                at = tonumber(p.at), sid = type(p.sid) == "string" and p.sid:sub(1, 8) or nil }
        end
    end
    return list
end

-- Orte und Vorschlaege dieser Map (bereinigt, fuer Auftraege und Anzeige).
function BN.loadPlaces()
    return cleanPlaces(readListFile(placesFile(), "places"), BN.MAX_PLACES),
           cleanPlaces(readListFile(suggestFile(), "suggestions"), 30)
end

local function writeList(dir, path, key, list)
    ensureDir(C.sharedDir)
    ensureDir(dir)
    return writeFileAtomic(path, json.encode({ [key] = list }))
end

local function fmtDist(lang, m)
    if m >= 1000 then
        local text = string.format("%.1f km", m / 1000)
        return lang == "en" and text or (text:gsub("%.", ","))
    end
    return string.format("%d m", math.floor(m / 10 + 0.5) * 10)
end

local function fmtClock(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local function drivenKm(s)
    return (tonumber(s.record.km) or 0) + (s.pendingKm or 0)
end

function commands.ort(pid, arg)
    local s = session(pid)
    local words = {}
    for w in tostring(arg or ""):gmatch("%S+") do words[#words + 1] = w end
    local sub = (words[1] or ""):lower()
    if sub == "" or sub == "liste" or sub == "list" then return commands.orte(pid) end
    local broken = "Die Orte-Datei dieser Map ist kaputt oder nicht lesbar – nichts geändert (beamnet doctor)."
    local brokenSugg = "Die Vorschlags-Datei dieser Map ist kaputt oder nicht lesbar – nichts geändert (beamnet doctor)."
    if sub == "vorschlag" or sub == "vorschlagen" or sub == "suggest" then
        -- Jeder mit Konto: hoechstens einer alle 10 Minuten (je Konto, auch ueber Neuverbinden), 3 offene je Spieler,
        -- 30 je Map; Admins nehmen an.
        if s.guest then say(pid, "Vorschläge gibt es nur mit BeamMP-Konto.") return end
        local typ = (words[2] or ""):lower()
        typ = PLACE_ALIASES[typ] or typ
        local name = clipText(table.concat(words, " ", 3), 40)
        if not BN.PLACE_TYPES[typ] or #name < 2 then
            say(pid, "Aufruf: /ort vorschlag <Typ> <Name> – z. B. /ort vorschlag krankenhaus St. Marien")
            return
        end
        local pos = currentPosition(s)
        if not pos then say(pid, "Keine Position – bitte erst mit einem Fahrzeug an den Ort fahren.") return end
        local now = BN.now()
        BN.suggestAt = BN.suggestAt or {}
        local last = BN.suggestAt[s.id]
        if last and now - last < 600 then
            say(pid, "Bitte warte noch %d min mit dem nächsten Vorschlag.", math.ceil((600 - (now - last)) / 60))
            return
        end
        local raw, err = readListFile(suggestFile(), "suggestions")
        if not raw then BN.logError("Ort-Vorschlaege", err) say(pid, brokenSugg) return end
        local list, mine = cleanPlaces(raw, 1000), 0
        for _, p in ipairs(list) do if p.byId == s.id then mine = mine + 1 end end
        if #list >= 30 or mine >= 3 then say(pid, "Es gibt schon viele offene Vorschläge – die Admins schauen sie sich an.") return end
        local sid, taken = tostring(math.floor(now) % 100000), {}
        for _, p in ipairs(list) do if p.sid then taken[p.sid] = true end end
        while taken[sid] do sid = tostring((tonumber(sid) + 1) % 100000) end
        list[#list + 1] = { type = typ, name = name, x = pos.x, y = pos.y, z = pos.z, by = s.name, byId = s.id, at = now, sid = sid }
        if not writeList(suggestDir(), suggestFile(), "suggestions", list) then
            say(pid, "Speichern fehlgeschlagen – bitte beamnet doctor prüfen.")
            return
        end
        for k, t in pairs(BN.suggestAt) do if now - t >= 600 then BN.suggestAt[k] = nil end end
        BN.suggestAt[s.id] = now
        say(pid, "Danke! Dein Vorschlag %s (%s) ist bei den Admins.", name, typ)
        modlog({ action = "ort-vorschlag", by = s.name, byId = s.id, target = name, kind = typ, map = BN.mapKey() })
        for apid, a in pairs(BN.players) do
            if BN.isAdmin(a) then say(apid, "📍 %s schlägt einen Ort vor: %s %s – /ort vorschlaege", s.name, BN.PLACE_TYPES[typ].icon, name) end
        end
        return
    end
    if not BN.isAdmin(s) then
        say(pid, "Nur Admins legen Orte an – du kannst einen vorschlagen: /ort vorschlag <Typ> <Name>")
        return
    end
    if sub == "vorschlaege" or sub == "vorschläge" or sub == "suggestions" then
        local _, suggestions = BN.loadPlaces()
        if #suggestions == 0 then say(pid, "Keine offenen Vorschläge.") return end
        say(pid, "Vorschläge (annehmen: /ort annehmen <Nr> · ablehnen: /ort ablehnen <Nr>):")
        local pos, lang = currentPosition(s), BN.langOf(pid)
        for i, p in ipairs(suggestions) do
            if i > 10 then break end
            chat(pid, string.format("#%s %s %s (%s) von %s%s", p.sid or "?", BN.PLACE_TYPES[p.type].icon, p.name, p.type,
                p.by or "?", pos and (" · " .. fmtDist(lang, dist(pos, p))) or ""))
        end
        return
    end
    -- Ab hier wird die Orte-Datei geaendert: nur, wenn sie sich lesen laesst; unbekannte Eintraege bleiben roh erhalten.
    local raw, err = readListFile(placesFile(), "places")
    if not raw then BN.logError("Orte", err) say(pid, broken) return end
    local places = cleanPlaces(raw, BN.MAX_PLACES)
    local function hasName(name)
        for _, q in ipairs(places) do if q.name:lower() == name:lower() then return q end end
    end
    if sub == "annehmen" or sub == "accept" or sub == "ablehnen" or sub == "reject" then
        -- Feste Kennung (#12345 aus der Liste) statt Listennummer: ein anderer Admin kann die Liste inzwischen geaendert haben.
        local want = tostring(words[2] or ""):gsub("^#", "")
        local sraw, serr = readListFile(suggestFile(), "suggestions")
        if not sraw then BN.logError("Ort-Vorschlaege", serr) say(pid, brokenSugg) return end
        local list = cleanPlaces(sraw, 1000)
        local idx
        for i, p in ipairs(list) do if p.sid == want then idx = i end end
        if not idx then say(pid, "Aufruf: /ort %s <Nr> – Liste: /ort vorschlaege", sub) return end
        local p = table.remove(list, idx)
        local accept = sub == "annehmen" or sub == "accept"
        if accept then
            if hasName(p.name) then
                writeList(suggestDir(), suggestFile(), "suggestions", list)
                say(pid, "Den Ort %s gibt es schon – Vorschlag entfernt.", p.name)
                return
            end
            if #places >= BN.MAX_PLACES then say(pid, "Auf dieser Map gibt es schon %d Orte.", BN.MAX_PLACES) return end
            raw[#raw + 1] = { type = p.type, name = p.name, x = p.x, y = p.y, z = p.z, by = p.by }
            if not writeList(placesDir(), placesFile(), "places", raw) then say(pid, "Speichern fehlgeschlagen – bitte beamnet doctor prüfen.") return end
            say(pid, "%s %s ist jetzt ein Ort für Aufträge.", BN.PLACE_TYPES[p.type].icon, p.name)
            for opid, o in pairs(BN.players) do
                if p.byId and o.id == p.byId then say(opid, "Dein Vorschlag %s wurde angenommen – danke!", p.name) end
            end
        else
            say(pid, "Vorschlag %s abgelehnt.", p.name)
        end
        writeList(suggestDir(), suggestFile(), "suggestions", list)
        modlog({ action = accept and "ort-angenommen" or "ort-abgelehnt", by = s.name, target = p.name, kind = p.type, map = BN.mapKey() })
        return
    end
    if sub == "neu" or sub == "new" then
        local typ = (words[2] or ""):lower()
        typ = PLACE_ALIASES[typ] or typ
        local name = clipText(table.concat(words, " ", 3), 40)
        if not BN.PLACE_TYPES[typ] or #name < 2 then
            local types = {}
            for k in pairs(BN.PLACE_TYPES) do types[#types + 1] = k end
            table.sort(types)
            say(pid, "Aufruf: /ort neu <Typ> <Name> – Typen: %s", table.concat(types, ", "))
            return
        end
        local pos = currentPosition(s)
        if not pos then
            say(pid, "Keine Position – bitte erst mit einem Fahrzeug an den Ort fahren.")
            return
        end
        local q = hasName(name)
        if q then
            say(pid, "Den Ort %s gibt es schon (löschen: /ort weg %s).", q.name, q.name)
            return
        end
        if #places >= BN.MAX_PLACES then
            say(pid, "Auf dieser Map gibt es schon %d Orte.", BN.MAX_PLACES)
            return
        end
        raw[#raw + 1] = { type = typ, name = name, x = pos.x, y = pos.y, z = pos.z, by = s.name }
        if not writeList(placesDir(), placesFile(), "places", raw) then say(pid, "Speichern fehlgeschlagen – bitte beamnet doctor prüfen.") return end
        say(pid, "%s %s angelegt (%s). Spieler fahren jetzt mit /auftrag hierher.", BN.PLACE_TYPES[typ].icon, name, typ)
        return
    end
    if sub == "weg" or sub == "loeschen" or sub == "löschen" or sub == "remove" then
        local name = table.concat(words, " ", 2):lower()
        for i, p in ipairs(raw) do
            if type(p) == "table" and clipText(p.name, 40):lower() == name then
                table.remove(raw, i)
                writeList(placesDir(), placesFile(), "places", raw)
                say(pid, "Ort %s gelöscht.", clipText(p.name, 40))
                return
            end
        end
        say(pid, "Den Ort „%s“ gibt es auf dieser Map nicht.", table.concat(words, " ", 2))
        return
    end
    say(pid, "Aufruf: /ort neu <Typ> <Name> · /ort weg <Name> · /orte")
end
commands.place = commands.ort

function commands.orte(pid)
    local places = BN.loadPlaces()
    if #places == 0 then
        say(pid, "Noch keine Orte auf dieser Map. Admins legen sie an: /ort neu krankenhaus <Name> – oder schlag einen vor: /ort vorschlag krankenhaus <Name>")
        return
    end
    local s, lang = session(pid), BN.langOf(pid)
    local pos = currentPosition(s)
    say(pid, "Orte auf dieser Map (%d) – Auftrag holen: /auftrag", #places)
    table.sort(places, function(a, b) return a.name:lower() < b.name:lower() end)
    for i = 1, math.min(10, #places) do
        local p = places[i]
        local d = pos and (" · " .. fmtDist(lang, dist(pos, p))) or ""
        chat(pid, string.format("%s %s (%s)%s", BN.PLACE_TYPES[p.type].icon, p.name, p.type, d))
    end
    if #places > 10 then say(pid, "… und %d weitere", #places - 10) end
end
commands.places = commands.orte

-- Zufall (in den Tests ersetzbar).
BN.random = BN.random or function(n) return math.random(1, n) end

BN.jobLimits = BN.jobLimits or {}

-- Stundengrenzen (Auftrags- und Konvoi-XP, Abklingzeit) gelten netzweit: der Stand der laufenden Stunde steht im
-- Spielerdatensatz (jobHour, convoyHour) und wird beim Betreten uebernommen – sonst gaebe jeder Serverwechsel eine
-- frische Stunde. Gespeichert wird der hoechste Stand (Werte wachsen nur innerhalb einer Stunde).
local function hourOf(saved)
    if type(saved) ~= "table" then return nil end
    local now = BN.now()
    local st, xp, done = tonumber(saved.start), tonumber(saved.xp), tonumber(saved.doneAt)
    if not (st and xp) or st ~= st or xp ~= xp or now - st >= 3600 or st - now > 60 then return nil end
    return { start = st, xp = math.max(0, math.min(xp, 1e6)),
             doneAt = done and done == done and done <= now + 60 and done or nil }
end

function BN.mergeHour(saved, e)
    local h = hourOf(saved)
    if e and BN.now() - e.hourStart < 3600 then
        if not h then return { start = e.hourStart, xp = e.xp, doneAt = e.doneAt } end
        local done = math.max(h.doneAt or 0, e.doneAt or 0)
        return { start = math.min(h.start, e.hourStart), xp = math.max(h.xp, e.xp), doneAt = done > 0 and done or nil }
    end
    return h
end

function BN.applyHourLimit(tbl, id, saved)
    local h = hourOf(saved)
    if not h or not id then return end
    local e = tbl[id]
    if not e or BN.now() - e.hourStart >= 3600 then
        e = { hourStart = h.start, xp = 0 }
        tbl[id] = e
    end
    e.xp = math.max(e.xp, h.xp)
    if h.doneAt then e.doneAt = math.max(e.doneAt or 0, h.doneAt) end
end

-- Abklingzeit und XP je Stunde gelten je Konto (Gaeste je IP), auch ueber Neuverbinden hinweg.
local function jobLimit(s)
    local key = s.id or ("ip:" .. tostring(s.ip or s.pid))
    local now = BN.now()
    local e = BN.jobLimits[key]
    if not e then
        e = { hourStart = now, xp = 0 }
        BN.jobLimits[key] = e
    elseif now - e.hourStart >= 3600 then
        e.hourStart, e.xp = now, 0          -- neue Stunde; Abklingzeit und Schicht laufen weiter
    end
    -- Aufraeumen, damit die Tabelle nicht waechst.
    BN.jobLimitCount = (BN.jobLimitCount or 0) + 1
    if BN.jobLimitCount % 200 == 0 then
        for k, v in pairs(BN.jobLimits) do
            if now - v.hourStart >= 3600 and now - (v.doneAt or 0) >= math.max(C.jobCooldownSec, 180) then BN.jobLimits[k] = nil end
        end
        BN.jobLimits[key] = e
    end
    return e
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Lieferpunkte: Punkte, an denen Spieler mit Konto wirklich gefahren sind (also erreichbar). roadpoints/<Map>.json,
-- gemeinsam fuer alle Server dieser Map; beim Speichern werden die Punkte der anderen Server dazugenommen. Eine kaputte
-- Datei wird nie ueberschrieben.

-- Ein Lieferpunkt entsteht erst nach ROAD_MIN_DRIVEN_M echter Fahrt seit dem letzten Sprung, Zuruecksetzen oder neuen
-- Fahrzeug (Teleport aufs Dach, ins Meer oder in die Luft gibt keine Punkte), hoechstens ROAD_PER_HOUR je Konto und
-- Stunde, nur mit Koordinaten in vernuenftigen Grenzen.
BN.ROAD_MIN_DRIVEN_M = 300
BN.ROAD_MAX_VERTICAL_MPS = 20
BN.ROAD_PER_HOUR = 30
BN.roadLimits = BN.roadLimits or {}

local function plausiblePoint(x, y, z)
    return x and y and z and x == x and y == y and z == z and math.abs(x) < 1e5 and math.abs(y) < 1e5 and math.abs(z) < 5000
end

local function roadDir() return C.sharedDir .. "/roadpoints" end
local function roadFile() return roadDir() .. "/" .. BN.mapKey() .. ".json" end

local function cleanPoints(src, max)
    local list = {}
    for _, p in ipairs(type(src) == "table" and src or {}) do
        if #list >= max then break end
        if type(p) == "table" and plausiblePoint(tonumber(p.x), tonumber(p.y), tonumber(p.z)) then
            local id = tonumber(p.id)
            list[#list + 1] = { x = tonumber(p.x), y = tonumber(p.y), z = tonumber(p.z),
                                id = id and id >= 1 and id < 1e6 and math.floor(id) or nil }
        end
    end
    return list
end

-- Feste Nummern (fuer "Lieferpunkt 17"): vorhandene bleiben, doppelte und fehlende bekommen die naechste freie.
local function assignIds(list)
    local used, maxId = {}, 0
    for _, p in ipairs(list) do
        if p.id and not used[p.id] then used[p.id], maxId = true, math.max(maxId, p.id) else p.id = nil end
    end
    for _, p in ipairs(list) do
        if not p.id then maxId = maxId + 1; p.id = maxId end
    end
end

local function nearPoint(list, pos, d)
    for _, p in ipairs(list) do
        if dist(p, pos) < d then return true end
    end
    return false
end

-- Lieferpunkte dieser Map (aus dem Speicher; alle 5 Minuten neu aus der Datei, solange nichts Ungespeichertes da ist).
function BN.roadPointList()
    local rp, now = BN.roadPoints, BN.now()
    if not rp or rp.map ~= BN.mapKey() or (not rp.dirty and now - rp.loadedAt >= 300) then
        local raw = readListFile(roadFile(), "points")
        rp = { map = BN.mapKey(), list = cleanPoints(raw, C.roadPointsMax), loadedAt = now, dirty = false,
               broken = raw == nil, savedAt = rp and rp.savedAt or now }
        assignIds(rp.list)
        BN.roadPoints = rp
    end
    return rp.list
end

function BN.roadTick()
    if C.roadPointsMax <= 0 then return end
    local now = BN.now()
    if now - (BN.lastRoadAt or 0) < C.roadPointSec then return end
    BN.lastRoadAt = now
    local list = BN.roadPointList()
    local rp = BN.roadPoints
    if rp.broken then return end
    for _, s in pairs(BN.players) do
        if #list >= C.roadPointsMax then break end
        local v = not s.guest and (tonumber(s.tickMoved) or 0) > 0 and (tonumber(s.roadDriven) or 0) >= BN.ROAD_MIN_DRIVEN_M
            and s.tickVid ~= nil and type(s.vehicles) == "table" and s.vehicles[s.tickVid]
        local lim = BN.roadLimits[s.id]
        if lim and now - lim.hourStart >= 3600 then lim = nil end
        if type(v) == "table" and plausiblePoint(tonumber(v.x), tonumber(v.y), tonumber(v.z))
            and (not lim or lim.n < BN.ROAD_PER_HOUR) and not nearPoint(list, v, C.roadPointSpacingM) then
            list[#list + 1] = { x = math.floor(v.x + 0.5), y = math.floor(v.y + 0.5), z = math.floor(v.z + 0.5) }
            assignIds(list)
            rp.dirty = true
            if not lim then
                lim = { hourStart = now, n = 0 }
                BN.roadLimits[s.id] = lim
            end
            lim.n = lim.n + 1
        end
    end
    if rp.dirty and now - (rp.savedAt or 0) >= 300 then BN.saveRoadPoints() end
    if now - (BN.roadLimitCleanAt or 0) >= 600 then
        BN.roadLimitCleanAt = now
        for k, e in pairs(BN.roadLimits) do if now - e.hourStart >= 3600 then BN.roadLimits[k] = nil end end
    end
end

-- Neue Punkte speichern (zusammen mit denen der anderen Server). Ist die Datei gerade kaputt: nichts schreiben, die
-- ungespeicherten Punkte verwerfen und in 5 Minuten neu lesen (sonst bliebe die Sammlung bis zum Neustart stehen).
function BN.saveRoadPoints()
    local rp = BN.roadPoints
    if not rp or not rp.dirty or rp.broken or rp.map ~= BN.mapKey() then return end
    local now = BN.now()
    rp.savedAt = now
    local raw = readListFile(roadFile(), "points")
    if not raw then
        rp.broken, rp.dirty, rp.loadedAt = true, false, now
        return
    end
    local list = rp.list
    for _, p in ipairs(cleanPoints(raw, C.roadPointsMax)) do
        if #list < C.roadPointsMax and not nearPoint(list, p, C.roadPointSpacingM) then list[#list + 1] = p end
    end
    assignIds(list)
    ensureDir(C.sharedDir)
    ensureDir(roadDir())
    if writeFileAtomic(roadFile(), json.encode({ points = list })) then rp.dirty, rp.loadedAt = false, now end
end

-- Richtung zum Ziel relativ zur Fahrtrichtung (aus den letzten Positionen des Auftragsfahrzeugs), nil ohne Fahrt.
local function relDirection(j, pos, target)
    if not j.hx then return nil end
    local tx, ty = target.x - pos.x, target.y - pos.y
    if math.sqrt(tx * tx + ty * ty) < 1 then return nil end
    local cross = j.hx * ty - j.hy * tx            -- > 0: Ziel liegt links
    local dot = j.hx * tx + j.hy * ty
    local ang = math.deg((math.atan2 or math.atan)(cross, dot))
    local a = math.abs(ang)
    if a <= 25 then return "geradeaus" end
    if a > 155 then return "hinter dir" end
    local side = ang > 0 and "links" or "rechts"
    if a <= 70 then return "halb " .. side end
    if a <= 115 then return side end
    return "hinten " .. side
end
BN.relDirection = relDirection

-- Bonus fuer Auftraege in Folge (Schicht): beim 3., 5. und 10. Auftrag, danach bei jedem fuenften.
function BN.jobStreakBonus(n)
    if n == 3 then return 25 end
    if n == 5 then return 50 end
    if n >= 10 and n % 5 == 0 then return 100 end
    return 0
end

function BN.startJob(s)
    local lang = BN.langOf(s.pid)
    local pos = currentPosition(s)
    if not pos then
        say(s.pid, "Steig erst in ein Fahrzeug, dann gibt es einen Auftrag.")
        return false
    end
    local lim = jobLimit(s)
    local wait = C.jobCooldownSec - (BN.now() - (lim.doneAt or -math.huge))
    if wait > 0 then
        say(s.pid, "Nächster Auftrag in %d s.", math.ceil(wait))
        return false
    end
    local places = BN.loadPlaces()
    local choices = {}
    for _, p in ipairs(places) do
        local d = dist(pos, p)
        if d >= C.jobMinDistM and p.name ~= s.lastJobPlace then choices[#choices + 1] = { place = p, d = d } end
    end
    -- Ohne passende Orte: Lieferung zu einem Lieferpunkt (bis 3 km), damit es auf jeder Map Auftraege gibt.
    if #choices == 0 and C.roadPointsMax > 0 then
        for _, p in ipairs(BN.roadPointList()) do
            local d = dist(pos, p)
            local name = tr(lang, "Lieferpunkt %d", p.id)
            if d >= C.jobMinDistM and d <= 3000 and name ~= s.lastJobPlace then
                choices[#choices + 1] = { place = { type = "ort", name = name, x = p.x, y = p.y, z = p.z }, d = d }
            end
        end
    end
    if #choices == 0 then
        say(s.pid, "Gerade kein Auftrag frei – auf dieser Map fehlen Orte (Admins: /ort neu krankenhaus <Name>).")
        return false
    end
    local pick = choices[BN.random(#choices)]
    local dest = pick.place
    local kind = BN.PLACE_TYPES[dest.type]
    -- Mit Abholung (Patient, Kinder, Fahrgast): erst zu einem anderen Ort, dann ans Ziel – wenn es einen passenden gibt.
    local pickup
    if kind.pickup then
        local stops = {}
        for _, p in ipairs(places) do
            if p ~= dest and dist(pos, p) >= C.jobMinDistM and dist(p, dest) >= C.jobMinDistM then stops[#stops + 1] = p end
        end
        if #stops > 0 then pickup = stops[BN.random(#stops)] end
    end
    local total = pickup and (dist(pos, pickup) + dist(pickup, dest)) or pick.d
    local speed = kind.urgent and 18 or 12
    local limit = math.floor(45 + 1.6 * total / speed + (pickup and 20 or 0))
    -- Fester Anteil erst ab 1 km: sonst lohnt Pendeln zwischen zwei nahen Orten mehr als Fahren.
    local xp = (total >= 1000 and C.jobXp or 0) + total / 1000 * C.jobXpPerKm
    if kind.urgent then xp = xp * 1.5 end
    local first = pickup or dest
    s.job = { place = first, dest = pickup and dest or nil, startAt = BN.now(), limit = limit, xp = math.floor(xp),
              legStraight = dist(pos, first), legDriven = 0, hintAt = BN.now(), finalName = dest.name, total = total,
              vid = pos.vid, lastPos = { x = pos.x, y = pos.y, z = pos.z }, lastAt = BN.now() }
    local text = pickup and tr(lang, kind.pickup, pickup.name, dest.name) or tr(lang, kind.text, dest.name)
    chat(s.pid, string.format("%s %s – %s, %s min Zeit (/auftrag stop bricht ab)", kind.icon, text,
        fmtDist(lang, total), fmtClock(limit)))
    return true
end

function BN.jobTick(s)
    local j = s.job
    local now = BN.now()
    local lang = BN.langOf(s.pid)
    local v = s.vehicles[j.vid]
    local pos = v and { x = v.x, y = v.y, z = v.z } or nil
    local left = j.limit - (now - j.startAt)
    -- Sprung (Teleport, Zuruecksetzen an einen anderen Ort, neues Fahrzeug mit derselben Nummer): Auftrag vorbei.
    if j.jumped or (pos and dist(pos, j.lastPos) > C.maxSpeedMps * math.max(1, now - j.lastAt) + 50) then
        s.job = nil
        jobLimit(s).streak = nil
        say(s.pid, "Sprung erkannt – der Auftrag nach %s ist abgebrochen. Neuer: /auftrag", j.place.name)
        return
    end
    if pos and j.lastPos then
        -- Fahrtrichtung fuer die Richtungshinweise (nur bei echter Bewegung).
        local dx, dy = pos.x - j.lastPos.x, pos.y - j.lastPos.y
        local m = math.sqrt(dx * dx + dy * dy)
        if m >= 3 then j.hx, j.hy = dx / m, dy / m end
    end
    if pos then j.lastPos, j.lastAt = pos, now end
    if pos and dist(pos, j.place) <= C.jobRadiusM then
        local driven = j.legDriven or 0
        if driven < 0.7 * j.legStraight then
            -- Ohne echte Fahrt (Sprung, Zuruecksetzen in die Naehe) zaehlt das Ankommen nicht.
            if not j.warned then
                j.warned = true
                say(s.pid, "Angekommen – aber ohne die Strecke zu fahren zählt der Auftrag nicht.")
            end
            return
        end
        if j.dest then
            -- Abgeholt: weiter zum Ziel.
            j.place, j.dest, j.warned = j.dest, nil, nil
            j.legStraight, j.legDriven, j.hintAt = dist(pos, j.place), 0, now
            say(s.pid, "Eingestiegen! Weiter nach %s – %s, noch %s", j.place.name, fmtDist(lang, j.legStraight), fmtClock(left))
            return
        end
        local xp = j.xp
        local fast = (j.total or 0) >= 1000 and (now - j.startAt) <= j.limit * 0.6
        if fast then xp = math.floor(xp * 1.5) end
        xp = math.min(xp, 250)
        local lim = jobLimit(s)
        -- Schicht: Wer den Auftrag hoechstens 3 Minuten nach dem letzten angenommen hat, setzt die Serie fort.
        -- Nur Auftraege ab 1 km zaehlen (kurze bringen auch sonst keinen festen Anteil); abgebrochene beenden die Serie.
        local streakXp = 0
        if (j.total or 0) >= 1000 then
            if lim.streak and lim.doneAt and j.startAt - lim.doneAt <= 180 then lim.streak = lim.streak + 1 else lim.streak = 1 end
            streakXp = BN.jobStreakBonus(lim.streak)
        end
        local capped = xp + streakXp > C.jobXpPerHour - lim.xp
        xp = math.max(0, math.min(xp, C.jobXpPerHour - lim.xp))
        streakXp = math.max(0, math.min(streakXp, C.jobXpPerHour - lim.xp - xp))
        lim.xp, lim.doneAt = lim.xp + xp + streakXp, now
        s.job = nil
        s.lastJobPlace = j.place.name
        s.pendingBonus = s.pendingBonus + xp
        s.pendingJobs = (s.pendingJobs or 0) + 1
        say(s.pid, "✅ Auftrag erledigt: %s in %s – +%d XP%s. Nächster: /auftrag", j.place.name, fmtClock(now - j.startAt), xp,
            fast and tr(lang, " (Blitzschnell! +50 %)") or "")
        if streakXp > 0 then
            s.pendingBonus = s.pendingBonus + streakXp
            say(s.pid, "🔥 Schicht: %d Aufträge in Folge – +%d Bonus-XP!", lim.streak, streakXp)
        elseif lim.streak == 2 and (j.total or 0) >= 1000 then
            say(s.pid, "Schicht läuft: 2 Aufträge in Folge – beim 3. gibt es Bonus-XP (nächsten innerhalb von 3 min annehmen).")
        end
        if capped then say(s.pid, "Stundenlimit für Auftrags-XP erreicht – weitere Aufträge zählen, bringen aber erst später wieder XP.") end
        return
    end
    if left <= 0 then
        s.job = nil
        jobLimit(s).streak = nil
        say(s.pid, "⌛ Zu spät – der Auftrag nach %s ist verfallen. Neuer Versuch: /auftrag", j.place.name)
        return
    end
    if pos and now - j.hintAt >= 30 then
        j.hintAt = now
        local dir = relDirection(j, pos, j.place)
        if dir then
            say(s.pid, "Noch %s bis %s (%s) · %s übrig", fmtDist(lang, dist(pos, j.place)), j.place.name, tr(lang, dir), fmtClock(left))
        else
            say(s.pid, "Noch %s bis %s · %s übrig", fmtDist(lang, dist(pos, j.place)), j.place.name, fmtClock(left))
        end
    end
end

function commands.auftrag(pid, arg)
    local s = session(pid)
    local sub = tostring(arg or ""):lower():match("^%s*(%S*)")
    local lang = BN.langOf(pid)
    if sub == "stop" or sub == "abbrechen" or sub == "cancel" then
        if not s.job then say(pid, "Du hast gerade keinen Auftrag.") return end
        s.job = nil
        jobLimit(s).streak = nil
        say(pid, "Auftrag abgebrochen. Neuer: /auftrag")
        return
    end
    if s.job then
        local pos = currentPosition(s)
        say(pid, "Dein Auftrag: %s · noch %s · %s übrig", s.job.place.name,
            pos and fmtDist(lang, dist(pos, s.job.place)) or "?", fmtClock(s.job.limit - (BN.now() - s.job.startAt)))
        local lim = jobLimit(s)
        if (lim.streak or 0) >= 2 and lim.doneAt and s.job.startAt - lim.doneAt <= 180 then
            say(pid, "Schicht: %d Aufträge in Folge – dieser wäre der %d.", lim.streak, lim.streak + 1)
        end
        return
    end
    if s.race then
        say(pid, "Erst das Rennen beenden (/rennen stop), dann gibt es einen Auftrag.")
        return
    end
    BN.startJob(s)
end
commands.job = commands.auftrag
commands.auftraege = commands.auftrag

-- ---------------------------------------------------------------------------------------------------------------------
-- Verfolgungsjagd (/fangen): Wer mitmacht, meldet sich in chaseJoinSec an; einer wird zufaellig der Fluechtige, alle
-- anderen jagen ihn. Nach dem Vorsprung zaehlt jeder Abstand unter chaseCatchM als gefangen (beide mit aktueller
-- Position). Hinweise alle 15 s: den Jaegern die Entfernung zum Fluechtigen, dem Fluechtigen die zum naechsten Jaeger.

local function chaseSay(text, ...)
    local c = BN.chase
    if not c then return end
    for pid in pairs(c.members) do if BN.players[pid] then say(pid, text, ...) end end
end

local function freshPosition(s)
    local pos = s and currentPosition(s)
    if pos and BN.now() - (pos.at or 0) <= 3 then return pos end
    return nil
end

BN.chaseXpDay = BN.chaseXpDay or {}

-- XP aus der Verfolgungsjagd: nur fuer Konten, hoechstens chaseXpPerDay je Tag und Konto.
local function chaseReward(s, xp)
    if not s or s.guest or xp <= 0 then return 0 end
    local day = dayNumber()
    local e = BN.chaseXpDay[s.id]
    if not e or e.day ~= day then
        e = { day = day, xp = 0 }
        BN.chaseXpDay[s.id] = e
        for id, v in pairs(BN.chaseXpDay) do if v.day ~= day then BN.chaseXpDay[id] = nil end end
    end
    xp = math.max(0, math.min(xp, C.chaseXpPerDay - e.xp))
    e.xp = e.xp + xp
    s.pendingBonus = s.pendingBonus + xp
    return xp
end

function BN.endChase(reason)
    local c = BN.chase
    if not c then return end
    BN.chase = nil
    BN.chaseEndedAt = BN.now()
    local runner = c.runner and BN.players[c.runner]
    -- Echte Jagd: genug Spieler mit Konto, der Fluechtige ist gefahren, und es hat eine Weile gedauert.
    local runnerM = runner and (drivenKm(runner) - (c.runnerKm0 or 0)) * 1000 or 0
    local huntSec = c.huntAt and (BN.now() - c.huntAt) or 0
    if not c.started then
        sayAll("Verfolgungsjagd abgesagt – %s", reason or "")
        return
    end
    local minutes = math.floor((BN.now() - c.huntAt) / 60)
    if reason == "gefangen" then
        local catcher = BN.players[c.catcher]
        local earned = c.rewarded and huntSec >= 60 and runnerM >= 300
        if catcher then
            if earned then
                -- Gewonnen zaehlt bei jeder Jagd, die XP bringt (auch wenn das Tageslimit erreicht ist).
                if not catcher.guest then catcher.pendingChaseWins = (catcher.pendingChaseWins or 0) + 1 end
                say(catcher.pid, "🚓 Gefangen! +%d XP", chaseReward(catcher, C.chaseXpCatch))
            else
                say(catcher.pid, "🚓 Gefangen! (keine XP: zu kurz, zu wenig gefahren oder zu wenige Spieler mit Konto)")
            end
        end
        if runner and earned then
            local xp = chaseReward(runner, minutes * C.chaseXpPerMin)
            if xp > 0 then say(runner.pid, "Du hast %d min durchgehalten: +%d XP", minutes, xp) end
        end
        sayAll("🚓 Verfolgungsjagd vorbei: %s hat %s nach %s gefangen!", catcher and catcher.name or "?", c.runnerName,
            fmtClock(BN.now() - c.huntAt))
    elseif reason == "entkommen" then
        if runner then
            if c.rewarded and runnerM >= 1000 then
                if not runner.guest then runner.pendingChaseWins = (runner.pendingChaseWins or 0) + 1 end
                say(runner.pid, "🏁 Entkommen! +%d XP", chaseReward(runner, C.chaseXpSurvive + minutes * C.chaseXpPerMin))
            else
                say(runner.pid, "🏁 Entkommen! (keine XP: zu wenig gefahren oder zu wenige Spieler mit Konto)")
            end
        end
        sayAll("🏁 Verfolgungsjagd vorbei: %s ist entkommen!", c.runnerName)
    else
        sayAll("Verfolgungsjagd beendet – %s", reason or "")
    end
end

function BN.chaseTick()
    local c = BN.chase
    if not c then return end
    local now = BN.now()
    for pid in pairs(c.members) do
        if not BN.players[pid] then c.members[pid] = nil end
    end
    if not c.started then
        if now < c.startAt then return end
        local list = {}
        for pid in pairs(c.members) do list[#list + 1] = pid end
        if #list < 2 then return BN.endChase(tr(C.language, "zu wenige Mitspieler")) end
        table.sort(list)
        c.runner = list[BN.random(#list)]
        c.runnerName = BN.players[c.runner].name
        c.started, c.huntAt, c.hintAt = true, now + C.chaseHeadStartSec, now
        c.runnerKm0 = drivenKm(BN.players[c.runner])
        local accounts = 0
        for _, p in ipairs(list) do if not BN.players[p].guest then accounts = accounts + 1 end end
        c.rewarded = accounts >= 2
        if not c.rewarded then chaseSay("Diese Jagd bringt keine XP (mindestens 2 Spieler mit BeamMP-Konto nötig).") end
        for pid in pairs(c.members) do
            if pid == c.runner then
                say(pid, "🏃 Du bist der Flüchtige! %d s Vorsprung – halte %s durch.", C.chaseHeadStartSec, fmtClock(C.chaseMaxSec))
            else
                say(pid, "🚓 %s ist der Flüchtige! Los geht's in %d s – fang ihn (näher als %d m).", c.runnerName,
                    C.chaseHeadStartSec, C.chaseCatchM)
            end
        end
        return
    end
    if not BN.players[c.runner] then return BN.endChase(tr(C.language, "der Flüchtige ist weg")) end
    local chasers = 0
    for pid in pairs(c.members) do if pid ~= c.runner then chasers = chasers + 1 end end
    if chasers == 0 then return BN.endChase(tr(C.language, "keine Jäger mehr")) end
    if now < c.huntAt then return end
    if now - c.huntAt >= C.chaseMaxSec then return BN.endChase("entkommen") end
    local rpos = freshPosition(BN.players[c.runner])
    if not rpos then return end
    local nearest, nearestPid
    for pid in pairs(c.members) do
        if pid ~= c.runner then
            local pos = freshPosition(BN.players[pid])
            if pos then
                local d = dist(pos, rpos)
                if not nearest or d < nearest then nearest, nearestPid = d, pid end
            end
        end
    end
    if nearest and nearest <= C.chaseCatchM then
        c.catcher = nearestPid
        return BN.endChase("gefangen")
    end
    if now - c.hintAt >= 15 then
        c.hintAt = now
        local left = fmtClock(C.chaseMaxSec - (now - c.huntAt))
        for pid in pairs(c.members) do
            local lang = BN.langOf(pid)
            if pid == c.runner then
                if nearest then say(pid, "Nächster Jäger: %s · noch %s", fmtDist(lang, nearest), left) end
            else
                local pos = freshPosition(BN.players[pid])
                if pos then say(pid, "Flüchtiger %s: %s entfernt · noch %s", c.runnerName, fmtDist(lang, dist(pos, rpos)), left) end
            end
        end
    end
end

BN.chaseStarts = BN.chaseStarts or {}

function commands.fangen(pid, arg)
    local s = session(pid)
    local sub = tostring(arg or ""):lower():match("^%s*(%S*)")
    local c = BN.chase
    if sub == "stop" then
        if not c then say(pid, "Gerade läuft keine Verfolgungsjagd.") return end
        if not BN.isAdmin(s) and c.by ~= pid then say(pid, "Nur der Starter oder ein Admin kann die Jagd beenden.") return end
        return BN.endChase(tr(C.language, "von %s gestoppt", s.name))
    end
    if sub == "mit" or sub == "join" then
        if not c or c.started then say(pid, "Gerade kann man keiner Verfolgungsjagd beitreten. Neue: /fangen") return end
        c.members[pid] = true
        chaseSay("%s macht bei der Verfolgungsjagd mit.", s.name)
        return
    end
    if c then
        if not c.started then
            say(pid, "Anmeldung läuft noch %d s – mitmachen: /fangen mit", math.max(0, c.startAt - BN.now()))
        else
            say(pid, "Verfolgungsjagd läuft: Flüchtiger ist %s.", c.runnerName)
        end
        return
    end
    if s.race or s.job then
        say(pid, "Erst Rennen oder Auftrag beenden, dann gibt es eine Verfolgungsjagd.")
        return
    end
    if not BN.isAdmin(s) then
        if s.mutedUntil and BN.now() < s.mutedUntil then
            say(pid, "Du bist noch %d s stummgeschaltet.", s.mutedUntil - BN.now())
            return
        end
        local key = s.id or ("ip:" .. tostring(s.ip or pid))
        local last = BN.chaseStarts[key]
        if last and BN.now() - last < 300 then
            say(pid, "Bitte warte noch %d s, bevor du wieder eine Verfolgungsjagd startest.", 300 - (BN.now() - last))
            return
        end
        -- Auch zwischen zwei Jagden auf diesem Server eine Pause (sonst wechseln sich zwei Spieler beim Starten ab).
        local since = BN.now() - (BN.chaseEndedAt or -math.huge)
        if since < C.chaseCooldownSec then
            say(pid, "Die nächste Verfolgungsjagd geht in %d s.", C.chaseCooldownSec - since)
            return
        end
        for k, t in pairs(BN.chaseStarts) do if BN.now() - t >= 300 then BN.chaseStarts[k] = nil end end
        BN.chaseStarts[key] = BN.now()
    end
    BN.chase = { by = pid, startAt = BN.now() + C.chaseJoinSec, members = { [pid] = true } }
    sayAll("🚓 Verfolgungsjagd! %s startet in %d s – mitmachen: /fangen mit", s.name, C.chaseJoinSec)
end
commands.chase = commands.fangen
commands.jagd = commands.fangen

-- ---------------------------------------------------------------------------------------------------------------------
-- Tipps im Chat: der Reihe nach, damit jede Funktion einmal drankommt.

BN.TIPS = {
    "Tipp: /auftrag – fahr einen Patienten ins Krankenhaus oder Kinder zur Schule und sammle XP.",
    "Tipp: /fangen – Verfolgungsjagd! Einer flüchtet, alle anderen jagen ihn.",
    "Tipp: /ziel – das Wochenziel für alle. Wer mitfährt, bekommt Bonus-XP.",
    "Tipp: /freund <Name> – du bekommst Bescheid, sobald ein Freund online kommt.",
    "Tipp: /rennen – Zeitrennen auf dieser Map, gemeinsam mit /rennen gruppe <Strecke>.",
    "Tipp: Jeden Tag ein Stück fahren lohnt sich – ab dem zweiten Tag in Folge gibt es Bonus-XP.",
    "Tipp: /aufgabe – die Tagesaufgabe mit Bonus-XP.",
    "Tipp: /vote map <Name> – stimmt für eine andere Map ab.",
    "Tipp: /team gründen <Name> – fahrt zusammen Kilometer für euer Team.",
    "Tipp: /konvoi – fahrt zusammen! Wer nah beieinander fährt, bekommt Bonus-XP.",
}

function BN.tipTick()
    if C.tipEverySec <= 0 or next(BN.players) == nil then return end
    local now = BN.now()
    if not BN.lastTipAt then BN.lastTipAt = now return end
    if now - BN.lastTipAt < C.tipEverySec then return end
    BN.lastTipAt = now
    BN.tipIndex = (BN.tipIndex or 0) % #BN.TIPS + 1
    local tip = BN.TIPS[BN.tipIndex]
    sayEach(function(lang) return tr(lang, tip) end)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Einsatz-Alarm: ein Ziel fuer alle auf diesem Server, 5 Minuten Zeit. Es zaehlt nur, wer beim Alarm mindestens
-- jobMinDistM entfernt war (wer schon dort steht, gewinnt nicht), mit demselben Fahrzeug ohne Sprung ankommt und
-- mindestens 70 % der Luftlinie gefahren ist (Eintraege je Konto, nicht je Verbindung).

BN.ALERT_TEXT = {
    krankenhaus = "🚨 Notfall! Ein Patient muss sofort ins Krankenhaus %s",
    schule = "🚨 Schulbus kaputt – die Kinder warten an der Schule %s",
    feuerwehr = "🚨 Großeinsatz! Die Feuerwache %s braucht Verstärkung",
    polizei = "🚨 Verfolgung! Die Polizei %s braucht Hilfe",
    tankstelle = "🚨 Brand an der Tankstelle %s!",
    werkstatt = "🚨 Abschleppen! Ein Auto ist liegen geblieben bei der Werkstatt %s",
}
local ALERT_DEFAULT = "🚨 Einsatz bei %s!"

function BN.alertTick()
    if C.alertEverySec <= 0 or C.alertXp <= 0 then return end
    local now = BN.now()
    local a = BN.alert
    if a then
        if now - a.at > 300 then
            BN.alert = nil
            sayAll("Einsatz bei %s vorbei – niemand war schnell genug.", a.place.name)
            return
        end
        -- Gewinnen kann nur, wer beim Alarm mit Konto und weit genug weg dabei war, mit demselben Fahrzeug ohne Sprung
        -- oder Zuruecksetzen ankommt und den Weg wirklich gefahren ist (wie bei /auftrag).
        for pid, s in pairs(BN.players) do
            local e = a.entries[s.id]
            for vid, ev in pairs(e and e.pid == pid and e.vids or {}) do
                local v = not ev.out and s.vehicles[vid]
                if v and now - (v.at or 0) <= 3 and dist(v, a.place) <= C.jobRadiusM and ev.driven >= 0.7 * ev.start then
                    BN.alert = nil
                    s.pendingBonus = s.pendingBonus + C.alertXp
                    sayAll("🏆 %s war zuerst beim Einsatz %s (%s) – +%d XP!", s.name, a.place.name, fmtClock(now - a.at), C.alertXp)
                    return
                end
            end
        end
        return
    end
    if not BN.nextAlertAt then BN.nextAlertAt = now + math.floor(C.alertEverySec * (0.5 + math.random())) return end
    if now < BN.nextAlertAt then return end
    BN.nextAlertAt = now + math.floor(C.alertEverySec * (0.5 + math.random()))
    -- Mitzaehlen nur Spieler mit Konto, die gerade fahren (Gaeste und Zuschauer zaehlen nicht).
    local count = 0
    for _, s in pairs(BN.players) do
        if not s.guest and currentPosition(s) then count = count + 1 end
    end
    if count < C.alertMinPlayers then return end
    local places = BN.loadPlaces()
    if #places == 0 then return end
    local place = places[BN.random(#places)]
    local entries = {}
    for pid, s in pairs(BN.players) do
        -- Jedes Fahrzeug zaehlt fuer sich (welches der Spieler gerade faehrt, ist beim Alarm nicht sicher bekannt).
        local vids = {}
        for vid, v in pairs(s.vehicles) do
            local d = dist(v, place)
            if d >= C.jobMinDistM then vids[vid] = { start = d, driven = 0 } end
        end
        if not s.guest and next(vids) then entries[s.id] = { pid = pid, vids = vids } end
    end
    BN.alert = { place = place, at = now, entries = entries }
    sayEach(function(lang)
        return tr(lang, BN.ALERT_TEXT[place.type] or ALERT_DEFAULT, place.name) .. tr(lang, " – wer zuerst da ist, bekommt +%d XP (5 min)", C.alertXp)
    end)
end

-- ---------------------------------------------------------------------------------------------------------------------
-- Konvoi: zusammen fahren lohnt sich. Zaehlt nur echte Bewegung (wie die Kilometer) des Fahrzeugs, das in diesem Takt
-- am meisten gefahren ist, und nur neben einem anderen Konto mit anderer IP, das ebenfalls gerade faehrt.

BN.convoyLimits = BN.convoyLimits or {}

local function convoyPos(s)
    local v = s.tickVid ~= nil and type(s.vehicles) == "table" and s.vehicles[s.tickVid]
    if type(v) == "table" and tonumber(v.x) and tonumber(v.y) and tonumber(v.z) then return v end
end

function BN.convoyTick()
    if C.convoyXp <= 0 then return end
    local movers = {}
    for _, s in pairs(BN.players) do
        if not s.guest and (tonumber(s.tickMoved) or 0) > 0 then
            -- Einzeln abgesichert: ein kaputter Datensatz trifft nur diesen Spieler, nicht den Konvoi aller.
            local ok, pos = pcall(convoyPos, s)
            if ok and pos then movers[#movers + 1] = { s = s, pos = pos } end
        end
    end
    if #movers < 2 then return end
    local now = BN.now()
    for i, a in ipairs(movers) do
        local mate
        for j, b in ipairs(movers) do
            if i ~= j and b.s.id ~= a.s.id and not (a.s.ip and a.s.ip == b.s.ip)
                and dist(a.pos, b.pos) <= C.convoyRadiusM and (not mate or b.s.tickMoved > mate.tickMoved) then
                mate = b.s
            end
        end
        if mate then
            local s = a.s
            -- Hoechstens so viel, wie der Partner im selben Takt gefahren ist: neben einem kriechenden Zweitkonto
            -- hin und her fahren bringt nichts.
            local moved = math.min(s.tickMoved, mate.tickMoved)
            s.convoyM = (s.convoyM or 0) + moved
            s.pendingConvoyKm = (s.pendingConvoyKm or 0) + moved / 1000
            if s.convoyM >= C.convoyKm * 1000 then
                s.convoyM = s.convoyM - C.convoyKm * 1000
                local lim = BN.convoyLimits[s.id]
                if not lim or now - lim.hourStart >= 3600 then
                    lim = { hourStart = now, xp = 0 }
                    BN.convoyLimits[s.id] = lim
                end
                local xp = math.max(0, math.min(C.convoyXp, C.convoyXpPerHour - lim.xp))
                lim.xp = lim.xp + xp
                if xp > 0 then
                    s.pendingBonus = s.pendingBonus + xp
                    say(s.pid, "🚗🚗 Konvoi mit %s: %s zusammen gefahren – +%d XP", mate.name, fmtKm(C.convoyKm), xp)
                elseif not lim.said then
                    lim.said = true
                    say(s.pid, "Konvoi: Stundenlimit für Konvoi-XP erreicht – zusammen fahren macht trotzdem Spaß!")
                end
            end
        end
    end
    -- Aufraeumen, damit die Tabelle nicht waechst (Eintraege aelter als eine Stunde braucht niemand mehr).
    BN.convoyCleanAt = BN.convoyCleanAt or now
    if now - BN.convoyCleanAt >= 600 then
        BN.convoyCleanAt = now
        for k, v in pairs(BN.convoyLimits) do if now - v.hourStart >= 3600 then BN.convoyLimits[k] = nil end end
    end
end

function commands.konvoi(pid)
    local s = session(pid)
    if C.convoyXp <= 0 then say(pid, "Der Konvoi-Bonus ist auf diesem Server aus.") return end
    say(pid, "Konvoi: fahr mit anderen Spielern (höchstens %d m Abstand) – je %s zusammen gibt es +%d XP (bis %d XP je Stunde).",
        C.convoyRadiusM, fmtKm(C.convoyKm), C.convoyXp, C.convoyXpPerHour)
    if not s.guest then
        local total = (tonumber(s.record.convoyKm) or 0) + (s.pendingConvoyKm or 0)
        say(pid, "Du: %s im Konvoi gefahren, nächster Bonus in %s.", fmtKm(total),
            fmtKm(math.max(0, C.convoyKm - (s.convoyM or 0) / 1000)))
    end
    -- Wer ist in der Naehe (bis 2 km)? Hilft, einander zu finden.
    local pos, lang = currentPosition(s), BN.langOf(pid)
    local near = {}
    if pos then
        for opid, o in pairs(BN.players) do
            local op = opid ~= pid and currentPosition(o)
            local d = op and dist(pos, op)
            if d and d <= 2000 then near[#near + 1] = { name = o.name, d = d } end
        end
    end
    table.sort(near, function(x, y) return x.d < y.d end)
    if #near == 0 then say(pid, "Gerade niemand in deiner Nähe – /server zeigt, wo was los ist.") return end
    local parts = {}
    for i = 1, math.min(5, #near) do parts[i] = near[i].name .. " (" .. fmtDist(lang, near[i].d) .. ")" end
    say(pid, "In der Nähe: %s", table.concat(parts, ", "))
end
commands.convoy = commands.konvoi

-- ---------------------------------------------------------------------------------------------------------------------
-- Wochenziel fuer alle: alle Fahrer zusammen communityKm km in der Kalenderwoche. Das Ziel der Woche steht in
-- community.json (der erste Server der Woche legt es fest, alle uebernehmen es). Fortschritt = Summe der Wochen-km
-- aller Fahrer (Bestenliste, hoechstens eine Minute alt).

local function communityFile() return C.sharedDir .. "/community.json" end

function BN.communityGoal()
    local now = BN.now()
    local wk = weekKey(now)
    local c = BN.communityCache
    if c and c.week == wk then return c.goal end
    local goal = C.communityKm
    local data = json.decode(readFile(communityFile()) or "")
    local saved = type(data) == "table" and data.week == wk and tonumber(data.goal)
    if saved and saved >= 1 and saved < 1e7 then
        goal = math.floor(saved)
    else
        if goal <= 0 then
            local prev, last = weekKey(now - 7 * 86400), 0
            for _, rec in ipairs(BN.playerRecords(false)) do
                if rec.week == prev then last = last + (tonumber(rec.weekKm) or 0)
                elseif rec.lastWeek == prev then last = last + (tonumber(rec.lastWeekKm) or 0) end
            end
            goal = math.max(200, math.ceil(last * 1.1 / 100) * 100)
        end
        ensureDir(C.sharedDir)
        writeFileAtomic(communityFile(), json.encode({ week = wk, goal = goal }))
    end
    BN.communityCache = { week = wk, goal = goal }
    return goal
end

function BN.communityProgress()
    local km = 0
    for _, rec in ipairs(BN.refreshBoard(false)) do km = km + (tonumber(rec.weekKm) or 0) end
    return km, BN.communityGoal()
end

local function progressBar(part, whole)
    local n = whole > 0 and math.min(10, math.floor(part / whole * 10)) or 0
    return string.rep("▰", n) .. string.rep("▱", 10 - n)
end

-- Einmal je Minute: geschafft? Dann Bonus fuer alle hier, die genug beigetragen haben (je Woche einmal).
function BN.communityCheck()
    if C.communityXp <= 0 then return end
    local now = BN.now()
    if now - (BN.lastCommunityCheck or -math.huge) < 60 then return end
    BN.lastCommunityCheck = now
    local km, goal = BN.communityProgress()
    if km < goal then return end
    local wk = weekKey(now)
    if BN.communityAnnounced ~= wk then
        BN.communityAnnounced = wk
        sayEach(function(lang) return tr(lang, "🎉 Wochenziel geschafft: zusammen %s! Alle mit mindestens %s diese Woche bekommen +%d XP.", fmtKm(km), fmtKm(C.communityMinKm), C.communityXp) end)
    end
    for pid, s in pairs(BN.players) do
        if not s.guest and s.record.communityWeek ~= wk and s.pendingCommunity ~= wk
            and BN.totals(s).weekKm >= C.communityMinKm then
            s.pendingCommunity, s.pendingCommunityXp = wk, C.communityXp
            s.pendingBonus = s.pendingBonus + C.communityXp
            say(pid, "🎉 Danke fürs Mitfahren beim Wochenziel: +%d XP!", C.communityXp)
        end
    end
end

function commands.ziel(pid)
    local s = session(pid)
    local km, goal = BN.communityProgress()
    local mine = BN.totals(s).weekKm
    say(pid, "Wochenziel für alle: %s von %s %s (%d %%)", fmtKm(km), fmtKm(goal), progressBar(km, goal),
        goal > 0 and math.min(100, math.floor(km / goal * 100)) or 100)
    if s.guest then return end
    if s.record.communityWeek == weekKey(BN.now()) or s.pendingCommunity == weekKey(BN.now()) then
        say(pid, "Dein Beitrag: %s – Belohnung schon bekommen.", fmtKm(mine))
    elseif mine >= C.communityMinKm then
        say(pid, "Dein Beitrag: %s – du bist dabei: +%d XP, sobald das Ziel erreicht ist.", fmtKm(mine), C.communityXp)
    else
        say(pid, "Dein Beitrag: %s – ab %s bist du dabei (+%d XP, wenn das Ziel erreicht ist).", fmtKm(mine), fmtKm(C.communityMinKm), C.communityXp)
    end
end
commands.goal = commands.ziel
commands.wochenziel = commands.ziel

-- ---------------------------------------------------------------------------------------------------------------------
-- Freundesliste: /freund <Name> fuegt hinzu, /freund weg <Name> entfernt, /freund zeigt, wer gerade wo faehrt.
-- Gespeichert wird die BeamMP-ID (Name nur zur Anzeige). Kommt ein Freund irgendwo im Netzwerk online, bekommt man
-- hier eine Nachricht (dieser Server live, die anderen ueber ihre Lebenszeichen, also mit bis zu einer Minute Verzug).

-- Wer gerade im Netzwerk ist: id -> { name, st } (st = Serverstatus eines anderen Servers, nil = hier).
function BN.networkOnline()
    local online = {}
    for _, s in pairs(BN.players) do
        if not s.guest and s.id then online[s.id] = { name = s.name } end
    end
    for _, st in ipairs(BN.serverList()) do
        if tonumber(st.port) ~= tonumber(BN.server.port) and type(st.ids) == "table" then
            local names = type(st.names) == "table" and st.names or {}
            for i, id in ipairs(st.ids) do
                id = safeId(id)
                if id and not online[id] then online[id] = { name = clipText(names[i] or "?", 64), st = st } end
            end
        end
    end
    return online
end

local function whereText(lang, entry)
    if not entry.st then return tr(lang, "hier") end
    return string.format("%s (%s)", tostring(entry.st.name or "?"), tostring(entry.st.map or "?"))
end

-- Freunde, die gerade online sind, als "Name – Server" (hoechstens 5, Rest als Zahl).
function BN.friendsOnlineText(s, lang, online)
    online = online or BN.networkOnline()
    local parts = {}
    for _, f in ipairs(s.record.friends or {}) do
        local e = online[f.id]
        if e then parts[#parts + 1] = string.format("%s – %s", e.name, whereText(lang, e)) end
    end
    table.sort(parts)
    local n = #parts
    while #parts > 5 do table.remove(parts) end
    local text = table.concat(parts, " · ")
    if n > 5 then text = text .. tr(lang, " · und %d weitere", n - 5) end
    return text, n
end

-- Prueft im Takt (alle friendCheckSec), wer neu im Netzwerk ist, und sagt es seinen Freunden auf diesem Server.
function BN.friendTick(force)
    local now = BN.now()
    if not force and now - (BN.lastFriendCheck or -math.huge) < C.friendCheckSec then return end
    BN.lastFriendCheck = now
    local online = BN.networkOnline()
    local before = BN.friendOnline
    BN.friendOnline = online
    if not before then return end            -- erster Durchlauf (Plugin-Start): nur merken, nichts melden
    for pid, s in pairs(BN.players) do
        for _, f in ipairs((s.record and s.record.friends) or {}) do
            local e = online[f.id]
            if e and not before[f.id] then
                local lang = BN.langOf(pid)
                if e.st then
                    local addr = C.publicHost ~= "" and (C.publicHost .. ":" .. tostring(e.st.port)) or tr(lang, "Port %s", tostring(e.st.port))
                    say(pid, "👋 Dein Freund %s ist jetzt online: %s · %s", e.name, whereText(lang, e), addr)
                else
                    say(pid, "👋 Dein Freund %s ist gerade auf diesen Server gekommen.", e.name)
                end
                if e.name ~= f.name and e.name ~= "?" then
                    f.name = e.name
                    s.friendsChanged, s.dirty = true, true
                end
            end
        end
    end
    -- Teamkollegen: wie Freunde (wer schon als Freund gemeldet wurde, nicht noch einmal). teams.json nur lesen, wenn
    -- jemand neu im Netzwerk ist.
    local fresh = false
    for id in pairs(online) do if not before[id] then fresh = true break end end
    if not fresh then return end
    local data = BN.loadTeams()
    for pid, s in pairs(BN.players) do
        local team
        if not s.guest and s.id then team = select(2, teamOf(data, s.id)) end
        if team then
            local friends = {}
            for _, f in ipairs((s.record and s.record.friends) or {}) do friends[f.id] = true end
            for id in pairs(team.members) do
                local e = online[id]
                if e and not before[id] and id ~= s.id and not friends[id] then
                    local lang = BN.langOf(pid)
                    if e.st then
                        local addr = C.publicHost ~= "" and (C.publicHost .. ":" .. tostring(e.st.port)) or tr(lang, "Port %s", tostring(e.st.port))
                        say(pid, "👥 Dein Teamkollege %s ist jetzt online: %s · %s", e.name, whereText(lang, e), addr)
                    else
                        say(pid, "👥 Dein Teamkollege %s ist gerade auf diesen Server gekommen.", e.name)
                    end
                end
            end
        end
    end
end

-- Sucht einen Spieler mit BeamMP-Konto: erst gleicher Name online (hier, dann andere Server), dann gleicher Name in
-- der Bestenliste, dann Teilname online (nur wenn eindeutig). Liefert id, name oder nil, Fehlertext.
local function findAccount(query)
    local lower = query:lower()
    local online = BN.networkOnline()
    for id, e in pairs(online) do
        if e.name:lower() == lower then return id, e.name end
    end
    for _, rec in ipairs(BN.refreshBoard(false)) do
        local id = safeId(rec.id)
        if id and tostring(rec.name or ""):lower() == lower then return id, tostring(rec.name) end
    end
    local hitId, hitName, count = nil, nil, 0
    for id, e in pairs(online) do
        if e.name:lower():find(lower, 1, true) then hitId, hitName, count = id, e.name, count + 1 end
    end
    if count == 1 then return hitId, hitName end
    if count > 1 then return nil, "mehrdeutig" end
    return nil, "unbekannt"
end

function commands.freund(pid, arg)
    local s = session(pid)
    local text = tostring(arg or ""):match("^%s*(.-)%s*$")
    local sub, rest = text:match("^(%S+)%s*(.-)$")
    sub = (sub or ""):lower()
    if s.guest then
        say(pid, "Freunde gibt es nur mit BeamMP-Konto.")
        return
    end
    local friends = s.record.friends
    if text == "" or sub == "liste" or sub == "list" then
        if #friends == 0 then
            say(pid, "Noch keine Freunde. /freund <Name> fügt jemanden hinzu – du bekommst dann Bescheid, wenn er online kommt.")
            return
        end
        local lang = BN.langOf(pid)
        local onlineText, n = BN.friendsOnlineText(s, lang)
        say(pid, "Deine Freunde: %d · online: %d", #friends, n)
        if n > 0 then chat(pid, onlineText) end
        local offline = {}
        local online = BN.friendOnline or BN.networkOnline()
        for _, f in ipairs(friends) do
            if not online[f.id] then offline[#offline + 1] = f.name end
        end
        table.sort(offline, function(a, b) return a:lower() < b:lower() end)
        if #offline > 0 then say(pid, "Offline: %s", table.concat(offline, ", ")) end
        return
    end
    if sub == "weg" or sub == "entfernen" or sub == "remove" or sub == "del" then
        if rest == "" then
            say(pid, "Aufruf: /freund weg <Name>")
            return
        end
        local lower = rest:lower()
        local idx
        for i, f in ipairs(friends) do if f.name:lower() == lower then idx = i end end
        if not idx then
            for i, f in ipairs(friends) do
                if f.name:lower():find(lower, 1, true) then
                    if idx then
                        say(pid, "Mehrere Freunde passen zu „%s“ – bitte genauer schreiben.", rest)
                        return
                    end
                    idx = i
                end
            end
        end
        if not idx then
            say(pid, "„%s“ ist nicht in deiner Freundesliste.", rest)
            return
        end
        local name = friends[idx].name
        table.remove(friends, idx)
        s.friendsChanged, s.dirty = true, true
        say(pid, "%s ist nicht mehr in deiner Freundesliste.", name)
        return
    end
    local query = (sub == "add" or sub == "neu" or sub == "hinzu") and rest or text
    if query == "" then
        say(pid, "Aufruf: /freund <Name> · /freund weg <Name> · /freund")
        return
    end
    if #friends >= C.maxFriends then
        say(pid, "Deine Freundesliste ist voll (%d). Entferne erst jemanden mit /freund weg <Name>.", C.maxFriends)
        return
    end
    local id, name = findAccount(query)
    if not id then
        if name == "mehrdeutig" then
            say(pid, "Mehrere Spieler passen zu „%s“ – bitte genauer schreiben.", query)
        else
            say(pid, "Keinen Spieler „%s“ gefunden (er muss online sein oder schon einmal gefahren sein).", query)
        end
        return
    end
    if id == s.id then
        say(pid, "Dich selbst brauchst du nicht als Freund. 😉")
        return
    end
    for _, f in ipairs(friends) do
        if f.id == id then
            say(pid, "%s ist schon in deiner Freundesliste.", f.name)
            return
        end
    end
    friends[#friends + 1] = { id = id, name = clipText(name, 64) }
    s.friendsChanged, s.dirty = true, true
    say(pid, "%s ist jetzt in deiner Freundesliste – du bekommst Bescheid, wenn er online kommt.", name)
end
commands.friend = commands.freund
commands.freunde = commands.freund
commands.friends = commands.freund

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
    s.dirty, s.langChanged = true, true
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

-- Alles fuer heute auf einen Blick: Tagesaufgabe, XP-Event bzw. naechster XP-Abend, Bonus-Map, Serie, Wochenziel.
function commands.heute(pid)
    local s = session(pid)
    local lang = BN.langOf(pid)
    say(pid, "☀️ Heute im BeamNet:")
    commands.aufgabe(pid)
    local ev = BN.activeEvent()
    if ev then
        say(pid, "XP-Event läuft: %s-fache XP bis %s Uhr.", fmtFactor(ev.factor), os.date("%H:%M", ev["until"]))
    else
        local e = BN.nextXpEvening()
        if e then chat(pid, xpEveningText(lang, e)) end
    end
    local bm = BN.bonusMap()
    if bm then
        local pct = math.floor((bm.factor - 1) * 100 + 0.5)
        if BN.server.map == bm.map then
            say(pid, "🗺️ Diese Map ist heute Bonus-Map: +%d %% XP beim Fahren!", pct)
        else
            say(pid, "🗺️ Bonus-Map heute: %s – +%d %% XP beim Fahren auf den Servern mit dieser Map (/server).", bm.map, pct)
        end
    end
    if not s.guest and C.streakXp > 0 then
        local streak = BN.streakOf(s.record)
        if streak >= 1 and s.record.streakDay == dayNumber() - 1 then
            say(pid, "🔥 Deine Serie: %d Tage – fahr heute %s, dann gibt es +%d Bonus-XP.", streak, fmtKm(C.streakMinKm),
                C.streakXp * (math.min(streak + 1, C.streakMaxDays) - 1))
        end
        local team = BN.teamNameOf and BN.teamNameOf(s.id)
        if team then
            local km, rank = 0, nil
            for i, e in ipairs(BN.teamWeekRanking(BN.weekRanking(weekKey(BN.now())), nil, weekStartAt(BN.now()))) do
                if e.name == clipText(team, 32) then km, rank = e.km, i end
            end
            say(pid, "👥 Team %s: %s diese Woche · Platz %s (/team woche)", team, fmtKm(km), rank and tostring(rank) or "–")
        end
    end
    commands.ziel(pid)
end
commands.today = commands.heute

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
    local prev = previousMonthKey(now)
    local archive = json.decode(readFile(seasonFile(prev)) or "")
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

-- ---------------------------------------------------------------------------------------------------------------------
-- Map-Abstimmung: /vote map <Name>, dann /vote ja|nein. Bei Mehrheit schreibt das Plugin einen Auftrag nach
-- votes/<Port>.json; der Waechter (beamnet watch, laeuft jede Minute als root) prueft die Map, stellt um und startet
-- den Server neu. Ohne laufenden Waechter (watch.json fehlt oder ist alt) gibt es keine Abstimmung.

BN.MAP_NAMES = {
    gridmap_v2 = "Grid Map", smallgrid = "Small Grid", west_coast_usa = "West Coast, USA", east_coast_usa = "East Coast, USA",
    italy = "Italy", utah = "Utah, USA", jungle_rock_island = "Jungle Rock Island", small_island = "Small Island, USA",
    hirochi_raceway = "Hirochi Raceway", johnson_valley = "Johnson Valley", industrial = "Industrial Site",
    derby = "Derby Arenas", automation_test_track = "Automation Test Track",
}

function BN.mapName(map)
    return BN.MAP_NAMES[map] or (tostring(map):gsub("_", " "))
end

-- Lebenszeichen des Waechters mit den erlaubten Maps; nil, wenn er nicht (mehr) laeuft oder Abstimmungen aus sind.
function BN.watcherInfo()
    local w = json.decode(readFile(C.sharedDir .. "/watch.json") or "")
    if type(w) ~= "table" or not tonumber(w.at) or BN.now() - tonumber(w.at) > 300 then return nil end
    if w.mapVote == false or type(w.maps) ~= "table" or #w.maps == 0 then return nil end
    return w
end

-- Map zu einer Eingabe: genauer Name, Anzeigename oder eindeutiger Teil davon. Gibt map oder nil, Kandidaten zurueck.
function BN.findMap(query, maps)
    local q = tostring(query or ""):lower():gsub("[%s_,%-]+", " ")
    q = q:gsub("^ +", ""):gsub(" +$", "")
    if q == "" then return nil, {} end
    local hits = {}
    for _, m in ipairs(maps) do
        local key = tostring(m):lower():gsub("_", " ")
        local pretty = BN.mapName(m):lower():gsub("[%s_,%-]+", " ")
        if key == q or pretty == q then return m, { m } end
        if key:find(q, 1, true) or pretty:find(q, 1, true) then hits[#hits + 1] = m end
    end
    if #hits == 1 then return hits[1], hits end
    return nil, hits
end

-- Spieler online; leaving (pid) zaehlt nicht mit (beim Abmelden steht er noch in der Liste).
local function onlineSet(leaving)
    local set, n = {}, 0
    for pid in pairs(MP and MP.GetPlayers and MP.GetPlayers() or {}) do
        if pid ~= leaving then set[pid] = true; n = n + 1 end
    end
    return set, n
end

-- Wertet die laufende Abstimmung aus: Mehrheit aller Spieler online = angenommen; kann sie nicht mehr gewinnen oder ist
-- die Zeit um, ist sie abgelehnt.
function BN.voteCheck(leaving)
    local v = BN.vote
    if not v then return end
    local online, n = onlineSet(leaving)
    local yes, no = 0, 0
    for pid in pairs(v.yes) do if online[pid] then yes = yes + 1 end end
    for pid in pairs(v.no) do if online[pid] then no = no + 1 end end
    local needed = math.floor(n / 2) + 1
    local now = BN.now()
    if n > 0 and yes >= needed then
        BN.vote, BN.lastVoteEnd = nil, now
        ensureDir(C.sharedDir)
        ensureDir(C.sharedDir .. "/votes")
        local order = { port = BN.server.port, map = v.map, from = BN.server.map, by = v.by, at = now, yes = yes, no = no, online = n }
        local ok = writeFileAtomic(C.sharedDir .. "/votes/" .. tostring(BN.server.port) .. ".json", json.encode(order))
        if not ok then
            sayAll("Abstimmung angenommen, aber der Auftrag konnte nicht gespeichert werden – bitte einem Admin melden.")
            return
        end
        BN.mapChangePending = { map = v.map, at = now }
        -- Vor dem Neustart alles sichern.
        for _, s in pairs(BN.players) do pcall(BN.savePlayer, s) end
        sayAll("Abstimmung angenommen (%d:%d): Wechsel auf %s – der Server startet in etwa einer Minute neu.", yes, no, BN.mapName(v.map))
    elseif n == 0 or n - no < needed or now >= v.endsAt then
        BN.vote, BN.lastVoteEnd = nil, now
        sayAll("Abstimmung für %s abgelehnt (%d:%d).", BN.mapName(v.map), yes, no)
    end
end

-- Spieler meldet sich ab: Stimme verwerfen (BeamMP vergibt freie pids neu) und neu auswerten.
function BN.voteForget(pid)
    if not BN.vote then return end
    BN.vote.yes[pid], BN.vote.no[pid] = nil, nil
    BN.voteCheck(pid)
end

-- Laeuft der Server BN.MAP_CHANGE_TIMEOUT Sekunden (3 Minuten) nach einer angenommenen Abstimmung noch, hat der
-- Waechter den Auftrag nicht umgesetzt (Wartung, kurz zuvor gewechselt, MAP_VOTE=0, Waechter aus): einmal melden und
-- neue Abstimmungen wieder erlauben (die Pause nach BN.lastVoteEnd gilt weiter). Bis dahin sperrt /vote neue
-- Abstimmungen – beide nutzen dieselbe Frist.
BN.MAP_CHANGE_TIMEOUT = 180
function BN.mapChangeCheck()
    local p = BN.mapChangePending
    if not p or BN.now() - p.at < BN.MAP_CHANGE_TIMEOUT then return end
    BN.mapChangePending = nil
    -- Liegt der Auftrag noch da (Waechter lief nicht), darf er nicht spaeter doch noch ausgefuehrt werden.
    local file = C.sharedDir .. "/votes/" .. tostring(BN.server.port) .. ".json"
    local order = json.decode(readFile(file) or "")
    if type(order) == "table" and order.at == p.at then os.remove(file) end
    sayAll("Der Map-Wechsel auf %s hat nicht geklappt – bitte einem Admin melden.", BN.mapName(p.map))
end

local function voteStatus(pid)
    local v = BN.vote
    local yes, no = 0, 0
    for _ in pairs(v.yes) do yes = yes + 1 end
    for _ in pairs(v.no) do no = no + 1 end
    say(pid, "Abstimmung: %s – %d ja, %d nein, noch %d s. /vote ja oder /vote nein", BN.mapName(v.map), yes, no,
        math.max(0, v.endsAt - BN.now()))
end

function commands.vote(pid, arg)
    local s = session(pid)
    if not C.mapVote then say(pid, "Map-Abstimmungen sind ausgeschaltet.") return end
    local sub, rest = tostring(arg or ""):match("^(%S*)%s*(.-)$")
    sub = sub:lower()
    local yesWords = { ja = true, j = true, yes = true, y = true }
    local noWords = { nein = true, n = true, no = true }
    if yesWords[sub] or noWords[sub] then
        if not BN.vote then say(pid, "Gerade läuft keine Abstimmung.") return end
        BN.vote.yes[pid] = yesWords[sub] or nil
        BN.vote.no[pid] = noWords[sub] or nil
        say(pid, "Stimme gezählt.")
        BN.voteCheck()
        return
    end
    if sub ~= "map" then
        if BN.vote then voteStatus(pid) return end
        local w = BN.watcherInfo()
        if not w then say(pid, "Map-Abstimmung ist auf diesem Netzwerk nicht eingerichtet (Admin: beamnet watch install).") return end
        local list = {}
        for _, m in ipairs(w.maps) do if m ~= BN.server.map then list[#list + 1] = m end end
        say(pid, "Map-Abstimmung: /vote map <Name> – möglich: %s", table.concat(list, ", "))
        return
    end
    -- Neue Abstimmung
    if BN.vote then say(pid, "Es läuft schon eine Abstimmung (%s).", BN.mapName(BN.vote.map)) return end
    local now = BN.now()
    if BN.mapChangePending and now - BN.mapChangePending.at < BN.MAP_CHANGE_TIMEOUT then say(pid, "Die Map wird gleich gewechselt.") return end
    local wait = BN.lastVoteEnd and (BN.lastVoteEnd + C.mapVoteCooldownMin * 60 - now) or 0
    if wait > 0 then say(pid, "Nächste Abstimmung in %s.", fmtDuration(wait)) return end
    local w = BN.watcherInfo()
    if not w then say(pid, "Map-Abstimmung ist auf diesem Netzwerk nicht eingerichtet (Admin: beamnet watch install).") return end
    local map, hits = BN.findMap(rest, w.maps)
    if not map then
        if #hits > 1 then
            say(pid, "Mehrdeutig: %s", table.concat(hits, ", "))
        else
            say(pid, "Unbekannte Map: %s. Möglich: %s", rest, table.concat(w.maps, ", "))
        end
        return
    end
    if map == BN.server.map then say(pid, "%s läuft hier bereits.", BN.mapName(map)) return end
    BN.vote = { map = map, by = s.name, endsAt = now + C.mapVoteSec, yes = { [pid] = true }, no = {} }
    sayAll("%s möchte auf %s wechseln (Neustart). Abstimmen: /vote ja oder /vote nein (%d s)", s.name, BN.mapName(map), C.mapVoteSec)
    BN.voteCheck()
end
commands.abstimmung = commands.vote

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

-- Fehler hoechstens einmal pro Minute je Stelle ins Log (ein Dauerfehler wuerde es sonst im Sekundentakt fluten).
BN.errorLog = BN.errorLog or {}
function BN.logError(where, err)
    local now = BN.now()
    local last = BN.errorLog[where]
    if last and now - last < 60 then return end
    BN.errorLog[where] = now
    print("[BeamNetCore] Fehler (" .. where .. "): " .. tostring(err))
end

-- Fuehrt fn abgesichert aus: ein Fehler an einer Stelle legt nie den ganzen Takt lahm.
local function guarded(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then BN.logError(where, err) end
    return ok, err
end
BN.guarded = guarded

-- Fahrzeit zaehlt nur, wer sich in den letzten so vielen Sekunden bewegt hat (Parken oder Zuschauen bringt keine XP).
local MOVING_WINDOW_SEC = 30

local function tickPlayer(pid)
    local s = session(pid)
    s.tickMoved, s.tickVid = 0, nil      -- bricht der Takt fuer diesen Spieler ab, zaehlt keine alte Strecke weiter
    local vehicles = MP.GetPlayerVehicles and MP.GetPlayerVehicles(pid) or nil
    if type(vehicles) == "table" then
        for vid in pairs(vehicles) do
            local ok, raw = pcall(MP.GetPositionRaw, pid, vid)
            if ok and type(raw) == "table" and raw.pos then BN.track(pid, vid, raw.pos, tonumber(raw.tim), raw.vel) end
        end
    end
    s.tickMoved = flushMoved(s)
    if s.lastMoveAt and BN.now() - s.lastMoveAt < MOVING_WINDOW_SEC then
        s.pendingSeconds = s.pendingSeconds + C.tickMs / 1000
        BN.eventGain(s, C.tickMs / 1000 / 60 * C.xpPerMinute)
    end
    if s.job then BN.jobTick(s) end
    checkProgress(s)
end

function BN.tick()
    if not MP then return end
    local online = MP.GetPlayers and MP.GetPlayers() or {}
    -- Jeder Spieler einzeln abgesichert: ein fehlerhafter Datensatz trifft nur diesen Spieler.
    for pid in pairs(online) do guarded("Takt Spieler " .. tostring(pid), tickPlayer, pid) end
    -- Sitzungen von Spielern entfernen, die ohne Abmeldung verschwunden sind.
    for pid, s in pairs(BN.players) do
        if online[pid] == nil then
            s.leaving = true
            guarded("Speichern", BN.savePlayer, s)
            BN.players[pid] = nil
            guarded("Abstimmung", BN.voteForget, pid)
            guarded("Duell", BN.forgetDuel, pid)
        end
    end
    local now = BN.now()
    local wk = weekKey(now)
    if BN.currentWeek and BN.currentWeek ~= wk then guarded("Wochensieger", BN.announceWeek, BN.currentWeek) end
    local mk = monthKey(now)
    if BN.currentMonth and BN.currentMonth ~= mk then guarded("Saisonende", BN.endSeason, BN.currentMonth) end
    BN.currentMonth = mk
    BN.currentWeek = wk
    guarded("Abstimmung", BN.voteCheck)
    guarded("Map-Wechsel", BN.mapChangeCheck)
    guarded("Gruppenrennen", BN.groupTick)
    guarded("Freunde", BN.friendTick)
    guarded("Wochenziel", BN.communityCheck)
    guarded("Verfolgungsjagd", BN.chaseTick)
    guarded("Tipps", BN.tipTick)
    guarded("Bestenliste", BN.rankTick)
    guarded("Einsatz", BN.alertTick)
    guarded("Konvoi", BN.convoyTick)
    guarded("Wo ist was los", BN.crowdTick)
    guarded("Lieferpunkte", BN.roadTick)
    if now - (BN.lastSeasonCheck or -math.huge) >= 3600 then
        BN.lastSeasonCheck = now
        guarded("Saisonarchiv", BN.ensureSeasonArchive)
    end
    guarded("Abgleich", BN.sync, false)
    if now - BN.lastStatus >= C.statusEverySec then guarded("Status", BN.writeStatus) end
    -- Gestaffelt speichern: jeder Spieler hat seine eigene Sekunde im Speicher-Abstand, damit bei vielen Spielern
    -- nicht alle Dateien im selben Takt geschrieben werden (12 Server teilen sich einen Datenordner).
    local every = C.saveEverySec
    for pid, s in pairs(BN.players) do
        if not s.lastSaveAt then s.lastSaveAt = now - ((tonumber(pid) or 0) * 7) % every end
        if now - s.lastSaveAt >= every then
            s.lastSaveAt = now
            guarded("Speichern", BN.savePlayer, s)
        end
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
    -- Update im laufenden Betrieb: ein Einsatz-Alarm im alten Format (vor 1.55 ohne vids) wird verworfen.
    if BN.alert then
        local ok = type(BN.alert.entries) == "table"
        for _, e in pairs(ok and BN.alert.entries or {}) do
            if type(e) ~= "table" or type(e.vids) ~= "table" then ok = false end
        end
        if not ok then BN.alert = nil end
    end
    -- Update im laufenden Betrieb: Sitzungen der alten Version um neue Felder ergaenzen.
    for pid, s in pairs(BN.players) do
        if not guarded("Sitzung " .. tostring(pid) .. " umstellen", BN.normalizeSession, s) then BN.players[pid] = nil end
    end
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

-- Rueckkehrer-Bonus: einmal, wenn jemand comebackDays Tage nicht da war (hoechstens alle 30 Tage).
function BN.comebackCheck(s)
    if s.guest or s.isNew or C.comebackXp <= 0 then return end
    local rec, now = s.record, BN.now()
    local seen = tonumber(rec.lastSeen)
    if not seen or now - seen < C.comebackDays * 86400 then return end
    if tonumber(rec.comebackAt) and now - tonumber(rec.comebackAt) < 30 * 86400 then return end
    s.pendingComeback = { at = now, xp = C.comebackXp }
    s.pendingBonus = s.pendingBonus + C.comebackXp
    s.dirty = true
    say(s.pid, "👋 Willkommen zurück! Du warst %d Tage weg – hier sind +%d XP zum Wiedereinstieg.",
        math.floor((now - seen) / 86400), C.comebackXp)
end

function BN_onPlayerJoin(pid)
    local s = BN.addPlayer(pid)
    guarded("Rueckkehrer", BN.comebackCheck, s)
    if not s.guest then
        guarded("Stundengrenzen", function()
            BN.applyHourLimit(BN.jobLimits, s.id, s.record.jobHour)
            BN.applyHourLimit(BN.convoyLimits, s.id, s.record.convoyHour)
        end)
    end
    local t = BN.totals(s)
    say(pid, "Willkommen auf %s (%s)! Level %d · Liga %s · %s gefahren. /hilfe für Befehle, /server für alle Server. English: /lang en",
        BN.server.name, BN.server.map, t.level, tr(BN.langOf(pid), t.league.name), fmtKm(t.km))
    local ch = BN.challengeFor()
    if ch and not BN.dayTotals(s).done then
        local lang = BN.langOf(pid)
        say(pid, "Heute: %s (/aufgabe)", tr(lang, ch.text, ch.goal))
    end
    local w = BN.trackOfWeek()
    if w and w.map == BN.mapKey() and s.record.weeklyTrackWeek ~= w.week then
        say(pid, "Strecke der Woche auf dieser Map: %s – %d Bonus-XP (/rennen %s)", w.name, C.weeklyTrackXp, w.name)
    end
    local ev = BN.activeEvent()
    if ev then say(pid, "XP-Event läuft: %s-fache XP bis %s Uhr.", fmtFactor(ev.factor), os.date("%H:%M", ev["until"])) end
    -- Wochenziel nur fuer die, die diese Woche noch nicht genug beigetragen haben (weniger Zeilen beim Betreten).
    if C.communityXp > 0 and not s.guest and t.weekKm < C.communityMinKm then
        local km, goal = BN.communityProgress()
        if km < goal then say(pid, "Wochenziel für alle: %s von %s – fahr mit! (/ziel)", fmtKm(km), fmtKm(goal)) end
    end
    local streak = BN.streakOf(s.record)
    if C.streakXp > 0 and streak >= 1 and s.record.streakDay == dayNumber() - 1 then
        say(pid, "🔥 Deine Serie: %d Tage – fahr heute %s, dann gibt es +%d Bonus-XP.", streak, fmtKm(C.streakMinKm),
            C.streakXp * (math.min(streak + 1, C.streakMaxDays) - 1))
    end
    if #(s.record.friends or {}) > 0 then
        local text, n = BN.friendsOnlineText(s, BN.langOf(pid))
        if n > 0 then say(pid, "Freunde online: %s", text) end
    end
    BN.seasonRecap(s)
    BN.weekRecap(s)
    guarded("Team der Woche", BN.teamWeekReward, s)
    -- Rueckblick/Belohnung: sofort merken, sonst gibt es sie bei schnellem Serverwechsel ein zweites Mal.
    if s.pendingRecap or s.pendingWeekRecap or s.pendingTeamWeek or s.isNew then guarded("Rueckblick speichern", BN.savePlayer, s) end
    BN.showNews(s)
    -- Bonus-Map des Tages: hier oder auf welcher Map.
    local bm = BN.bonusMap()
    if bm then
        local pct = math.floor((bm.factor - 1) * 100 + 0.5)
        if BN.server.map == bm.map then
            say(pid, "🗺️ Diese Map ist heute Bonus-Map: +%d %% XP beim Fahren!", pct)
        else
            say(pid, "🗺️ Bonus-Map heute: %s – +%d %% XP beim Fahren auf den Servern mit dieser Map (/server).", bm.map, pct)
        end
    end
    -- XP-Abend heute (spaetestens in 12 Stunden): Hinweis beim Betreten.
    local xe = BN.nextXpEvening()
    if xe and xe.at - BN.now() <= 12 * 3600 and os.date("%Y-%m-%d", xe.at) == os.date("%Y-%m-%d", BN.now()) then
        chat(pid, "🎉 " .. xpEveningText(BN.langOf(pid), xe))
    end
    if s.isNew and not s.guest and C.tutorialXp > 0 and s.record.tutorial == nil then
        s.record.tutorial, s.tutorialStarted = {}, true
    end
    if C.tutorialXp > 0 and type(s.record.tutorial) == "table" then
        local done, nextStep = tutorialState(s)
        if nextStep then say(pid, "Einsteiger-Pfad %d/%d: %s (/start)", done, #BN.TUTORIAL, tr(BN.langOf(pid), nextStep.text)) end
    end
    if s.isNew and C.welcomeNew then
        say(pid, "Schön, dass du da bist, %s! Deine Kilometer und XP zählen auf allen BeamNet-Servern.", s.name)
        BN.sayRules(pid)
        for other in pairs(BN.players) do
            if other ~= pid then say(other, "%s ist zum ersten Mal im BeamNet – herzlich willkommen!", s.name) end
        end
    end
    BN.writeStatus()
end

-- Offene Duell-Einladungen von und an diese Sitzung verfallen.
function BN.forgetDuel(pid)
    BN.duelInvites[pid] = nil
    for to, inv in pairs(BN.duelInvites) do if inv.from == pid then BN.duelInvites[to] = nil end end
end

function BN_onPlayerDisconnect(pid)
    local s = BN.players[pid]
    if s then
        s.leaving = true
        guarded("Speichern", BN.savePlayer, s)
    end
    BN.players[pid] = nil
    guarded("Abstimmung", BN.voteForget, pid)
    guarded("Duell", BN.forgetDuel, pid)
    BN.writeStatus()
end

function BN.onChat(pid, message)
    if BN.handleChat(pid, message) then return 1 end
    local s = BN.players[pid]
    -- Alles andere (auch "/..." anderer Plugins) unterliegt Spamschutz und Stummschaltung.
    if s and type(message) == "string" and BN.spamCheck(s) then return 1 end
    if s and type(message) == "string" and BN.filterCheck(s, message) then return 1 end
end

function BN_onChatMessage(pid, _, message)
    local ok, result = pcall(BN.onChat, pid, message)
    if not ok then
        print("[BeamNetCore] Fehler im Chat: " .. tostring(result))
        return nil
    end
    return result
end

-- Verbindungs-Spam: Zeitpunkte der Versuche je Schluessel (IP und Konto), gesperrt bis blockedUntil.
BN.joins = BN.joins or {}

function BN.joinAllowed(name, id, ip)
    for _, a in ipairs(C.admins or {}) do
        a = tostring(a)
        if id and (a == id or a:lower() == tostring(name or ""):lower()) then return true end
    end
    local now = BN.now()
    local keys = {}
    if ip and ip ~= "" then keys[#keys + 1] = "ip:" .. tostring(ip) end
    if id then keys[#keys + 1] = "id:" .. id end
    if #keys == 0 then return true end
    -- Aufraeumen, damit die Tabelle nicht waechst.
    BN.joinsCount = (BN.joinsCount or 0) + 1
    if BN.joinsCount % 200 == 0 then
        for k, e in pairs(BN.joins) do
            if (e.blockedUntil or 0) < now and (e.times[#e.times] or 0) < now - C.joinWindowSec then BN.joins[k] = nil end
        end
    end
    local blocked, newlyBlocked = false, false
    for _, k in ipairs(keys) do
        local e = BN.joins[k] or { times = {} }
        BN.joins[k] = e
        if (e.blockedUntil or 0) > now then
            blocked = true
        else
            local kept = {}
            for _, t in ipairs(e.times) do if now - t < C.joinWindowSec then kept[#kept + 1] = t end end
            kept[#kept + 1] = now
            e.times = kept
            if #kept > C.joinLimit then
                e.blockedUntil, e.times = now + C.joinBlockSec, {}
                blocked, newlyBlocked = true, true
            end
        end
    end
    if newlyBlocked then
        print("[BeamNetCore] Zu viele Verbindungsversuche, kurz gesperrt: " .. tostring(name))
        modlog({ action = "join-spam", target = clipText(name or "?", 40), targetId = id, seconds = C.joinBlockSec })
    end
    return not blocked
end

-- Gesperrte Spieler gar nicht erst hereinlassen (Rueckgabe eines Textes = Ablehnung mit diesem Grund).
function BN_onPlayerAuth(name, role, isGuest, identifiers)
    local ids = type(identifiers) == "table" and identifiers or {}
    local id = safeId(ids.beammp)
    if not BN.joinAllowed(name, id, ids.ip) then
        return tr(C.language, "Zu viele Verbindungsversuche – bitte in %d Minuten erneut versuchen.", math.ceil(C.joinBlockSec / 60))
    end
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
    guarded("Lieferpunkte", BN.saveRoadPoints)
    for _, s in pairs(BN.players) do guarded("Speichern", BN.savePlayer, s) end
    guarded("Status", BN.writeStatus)
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
