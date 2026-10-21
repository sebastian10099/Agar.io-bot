"""Rechnet die in 2026-10-21-trend-vorab.md festgelegten Regeln. Erst in-sample aussuchen, dann out-of-sample prüfen."""
import datetime
import json
import math
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "trading-bot"))
from bot import crypto_scan as scan  # noqa: E402

DAY = 86400
COST = (scan.FEE_PCT + scan.SLIP_PCT) / 100        # je Seite
LIST = ["BTC", "ETH", "XRP", "BNB", "ADA", "LTC", "EOS", "TRX", "XLM", "NEO", "ETC", "LINK", "IOTA", "DASH",
        "XMR", "ZEC", "QTUM", "ONT", "VET", "ICX"]


def ts(y, m, d):
    return int(datetime.datetime(y, m, d, tzinfo=datetime.timezone.utc).timestamp())


IS = (ts(2018, 1, 1), ts(2023, 1, 1))
OOS = (ts(2023, 1, 1), None)


def load(cache="data.json"):
    try:
        return {k: {int(t): v for t, v in d.items()} for k, d in json.load(open(cache)).items()}
    except (OSError, ValueError):
        pass
    feed = scan.Feed()
    now_ms = int(time.time() * 1000)
    out = {}
    for base in LIST:
        try:
            rows = scan.closed(feed.klines(base + "USDT", "1d", start_ms=ts(2017, 1, 1) * 1000), now_ms)
        except RuntimeError as e:
            print(f"  {base}: {e}")
            continue
        out[base] = {int(k[0]) // 1000: [float(k[1]), float(k[2]), float(k[3]), float(k[4])] for k in rows}
        print(f"  {base}: {len(rows)} Tage ab {scan.utc_text(rows[0][0] // 1000)[:10] if rows else '-'}"
              f" bis {scan.utc_text(rows[-1][0] // 1000)[:10] if rows else '-'}")
    json.dump(out, open(cache, "w"))
    return out


def sma_map(series, days, n):
    """SMA of closes ending at each day (None until n days exist, or across a gap)."""
    out, window = {}, []
    for t in days:
        if t not in series:
            window = []
            continue
        window.append(series[t][3])
        if len(window) > n:
            window.pop(0)
        out[t] = sum(window) / n if len(window) == n else None
    return out


def simulate(data, days, start, end, weights_at):
    """weights_at(t) -> {coin: w} decided on day t's close, traded at t+1's open."""
    days = [t for t in days if t >= start and (end is None or t < end)]
    cash, units, eq = 1000.0, {}, []
    target = {}
    for i, t in enumerate(days):
        # trade at today's open towards yesterday's decision
        if i > 0:
            # a coin without a price today: sell at its last close (delisted/data gap)
            for c in list(units):
                if t not in data[c]:
                    last = max(k for k in data[c] if k < t)
                    cash += units.pop(c) * data[c][last][3] * (1 - COST)
            opens = {c: data[c][t][0] for c in set(units) | set(target) if t in data[c]}
            equity = cash + sum(u * opens[c] for c, u in units.items())
            for c in set(units) | set(target):
                if c not in opens:
                    continue
                want = target.get(c, 0.0) * equity / opens[c]
                diff = want - units.get(c, 0.0)
                if abs(diff) * opens[c] < 1e-6:
                    continue
                cash -= diff * opens[c] + abs(diff) * opens[c] * COST
                units[c] = want
                if units[c] <= 1e-12:
                    units.pop(c)
        closes = {c: data[c][t][3] for c in units if t in data[c]}
        eq.append((t, cash + sum(u * closes.get(c, 0.0) for c, u in units.items())))
        target = weights_at(t)
    return eq


def stats(eq):
    vals = [v for _, v in eq]
    rets = [vals[i] / vals[i - 1] - 1 for i in range(1, len(vals)) if vals[i - 1] > 0]
    m = sum(rets) / len(rets)
    sd = math.sqrt(sum((r - m) ** 2 for r in rets) / (len(rets) - 1))
    years = (eq[-1][0] - eq[0][0]) / (365 * DAY)
    peak, dd = 0.0, 0.0
    for v in vals:
        peak = max(peak, v)
        dd = max(dd, 1 - v / peak)
    return {"end": vals[-1], "cagr": (vals[-1] / vals[0]) ** (1 / years) - 1 if years > 0 else 0.0,
            "sharpe": m / sd * math.sqrt(365) if sd > 0 else 0.0, "max_dd": dd}


def main():
    data = load()
    days = sorted(set().union(*[set(d) for d in data.values()]))
    sma = {}

    def S(c, n):
        if (c, n) not in sma:
            sma[(c, n)] = sma_map(data[c], days, n)
        return sma[(c, n)]

    variants = {}
    for c in ("BTC", "ETH"):
        for n in (20, 50, 100, 200):
            variants[f"A {c} > SMA{n}"] = ("A", lambda c=c, n=n: lambda t: {c: 1.0} if t in data[c] and S(c, n).get(t) and data[c][t][3] > S(c, n)[t] else {})
        for f, s in ((10, 50), (20, 100), (50, 200)):
            variants[f"B {c} SMA{f}>SMA{s}"] = ("B", lambda c=c, f=f, s=s: lambda t: {c: 1.0} if S(c, f).get(t) and S(c, s).get(t) and S(c, f)[t] > S(c, s)[t] else {})
    def rotation(k):
        held = {"w": {}}

        def rot(t):
            if datetime.datetime.fromtimestamp(t, datetime.timezone.utc).weekday() != 0:
                return {c: w for c, w in held["w"].items() if t in data[c]}
            cands = []
            for c in data:
                if t not in data[c] or t - 28 * DAY not in data[c] or not S(c, 50).get(t):
                    continue
                if data[c][t][3] > S(c, 50)[t]:
                    cands.append((data[c][t][3] / data[c][t - 28 * DAY][3] - 1, c))
            top = [c for _, c in sorted(cands, reverse=True)[:k]]
            held["w"] = {c: 1.0 / len(top) for c in top} if top else {}
            return dict(held["w"])
        return rot
    for k in (1, 2, 3):
        variants[f"C Rotation Top {k}"] = ("C", lambda k=k: rotation(k))

    hold = lambda t: {"BTC": 1.0}   # noqa: E731
    rows = {}
    for name, (fam, fn) in variants.items():
        rows[name] = (fam, stats(simulate(data, days, IS[0], IS[1], fn())))
    base_is = stats(simulate(data, days, IS[0], IS[1], hold))
    print("\nIN-SAMPLE 2018-2022 (nur zum Aussuchen)")
    print(f"  {'BTC halten':<24} Ende {base_is['end']:8.0f} $  CAGR {base_is['cagr']:+6.1%}  Sharpe {base_is['sharpe']:5.2f}  Rückgang {base_is['max_dd']:.0%}")
    for name, (fam, st) in rows.items():
        print(f"  {name:<24} Ende {st['end']:8.0f} $  CAGR {st['cagr']:+6.1%}  Sharpe {st['sharpe']:5.2f}  Rückgang {st['max_dd']:.0%}")
    chosen = {}
    for name, (fam, st) in rows.items():
        if fam not in chosen or st["sharpe"] > rows[chosen[fam]][1]["sharpe"]:
            chosen[fam] = name
    print("\nAusgewählt (beste Sharpe in-sample je Familie):", ", ".join(chosen[f] for f in sorted(chosen)))

    base = stats(simulate(data, days, OOS[0], OOS[1], hold))
    print(f"\nOUT-OF-SAMPLE 2023 bis heute (die eigentliche Prüfung)")
    print(f"  {'BTC halten':<24} Ende {base['end']:8.0f} $  CAGR {base['cagr']:+6.1%}  Sharpe {base['sharpe']:5.2f}  Rückgang {base['max_dd']:.0%}")
    result = {"base": base, "chosen": {}}
    for fam in sorted(chosen):
        name = chosen[fam]
        eq = simulate(data, days, OOS[0], OOS[1], variants[name][1]())
        st = stats(eq)
        ok = [st["end"] > 1000, st["sharpe"] >= base["sharpe"], st["max_dd"] < base["max_dd"]]
        print(f"  {name:<24} Ende {st['end']:8.0f} $  CAGR {st['cagr']:+6.1%}  Sharpe {st['sharpe']:5.2f}  Rückgang {st['max_dd']:.0%}"
              f"  -> Gewinn {'ja' if ok[0] else 'nein'}, Sharpe {'ja' if ok[1] else 'nein'}, Rückgang {'ja' if ok[2] else 'nein'}"
              f"  => {'BESTANDEN' if all(ok) else 'durchgefallen'}")
        result["chosen"][name] = {"stats": st, "passed": all(ok), "curve": eq}
    result["base_curve"] = simulate(data, days, OOS[0], OOS[1], hold)
    json.dump(result, open("result.json", "w"))


if __name__ == "__main__":
    main()
