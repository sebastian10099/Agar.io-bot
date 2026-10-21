"""Single source of truth for everything the control page may change.

The schema drives both validation on the server and the form in the browser,
so a new parameter is one entry here and nothing else."""
from __future__ import annotations

import copy
import math
from typing import Any, Optional

CHAINS = ["solana", "ethereum", "base", "bsc"]

# path, type, min, max, step, label, help, group
SCHEMA: list[dict[str, Any]] = [
    {"path": "poll_seconds", "type": "int", "min": 2, "max": 300, "step": 1,
     "label": "Abfrage-Intervall", "unit": "s", "group": "Allgemein",
     "help": "Wie oft neue Tokens geholt und offene Positionen geprüft werden. Unter 10 s drohen Rate-Limits der kostenlosen APIs (429) – dann wird ein Poll übersprungen, kein Schaden, aber auch kein Gewinn."},
    {"path": "chains", "type": "chains", "label": "Chains", "group": "Allgemein",
     "help": "Welche Netzwerke beobachtet werden. RugCheck gibt es nur für Solana."},
    {"path": "discovery.sources", "type": "multi", "label": "Discovery-Quellen", "group": "Allgemein",
     "options": [["dexscreener", "DexScreener"], ["geckoterminal", "GeckoTerminal"], ["pumpfun", "pump.fun"]],
     "help": "Woher neue Tokens kommen. DexScreener liefert immer die Kennzahlen; GeckoTerminal sieht frische Pools früher; pump.fun meldet Solana-Starts Sekunden nach der Erstellung (inoffizielle API, kann ausfallen). Status unten unter „Quellen“."},

    {"path": "auto_update", "type": "bool", "label": "Automatisch aktualisieren", "group": "Allgemein",
     "help": "Alle 30 Minuten nach einer neuen Version schauen und sie selbst einspielen; der Bot startet dafür "
             "kurz neu, Konto und Einstellungen bleiben. Nur bei einer Installation über get.sh auf dem Mac."},

    {"path": "risk_per_trade_pct", "type": "float", "min": 0.1, "max": 10, "step": 0.1,
     "label": "Risiko pro Trade", "unit": "%", "group": "Risiko",
     "help": "Anteil der Bankroll, der bei einem Stop-Loss verloren geht. Positionsgröße = Risiko ÷ Stop-Abstand."},
    {"path": "max_open_positions", "type": "int", "min": 1, "max": 50, "step": 1,
     "label": "Max. offene Positionen", "group": "Risiko"},
    {"path": "daily_loss_limit_pct", "type": "float", "min": 0.5, "max": 50, "step": 0.5,
     "label": "Tages-Verlustlimit", "unit": "%", "group": "Risiko",
     "help": "Ab diesem realisierten Tagesverlust werden keine neuen Positionen eröffnet."},
    {"path": "reentry_pause_minutes", "type": "float", "min": 0, "max": 10080, "step": 5,
     "label": "Wiedereinstieg-Sperre", "unit": "min", "group": "Risiko",
     "help": "Nach dem Verkauf wird derselbe Token so lange nicht automatisch wieder gekauft – ein Trailing- oder Stop-Loss-Ausstieg hat gerade gesagt, dass der Lauf vorbei ist. 0 = aus. Der Knopf „Kaufen“ von Hand gilt immer."},
    {"path": "paper.fee_pct", "type": "float", "min": 0, "max": 10, "step": 0.1,
     "label": "Gebühr pro Fill", "unit": "%", "group": "Risiko",
     "help": "Wird bei jedem Kauf und Verkauf abgezogen. Pessimistisch halten."},
    {"path": "paper.slippage_pct", "type": "float", "min": 0, "max": 20, "step": 0.1,
     "label": "Slippage pro Fill", "unit": "%", "group": "Risiko"},

    {"path": "filters.min_age_minutes", "type": "float", "min": 0, "max": 1440, "step": 0.5,
     "label": "Mindestalter", "unit": "min", "group": "Filter"},
    {"path": "filters.max_age_minutes", "type": "float", "min": 1, "max": 10080, "step": 1,
     "label": "Höchstalter", "unit": "min", "group": "Filter"},
    {"path": "filters.min_liquidity_usd", "type": "float", "min": 0, "max": 1e9, "step": 1000,
     "label": "Min. Liquidität", "unit": "$", "group": "Filter"},
    {"path": "filters.max_liquidity_usd", "type": "float", "min": 1000, "max": 1e10, "step": 10000,
     "label": "Max. Liquidität", "unit": "$", "group": "Filter"},
    {"path": "filters.min_volume_m5_usd", "type": "float", "min": 0, "max": 1e9, "step": 500,
     "label": "Min. Volumen 5 min", "unit": "$", "group": "Filter"},
    {"path": "filters.min_buys_m5", "type": "int", "min": 0, "max": 100000, "step": 1,
     "label": "Min. Käufe 5 min", "group": "Filter"},
    {"path": "filters.min_buy_sell_ratio_m5", "type": "float", "min": 0, "max": 100, "step": 0.1,
     "label": "Min. Käufe/Verkäufe", "group": "Filter"},
    {"path": "filters.min_price_change_m5_pct", "type": "float", "min": -100, "max": 10000, "step": 1,
     "label": "Min. Kursänderung 5 min", "unit": "%", "group": "Filter"},
    {"path": "filters.max_price_change_m5_pct", "type": "float", "min": -100, "max": 100000, "step": 5,
     "label": "Max. Kursänderung 5 min", "unit": "%", "group": "Filter",
     "help": "Darüber gilt der Token als parabolisch – zu spät."},
    {"path": "filters.max_fdv_usd", "type": "float", "min": 0, "max": 1e12, "step": 100000,
     "label": "Max. FDV", "unit": "$", "group": "Filter"},
    {"path": "filters.max_fdv_liquidity_ratio", "type": "float", "min": 0, "max": 1000, "step": 0.5,
     "label": "Max. Bewertung / Liquidität", "unit": "×", "group": "Filter",
     "help": "Ist der Token (FDV) viel mehr wert als der Pool dahinter, leeren ihn wenige Verkäufer: "
             "im Live-Test stürzten 31–40 % solcher Pools binnen einer Stunde um 80 % ab, sonst 13 %. 0 = aus."},
    {"path": "filters.require_rugcheck", "type": "bool",
     "label": "Sicherheitsprüfung verlangen", "group": "Filter",
     "help": "Solana-Tokens werden nur gekauft, wenn RugCheck oder – falls RugCheck nicht antwortet – die eigene Prüfung über die Blockchain (Freeze-/Mint-Authority, Token-2022-Fallen) ein Ergebnis liefert."},
    {"path": "filters.allow_rugcheck_unknown", "type": "bool",
     "label": "RugCheck-Ausfall tolerieren", "group": "Filter",
     "help": "Wenn an: Ist RugCheck nicht erreichbar, zählt das nicht als Ablehnung."},
    {"path": "filters.allow_curve_buys", "type": "bool",
     "label": "Tokens auf der Bonding-Kurve kaufen", "group": "Filter",
     "help": "Aus (empfohlen): Coins, die noch auf ihrer pump.fun-Kurve handeln, werden nur beobachtet und "
             "erst gekauft, wenn sie in einen echten Pool umgezogen sind. Im Live-Test verloren Kurven-Coins "
             "nach Kosten im Schnitt 30 % in 15 Minuten, Pool-Coins gewannen."},
    {"path": "filters.early_own_pools", "type": "bool",
     "label": "Frühkauf: selbst eröffnete PumpSwap-Pools", "group": "Filter",
     "help": "Hohes Risiko – nur zum Testen mit Spielgeld. Wenn an: gekauft werden nur Pools, die jemand selbst "
             "auf PumpSwap für einen eigenen Coin eröffnet hat, und „LP unlocked“ wird dort hingenommen – der "
             "Ersteller kann die Liquidität jederzeit abziehen. Im Live-Test stiegen solche Pools, in ihrer ersten "
             "Minute gekauft, meist deutlich; Minuten später gekauft verloren sie. Mit Höchstalter 1,5 min nutzen "
             "(Profil „★ Frühkauf“)."},
    {"path": "filters.max_top_holder_pct", "type": "float", "min": 1, "max": 100, "step": 1,
     "label": "Max. Anteil der größten Wallet", "unit": "%", "group": "Filter",
     "help": "Hält eine einzelne Wallet (ohne Pools und Sperrkonten) mehr, wird nicht gekauft. 100 = aus. "
             "Im Frühkauf-Test wurden 2 von 3 Coins mit einer Wallet über 10 % geleert."},
    {"path": "filters.reject_mutable_metadata", "type": "bool",
     "label": "Änderbare Metadaten ablehnen", "group": "Filter",
     "help": "RugCheck-Warnung „Mutable metadata“: der Ersteller kann Name und Bild noch ändern. Im "
             "Frühkauf-Test wurden 4 von 5 solcher Coins geleert."},
    {"path": "filters.require_holder_check", "type": "bool",
     "label": "Nur mit geprüften Haltern kaufen", "group": "Filter",
     "help": "Solana-Tokens werden nur gekauft, wenn bekannt ist, wer die Menge hält: die Halterverteilung "
             "oder bei pump.fun-Coins wenigstens der Ersteller-Anteil. Sonst wird nur beobachtet – "
             "die meisten schnellen Abstürze kommen von großen Haltern, die abverkaufen."},
    {"path": "filters.max_rugcheck_score", "type": "float", "min": 0, "max": 100000, "step": 100,
     "label": "Max. RugCheck-Score", "group": "Filter"},

    {"path": "scoring.min_score", "type": "float", "min": 0, "max": 100, "step": 1,
     "label": "Min. Score für Kauf", "group": "Strategie",
     "help": "0–100. Darunter wird nur beobachtet (watch)."},

    {"path": "exits.stop_loss_pct", "type": "float", "min": -95, "max": -1, "step": 1,
     "label": "Stop-Loss", "unit": "%", "group": "Exits"},
    {"path": "exits.take_profit_ladder", "type": "ladder",
     "label": "Gewinnleiter", "group": "Exits",
     "help": "Stufen als „Gewinn%: Anteil“, z. B. 50: 0.5, 100: 0.25 – bei +50 % die Hälfte verkaufen, bei +100 % ein weiteres Viertel."},
    {"path": "exits.trailing_stop_pct", "type": "float", "min": 1, "max": 95, "step": 1,
     "label": "Trailing-Stop", "unit": "%", "group": "Exits",
     "help": "Abstand vom Hoch. Wird erst scharf, wenn das Hoch so weit im Plus lag."},
    {"path": "exits.time_stop_minutes", "type": "float", "min": 1, "max": 10080, "step": 1,
     "label": "Zeit-Stop", "unit": "min", "group": "Exits"},

    {"path": "ai.mode", "type": "enum", "options": [["off", "Aus"], ["advise", "Beraten – Urteil nur protokollieren"], ["decide", "Entscheiden – Urteil ersetzt die Regeln"]],
     "label": "KI-Modus", "group": "KI",
     "help": "Claude bewertet nur Kandidaten, die die harten Filter bestanden haben. „Beraten“ misst, ob die KI besser wäre; „Entscheiden“ lässt sie kaufen."},
    {"path": "ai.provider", "type": "enum", "options": [["anthropic", "Claude (Anthropic)"], ["openrouter", "OpenRouter – auch kostenlose Modelle"]],
     "label": "Anbieter", "group": "KI",
     "help": "Claude über Anmeldung oder Schlüssel; OpenRouter mit kostenlosem Schlüssel von openrouter.ai, Modelle mit „:free“ kosten nichts."},
    {"path": "ai.model", "type": "text", "max_len": 60, "label": "Claude-Modell", "group": "KI",
     "help": "Standard claude-opus-5-5. Nur ändern, wenn du weißt, welches Modell du willst."},
    {"path": "ai.openrouter_model", "type": "text", "max_len": 80, "label": "OpenRouter-Modell", "group": "KI",
     "help": "Z. B. meta-llama/llama-3.3-70b-instruct:free oder deepseek/deepseek-chat-v3-0324:free. Liste: openrouter.ai/models?q=free"},
    {"path": "ai.effort", "type": "enum", "options": [["low", "niedrig"], ["medium", "mittel"], ["high", "hoch"]],
     "label": "Denk-Tiefe", "group": "KI", "help": "Mehr Tiefe = genauer, langsamer, teurer."},
    {"path": "ai.max_calls_per_hour", "type": "int", "min": 1, "max": 600, "step": 1,
     "label": "Max. Anfragen pro Stunde", "group": "KI", "help": "Kostenbremse. Darüber hinaus wird nicht gefragt, die Regeln entscheiden allein."},
    {"path": "ai.min_confidence", "type": "float", "min": 0, "max": 1, "step": 0.05,
     "label": "Mindest-Vertrauen für Kauf", "group": "KI", "help": "Im Modus „Entscheiden“ kauft die KI nur ab dieser Vertrauenszahl."},

    {"path": "crypto.enabled", "type": "bool", "label": "Krypto-Desk", "group": "Krypto",
     "help": "Eigenes Spielgeld-Konto gegen echte Binance-Kurse: jeden Tag nach 00:00 UTC die Setups des Krypto-Scanners, "
             "mit Stop, Ziel, Gebühr und Schlupf. Echtes Geld bewegt es nie."},
    {"path": "crypto.risk_pct", "type": "float", "min": 0.1, "max": 5, "step": 0.1,
     "label": "Risiko pro Krypto-Trade", "unit": "%", "group": "Krypto",
     "help": "So viel vom Krypto-Konto geht verloren, wenn der Stop greift (nach Gebühren)."},
    {"path": "crypto.max_open", "type": "int", "min": 1, "max": 30, "step": 1,
     "label": "Max. offene Krypto-Positionen", "group": "Krypto"},
    {"path": "crypto.entry_window_h", "type": "int", "min": 1, "max": 24, "step": 1,
     "label": "Einstiegsfenster nach 00:00 UTC", "unit": "h", "group": "Krypto",
     "help": "Nur in diesen Stunden nach dem Tagesschluss kaufen – so wurde im Rückblick gerechnet. Läuft der Bot dann nicht, fällt der Tag aus."},
    {"path": "crypto.require_hint", "type": "bool", "label": "Nur mit Zeitmaschinen-Hinweis", "group": "Krypto",
     "help": "Nur kaufen, wenn die Zeitmaschine „Schwacher Hinweis“ sagt (Historie deutlich im Plus). Aus: alle Setups kaufen und das Urteil nur mitschreiben, damit man sieht, ob es etwas taugt."},
]

