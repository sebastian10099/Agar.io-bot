# Krypto-Skills für Claude

Zwei Claude-Skills nur für Krypto (Binance, Spot, nur Long). Reines Python ohne
Zusatzpakete und ohne API-Schlüssel. Sie lesen kostenlose öffentliche
Binance-Kerzen, rechnen alles nach Gebühren und sagen ehrlich, wenn ein Setup
keinen Vorsprung hat. Keiner der beiden platziert je eine Order.

| Befehl | Aufgabe |
| --- | --- |
| `/crypto-scanner` | Findet Setups auf den 60 liquidesten Krypto-Paaren (20-Tage-Ausbruch, Bullenflagge, zurück über den 20-Tage-Schnitt, überverkauft, Abprall, Ausbruch aus der Eröffnungsspanne) und prüft mit `backtest`, ob jedes Setup früher nach Gebühren verdient hätte. |
| `/crypto-timemachine` | Spielt einen Plan 10.000-mal aus den eigenen Kerzen des Coins durch (Trend neutralisiert, nach Gebühren) und vergleicht mit der echten Historie derselben Regel. |

## Installieren (Mac)

Im Terminal, einmal:

```bash
curl -fsSL https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/agenen-funktionalitaet-hnw6g5/crypto-skills/install.sh | bash
```

Das legt `~/.claude/skills/crypto-scanner` und `~/.claude/skills/crypto-timemachine`
an. Danach in Claude Code einfach schreiben: "scanne Krypto" oder
`/crypto-scanner`. Aus dem Repo heraus geht auch `bash crypto-skills/install.sh`.
Ein erneuter Aufruf aktualisiert die Skills.

In der Claude-App (Einstellungen → Fähigkeiten → Skills) lassen sich die
beiden Ordner auch als Zip hochladen; die Zeitmaschine braucht dann eine Kopie
von `scan.py` in ihrem eigenen Ordner. Ob die App-Sandbox Binance erreicht,
hängt von deren Netzwerk-Freigaben ab; in Claude Code auf dem Mac geht es.

Python 3.8 oder neuer. Auf dem Mac ist `python3` nach `xcode-select --install` da.

## Ablauf

```
crypto-scanner universe -> daily (oder orb) -> backtest -> crypto-timemachine
```

```bash
python3 ~/.claude/skills/crypto-scanner/scan.py universe
python3 ~/.claude/skills/crypto-scanner/scan.py daily
python3 ~/.claude/skills/crypto-scanner/scan.py backtest
python3 ~/.claude/skills/crypto-timemachine/timemachine.py run --pick 1
```

Alles landet in einem Ordner `crypto/` im aktuellen Verzeichnis.

## Was der erste Rückblick zeigte (21.10.2026)

60 Coins, bis 1000 Tage, Stop 1,5 × ATR, Ziel 2 R, höchstens 10 Tage, 0,10 %
Gebühr + 0,05 % Schlupf je Seite:

| Setup | Fälle | Ø R | t | Urteil |
| --- | ---: | ---: | ---: | --- |
| 20-Tage-Ausbruch | 4252 | −0,034 | −2,1 | verliert nach Gebühren |
| Bullenflagge | 1244 | −0,079 | −1,6 | verliert nach Gebühren |
| zurück über den 20-Tage-Schnitt | 2745 | −0,042 | −0,7 | verliert nach Gebühren |
| überverkauft (RSI ≤ 30) | 1875 | +0,066 | −0,4 | positiv, aber nicht stabil |
| Abprall aus überverkauft | 993 | −0,002 | 0,9 | verliert nach Gebühren |
| jeder Tag (Vergleich) | 47476 | −0,064 | −3,0 | – |

Kein Setup hält alle Prüfungen. "Überverkauft" sieht im Mittel gut aus, aber
das Plus kommt von wenigen Tagen, an denen viele Coins gleichzeitig
zurücksprangen (t über die Tage negativ), und die Liste enthält nur Coins, die
heute noch handeln, was Käufe nach Kursrutschen schönt. Auf den Top 20 sah es
anders aus als auf den Top 60. Das ist kein Vorsprung, auf den man Geld setzen
sollte.

## Tests

```bash
cd crypto-skills && python3 -m unittest discover -s tests
```

Offline, mit erzeugten Kerzen: Universum-Filter (Aktien-Token, Stablecoins,
Hebel-Token), R nach Gebühren (Stop = −1 R), Stop vor Ziel in einer Kerze,
Sprünge unter den Stop, die Setups, ORB, der Pool ohne Trend, wiederholbare
Simulation mit Seed, das Urteil.

## Kleingedrucktes

Keine Finanzberatung. Eine Simulation ist keine Vorhersage. Die meisten, die
kurzfristig traden, verlieren Geld. Kostenlose Daten können haken oder sich
ändern. Nur Spot, nur Long, kein Hebel.
