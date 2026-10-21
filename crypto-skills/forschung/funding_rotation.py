"""Funding-Rotation wie in 2026-10-21-funding-rotation-vorab.md festgelegt.

  python3 funding_rotation.py ORDNER_MIT_ZIPS
"""
import csv
import io
import sys
import zipfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

DL = Path(sys.argv[1])
LIST = ["BTC", "ETH", "BNB", "XRP", "ADA", "SOL", "DOGE", "LTC", "LINK", "DOT", "AVAX", "TRX", "ETC", "BCH", "XLM",
        "ATOM", "FIL", "NEAR", "MATIC", "UNI"]
LEG_SIDE = ((0.10 + 0.05) + (0.05 + 0.05)) / 100     # beide Beine, eine Richtung, auf den Nennwert
WEEK = timedelta(days=7)
IS_END = datetime(2023, 1, 1, tzinfo=timezone.utc)


def load():
    rates = {}
    for c in LIST:
        rows = []
        for f in sorted(DL.glob(f"{c}USDT-fundingRate-*.zip")):
            with zipfile.ZipFile(f) as z:
                for name in z.namelist():
                    for row in csv.reader(io.StringIO(z.read(name).decode("utf-8"))):
                        if row and row[0].isdigit():
                            rows.append((datetime.fromtimestamp(int(row[0]) / 1000, timezone.utc), float(row[2])))
        rates[c] = sorted(rows)
    return rates


def window(rows, a, b):
    return [r for t, r in rows if a <= t < b]


def run(rates, k, start, end, fixed=None):
    """Weekly loop from start (a Monday) to end; returns {year: net $} and the final equity, from 1.000 $."""
    equity, held, yearly = 1000.0, {}, defaultdict(float)
    w = start
    while w + WEEK <= end:
        if fixed:
            pick = [fixed] if window(rates[fixed], w, w + WEEK) else []
        else:
            score = []
            for c, rows in rates.items():
                past = window(rows, w - WEEK, w)
                if len(past) >= 15 and sum(past) / len(past) > 0:
                    score.append((sum(past) / len(past), c))
            pick = [c for _, c in sorted(score, reverse=True)[:k]]
        notional = equity / 2
        new = {c: notional / len(pick) for c in pick}
        cost = sum(abs(new.get(c, 0.0) - held.get(c, 0.0)) for c in set(new) | set(held)) * LEG_SIDE
        income = sum(n * sum(window(rates[c], w, w + WEEK)) for c, n in new.items())
        equity += income - cost
        yearly[w.year] += income - cost
        held = new
        w += WEEK
    exit_cost = sum(held.values()) * LEG_SIDE
    equity -= exit_cost
    yearly[(w - WEEK).year] -= exit_cost
    return dict(yearly), equity


def main():
    rates = load()
    first = datetime(2020, 1, 6, tzinfo=timezone.utc)                  # a Monday
    oos_start = datetime(2023, 1, 2, tzinfo=timezone.utc)              # the first Monday of 2023
    last = max(t for rows in rates.values() for t, _ in rows)
    print("In-sample 2020–2022 (nur zum Aussuchen), Start 1.000 $:")
    best = None
    for k in (1, 3, 5):
        _, eq = run(rates, k, first, IS_END)
        print(f"  Top {k}: Ende {eq:8.2f} $  ({eq / 10 - 100:+.1f} %)")
        if best is None or eq > best[1]:
            best = (k, eq)
    _, eq = run(rates, 1, first, IS_END, fixed="BTC")
    print(f"  nur BTC: Ende {eq:8.2f} $  ({eq / 10 - 100:+.1f} %)")
    k = best[0]
    print(f"\nAusgewählt: Top {k}\n\nOut-of-sample 2023 bis {last:%Y-%m-%d} (die eigentliche Prüfung), Start 1.000 $:")
    yearly, eq = run(rates, k, oos_start, last)
    base_yearly, base_eq = run(rates, 1, oos_start, last, fixed="BTC")
    print(f"  {'Jahr':<6}{'Top ' + str(k):>12}{'nur BTC':>12}")
    for y in sorted(yearly):
        print(f"  {y:<6}{yearly[y] / 10:>+11.1f}%{base_yearly.get(y, 0) / 10:>+11.1f}%")
    full = [y for y in yearly if y < last.year]
    ok = all(yearly[y] > 0 for y in full) and eq > base_eq
    print(f"  zusammen: Top {k} {eq:.2f} $ ({eq / 10 - 100:+.1f} %), nur BTC {base_eq:.2f} $ ({base_eq / 10 - 100:+.1f} %)")
    print(f"  volle Jahre alle im Plus: {'ja' if all(yearly[y] > 0 for y in full) else 'nein'}, mehr als nur BTC: "
          f"{'ja' if eq > base_eq else 'nein'} => {'BESTANDEN' if ok else 'durchgefallen'}")


if __name__ == "__main__":
    main()