GROUPS = ["Allgemein", "Risiko", "Filter", "Strategie", "Exits", "KI", "Krypto"]


def get_path(cfg: dict[str, Any], path: str) -> Any:
    node: Any = cfg
    for key in path.split("."):
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node


def set_path(cfg: dict[str, Any], path: str, value: Any) -> None:
    keys = path.split(".")
    node = cfg
    for key in keys[:-1]:
        node = node.setdefault(key, {})
    node[keys[-1]] = value


def parse_ladder(value: Any) -> list[list[float]]:
    """Accepts [[50, 0.5], ...] or the text form '50: 0.5, 100: 0.25'."""
    if isinstance(value, str):
        pairs = []
        for chunk in value.replace(";", ",").split(","):
            chunk = chunk.strip()
            if not chunk:
                continue
            if ":" not in chunk:
                raise ValueError(f"Stufe „{chunk}“ braucht die Form Gewinn%: Anteil")
            a, b = chunk.split(":", 1)
            pairs.append([float(a), float(b)])
        value = pairs
    if not isinstance(value, list):
        raise ValueError("Gewinnleiter muss eine Liste sein")
    out: list[list[float]] = []
    for item in value:
        if not isinstance(item, (list, tuple)) or len(item) != 2:
            raise ValueError("Jede Stufe ist ein Paar aus Gewinn% und Anteil")
        pct, frac = float(item[0]), float(item[1])
        if not (math.isfinite(pct) and 0 < pct <= 100_000):         # NaN and Infinity broke the page and every exit
            raise ValueError("Gewinn% jeder Stufe muss eine Zahl zwischen 0 und 100000 sein")
        if not 0 < frac <= 1:
            raise ValueError("Anteil jeder Stufe muss zwischen 0 und 1 liegen")
        out.append([pct, frac])
    out.sort(key=lambda p: p[0])
    if sum(f for _, f in out) > 1.0 + 1e-9:
        raise ValueError("Die Anteile der Gewinnleiter dürfen zusammen 1 nicht übersteigen")
    return out


