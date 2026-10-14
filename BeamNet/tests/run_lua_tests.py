"""Fuehrt die Lua-Tests von BeamNetCore unter Lua 5.3 (wie BeamMP), 5.4 und LuaJIT aus.

Aufruf: python3 BeamNet/tests/run_lua_tests.py      (braucht: pip install lupa)
"""
import importlib
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.join(HERE, "..", "server", "BeamNetCore", "main.lua")
TEST = os.path.join(HERE, os.environ.get("BEAMNET_TEST_FILE", "core_test.lua"))


def run(runtime_name: str) -> int:
    try:
        module = importlib.import_module("lupa." + runtime_name)
    except ImportError:
        if runtime_name == "lua53" or os.environ.get("BEAMNET_ALL_RUNTIMES"):
            raise
        print(f"(übersprungen: {runtime_name} gibt es in dieser lupa-Version nicht)")
        return 0
    with tempfile.TemporaryDirectory() as tmp:
        shared = os.path.join(tmp, "shared", "beamnet")
        os.environ["BEAMNET_SHARED"] = shared
        os.environ["BEAMNET_PLUGIN"] = os.path.abspath(PLUGIN)
        old = os.getcwd()
        os.chdir(tmp)
        try:
            lua = module.LuaRuntime()
            with open(TEST, encoding="utf-8") as f:
                failed = lua.execute(f.read())
        finally:
            os.chdir(old)
    return int(failed or 0)


def main() -> int:
    total = 0
    for name in ("lua53", "lua54", "luajit21"):
        print(f"--- {name}")
        total += run(name)
    print("ALLES GRÜN" if total == 0 else f"{total} Fehler")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
