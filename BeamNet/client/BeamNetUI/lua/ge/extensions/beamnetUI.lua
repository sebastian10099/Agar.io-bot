-- BeamNetUI (Spielseite): verbindet das Fenster (UI-App "BeamNet") mit dem Server-Plugin BeamNetCore.
--   Server -> Spiel:   BeamMP-Ereignis "BN_UI" (JSON mit dem Stand: Strecken, Spieler, Herausforderung, Rennen)
--   Spiel -> Server:   BeamMP-Ereignis "BN_UIReq" (JSON: { a = Aktion, track = Strecke, target = Spielernummer })
-- Der Server prueft jede Anfrage wie einen Chat-Befehl; hier wird nur weitergereicht und begrenzt.
local M = {}

local ACTIONS = { state = true, race = true, group = true, join = true, stop = true, duel = true, accept = true,
                  decline = true }
local lastState = nil
local hinted = false

local function toUI(state)
    if guihooks and guihooks.trigger then guihooks.trigger("BeamNetUI", state) end
end

-- Stand vom Server (Text): pruefen, merken und an das Fenster geben.
local function onServerState(data)
    if type(data) ~= "string" or #data > 200000 then return end
    local ok, state = pcall(jsonDecode, data)
    if not ok or type(state) ~= "table" then return end
    lastState = state
    toUI(state)
    -- /fenster: einmal erklaeren, wo das Fenster zu finden ist (falls es noch nicht auf dem Bildschirm liegt).
    if state.open and not hinted and guihooks and guihooks.trigger then
        hinted = true
        local en = state.lang == "en"
        guihooks.trigger("toastrMsg", { type = "info", title = "BeamNet",
            msg = en and "Window: Esc -> UI Apps -> BeamNet" or "Fenster: Esc -> UI-Apps -> BeamNet" })
    end
end
M.onServerState = onServerState

-- Anfrage aus dem Fenster an den Server (nur bekannte Aktionen, kurze Werte).
function M.uiRequest(req)
    if type(req) ~= "table" or not ACTIONS[req.a] then return false end
    local out = { a = req.a }
    if type(req.track) == "string" then out.track = req.track:sub(1, 24) end
    local target = tonumber(req.target)
    if target then out.target = math.floor(target) end
    if not TriggerServerEvent then return false end
    TriggerServerEvent("BN_UIReq", jsonEncode(out))
    return true
end

-- Das Fenster ist (wieder) da: letzten Stand zeigen und einen frischen holen.
function M.uiReady()
    if lastState then toUI(lastState) end
    M.uiRequest({ a = "state" })
end

function M.onExtensionLoaded()
    if AddEventHandler then AddEventHandler("BN_UI", onServerState) end
end

return M
