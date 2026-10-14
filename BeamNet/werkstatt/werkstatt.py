"""BeamNet-Werkstatt: Deine lokale KI arbeitet die Aufgaben von Claude ab, Claude prüft nur noch.

Ablauf (immer wieder, alle 10 Minuten):
  1. neue Aufgaben aus BeamNet/lokale-ki/aufgaben/*.md im GitHub-Projekt holen
  2. die lokale KI (Ollama oder LM Studio – auf diesem Rechner oder auf deinem Server) schreibt Änderungsblöcke
  3. Änderungen einspielen, Schnelltest ausführen; bei Fehlern bis zu 3 Versuche mit der Fehlermeldung
  4. Ergebnis als Branch lokal/<name> hochladen – dann Claude sagen: "prüfe Branch lokal/<name>"

Start: Doppelklick auf BeamNet-Werkstatt (Windows: .exe). Optionen: --hilfe
"""
import argparse
import contextlib
import io
import json
import locale
import os
import re
import runpy
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

VERSION = "1.1"
REPO_URL = "https://github.com/sebastian10099/Agar.io-bot.git"
BASE = "claude/friendly-goldberg-31l8fp"
TASK_DIR = "BeamNet/lokale-ki/aufgaben"
HOME = os.path.join(os.path.expanduser("~"), "BeamNet-Werkstatt")
CONFIG = os.path.join(HOME, "einstellungen.json")
STATE = os.path.join(HOME, "erledigt.json")
LOG = os.path.join(HOME, "werkstatt.log")
# Bevorzugte Modelle (Anfang des Namens), das erste vorhandene gewinnt.
PREFERRED = ["qwen3-coder", "devstral", "qwen2.5-coder:32b", "qwen2.5-coder:14b", "gpt-oss", "qwen2.5-coder", "deepseek-coder"]
MAX_TRIES = 3


# ---------------------------------------------------------------------------------------------------------------------
# Ausgabe

