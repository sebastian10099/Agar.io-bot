"""Cash-and-Carry wie in 2026-10-21-funding-vorab.md festgelegt.

  python3 carry.py ORDNER_MIT_ZIPS [ergebnis.json]
Die Zips: https://data.binance.vision/data/futures/um/monthly/fundingRate/BTCUSDT/BTCUSDT-fundingRate-JJJJ-MM.zip
"""
import csv
import io
import json
import sys
import zipfile
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

DL = Path(sys.argv[1])
CAP = 1000.0
SHORT = CAP / 2                       # Nennwert des Shorts = Spot-Hälfte
ROUND_TRIP = 2 * ((0.10 + 0.05) + (0.05 + 0.05)) / 100   # Ein- und Ausstieg, beide Beine
COST_PER_YEAR = SHORT * ROUND_TRIP    # auf den jeweiligen Nennwert je Bein

out = {}
for sym in ("BTCUSDT", "ETHUSDT"):
    rates = []
    for f in sorted(DL.glob(f"{sym}-fundingRate-*.zip")):
        with zipfile.ZipFile(f) as z:
            for name in z.namelist():
                text = z.read(name).decode("utf-8")
                for row in csv.reader(io.StringIO(text)):
                    if not row or not row[0].isdigit():
                        continue
                    rates.append((int(row[0]) // 1000, float(row[2])))
    rates.sort()
    monthly = defaultdict(float)
    yearly = defaultdict(float)
    for t, r in rates:
        d = datetime.fromtimestamp(t, timezone.utc)
        monthly[(d.year, d.month)] += SHORT * r
        yearly[d.year] += SHORT * r
    years = {}
    for y in sorted(yearly):
        months = [v for (yy, _), v in monthly.items() if yy == y]
        net = yearly[y] - COST_PER_YEAR
        years[y] = {"months": len(months), "funding": yearly[y], "net": net, "pct": net / CAP * 100,
                    "neg_months": sum(1 for v in months if v < 0), "worst_month": min(months)}
    first, last = rates[0][0], rates[-1][0]
    out[sym] = {"from": first, "to": last, "years": years}
    print(f"\n{sym}: {datetime.fromtimestamp(first, timezone.utc):%Y-%m} bis {datetime.fromtimestamp(last, timezone.utc):%Y-%m}, "
          f"{len(rates)} Funding-Zahlungen")
    print(f"  {'Jahr':<6}{'Monate':>7}{'Funding':>10}{'nach Kosten':>13}{'aufs Kapital':>14}{'neg. Monate':>13}{'schlechtester Monat':>21}")
    for y, v in years.items():
        print(f"  {y:<6}{v['months']:>7}{v['funding']:>9.2f}${v['net']:>12.2f}${v['pct']:>12.1f} %{v['neg_months']:>13}{v['worst_month']:>20.2f}$")
    pre = sum(v["net"] for y, v in years.items() if y <= 2022)
    post = sum(v["net"] for y, v in years.items() if y >= 2023)
    full_post = [y for y, v in years.items() if y >= 2023 and v["months"] == 12]
    ok = all(years[y]["net"] > 0 for y in full_post) and post > 0
    print(f"  bis 2022 zusammen {pre:+.2f} $ · ab 2023 zusammen {post:+.2f} $ "
          f"({post / CAP * 100:+.1f} % aufs Kapital) · volle Jahre ab 2023 alle im Plus: {'ja' if ok else 'nein'}"
          f" => {'BESTANDEN' if ok else 'durchgefallen'}")
    out[sym]["passed"] = ok
if len(sys.argv) > 2:
    json.dump(out, open(sys.argv[2], "w"))
