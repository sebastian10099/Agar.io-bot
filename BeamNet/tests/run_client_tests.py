"""Test der Spielseite des Fensters (Client-Mod BeamNetUI, lua/ge/extensions/beamnetUI.lua) mit nachgebauten
BeamMP- und BeamNG-Funktionen (AddEventHandler, TriggerServerEvent, guihooks, jsonEncode/jsonDecode).

Aufruf: python3 BeamNet/tests/run_client_tests.py      (braucht: pip install lupa)
"""
import importlib
import json
import os
import sys

# BeamNG laeuft mit LuaJIT; BEAMNET_LUA=lua53 prueft zusaetzlich unter Lua 5.3.
lupa53 = importlib.import_module("lupa." + os.environ.get("BEAMNET_LUA", "luajit21"))

HERE = os.path.dirname(os.path.abspath(__file__))
EXT = os.path.join(HERE, "..", "client", "BeamNetUI", "lua", "ge", "extensions", "beamnetUI.lua")
MOD = os.path.join(HERE, "..", "client", "BeamNetUI", "scripts", "beamnetUI", "modScript.lua")

passed = failed = 0


def check(cond, what):
    global passed, failed
    if cond:
        passed += 1
    else:
        failed += 1
        print("FEHLER: " + what)


def to_py(v):
    if lupa53.lua_type(v) == "table":
        return {k: to_py(x) for k, x in v.items()}
    return v


lua = lupa53.LuaRuntime(unpack_returned_tuples=True)
g = lua.globals()
sent, ui, handlers = [], [], {}
g.jsonEncode = lambda t: json.dumps(to_py(t), sort_keys=True)
g.jsonDecode = lambda s: lua.table_from(json.loads(s), recursive=True)
g.TriggerServerEvent = lambda ev, data: sent.append((ev, data))
g.AddEventHandler = lambda ev, fn: handlers.__setitem__(ev, fn)
hooks = lua.table()
hooks.trigger = lambda ev, data: ui.append((ev, to_py(data)))
g.guihooks = hooks

with open(EXT, encoding="utf-8") as f:
    M = lua.execute(f.read())
M.onExtensionLoaded()
check("BN_UI" in handlers, "Ereignis BN_UI angemeldet")

# Stand vom Server ins Fenster
handlers["BN_UI"]('{"lang":"de","me":{"name":"Sebi"},"tracks":[{"name":"Bergsprint"}]}')
check(ui and ui[-1][0] == "BeamNetUI" and ui[-1][1]["me"]["name"] == "Sebi", "Stand geht an das Fenster")
n = len(ui)
handlers["BN_UI"]("{kaputt")
handlers["BN_UI"]("x" * 300000)
handlers["BN_UI"](None)
check(len(ui) == n, "kaputter oder zu grosser Stand wird ignoriert")
# /fenster: einmal ein Hinweis, wo das Fenster ist
handlers["BN_UI"]('{"open":true,"lang":"en"}')
handlers["BN_UI"]('{"open":true,"lang":"en"}')
toasts = [d for ev, d in ui if ev == "toastrMsg"]
check(len(toasts) == 1 and "UI Apps" in toasts[0]["msg"], "Hinweis auf das Fenster genau einmal (Englisch)")

# Anfragen aus dem Fenster an den Server
check(M.uiRequest(lua.table_from({"a": "race", "track": "Bergsprint"})) is True, "Rennen-Anfrage gesendet")
check(sent[-1] == ("BN_UIReq", '{"a": "race", "track": "Bergsprint"}'), "Anfrage als JSON an BN_UIReq")
M.uiRequest(lua.table_from({"a": "duel", "target": 3.7, "track": "x" * 40, "extra": "rm -rf /"}))
req = json.loads(sent[-1][1])
check(req == {"a": "duel", "target": 3, "track": "x" * 24}, "nur bekannte Felder, gekuerzt")
k = len(sent)
check(M.uiRequest(lua.table_from({"a": "kick"})) is False and len(sent) == k, "unbekannte Aktion nicht gesendet")
check(M.uiRequest("race") is False and len(sent) == k, "keine Tabelle: nichts gesendet")
# Fenster neu geladen: letzten Stand zeigen und frischen holen
n = len(ui)
M.uiReady()
check(len(ui) == n + 1 and json.loads(sent[-1][1]) == {"a": "state"}, "uiReady: letzter Stand und neue Anfrage")

# modScript laedt die Erweiterung
loaded = []
g.load = lambda name: loaded.append(name)
g.setExtensionUnloadMode = lambda name, mode: loaded.append(name + ":" + mode)
with open(MOD, encoding="utf-8") as f:
    lua.execute(f.read())
check(loaded == ["beamnetUI", "beamnetUI:manual"], "modScript laedt beamnetUI")

print(f"Fenster (Spielseite, {os.environ.get('BEAMNET_LUA', 'luajit21')}): {passed} Prüfungen bestanden, {failed} fehlgeschlagen")
sys.exit(1 if failed else 0)