def log(msg):
    line = time.strftime("%H:%M:%S ") + msg
    print(line, flush=True)
    try:
        os.makedirs(HOME, exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d ") + line + "\n")
    except OSError:
        pass


def load_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


# ---------------------------------------------------------------------------------------------------------------------
# Aufgaben

def parse_task(text):
    """Kopfzeilen (Branch, Dateien, Lesen, Test) bis '---', danach die Beschreibung."""
    head, _, body = text.partition("\n---")
    task = {"branch": "", "files": [], "read": [], "test": "", "body": body.strip()}
    for line in head.splitlines():
        key, sep, value = line.partition(":")
        if not sep:
            continue
        key, value = key.strip().lower(), value.strip()
        if key == "branch":
            task["branch"] = value
        elif key == "dateien":
            task["files"] = value.split()
        elif key == "lesen":
            task["read"] = value.split()
        elif key == "test":
            task["test"] = value
    return task


def valid_task(task):
    if not re.fullmatch(r"lokal/[A-Za-z0-9._-]+", task["branch"]):
        return "Branch muss lokal/<name> heißen"
    if not task["files"]:
        return "Zeile 'Dateien:' fehlt"
    for p in task["files"] + task["read"]:
        if p.startswith(("/", "\\")) or ".." in p.replace("\\", "/").split("/"):
            return "unsicherer Pfad: " + p
    return None


# ---------------------------------------------------------------------------------------------------------------------
# Änderungsblöcke (SEARCH/REPLACE wie bei Aider – das Format kennen Code-Modelle gut)

BLOCK = re.compile(
    r"^[ \t]*([^\n`<>=]+?)[ \t]*\n(?:[ \t]*```[^\n]*\n)?<<<<<<< SEARCH[ \t]*\n(.*?)^=======[ \t]*\n(.*?)^>>>>>>> REPLACE[ \t]*$",
    re.M | re.S,
)


def parse_edits(answer):
    edits = []
    for m in BLOCK.finditer(answer):
        path = m.group(1).strip().strip("`*#").strip()
        path = re.sub(r"^(?:datei|file|pfad|path)\s*:\s*", "", path, flags=re.I)
        edits.append((path, m.group(2), m.group(3)))
    return edits


def apply_edit(text, search, replace):
    """Ersetzt search genau einmal; toleriert abweichende Leerzeichen am Zeilenende. None, wenn nicht gefunden."""
    if search == "":
        return replace if text == "" else text.rstrip("\n") + "\n" + replace
    if search in text:
        return text.replace(search, replace, 1)
    # Toleranter Vergleich: Zeilen ohne Leerzeichen am Ende.
    lines = text.split("\n")
    want = [l.rstrip() for l in search.rstrip("\n").split("\n")]
    for i in range(len(lines) - len(want) + 1):
        if [l.rstrip() for l in lines[i:i + len(want)]] == want:
            new = lines[:i] + replace.rstrip("\n").split("\n") + lines[i + len(want):]
            return "\n".join(new)
    return None


def apply_edits(repo, task, edits):
    """Spielt alle Blöcke ein; gibt eine Liste von Problemen zurück (leer = alles gut)."""
    problems = []
    allowed = set(task["files"])
    for path, search, replace in edits:
        norm = path.replace("\\", "/")
        if norm not in allowed:
            problems.append(f"{path}: diese Datei darf nicht geändert werden (erlaubt: {', '.join(task['files'])})")
            continue
        full = os.path.join(repo, *norm.split("/"))
        try:
            with open(full, encoding="utf-8", newline="") as f:
                text = f.read()
        except FileNotFoundError:
            text = ""
        new = apply_edit(text, search, replace)
        if new is None:
            first = search.strip().split("\n")[0][:80]
            problems.append(f"{path}: SEARCH-Block nicht gefunden (beginnt mit: {first!r}) – muss exakt mit der Datei übereinstimmen")
            continue
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8", newline="") as f:
            f.write(new)
    return problems


# ---------------------------------------------------------------------------------------------------------------------
# Lokale KI (Ollama oder OpenAI-kompatibel wie LM Studio)

def http_json(url, payload=None, timeout=30):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def detect_backend(url=None):
    """(art, basis-url, modelle) oder None."""
    candidates = [url] if url else ["http://127.0.0.1:11434", "http://127.0.0.1:1234"]
    for base in candidates:
        base = base.rstrip("/")
        try:
            tags = http_json(base + "/api/tags", timeout=5)
            return "ollama", base, [m["name"] for m in tags.get("models", [])]
        except Exception:
            pass
        for v1 in (base + "/v1", base):
            try:
                models = http_json(v1 + "/models", timeout=5)
                return "openai", v1, [m["id"] for m in models.get("data", [])]
            except Exception:
                pass
    return None


def pick_model(models, wanted=None):
    if wanted:
        return wanted
    for pref in PREFERRED:
        for m in models:
            if m.startswith(pref):
                return m
    return models[0] if models else None


def ask_model(backend, messages, model, context):
    kind, base = backend
    if kind == "ollama":
        r = http_json(base + "/api/chat", {"model": model, "messages": messages, "stream": False,
                                           "options": {"num_ctx": context, "temperature": 0.2}}, timeout=3600)
        return r["message"]["content"]
    r = http_json(base + "/chat/completions", {"model": model, "messages": messages, "temperature": 0.2}, timeout=3600)
    return r["choices"][0]["message"]["content"]


SYSTEM = """Du bist ein sorgfältiger Programmierer im Projekt BeamNet (BeamMP-Server-Netzwerk: Lua-Plugin und Bash-Werkzeug).
Du bekommst eine Aufgabe und den vollständigen Inhalt der Dateien, die du ändern darfst.
Antworte NUR mit Änderungsblöcken in genau diesem Format (beliebig viele):

pfad/zur/datei
<<<<<<< SEARCH
exakt kopierte, zusammenhängende Zeilen aus der Datei (genug, um eindeutig zu sein)
=======
die neuen Zeilen
>>>>>>> REPLACE

Regeln: SEARCH muss Zeichen für Zeichen mit der Datei übereinstimmen (Einrückung!). Kleine Blöcke statt ganzer Dateien.
Nur die erlaubten Dateien ändern. Stil des vorhandenen Codes übernehmen (Kommentare auf Deutsch). Spieler-Texte auf Deutsch
mit Umlauten; jeder neue deutsche Chat-Text im Plugin braucht einen englischen Eintrag in der Tabelle EN.
Zu jeder Änderung einen Test schreiben, wenn die Aufgabe eine Testdatei nennt. Keine Versionsnummern, README oder ROADMAP ändern."""


def build_prompt(repo, task):
    parts = ["AUFGABE:\n" + task["body"], ""]
    for label, paths in (("DATEI (darf geändert werden)", task["files"]), ("NUR ZUM LESEN", task["read"])):
        for p in paths:
            full = os.path.join(repo, *p.split("/"))
            try:
                with open(full, encoding="utf-8") as f:
                    content = f.read()
            except FileNotFoundError:
                content = "(Datei gibt es noch nicht – neu anlegen mit leerem SEARCH)"
            parts.append(f"{label}: {p}\n```\n{content}\n```")
    return "\n\n".join(parts)


# ---------------------------------------------------------------------------------------------------------------------
# Git und Tests

def git(repo, *args, check=True):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, encoding="utf-8", errors="replace")
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip() or r.stdout.strip()}")
    return r.stdout


