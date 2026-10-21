# Vorab festgelegt: Cash-and-Carry mit Funding (21.10.2026, ~20:35 UTC, vor jeder Rechnung)

Frage: Hätte "BTC bzw. ETH kaufen und gleich viel im Perpetual-Future short halten"
nach Kosten Geld verdient, unabhängig davon, ob der Kurs steigt oder fällt?

Aufbau (fest, keine Varianten zum Aussuchen):
- Kapital 1.000 $: die Hälfte kauft Spot, die andere Hälfte ist Sicherheit für einen
  gleich großen Short im USDT-M-Perpetual (Hebel 1, kein Nachkaufen).
- Ertrag: das Funding, das der Short alle 8 Stunden bekommt (oder zahlt, wenn es
  negativ ist), auf den Short-Nennwert; ungenutztes Geld ohne Zins.
- Immer an, kein Ein- und Ausschalten nach dem Funding (nichts zum Überanpassen).
- Kosten: Einstieg und Ausstieg je Bein 0,10 % (Spot) bzw. 0,05 % (Perp) Gebühr plus
  0,05 % Schlupf, einmal pro Kalenderjahr gerechnet (also als ob man jedes Jahr neu
  einsteigt – eher zu teuer).
- Daten: Binance-Funding-Historie (data.binance.vision, monatliche Dateien) für
  BTCUSDT und ETHUSDT, so weit vorhanden.

Bericht: Rendite aufs Kapital je Kalenderjahr nach Kosten, Anteil negativer Monate,
schlechtester Monat. Getrennt: bis 2022 und ab 2023.

Erfolg: ab 2023 jedes volle Jahr nach Kosten im Plus und insgesamt im Plus.

Nicht abgebildet (wird im Bericht genannt): Börsenpleite/Gegenparteirisiko,
Abstand Perp- zu Spotkurs beim Ausstieg, Liquidation bei einem Anstieg um mehr als
ungefähr 90 % ohne Nachschuss, ob Futures für den Nutzer in Deutschland zulässig sind.
