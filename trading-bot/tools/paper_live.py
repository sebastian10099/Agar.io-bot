#!/usr/bin/env python3
"""Snapshot of a running bot for viewing elsewhere. Reads /api/state of the
local bot and writes, into OUTDIR:

  index.html   read-only dashboard that reloads itself every minute
  REPORT.md    the same as text (GitHub renders it on the branch page)
  state.json   the raw state, for anyone who wants the numbers

  python3 tools/paper_live.py http://127.0.0.1:8765 OUTDIR

The Paper-Live workflow runs it every two minutes and publishes OUTDIR to
the branch paper-live. Nothing here can trade or change the bot: it only
reads /api/state."""
from __future__ import annotations

import html
import json
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

try:
    from zoneinfo import ZoneInfo
    TZ: Any = ZoneInfo("Europe/Berlin")
except Exception:  # noqa: BLE001 - no tz database: UTC is still a clear time
    TZ = timezone.utc

PUMP_DEXES = {"pumpfun", "pump-fun"}


def fetch_state(base: str) -> dict[str, Any]:
    with urllib.request.urlopen(base.rstrip("/") + "/api/state", timeout=20) as r:
        return json.loads(r.read().decode("utf-8"))


def _t(ts: Optional[float], fmt: str = "%d.%m. %H:%M") -> str:
    return datetime.fromtimestamp(ts, TZ).strftime(fmt) if ts else "–"


def _usd(v: Optional[float], sign: bool = False) -> str:
    if v is None:
        return "–"
    s = f"{abs(v):,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
    return ("+" if sign and v > 0 else "−" if v < 0 else "") + "$" + s


def _pct(v: Optional[float]) -> str:
    return "–" if v is None else f"{v:+.1f} %".replace(".", ",").replace("-", "−")


def _liq(sn: dict[str, Any]) -> str:
    kind = sn.get("liquidity_kind")
    if kind == "graduated":
        return "Kurve fertig"
    if kind == "unknown" and not sn.get("liquidity_usd"):
        return "unbekannt"
    return _usd(sn.get("liquidity_usd")) + (" Kurve" if kind == "curve" else "")


def _cls(v: Optional[float]) -> str:
    return "" if not v else ("pos" if v > 0 else "neg")


def token_url(chain: str, token: str, dex: Optional[str], url: Optional[str]) -> Optional[str]:
    """pump.fun's coin page survives the move from the curve to PumpSwap; else the source's own link."""
    if chain == "solana" and dex in PUMP_DEXES and token and token.isalnum():
        return f"https://pump.fun/coin/{token}"
    return url if isinstance(url, str) and url.startswith("https://") else None


def position_url(p: dict[str, Any], sn: dict[str, Any]) -> Optional[str]:
    """A position whose candidate has scrolled out of the snapshot still gets a link: pump.fun
    mints end in "pump", anything else goes to its pair on DexScreener."""
    url = token_url(p["chain"], p["token"], sn.get("dex"), sn.get("url"))
    if url or not str(p.get("token") or "").isalnum():
        return url
    if p["chain"] == "solana" and p["token"].endswith("pump"):
        return f"https://pump.fun/coin/{p['token']}"
    return f"https://dexscreener.com/{p['chain']}/{p['pair']}" if str(p.get("pair") or "").isalnum() else None


def _num(v: Any, fmt: str) -> str:
    """German decimal comma for scores and prices."""
    return "–" if v is None else format(v, fmt).replace(".", ",").replace("-", "−")


def _hit(m: dict[str, Any]) -> str:
    return f"{m['wins'] / m['closed_n'] * 100:.0f} %" if m["closed_n"] else "–"