def find_bash():
    b = shutil.which("bash")
    if b:
        return b
    for p in (r"C:\Program Files\Git\bin\bash.exe", r"C:\Program Files (x86)\Git\bin\bash.exe"):
        if os.path.exists(p):
            return p
    return None


def run_test(repo, cmd):
    """(ok, ausgabe). Plugin-Tests laufen eingebaut (lupa ist im Programm enthalten), alles andere über bash."""
    if not cmd:
        return True, "(kein Test angegeben)"
    m = re.search(r"(BeamNet/tests/run_lua_tests\.py)", cmd)
    if m:
        out = io.StringIO()
        old = os.getcwd()
        code = 0
        try:
            os.chdir(repo)
            # Wie auf dem BeamMP-Server: C-Zeichenklassen (sonst verhaelt sich Lua je nach Sprache anders).
            with contextlib.suppress(locale.Error):
                locale.setlocale(locale.LC_CTYPE, "C")
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                try:
                    runpy.run_path(os.path.join(repo, m.group(1)), run_name="__main__")
                except SystemExit as e:
                    code = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
                except Exception as e:  # Lua-Fehler beim Laden usw.
                    print(f"{type(e).__name__}: {e}")
                    code = 1
        finally:
            os.chdir(old)
        return code == 0, out.getvalue()
    bash = find_bash()
    if not bash:
        return True, "(Test übersprungen: bash nicht gefunden – läuft in GitHub)"
    r = subprocess.run([bash, "-c", cmd], cwd=repo, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return r.returncode == 0, (r.stdout + r.stderr)


def ensure_repo(path):
    if os.path.isdir(os.path.join(path, ".git")):
        return path
    log(f"Lade das Projekt nach {path} …")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    r = subprocess.run(["git", "clone", "--branch", BASE, REPO_URL, path], text=True)
    if r.returncode != 0:
        raise RuntimeError("git clone fehlgeschlagen")
    return path


def ensure_identity(repo):
    if not git(repo, "config", "user.name", check=False).strip():
        git(repo, "config", "user.name", "BeamNet-Werkstatt")
    if not git(repo, "config", "user.email", check=False).strip():
        git(repo, "config", "user.email", "werkstatt@beamnet.local")


def remote_branch_exists(repo, branch):
    return bool(git(repo, "ls-remote", "--heads", "origin", branch, check=False).strip())


def list_tasks(repo):
    names = git(repo, "ls-tree", "--name-only", f"origin/{BASE}", TASK_DIR + "/").split()
    return sorted(n for n in names if n.endswith(".md"))


# ---------------------------------------------------------------------------------------------------------------------
# Eine Aufgabe

def run_task(repo, path, backend, model, context, push=True):
    text = git(repo, "show", f"origin/{BASE}:{path}")
    task = parse_task(text)
    problem = valid_task(task)
    if problem:
        log(f"  übersprungen ({problem})")
        return "ungueltig"
    git(repo, "checkout", "-q", "-B", task["branch"], f"origin/{BASE}")
    git(repo, "reset", "-q", "--hard", f"origin/{BASE}")
    git(repo, "clean", "-qfd")
    messages = [{"role": "system", "content": SYSTEM}, {"role": "user", "content": build_prompt(repo, task)}]
    ok, output, tries = False, "", 0
    for tries in range(1, MAX_TRIES + 1):
        log(f"  Versuch {tries}/{MAX_TRIES}: die KI arbeitet … (das kann einige Minuten dauern)")
        try:
            answer = ask_model(backend, messages, model, context)
        except Exception as e:
            log(f"  KI nicht erreichbar: {e}")
            return "fehler"
        edits = parse_edits(answer)
        git(repo, "checkout", "-q", "--", ".")
        git(repo, "clean", "-qfd")
        problems = apply_edits(repo, task, edits) if edits else ["Keine Änderungsblöcke gefunden – bitte genau im SEARCH/REPLACE-Format antworten."]
        if problems:
            output = "\n".join(problems)
            log("  Änderungen passten nicht: " + output.splitlines()[0])
        else:
            ok, output = run_test(repo, task["test"])
            log("  Schnelltest: " + ("grün ✔" if ok else "rot ✖"))
            if ok:
                break
        messages += [{"role": "assistant", "content": answer},
                     {"role": "user", "content": "Das hat nicht geklappt:\n" + output[-4000:] +
                      "\n\nBitte gib den vollständigen, korrigierten Satz Änderungsblöcke an – bezogen auf die ORIGINAL-Dateien von oben."}]
    if not git(repo, "status", "--porcelain").strip():
        log("  Die KI hat nichts geändert.")
        return "leer"
    git(repo, "add", "-A", *task["files"])
    status = "Schnelltest grün" if ok else f"Schnelltest ROT nach {tries} Versuchen"
    git(repo, "commit", "-q", "-m", f"Lokale KI: {os.path.basename(path)} ({status})\n\nModell: {model}\n\n{output[-1500:]}")
    if push:
        r = subprocess.run(["git", "-C", repo, "push", "-q", "-u", "origin", task["branch"], "--force"], text=True)
        if r.returncode != 0:
            log("  Hochladen fehlgeschlagen – beim nächsten Durchlauf erneut.")
            return "fehler"
    log(f"  Fertig: {task['branch']} ({status}). Sag Claude: \"prüfe Branch {task['branch']}\"")
    return "gruen" if ok else "rot"


# ---------------------------------------------------------------------------------------------------------------------
# Hauptschleife

def main(argv=None):
    ap = argparse.ArgumentParser(prog="BeamNet-Werkstatt", add_help=False,
                                 description="Lokale KI arbeitet die Aufgaben von Claude ab.")
    ap.add_argument("--hilfe", "-h", action="help", help="diese Hilfe")
    ap.add_argument("--url", help="Adresse der KI, z. B. http://127.0.0.1:11434 (Ollama) oder http://meinserver:11434")
    ap.add_argument("--modell", help="Modellname, z. B. qwen3-coder:30b")
    ap.add_argument("--kontext", type=int, help="Kontextgröße in Tokens (Standard 65536)")
    ap.add_argument("--projekt", help="Ordner des Projekts (Standard: ~/BeamNet-Werkstatt/Agar.io-bot)")
    ap.add_argument("--einmal", action="store_true", help="nur einen Durchlauf, dann beenden")
    ap.add_argument("--nicht-hochladen", action="store_true", help="nichts hochladen (zum Ausprobieren)")
    ap.add_argument("--version", action="version", version=f"BeamNet-Werkstatt {VERSION}")
    ap.add_argument("--selbsttest", metavar="ORDNER", help=argparse.SUPPRESS)
    args = ap.parse_args(argv)
    if args.selbsttest:     # fuer die Bau-Pruefung: laufen die eingebauten Plugin-Tests?
        ok, out = run_test(os.path.abspath(args.selbsttest), "python3 BeamNet/tests/run_lua_tests.py")
        print(out[-3000:])
        return 0 if ok else 1

    cfg = load_json(CONFIG, {})
    for key in ("url", "modell", "kontext", "projekt"):
        if getattr(args, key):
            cfg[key] = getattr(args, key)
    save_json(CONFIG, cfg)
    log(f"BeamNet-Werkstatt {VERSION} – Einstellungen: {CONFIG}")

    if not shutil.which("git"):
        log("Git fehlt. Bitte installieren (Windows: https://git-scm.com/download/win, Mac: xcode-select --install) und neu starten.")
        return 2
    repo = ensure_repo(cfg.get("projekt") or os.path.join(HOME, "Agar.io-bot"))
    ensure_identity(repo)

    while True:
        found = detect_backend(cfg.get("url"))
        if not found or not found[2]:
            log("Keine lokale KI gefunden. Ollama installieren (https://ollama.com), dann z. B.: ollama pull qwen3-coder:30b")
            log("Läuft die KI auf deinem Server: --url http://<server>:11434 (am sichersten über einen SSH-Tunnel).")
            if args.einmal:
                return 3
            time.sleep(60)
            continue
        kind, base, models = found
        model = pick_model(models, cfg.get("modell"))
        log(f"KI: {kind} unter {base}, Modell {model}")
        done = load_json(STATE, {})
        try:
            git(repo, "fetch", "-q", "origin", BASE)
            tasks = list_tasks(repo)
        except RuntimeError as e:
            log(f"Projekt nicht erreichbar: {e}")
            tasks = []
        todo = [t for t in tasks if t not in done]
        log(f"{len(tasks)} Aufgaben, davon neu: {len(todo)}")
        for path in todo:
            branch = parse_task(git(repo, "show", f"origin/{BASE}:{path}")).get("branch", "")
            if branch and remote_branch_exists(repo, branch):
                log(f"{path}: Branch {branch} gibt es schon – übersprungen")
                done[path] = "vorhanden"
                save_json(STATE, done)
                continue
            log(f"Aufgabe {path}")
            result = run_task(repo, path, (kind, base), model, int(cfg.get("kontext") or 65536), push=not args.nicht_hochladen)
            if result != "fehler":
                done[path] = result
                save_json(STATE, done)
        if args.einmal:
            return 0
        log("Warte 10 Minuten auf neue Aufgaben … (Beenden: Fenster schließen oder Strg+C)")
        time.sleep(600)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
    except Exception as e:  # Fenster nicht sofort schließen, damit man die Meldung lesen kann
        log(f"Fehler: {e}")
        if getattr(sys, "frozen", False):
            input("Enter drücken zum Beenden …")
        sys.exit(1)
