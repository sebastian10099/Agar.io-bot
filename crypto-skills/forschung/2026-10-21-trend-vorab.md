# Vorab festgelegt (21.10.2026, ~20:20 UTC, bevor irgendein Ergebnis berechnet wurde)

Frage: Gibt es eine einfache Krypto-Regel, die nach Kosten Geld verdient und dabei
besser ist als "BTC halten" (Rendite pro Risiko) – auf Daten, die beim Aussuchen
nicht benutzt wurden?

Daten: Binance-Tageskerzen, USDT-Paare. Signal auf dem Schluss von Tag t, Handel zur
Eröffnung von Tag t+1. Kosten: 0,10 % Gebühr + 0,05 % Schlupf je Seite. Nicht
investiertes Geld liegt als USDT ohne Zins.

Aussuchen (in-sample):  2018-01-01 bis 2022-12-31
Prüfen (out-of-sample): 2023-01-01 bis heute – wird erst angeschaut, wenn je Familie
die Regel feststeht.

Familien und Varianten (alle werden gerechnet, keine weiteren nachgeschoben):
A  Trend, ein Coin: halten, wenn Schluss > SMA(N), sonst Cash.
   Coin ∈ {BTC, ETH}, N ∈ {20, 50, 100, 200}                       -> 8 Varianten
B  Zwei Schnitte: halten, wenn SMA(f) > SMA(s), sonst Cash.
   Coin ∈ {BTC, ETH}, (f, s) ∈ {(10,50), (20,100), (50,200)}      -> 6 Varianten
C  Rotation: feste Liste der großen Coins von Anfang 2018 (BTC, ETH, XRP, BNB, ADA,
   LTC, EOS, TRX, XLM, NEO, ETC, LINK, IOTA, DASH, XMR, ZEC, QTUM, ONT, VET, ICX –
   was Binance davon hat; tote Coins bleiben drin). Jeden Montag: die k Coins mit
   der höchsten 28-Tage-Rendite, die über ihrem SMA(50) stehen, zu gleichen Teilen;
   keiner -> Cash. k ∈ {1, 2, 3}                                    -> 3 Varianten

Auswahl: je Familie die Variante mit der besten Sharpe-Zahl (täglich, annualisiert
mit 365) in-sample. Nur diese drei werden out-of-sample geprüft.

Erfolg (alle drei müssen out-of-sample gelten):
1. Endwert > Startwert nach Kosten (Geld verdient),
2. Sharpe ≥ Sharpe von "BTC halten" im selben Zeitraum,
3. größter Rückgang kleiner als bei "BTC halten".

Besteht eine Regel, läuft sie als vorab festgelegte Probe mit Spielgeld im
Krypto-Desk vorwärts weiter. Besteht keine, wird das so berichtet.