def model(state: dict[str, Any], now: float) -> dict[str, Any]:
    """Everything the two renderings show, computed once."""
    cands = state.get("candidates") or []
    by_token = {c["token"]: c for c in reversed(cands)}
    open_rows = []
    for p in state.get("open_positions") or []:
        c = by_token.get(p["token"]) or {}
        sn = c.get("snapshot") or {}
        open_rows.append({**p, "url": position_url(p, sn)})
    closed_rows = []
    for p in (state.get("closed") or [])[:25]:
        c = by_token.get(p["token"]) or {}
        sn = c.get("snapshot") or {}
        pct = p["realized_usd"] / p["size_usd"] * 100 if p.get("size_usd") else None
        mins = (p["closed_at"] - p["opened_at"]) / 60 if p.get("closed_at") else None
        closed_rows.append({**p, "pct": pct, "minutes": mins, "url": position_url(p, sn)})
    interesting = [c for c in cands if c["decision"] != "skip"][:15]
    stats = state.get("stats") or {}
    initial = float(state.get("initial") or 0)
    bankroll = float(state.get("bankroll") or 0)
    last = state.get("last_poll_wall")
    return {
        "now": now, "started": state.get("started_at"), "polls": state.get("polls", 0), "errors": state.get("errors", 0),
        "last_poll_ago": (now - last) if last else None, "poll_ms": state.get("poll_ms_avg"),
        "initial": initial, "bankroll": bankroll, "total_pnl": bankroll - initial + float(state.get("unrealized") or 0),
        "realized": stats.get("realized_usd", 0.0), "unrealized": state.get("unrealized"), "cash": state.get("cash"),
        "today": state.get("daily_pnl"), "closed_n": stats.get("closed", 0), "wins": stats.get("wins", 0),
        "candidates_n": stats.get("candidates", 0), "open": open_rows, "closed": closed_rows,
        "interesting": interesting, "recent": cands[:20],
        "reasons": ((state.get("skip_reasons") or {}).get("reasons") or [])[:8],
        "edge": state.get("edge") or [], "exits": state.get("exits_by_reason") or [],
        "sources": state.get("sources") or [], "events": (state.get("events") or [])[:20],
        "paused": state.get("paused"), "mode": state.get("mode"), "demo": state.get("demo"),
        "crypto": state.get("crypto"),
    }


# --- Krypto-Desk -------------------------------------------------------------
def _coin(sym: Any) -> str:
    return str(sym or "").removesuffix("USDT")


def _rate(v: Optional[float]) -> str:
    return "–" if v is None else f"{v * 100:.0f} %"


def _r(v: Optional[float]) -> str:
    return "–" if v is None else f"{v:+.2f} R".replace(".", ",").replace("-", "−")