def validate(patch: dict[str, Any]) -> tuple[dict[str, Any], dict[str, str]]:
    """Coerce and range-check a flat {path: value} patch. Returns (clean, errors)."""
    by_path = {e["path"]: e for e in SCHEMA}
    clean: dict[str, Any] = {}
    errors: dict[str, str] = {}
    for path, raw in patch.items():
        entry = by_path.get(path)
        if entry is None:
            errors[path] = "unbekannter Parameter"
            continue
        kind = entry["type"]
        try:
            if kind in ("int", "float"):
                if isinstance(raw, str):
                    raw = raw.replace(",", ".").strip()
                try:
                    value = float(raw)
                except (TypeError, ValueError, OverflowError):
                    raise ValueError("keine Zahl") from None
                if value != value or value in (float("inf"), float("-inf")):  # NaN / Infinity
                    raise ValueError("keine Zahl")
                if kind == "int":
                    if abs(value - round(value)) > 1e-9:
                        raise ValueError("muss eine ganze Zahl sein")
                    value = int(round(value))
                if value < entry["min"] or value > entry["max"]:
                    raise ValueError(f"muss zwischen {entry['min']:g} und {entry['max']:g} liegen")
                clean[path] = value
            elif kind == "bool":
                if isinstance(raw, str):
                    raw = raw.lower() in ("1", "true", "on", "yes", "ja")
                clean[path] = bool(raw)
            elif kind == "chains":
                items = raw if isinstance(raw, list) else str(raw).split(",")
                chains = [str(c).strip().lower() for c in items if str(c).strip()]
                bad = [c for c in chains if c not in CHAINS]
                if bad:
                    raise ValueError("unbekannt: " + ", ".join(bad) + ". Erlaubt: " + ", ".join(CHAINS))
                if not chains:
                    raise ValueError("mindestens eine Chain")
                clean[path] = sorted(set(chains), key=chains.index)
            elif kind == "multi":
                allowed = [o[0] for o in entry["options"]]
                items = raw if isinstance(raw, list) else str(raw).split(",")
                picked = [str(c).strip().lower() for c in items if str(c).strip()]
                bad = [c for c in picked if c not in allowed]
                if bad:
                    raise ValueError("unbekannt: " + ", ".join(bad) + ". Erlaubt: " + ", ".join(allowed))
                if not picked:
                    raise ValueError("mindestens eine Quelle")
                clean[path] = [c for c in allowed if c in picked]
            elif kind == "ladder":
                clean[path] = parse_ladder(raw)
            elif kind == "enum":
                allowed = [o[0] for o in entry["options"]]
                if raw not in allowed:
                    raise ValueError("muss eines von " + ", ".join(allowed) + " sein")
                clean[path] = raw
            elif kind == "text":
                if not isinstance(raw, str):
                    raise ValueError("muss Text sein")
                value = raw.strip()
                if not value or len(value) > entry.get("max_len", 200):
                    raise ValueError("fehlt oder ist zu lang")
                clean[path] = value
            else:
                errors[path] = "unbekannter Typ"
        except (TypeError, ValueError, OverflowError) as error:
            errors[path] = str(error) or "ungültig"
    return clean, errors


