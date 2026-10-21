# Ergebnisse der vorab festgelegten Prüfungen (21.10.2026)

Rechnung: `trend.py` und `carry.py` (Binance-Tageskerzen bzw. Binance-Funding-Historie),
Kosten wie vorab festgelegt. Ausgesucht wurde nur auf 2018–2022, geprüft auf 2023–heute.

## 1. Trendfolge und Rotation – keine Regel bestanden

| Out-of-sample 2023–heute (1.000 $ Start) | Ende | CAGR | Sharpe | größter Rückgang | Urteil |
|---|---:|---:|---:|---:|---|
| BTC halten (Vergleich) | 4.989 $ | +52,6 % | 1,14 | 53 % | – |
| A: ETH > SMA20 (in-sample beste) | 1.473 $ | +10,7 % | 0,45 | 48 % | durchgefallen (Sharpe) |
| B: ETH SMA10 > SMA50 (in-sample beste) | 2.684 $ | +29,6 % | 0,81 | 46 % | durchgefallen (Sharpe) |
| C: Rotation Top 2 (in-sample beste) | 502 $ | −16,6 % | 0,21 | 84 % | durchgefallen |

Die Trendregeln verdienen Geld, aber weniger als einfaches Halten von BTC und mit
schlechterer Rendite pro Risiko. Nachträglich wird keine andere Variante ausgesucht.

## 2. Cash-and-Carry mit Funding – bestanden, aber klein

Hälfte des Kapitals in Spot, gleich großer Short im Perpetual (Hebel 1), Funding
eingesammelt, Ein- und Ausstieg jedes Jahr neu bezahlt.

| Jahr | BTC aufs Kapital | ETH aufs Kapital |
|---|---:|---:|
| 2020 | +8,4 % | +13,5 % |
| 2021 | +15,1 % | +18,5 % |
| 2022 | +1,8 % | +0,1 % |
| 2023 | +3,7 % | +3,9 % |
| 2024 | +5,7 % | +6,2 % |
| 2025 | +2,3 % | +2,2 % |
| 2026 (9 Monate) | +0,8 % | +0,5 % |

Ab 2023 war jedes volle Jahr im Plus (seit 2023 zusammen +12,6 % bzw. +12,8 %).
Der Ertrag kommt vom Funding, nicht vom Kurs – er schrumpft aber: 2026 bisher unter 1 %.
Nicht abgebildet: Pleite der Börse, Abstand Perp/Spot beim Ausstieg, Zulässigkeit von
Futures für Privatkunden in Deutschland.

Folge: Cash-and-Carry läuft ab jetzt als vorab festgelegte Probe mit Spielgeld
vorwärts im Krypto-Desk (Funding live von OKX, BTC-USDT-SWAP).