def crypto_svg(c: dict[str, Any], w: int = 1000, h: int = 240) -> str:
    """The account against "BTC halten" as a static chart: the page runs no scripts, so every
    20th point carries its numbers as a hover title."""
    pts = [p for p in (c.get("curve") or []) if p and p[1] is not None]
    if len(pts) < 2:
        return "<p class=muted>Die Kurve beginnt nach den ersten 10 Minuten.</p>"
    start = float(c.get("start_usd") or pts[0][1])
    vals = [p[1] for p in pts] + [p[2] for p in pts if p[2]] + [start]
    lo, hi = min(vals), max(vals)
    pad = (hi - lo or start * 0.01) * 0.15
    lo, hi = lo - pad, hi + pad
    ml, mr, mt, mb = 70, 100, 10, 26
    x0, x1 = pts[0][0], pts[-1][0]
    xs = (x1 - x0) or 1

    def X(ts: float) -> float:
        return ml + (ts - x0) / xs * (w - ml - mr)

    def Y(v: float) -> float:
        return mt + (hi - v) / (hi - lo) * (h - mt - mb)

    def path(i: int) -> str:
        d, pen = [], False
        for p in pts:
            if p[i] is None:
                pen = False
                continue
            d.append(f"{'L' if pen else 'M'}{X(p[0]):.1f} {Y(p[i]):.1f}")
            pen = True
        return " ".join(d)

    parts = [f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="Krypto-Konto gegen BTC halten" style="width:100%;height:auto;display:block">']
    for v in sorted({round(lo + pad, 2), round(start, 2), round(hi - pad, 2)}):
        parts.append(f'<line class=cv-grid x1={ml} x2={w - mr} y1="{Y(v):.1f}" y2="{Y(v):.1f}"/>'
                     f'<text class=cv-text x={ml - 6} y="{Y(v) + 4:.1f}" text-anchor=end>{_h(_usd(v))}</text>')
    parts.append(f'<text class=cv-text x={ml} y={h - 6}>{_h(_t(x0))}</text>'
                 f'<text class=cv-text x={w - mr} y={h - 6} text-anchor=end>{_h(_t(x1))}</text>')
    parts.append(f'<path class=cv-bench d="{path(2)}"/><path class=cv-line d="{path(1)}"/>')
    last = pts[-1]
    ys = [Y(last[1])] + ([Y(last[2])] if last[2] else [])
    if len(ys) == 2 and abs(ys[0] - ys[1]) < 14:
        mid, up = (ys[0] + ys[1]) / 2, 0 if ys[0] <= ys[1] else 1
        ys[up], ys[1 - up] = mid - 7, mid + 7
    parts.append(f'<text class=cv-end x="{X(last[0]) + 8:.1f}" y="{ys[0] + 4:.1f}">{_h(_usd(last[1]))}</text>')
    if last[2]:
        parts.append(f'<text class=cv-text x="{X(last[0]) + 8:.1f}" y="{ys[1] + 4:.1f}">BTC {_h(_usd(last[2]))}</text>')
    for p in pts[::max(1, len(pts) // 50)] + [last]:
        tip = f"{_t(p[0])}: Konto {_usd(p[1])}" + (f", BTC halten {_usd(p[2])}" if p[2] else "")
        parts.append(f'<circle class=cv-hit cx="{X(p[0]):.1f}" cy="{Y(p[1]):.1f}" r=7><title>{_h(tip)}</title></circle>')
    parts.append("</svg>")
    return "".join(parts)


def render_crypto_html(c: Optional[dict[str, Any]]) -> str:
    if not c:
        return ""
    kpis = (f"<div class=kpi><span>Konto</span><b>{_usd(c['equity'])}</b></div>"
            f"<div class=kpi><span>Gewinn seit Start</span><b class='{_cls(c['pnl'])}'>{_usd(c['pnl'], True)} · {_pct(c['pnl_pct'])}</b></div>"
            f"<div class=kpi><span>BTC halten</span><b class='{_cls(c.get('bench_pct'))}'>{_pct(c.get('bench_pct'))}</b></div>"
            f"<div class=kpi><span>Offen</span><b>{len(c['positions'])} / {c['max_open']}</b></div>"
            f"<div class=kpi><span>Trades · Treffer</span><b>{c['closed_n']} · {_rate(c.get('win_rate'))}</b></div>"
            f"<div class=kpi><span>Ø je Trade</span><b class='{_cls(c.get('avg_r'))}'>{_r(c.get('avg_r'))}</b></div>")
    rows = "".join(
        f"<tr><td>{_h(_coin(p['symbol']))}</td><td>{_h(p['setup_name'])}</td><td class=num>{_num(p['price'], '.5g')}</td>"
        f"<td class=num>{_num(p['last'], '.5g')}</td><td class='num {_cls(p['gain_pct'])}'>{_pct(p['gain_pct'])}</td>"
        f"<td class='num {_cls(p['unrealized'])}'>{_usd(p['unrealized'], True)}</td><td class=num>{_num(p['stop'], '.5g')}</td>"
        f"<td class=num>{_num(p['target'], '.5g')}</td><td>{_h((p.get('tm') or {}).get('key') or '–')}</td></tr>" for p in c["positions"])
    opened = (f"<table><tr><th>Coin</th><th>Setup</th><th class=num>Einstieg</th><th class=num>jetzt</th><th class=num>Δ</th>"
              f"<th class=num>offen</th><th class=num>Stop</th><th class=num>Ziel</th><th>Zeitmaschine</th></tr>{rows}</table>"
              if c["positions"] else "<p class=muted>keine offene Position</p>")
    rows = "".join(
        f"<tr><td>{_h(_coin(t['symbol']))}</td><td class='num {_cls(t['pnl'])}'>{_usd(t['pnl'], True)}</td>"
        f"<td class='num {_cls(t['r'])}'>{_r(t['r'])}</td><td>{_h(t['reason'])}</td><td>{_h(t['verdict'])}</td>"
        f"<td class=num>{_h(_t(t['closed_at']))}</td></tr>" for t in c["closed"][:20])
    closed = (f"<table><tr><th>Coin</th><th class=num>Ergebnis</th><th class=num>R</th><th>Grund</th><th>Zeitmaschine</th>"
              f"<th class=num>Schluss</th></tr>{rows}</table>" if c["closed"] else "<p class=muted>noch kein abgeschlossener Trade</p>")
    return (f"<section><h2>Krypto-Desk · Spielgeld gegen echte Binance-Kurse</h2><div class=kpis>{kpis}</div>"
            f"<p class=muted>{_h(c.get('status'))}</p>{crypto_svg(c)}"
            f"<p class=muted><span class=cv-key></span> Konto (was es nach Gebühren brächte) &nbsp; <span class='cv-key bench'></span> "
            f"derselbe Startbetrag in BTC</p><h2>Offen</h2>{opened}<h2 style='margin-top:12px'>Abgeschlossen</h2>{closed}</section>")


def render_crypto_md(c: Optional[dict[str, Any]]) -> list[str]:
    if not c:
        return []
    L = ["## Krypto-Desk (Spielgeld, Binance)", "",
         "| Konto | Gewinn | BTC halten | offen | Trades | Ø je Trade |", "|---:|---:|---:|---:|---:|---:|",
         f"| {_usd(c['equity'])} | {_usd(c['pnl'], True)} ({_pct(c['pnl_pct'])}) | {_pct(c.get('bench_pct'))} | "
         f"{len(c['positions'])} | {c['closed_n']} | {_r(c.get('avg_r'))} |", "", _md(c.get("status")), ""]
    for p in c["positions"]:
        L.append(f"- {_md(_coin(p['symbol']))}: {_md(p['setup_name'])}, Einstieg {_num(p['price'], '.5g')}, jetzt "
                 f"{_num(p['last'], '.5g')} ({_pct(p['gain_pct'])}), Stop {_num(p['stop'], '.5g')}, Ziel {_num(p['target'], '.5g')}")
    return L + [""]


# --- Markdown --------------------------------------------------------------
def _md(text: Any) -> str:
    return str(text if text is not None else "–").replace("|", "¦").replace("`", "'").replace("\n", " ")[:120]


def _md_link(label: Any, url: Optional[str]) -> str:
    return f"[{_md(label)}]({url})" if url else _md(label)


def render_md(m: dict[str, Any], site: Optional[str] = None) -> str:
    L = ["# Paper-Live – New Token Bot",
         "",
         f"**Spielgeld, echte Kurse.** Stand {_t(m['now'], '%d.%m.%Y %H:%M')} · läuft seit {_t(m['started'])} · "
         f"{m['polls']} Polls · letzter vor {m['last_poll_ago']:.0f} s" if m["last_poll_ago"] is not None else
         f"**Spielgeld, echte Kurse.** Stand {_t(m['now'], '%d.%m.%Y %H:%M')} · noch kein Poll",
         ""]
    if site:
        L += [f"Fenster mit Tabellen: {site}", ""]
    L += ["| Bankroll (realisiert) | Gewinn gesamt | davon offen | heute realisiert | Trades | Treffer | Kandidaten |",
          "|---:|---:|---:|---:|---:|---:|---:|",
          f"| {_usd(m['bankroll'])} | {_usd(m['total_pnl'], True)} | {_usd(m['unrealized'], True)} | {_usd(m['today'], True)} | "
          f"{m['closed_n']} | {_hit(m)} | {m['candidates_n']} |", ""]
    L += render_crypto_md(m.get("crypto"))
    L += [f"## Offene Positionen ({len(m['open'])})", ""]
    if m["open"]:
        L += ["| Token | Einstieg | jetzt | Δ | offen $ | Alter |", "|---|---:|---:|---:|---:|---:|"]
        for p in m["open"]:
            L.append(f"| {_md_link(p['symbol'], p['url'])} | {_num(p['entry_price'], '.4g')} | {_num(p.get('price'), '.4g')} | "
                     f"{_pct(p.get('gain_pct'))} | {_usd(p.get('unrealized'), True)} | {p.get('age_min', 0):.0f} min |")
    else:
        L.append("keine")
    L += ["", f"## Geschlossene Trades (letzte {len(m['closed'])})", ""]
    if m["closed"]:
        L += ["| Token | Ergebnis | % | Grund | Dauer | Schluss |", "|---|---:|---:|---|---:|---:|"]
        for p in m["closed"]:
            L.append(f"| {_md_link(p['symbol'], p['url'])} | {_usd(p['realized_usd'], True)} | {_pct(p['pct'])} | "
                     f"{_md(p.get('exit_reason'))} | {(p['minutes'] or 0):.0f} min | {_t(p.get('closed_at'), '%H:%M')} |")
    else:
        L.append("noch keine")
    if m["edge"]:
        L += ["", "## Edge – was wurde aus den Kandidaten?", "", "| Entscheidung | nach | n | Ø Änderung | Anteil im Plus |", "|---|---:|---:|---:|---:|"]
        for e in m["edge"]:
            L.append(f"| {e['decision']} | {e['horizon_min']} min | {e['n']} | {_pct(e['avg_change_pct'])} | {e['win_rate'] * 100:.0f} % |")
    if m["reasons"]:
        L += ["", "## Warum fällt was durch", "", "| Grund | Anteil |", "|---|---:|"]
        for r in m["reasons"]:
            L.append(f"| {_md(r['label'])} | {r['share'] * 100:.0f} % |")
    L += ["", "## Kandidaten (zuletzt kaufbar/beobachtet)", ""]
    if m["interesting"]:
        L += ["| Zeit | Token | Urteil | Score | Liquidität | Vol 5m | Gründe |", "|---|---|---|---:|---:|---:|---|"]
        for c in m["interesting"]:
            sn = c.get("snapshot") or {}
            L.append(f"| {_t(c['seen_at'], '%H:%M')} | {_md_link(c['symbol'], token_url(c['chain'], c['token'], sn.get('dex'), sn.get('url')))} | "
                     f"{c['decision']} | {_num(c.get('score') or None, '.1f')} | {_liq(sn)} | {_usd(sn.get('volume_m5'))} | "
                     f"{_md('; '.join((c.get('reasons') or [])[:2]))} |")
    else:
        L.append("noch keine")
    L += ["", "## Protokoll", ""]
    L += [f"- {_t(e['at'], '%H:%M:%S')} {_md(e['level'])}: {_md(e['message'])}" for e in m["events"]] or ["leer"]
    L += ["", "_Nur Ansicht. Der Bot handelt mit Spielgeld gegen echte Kurse (DexScreener, GeckoTerminal, pump.fun, Solana-RPC). Rohdaten: state.json_", ""]
    return "\n".join(L)


# --- HTML ------------------------------------------------------------------
def _h(text: Any) -> str:
    return html.escape(str(text if text is not None else "–"))


def _a(label: Any, url: Optional[str]) -> str:
    return f'<a href="{html.escape(url)}" target="_blank" rel="noopener noreferrer">{_h(label)}</a>' if url else _h(label)


CSS = """
:root { --bg:#f6f7f9; --card:#fff; --ink:#15181d; --muted:#5d6673; --line:#e3e6eb; --pos:#0a7a43; --neg:#c0352b; --accent:#2457d6; }
@media (prefers-color-scheme: dark) { :root { --bg:#0f1216; --card:#171b21; --ink:#e7eaee; --muted:#9aa4b2; --line:#262c35; --pos:#3ccf7f; --neg:#ff6b5e; --accent:#7aa2ff; } }
* { box-sizing:border-box; } body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; }
main { max-width:1100px; margin:0 auto; padding:16px; } h1 { font-size:20px; margin:0 0 4px; } h2 { font-size:13px; text-transform:uppercase; letter-spacing:.06em; color:var(--muted); margin:0 0 10px; }
.sub { color:var(--muted); margin-bottom:16px; } .kpis { display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:10px; margin-bottom:16px; }
.kpi, section { background:var(--card); border:1px solid var(--line); border-radius:12px; padding:12px 14px; } .kpi span { display:block; color:var(--muted); font-size:12px; } .kpi b { font-size:20px; font-variant-numeric:tabular-nums; }
section { margin-bottom:14px; overflow-x:auto; } table { width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums; } th, td { text-align:left; padding:6px 8px; border-bottom:1px solid var(--line); white-space:nowrap; }
th { color:var(--muted); font-weight:600; font-size:12px; } td.num, th.num { text-align:right; } td.why { white-space:normal; color:var(--muted); min-width:220px; }
.pos { color:var(--pos); } .neg { color:var(--neg); } a { color:var(--accent); text-decoration:none; } .muted { color:var(--muted); } .pill { display:inline-block; padding:1px 8px; border-radius:99px; border:1px solid var(--line); font-size:12px; }
.bar { height:6px; background:var(--accent); border-radius:3px; } ul { margin:0; padding-left:18px; } li { margin:2px 0; }
.pre { margin:0; font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; white-space:pre; overflow-x:auto; }
.cv-line { fill:none; stroke:var(--accent); stroke-width:2; stroke-linejoin:round; } .cv-bench { fill:none; stroke:var(--muted); stroke-width:2; stroke-dasharray:5 4; }
.cv-grid { stroke:var(--line); } .cv-text { fill:var(--muted); font-size:12px; } .cv-end { fill:var(--ink); font-size:12px; font-weight:600; } .cv-hit { fill:transparent; }
.cv-key { display:inline-block; width:14px; border-top:2px solid var(--accent); vertical-align:middle; } .cv-key.bench { border-top:2px dashed var(--muted); }
"""


def render_html(m: dict[str, Any], extras: Optional[dict[str, str]] = None) -> str:
    total_cls = _cls(m["total_pnl"])
    hit = _hit(m)
    live = (f"letzter Poll vor {m['last_poll_ago']:.0f} s" if m["last_poll_ago"] is not None else "noch kein Poll")
    parts = [f"""<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="refresh" content="60"><title>Paper-Live · New Token Bot</title><style>{CSS}</style></head><body><main>
<h1>Paper-Live · New Token Bot</h1>
<div class="sub"><span class="pill">Spielgeld · echte Kurse</span> Stand {_h(_t(m['now'], '%d.%m.%Y %H:%M:%S'))} · läuft seit {_h(_t(m['started']))} · {m['polls']} Polls · {_h(live)}{' · <b>pausiert</b>' if m['paused'] else ''} · lädt jede Minute neu</div>
<div class="kpis">
<div class="kpi"><span>Bankroll (realisiert)</span><b>{_usd(m['bankroll'])}</b></div>
<div class="kpi"><span>Gewinn gesamt</span><b class="{total_cls}">{_usd(m['total_pnl'], True)}</b></div>
<div class="kpi"><span>davon offen</span><b class="{_cls(m['unrealized'])}">{_usd(m['unrealized'], True)}</b></div>
<div class="kpi"><span>heute realisiert</span><b class="{_cls(m['today'])}">{_usd(m['today'], True)}</b></div>
<div class="kpi"><span>Trades · Treffer</span><b>{m['closed_n']} · {hit}</b></div>
<div class="kpi"><span>Kandidaten bewertet</span><b>{m['candidates_n']}</b></div>
</div>"""]
    parts.append(render_crypto_html(m.get("crypto")))
    rows = "".join(
        f"<tr><td>{_a(p['symbol'], p['url'])}</td><td class=num>{_num(p['entry_price'], '.4g')}</td><td class=num>{_num(p.get('price'), '.4g')}</td>"
        f"<td class='num {_cls(p.get('gain_pct'))}'>{_pct(p.get('gain_pct'))}</td><td class='num {_cls(p.get('unrealized'))}'>{_usd(p.get('unrealized'), True)}</td>"
        f"<td class=num>{_usd(p['size_usd'] * p['remaining_frac'])}</td><td class=num>{p.get('age_min', 0):.0f} min</td></tr>" for p in m["open"])
    parts.append(f"<section><h2>Offene Positionen ({len(m['open'])})</h2>" + (
        f"<table><tr><th>Token</th><th class=num>Einstieg</th><th class=num>jetzt</th><th class=num>Δ</th><th class=num>offen</th><th class=num>Einsatz</th><th class=num>Alter</th></tr>{rows}</table>"
        if m["open"] else "<p class=muted>keine – der Bot wartet auf einen Token, der alle Filter besteht</p>") + "</section>")
    rows = "".join(
        f"<tr><td>{_a(p['symbol'], p['url'])}</td><td class='num {_cls(p['realized_usd'])}'>{_usd(p['realized_usd'], True)}</td>"
        f"<td class='num {_cls(p['pct'])}'>{_pct(p['pct'])}</td><td>{_h(p.get('exit_reason'))}</td><td class=num>{(p['minutes'] or 0):.0f} min</td>"
        f"<td class=num>{_h(_t(p.get('closed_at'), '%H:%M'))}</td></tr>" for p in m["closed"])
    parts.append("<section><h2>Geschlossene Trades</h2>" + (
        f"<table><tr><th>Token</th><th class=num>Ergebnis</th><th class=num>%</th><th>Grund</th><th class=num>Dauer</th><th class=num>Schluss</th></tr>{rows}</table>"
        if m["closed"] else "<p class=muted>noch keine</p>") + "</section>")
    if m["edge"]:
        rows = "".join(f"<tr><td>{_h(e['decision'])}</td><td class=num>{e['horizon_min']} min</td><td class=num>{e['n']}</td>"
                       f"<td class='num {_cls(e['avg_change_pct'])}'>{_pct(e['avg_change_pct'])}</td><td class=num>{e['win_rate'] * 100:.0f} %</td></tr>" for e in m["edge"])
        parts.append("<section><h2>Edge – was wurde aus den Kandidaten?</h2><p class=muted>Kursänderung nach 5/15/60 Minuten, getrennt nach dem Urteil des Bots. "
                     "Bringt „buy“ mehr als „skip“, haben die Regeln einen Vorteil.</p>"
                     f"<table><tr><th>Urteil</th><th class=num>nach</th><th class=num>n</th><th class=num>Ø Änderung</th><th class=num>im Plus</th></tr>{rows}</table></section>")
    if m["reasons"]:
        rows = "".join(f"<tr><td>{_h(r['label'])}</td><td class=num>{r['share'] * 100:.0f} %</td>"
                       f"<td style='width:40%'><div class=bar style='width:{max(2, r['share'] * 100):.0f}%'></div></td></tr>" for r in m["reasons"])
        parts.append(f"<section><h2>Warum fällt was durch</h2><table>{rows}</table></section>")
    rows = "".join(
        f"<tr><td>{_h(_t(c['seen_at'], '%H:%M'))}</td><td>{_a(c['symbol'], token_url(c['chain'], c['token'], (c.get('snapshot') or {}).get('dex'), (c.get('snapshot') or {}).get('url')))}</td>"
        f"<td>{_h(c['decision'])}</td><td class=num>{_num(c.get('score') or None, '.1f')}</td><td class=num>{_liq(c.get('snapshot') or {})}</td>"
        f"<td class=num>{_usd((c.get('snapshot') or {}).get('volume_m5'))}</td><td class=why>{_h('; '.join((c.get('reasons') or [])[:3]))}</td></tr>"
        for c in m["recent"])
    parts.append(f"<section><h2>Zuletzt bewertet</h2><table><tr><th>Zeit</th><th>Token</th><th>Urteil</th><th class=num>Score</th><th class=num>Liquidität</th><th class=num>Vol 5m</th><th>Gründe</th></tr>{rows}</table></section>")
    src = "".join(f"<li>{_h(s['label'])}: {'liefert' if s.get('ok') else 'Pause (Rate-Limit)' if s.get('throttled') else 'gestört' if s.get('ok') is False else 'wartet'}"
                  f"{(' – ' + _h(s.get('error'))) if s.get('error') else ''}</li>" for s in m["sources"] if s.get("enabled"))
    ev = "".join(f"<li><span class=muted>{_h(_t(e['at'], '%H:%M:%S'))}</span> {_h(e['message'])}</li>" for e in m["events"])
    for title, text in (extras or {}).items():           # the run's audit and backtest, as the report shows them
        parts.append(f"<section><h2>{_h(title)}</h2><pre class=pre>{_h(text)}</pre></section>")
    parts.append(f"<section><h2>Quellen</h2><ul>{src}</ul></section><section><h2>Protokoll</h2><ul>{ev}</ul></section>")
    parts.append("<p class=muted>Nur Ansicht. Der Bot handelt mit Spielgeld gegen echte Kurse; gesteuert wird er nicht von hier. "
                 "Rohdaten: <a href='state.json'>state.json</a> · Text: <a href='REPORT.md'>REPORT.md</a></p></main></body></html>")
    return "\n".join(parts)


def write(state: dict[str, Any], out: Path, site: Optional[str] = None, now: Optional[float] = None) -> None:
    out.mkdir(parents=True, exist_ok=True)
    m = model(state, now or time.time())
    extras = {title: (out / name).read_text(encoding="utf-8").strip() for title, name in
              (("Laufzeit-Prüfung", "audit.txt"), ("Backtest auf den Kursverläufen", "backtest.txt")) if (out / name).is_file()}
    (out / "index.html").write_text(render_html(m, extras), encoding="utf-8")
    (out / "REPORT.md").write_text(render_md(m, site), encoding="utf-8")
    (out / "state.json").write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2
    write(fetch_state(argv[1]), Path(argv[2]), argv[3] if len(argv) > 3 else None)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
