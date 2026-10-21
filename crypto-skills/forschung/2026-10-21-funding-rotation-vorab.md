# Vorab festgelegt: Funding-Rotation (21.10.2026, ~20:35 UTC, vor jeder Rechnung)

Frage: Bringt Cash-and-Carry mehr, wenn man jede Woche die Coins mit dem höchsten
Funding nimmt statt immer BTC – nach allen Wechselkosten, auf Daten, die beim
Aussuchen nicht benutzt wurden?

Liste (fest, heute gewählt, tote Coins bleiben drin): BTC, ETH, BNB, XRP, ADA, SOL,
DOGE, LTC, LINK, DOT, AVAX, TRX, ETC, BCH, XLM, ATOM, FIL, NEAR, MATIC, UNI
(USDT-M-Perpetual auf Binance, Funding von data.binance.vision).

Regel: jeden Montag 00:00 UTC die k Coins mit dem höchsten Mittel der Funding-Raten der
letzten 7 Tage, nur wenn dieses Mittel > 0; zu gleichen Teilen; sonst nichts.
Je Coin: Spot long und Perp short mit gleichem Nennwert; die Hälfte des Kapitals ist
Spot, die andere Hälfte Sicherheit (Ertrag = Funding auf den halben Kapitalbetrag).
Hat ein Coin in einer Woche kein Funding mehr (delistet), ist er draußen.
Varianten: k ∈ {1, 3, 5}.

Kosten: jeder Wechsel eines Coins kostet beide Beine raus und rein – Spot 0,10 % + 0,05 %,
Perp 0,05 % + 0,05 % je Seite – auf den gewechselten Nennwert; Ein- und Ausstieg am
Anfang und Ende ebenso.

Auswahl: das k mit dem höchsten Ertrag nach Kosten 2020-01 bis 2022-12.
Prüfung: dasselbe k 2023-01 bis heute.

Erfolg (beides): ab 2023 jedes volle Jahr nach Kosten im Plus UND zusammen mehr als
"immer nur BTC" (Cash-and-Carry ohne Wechsel) im selben Zeitraum.

Nicht abgebildet (wird genannt): Abstand Perp/Spot beim Wechsel, Liquidation des Shorts
bei einem starken Anstieg (bei kleinen Coins realer als bei BTC), Börsenrisiko.