def cross_check(cfg: dict[str, Any]) -> dict[str, str]:
    """Rules that span two fields, checked on the merged result."""
    errors: dict[str, str] = {}
    f = cfg["filters"]
    if f["min_age_minutes"] >= f["max_age_minutes"]:
        errors["filters.max_age_minutes"] = "muss größer als das Mindestalter sein"
    if f["min_liquidity_usd"] >= f["max_liquidity_usd"]:
        errors["filters.max_liquidity_usd"] = "muss größer als die Mindestliquidität sein"
    if f["min_price_change_m5_pct"] >= f["max_price_change_m5_pct"]:
        errors["filters.max_price_change_m5_pct"] = "muss größer als das Minimum sein"
    return errors


def apply(cfg: dict[str, Any], clean: dict[str, Any]) -> Optional[dict[str, str]]:
    """Merge a validated patch into cfg in place (so every holder of the dict
    sees it). Returns cross-check errors and leaves cfg untouched if any."""
    trial = copy.deepcopy(cfg)
    for path, value in clean.items():
        set_path(trial, path, value)
    errors = cross_check(trial)
    if errors:
        return errors
    for path, value in clean.items():
        set_path(cfg, path, value)
    return None


def flat(cfg: dict[str, Any]) -> dict[str, Any]:
    return {e["path"]: get_path(cfg, e["path"]) for e in SCHEMA}


def schema_for_client() -> dict[str, Any]:
    return {"groups": GROUPS, "fields": SCHEMA, "chains": CHAINS}
