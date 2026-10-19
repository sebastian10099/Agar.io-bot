# New-Token Bot

Ein Trading-Bot für frisch gelistete Tokens — **Paper-first**: echte Kurse,
simulierte Ausführung, und ein eingebauter Beweis, ob die Strategie überhaupt
eine Kante hat. Läuft als lokale Mac-App, ohne Abhängigkeiten außer Python 3.9+.

> Ehrlich vorweg: Es gibt keinen Bot, der bei neuen Tokens garantiert Gewinn
> macht. Der Großteil neuer Listings sind Rug-Pulls oder Honeypots. Dieses
> Projekt ist dafür gebaut, das **messbar** zu machen, bevor echtes Geld im
> Spiel ist. Echtgeld-Ausführung ist absichtlich nicht enthalten.

## Starten

| Was | Wie |
| --- | --- |
| Ohne git, ein Befehl | `curl -fsSL https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/agenen-funktionalitaet-hnw6g5/trading-bot/get.sh \| bash` – lädt nach `~/NewTokenBot/src` und legt die App auf den Schreibtisch; zum Aktualisieren nochmal ausführen |
| Als App aus einem Klon | einmal `bash install-app.sh` im Ordner `trading-bot`, danach Doppelklick auf **New Token Bot** |
| Live-Markt, Spielgeld | Doppelklick auf **Start Trading Bot.command** |
| Offline-Demo, Zeitraffer | Doppelklick auf **Start Demo.command** |
| Auf einem VPS (Linux-Server), rund um die Uhr | auf dem Server `curl -fsSL https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/agenen-funktionalitaet-hnw6g5/trading-bot/deploy/vps-install.sh \| sudo bash`, auf dem Mac Doppelklick auf **VPS verbinden.command** – siehe [Auf einem VPS](#auf-einem-vps--rund-um-die-uhr-ohne-den-mac) |

**Vorab-Check beim Start** (`bot/preflight.py`, von `launch.sh` und der App
aufgerufen): prüft HTTPS mit dem gewählten Python und installiert bei
`CERTIFICATE_VERIFY_FAILED` einmalig `certifi`, dazu das Anthropic-SDK, wenn
es fehlt – beides per `pip install --user`, ohne dass du ein Terminal brauchst.
Klappt HTTPS mit keinem Python, steht die Abhilfe im Log und im Dialog.

**Schutz vor fremden Webseiten:** Die Steuer-API antwortet nur auf Anfragen
an `127.0.0.1`, `localhost` oder `::1`; ändernde Anfragen müssen JSON sein und
dürfen nur von der Steuerseite selbst kommen (gleicher Ursprung – auch durch
einen SSH-Tunnel mit anderem Port). Eine andere Webseite im selben
Browser kann den Bot damit weder pausieren noch Einstellungen ändern oder das
Konto zurücksetzen; abgewiesene Versuche stehen im Protokoll.

**Port-Konflikte:** Der Bot nimmt Port 8765; ist der belegt (Local Studio
nutzt denselben), weicht er automatisch auf den nächsten freien aus und
nennt die Adresse im Log. Die App erkennt den eigenen Bot an einer
Kennung in `/api/state` und öffnet nie die Seite eines fremden Programms.

**Aktualisieren** geht direkt von der Steuerseite: Knopf „Aktualisieren &
neu starten“ auf der Paper-Konto-Karte (erscheint, wenn das Programm über
`get.sh` installiert wurde). Er lädt die neueste Version, der Bot beendet
sich, die App startet ihn neu; Protokoll in `update.log` im Datenordner.

**Die App** (`New Token Bot.app`) startet den Bot im Hintergrund, öffnet die
Steuerseite im Browser und beendet sich über den Knopf **Beenden** oben
rechts. Läuft der Bot schon, öffnet ein Doppelklick nur die Seite. Das Log
liegt in `~/Library/Application Support/NewTokenBot/bot.log`; startet der Bot
nicht, zeigt die App die letzten Logzeilen in einem Dialog. `install-app.sh`
kopiert die App auf den Schreibtisch, merkt sich den Projektordner und
installiert die Anthropic-CLI für „Mit Claude anmelden“ – per Homebrew,
oder ohne Homebrew als Download nach `~/NewTokenBot/bin/ant`. Das Icon entsteht mit `python3 tools/make_icon.py` ohne
Zusatzpakete.
| Terminal | `python3 -m bot.main` bzw. `python3 -m bot.main --demo` |

Das Dashboard öffnet sich unter http://127.0.0.1:8765 — nur lokal erreichbar.
Daten liegen in `~/Library/Application Support/NewTokenBot/`.

Beim ersten Start entsteht dort eine `config.json`; alles, was du dort
einträgst, überschreibt die Standardwerte aus `bot/config.json`.

Falls der Starter „Kein Python gefunden, das HTTPS-Verbindungen aufbauen kann"
meldet: Der python.org-Build bringt keine Zertifikate mit. Einmalig
`/Applications/Python 3.x/Install Certificates.command` doppelklicken.

## Auf einem VPS – rund um die Uhr, ohne den Mac

Ein kleiner Linux-Server reicht (1 CPU, 512 MB RAM; Ubuntu 22.04/24.04 oder
Debian 12). Auf dem Server, als root oder mit sudo:

```
curl -fsSL https://raw.githubusercontent.com/sebastian10099/Agar.io-bot/claude/agenen-funktionalitaet-hnw6g5/trading-bot/deploy/vps-install.sh | sudo bash
```

`deploy/vps-install.sh` installiert Python, lädt den Bot nach
`/opt/new-token-bot`, legt den Systembenutzer `newtokenbot` an und richtet den
systemd-Dienst `new-token-bot` ein: Er startet beim Booten, nach einem Absturz
von selbst neu, läuft im Paper-Modus und darf nur seinen Datenordner
`/var/lib/new-token-bot` beschreiben – sein eigenes Programm nicht. Derselbe
Befehl noch einmal **aktualisiert**; Konto und Einstellungen bleiben.

**Die Steuerseite** hört auch auf dem Server nur auf `127.0.0.1` – aus dem
Internet ist sie nicht erreichbar, es gibt kein Passwort, das man erraten
könnte. Man holt sie über SSH auf den Mac: Doppelklick auf
**VPS verbinden.command** (fragt beim ersten Mal nach `benutzer@server`, baut
den Tunnel auf und öffnet `http://127.0.0.1:18765/`; Fenster offen lassen),
oder von Hand `ssh -N -L 18765:127.0.0.1:8765 benutzer@server`.

**Schlüssel** (Claude, eigener Solana-Knoten für die Halter-Prüfung) stehen in
`/etc/new-token-bot.env`, lesbar nur für root; danach
`sudo systemctl restart new-token-bot`. Protokoll: `sudo journalctl -u
new-token-bot -f`. „Beenden“ auf der Steuerseite hält den Dienst an,
`sudo systemctl start new-token-bot` startet ihn wieder.

Getestet wird das bei jedem Push auf einem echten Ubuntu-Server von GitHub:
installieren, Dienst aktiv, von außen nicht erreichbar, echte Polls als
eingeschränkter Benutzer, Absturz → Neustart, Beenden → bleibt aus, erneut
installieren → Konto bleibt.

## Die Steuerseite

Das Dashboard ist zugleich die Steuerung. Vier Reiter:

- **Übersicht** – offene Positionen mit Live-Gain, Hoch, Rest-Anteil, den
  **Zielkursen** (Stop, nächste Leiterstufe, Trailing sobald scharf, Restzeit bis
  zum Zeit-Stop) und einem Knopf zum manuellen Schließen; die **Kapitalkurve**
  (realisierter Stand nach jedem Exit, mit Fadenkreuz und Tastaturablesung);
  Edge-Report mit Balken, umschaltbar nach Bot / Regeln / KI / **Quelle**
  (liefert GeckoTerminal im Schnitt bessere Tokens als DexScreener?);
  geschlossene Positionen. Jede Position hat einen
  **Details**-Dialog mit dem **Kursverlauf seit Einstieg** (Einstieg, Stop und
  Leiterstufen als Linien, Hoch markiert) und ihren einzelnen Fills.
- **Steuerung** – jeder Parameter der Strategie als Formular, gruppiert nach
  Allgemein / Risiko / Filter / Strategie / Exits. Geänderte Felder werden
  markiert, Fehler stehen direkt am Feld, „Speichern“ gilt **sofort** für den
  laufenden Bot und landet in `~/Library/Application Support/NewTokenBot/config.json`.
  Dazu: **Profile** (Parametersätze unter Namen speichern, laden, löschen – zum
  Vergleichen von Strategien; mitgeliefert sind die Voreinstellungen
  **★ Locker**, **★ Standard** und **★ Streng** – „Locker“ ist der schnelle
  Weg, wenn kaum ein Kandidat durchkommt), Standardwerte laden, Paper-Konto zurücksetzen
  (nur Positionen, oder alles inklusive Edge-Daten), wahlweise mit neuem
  Startkapital, und CSV-Export von Positionen, Fills und Kandidaten. Bricht
  die Verbindung zum Bot ab, erscheint ein Banner mit „Erneut versuchen“.
  Die Seite holt sich alle 2 Sekunden den Stand, der Bot pollt standardmäßig
  alle 10 Sekunden (einstellbar; darunter drohen Rate-Limits der kostenlosen
  APIs). Im Demo-Modus zeigt die Modus-Pille „paper · Demo“ und es gibt
  keine Kursseiten-Links, weil Demo-Tokens nicht existieren.
  **Diagnose kopieren** legt Zustand, Quellen, Selbsttest, Konfiguration und
  die letzten Protokollzeilen als Text in die Zwischenablage – zum Einfügen,
  wenn du Hilfe brauchst.
  Die Karte **Quellen** zeigt für jede Discovery-Quelle, ob sie liefert, wie
  viele Tokens sie im letzten Poll gemeldet hat und wie viele davon nur sie
  gesehen hat – so siehst du, welche Quelle wirklich etwas bringt. Der
  **Selbsttest** daneben prüft in einem Rutsch: Python und TLS-Zertifikate,
  Datenverzeichnis, DexScreener (Discovery und Parser), GeckoTerminal (neue
  Pools und Parser), pump.fun, RugCheck mit der Eigenprüfung als Ersatz, die
  pump.fun-Kurven-Reserven und den Claude-Zugang – mit Laufzeit und Befund je
  Prüfung. Gelb heißt Hinweis (z. B. RugCheck aus, die Eigenprüfung springt
  ein), rot Fehler. Im Terminal: `python3 -m bot.doctor`.
- **Kandidaten** – alle bewerteten Tokens mit Score, Kennzahlen, den
  Gründen für die Entscheidung und der Spalte **Danach**: die tatsächliche
  Kursänderung 5, 15 und 60 Minuten nach der Bewertung, sobald sie vorliegt.
  Filterbar nach buy/watch/skip und Suchtext, sortierbar per Klick auf die
  Spaltenköpfe (auch nach „Danach“). Klick auf das Symbol öffnet den
  **Kandidaten-Dialog** mit allen Kennzahlen, RugCheck-Details, KI-Urteil und
  den Renditen je Horizont. **Kaufen** eröffnet einen Token
  als Paper-Position unabhängig vom Bot-Urteil – der Tracker behält die
  ursprüngliche Entscheidung, so lässt sich das eigene Urteil gegen die Regeln
  messen.
- **Analyse** – ganz oben **Warum fällt was durch?**: welcher Filter wie viele
  der letzten 200 Kandidaten aussortiert hat, mit Sprung zum Parameter. Steht
  „RugCheck nicht erreichbar“ bei fast allen, antwortet die Prüfung nicht –
  Quellen-Karte und Selbsttest zeigen es. Dann **Exits nach Grund**: wie oft jede Ausstiegsregel
  gegriffen hat, mit Trefferquote, Ø und Σ P&L und Ø Haltedauer – so siehst
  du, ob der Zeit-Stop Geld kostet oder die Leiter zu früh verkauft. Darunter
  der Rückblick: Jeder Filterwert wird einzeln über ein Raster
  bewegt (alle anderen bleiben wie eingestellt), und für jeden Wert steht da,
  wie viele der bisherigen Kandidaten damit `buy` gewesen wären und welche
  Rendite sie danach tatsächlich hatten. Zeilen mit weniger als fünf Treffern
  sind ausgegraut – Rauschen, kein Ergebnis. Umschaltbar nach Horizont
  (5 / 15 / 60 Minuten). **Übernehmen** trägt einen besseren Wert (oder alle
  auf einmal) ins Formular ein – gespeichert wird erst mit „Speichern“.
- **Protokoll** – was der Bot getan hat, inklusive jeder Änderung über die Seite,
  filterbar nach Trades / Polls / Info / Fehler.

Oben rechts: **🔔** (Browser-Benachrichtigung bei jedem Einstieg und Exit,
fragt einmal um Erlaubnis), **Jetzt pollen** (sofort neue Tokens holen) und
**Pause**. Pause stoppt nur neue Einstiege – Exits offener Positionen laufen
weiter. Tasten: `1`–`5` Reiter, `p` Pause, `r` Pollen, `/` Suche.

Die Seite ist vollständig per Tastatur bedienbar, jedes Bedienelement hat einen
Namen für Screenreader, Rückmeldungen werden vorgelesen, und alle Farbpaare
erfüllen WCAG AA in beiden Themes – nachgemessen, nicht geschätzt
(`tests/ui/verify.js` prüft Tastaturbedienung und Beschriftungen mit).
Der Punkt links im Titel zeigt, ob der Bot lebt (grün), noch nie gepollt hat
(gelb) oder länger als drei Intervalle nichts gemeldet hat (rot).

Die Seite redet über eine kleine JSON-API mit dem Bot, die du auch direkt
nutzen kannst (nur von `127.0.0.1` erreichbar):

| Methode | Pfad | Zweck |
| --- | --- | --- |
| GET | `/api/state` | Alles, was die Seite anzeigt |
| GET | `/api/schema` | Parameter-Schema (Typ, Grenzen, Beschriftung) |
| GET | `/api/config` · `/api/defaults` | Aktuelle bzw. Standard-Parameter |
| POST | `/api/config` `{"patch": {"exits.stop_loss_pct": -25}}` | Parameter ändern, validiert, 422 bei Fehlern |
| POST | `/api/control` `{"action": "pause"\|"resume"\|"poll"}` | Steuern |
| POST | `/api/positions/close` `{"id": 3}` | Position zum letzten Kurs schließen |
| POST | `/api/positions/open` `{"candidate_id": 12}` | Kandidaten manuell als Paper-Position kaufen |
| GET | `/api/positions/3` | Position mit allen Fills, Kursverlauf (`ticks`) und den Exit-Parametern |
| GET | `/api/candidates/12` | Kandidat mit Snapshot, RugCheck, KI-Urteil und Renditen je Horizont |
| GET | `/api/sweep?horizon=15` | Rückblick-Analyse der Filterwerte |
| POST | `/api/doctor` `{}` | Selbsttest aller Quellen, Parser und Zugänge |
| POST | `/api/quit` `{}` | Bot und Dashboard beenden |
| POST | `/api/update` `{}` | Neue Version per get.sh laden, Bot beenden, App neu starten (nur macOS, Installation über get.sh) |
| POST | `/api/reset` `{"what": "positions"\|"all", "bankroll": 500}` | Paper-Konto zurücksetzen, optional mit neuem Startkapital |
| GET/POST | `/api/profiles` · `/api/profiles/apply` · `/api/profiles/delete` | Parameter-Profile verwalten |
| GET | `/api/export/positions.csv` · `trades.csv` · `candidates.csv` | Export (Semikolon-CSV, UTF-8 mit BOM) |
| POST | `/api/ai/key` `{"key": "sk-ant-…"}` | Anthropic-Schlüssel im macOS-Schlüsselbund ablegen |

Ein neuer Parameter ist ein Eintrag in `bot/settings.py` – Validierung und
Formular entstehen daraus automatisch.

## Wie der Bot entscheidet

```
DexScreener-Profile + GeckoTerminal-Pools  ->  Harte Filter  ->  Score 0-100  ->  buy / watch / skip
          (Discovery-Quellen)                      |                                   |
                                               RugCheck                          Tracker: was wurde
                                                                                 5/15/60 min später daraus?
```

**Discovery** – woher neue Tokens kommen – ist steckbar (`discovery.sources`,
auch über die Steuerseite). Eingebaut sind zwei kostenlose Feeds ohne Schlüssel:

- **DexScreener** – „neueste Profile“ und „neueste Boosts“: Tokens, die gerade
  beworben werden. Zuverlässig, aber erst, wenn jemand dafür bezahlt hat.
- **GeckoTerminal** – „neue Pools“ pro Chain in Entstehungsreihenfolge. Sieht
  einen Launch meist einige Minuten früher. Begrenzt auf eine Abfrage je Chain
  alle 15 Sekunden (die Freigrenze sind 30 pro Minute), dazwischen wird die
  letzte Antwort wiederverwendet.
- **pump.fun** – die neuesten Coins der Launch-Plattform, Sekunden nach der
  Erstellung; nur Solana. Liefert Mint und Alter, die Kennzahlen holt
  DexScreener (indexiert pump.fun als Dex „pumpfun“). Inoffizielle API: fällt
  sie aus oder ändert ihr Format, wird die Quelle rot und der Rest läuft weiter.

Die erste Quelle in der Reihenfolge, die einen Token nennt, gilt als seine
Quelle (steht am Kandidaten). Die Kennzahlen holt immer DexScreener; ist ein
Token dort noch nicht gelistet, wird er mit den Zahlen des Feeds bewertet und
der Kandidat trägt „via Feed“. Gekauft wird so ein Token erst, wenn DexScreener ihn listet –
sonst gäbe es keinen Kurs für Stop-Loss und Zeit-Stop. Fällt eine Quelle aus, steht das einmal im
Protokoll und in der Quellen-Karte – die anderen laufen weiter.

**Wiedervorlage:** Ein Token, der nur „zu neu“ war, wird nach zwei Minuten
erneut bewertet, ein `watch` alle fünf Minuten (seine Zahlen bewegen sich
schnell), ein harter `skip` (RugCheck-Gefahr, zu alt, parabolisch) erst nach
einer halben Stunde. So verpasst der Bot nicht das Fenster zwischen Minute 2
und 30, nur weil er den Token in Minute 1 schon gesehen hat. GeckoTerminal und
pump.fun listen nur die letzten paar Dutzend Starts – wenn ein Token alt genug
ist oder wieder fällig wird, steht er dort längst nicht mehr. Der Bot merkt
sich deshalb jeden Token, der nur „zu neu“ war oder beobachtet wird, und holt
ihn selbst wieder: den zu neuen, sobald er das Mindestalter erreicht, den
beobachteten nach fünf Minuten, jeweils mit den aktuellen Zahlen von
DexScreener (listet DexScreener ihn zehn Minuten danach noch immer nicht, wird
er vergessen). Ohne das sah der Bot neue Tokens nur zu früh und die beworbenen
nur zu spät – und kaufte nie.

**Harte Filter** (ein Verstoß = `skip`, Grund wird gespeichert):

- Alter 2–120 Minuten — nicht in der ersten Minute kaufen, nicht alten Tokens hinterherlaufen
- Liquidität 15 k–2 M $, 5-Minuten-Volumen ≥ 3 k $, ≥ 15 Käufe in 5 Minuten (Bonding-Kurven: siehe unten)
- Käufe/Verkäufe ≥ 1.2 — es muss mehr rein- als rausgehen
- 5-Minuten-Kursänderung zwischen 0 % und +150 % — nichts Fallendes, nichts Parabolisches
- FDV ≤ 20 M $
- RugCheck: keine `danger`-Einstufung (Freeze-Authority, Holder-Konzentration, …), Score ≤ 2000. Ist RugCheck nicht erreichbar, wird der Token bewertet und verfolgt (`watch`), aber **nicht** gekauft – auch nicht von der KI.

**Score** aus Liquidität, Aktivität (Volumen/Liquidität), Kaufdruck, Momentum,
Alter (5–30 min ideal), Socials und RugCheck. Ab 60 Punkten `buy`, darunter `watch`.

**Bonding-Kurven:** Die meisten neuen Solana-Coins handeln anfangs gegen die
Preiskurve ihrer Startplattform (pump.fun, Meteora DBC, LaunchLab), nicht in
einem Pool. DexScreener nennt dafür keine Liquidität, GeckoTerminal nur die
unverkaufte Token-Seite – ohne Korrektur fiele jeder dieser Coins mit „$0“
durch. Für pump.fun liest der Bot die Reserven direkt aus dem Kurven-Konto auf
der Chain (eine `getMultipleAccounts`-Abfrage pro Poll für alle Kurven, die
bewertet werden): Liquidität = 2 × virtuelle Tokens × Kurs, also die eines
Pools mit gleicher Kurswirkung – gleich ob die Kurve gegen SOL, USDC oder einen
anderen Token läuft. Auf der Steuerseite steht dann „$… Kurve“. Andere
Plattformen bleiben „unbekannt“ und werden mit diesem Grund übersprungen; eine
abgeschlossene Kurve heißt „Kurve fertig“.

**Wechsel an die Börse:** Ist eine pump.fun-Kurve voll, zieht der Handel in einen
PumpSwap-Pool um, und die Kurve friert ein oder verschwindet. Offene Positionen
und der Tracker folgen dem Token: Fehlt das Paar, zählt der beste verbliebene
Pool des Tokens; bei einer Kurve zählt ein echter Pool, sobald es einen gibt
(ab 1.000 $ Liquidität). So wird ein „graduierter“ Coin weder mit einem
eingefrorenen Kurs gehalten noch als Totalverlust abgeschrieben.

**Wiedereinstieg-Sperre** (Risiko, Standard 120 min, 0 = aus): Nach einem
Verkauf kauft der Bot denselben Token so lange nicht automatisch zurück – ein
Trailing- oder Stop-Loss-Ausstieg hat gerade gesagt, dass der Lauf vorbei ist.
Der Knopf „Kaufen“ von Hand geht immer.

## Wie gehandelt wird (Paper)

- Positionsgröße aus Risiko: 1 % der Bankroll pro Trade, geteilt durch den Stop-Abstand → ~3,3 % pro Position
- Stop-Loss −30 %, Gewinnleiter: 50 % der Position bei +50 %, 25 % bei +100 %
- Trailing-Stop 25 % vom Hoch, der erst ab +25 % scharf wird
- Zeit-Stop nach 45 Minuten — neue Tokens verfallen schnell, Halten ist kein Plan
- Maximal 5 offene Positionen, Tages-Verlustlimit 5 % → danach keine neuen Einstiege
- **Jeder Fill zahlt 1 % Gebühr und 2 % Slippage.** Das ist bewusst pessimistisch. Ein Bot, der nur mit null Kosten profitabel ist, ist nicht profitabel.

## KI-Modus: Claude als zweiter Blick – oder als Entscheider

**Zwei Anbieter:** Claude (Anthropic) oder **OpenRouter** – dort gibt es einen
kostenlosen Schlüssel (openrouter.ai) und Modelle mit „:free“, die nichts kosten.
Anbieter und Modell stehen im Formular unter „KI“; der Schlüssel wird unten im
KI-Bereich gespeichert. `python3 -m bot.ai --provider openrouter` macht den Test.

**Zugang ohne Schlüssel (Claude):** Knopf „Mit Claude anmelden“ auf der Steuerseite.
Er startet `ant auth login` (Anthropic-CLI, einmalig `brew install
anthropics/tap/ant`), der Browser geht auf, du meldest dich mit deinem
Claude-Konto an, und der Bot nutzt ab dann dieses Profil – kein Schlüssel zum
Einfügen. Die Reihenfolge, die der Bot prüft: Umgebungsvariable, Schlüsselbund,
Profil. Ob dein Konto API-Aufrufe abdeckt, entscheidet die Anthropic Console;
`python3 -m bot.ai` macht einen echten Testaufruf und sagt es dir.

Im Reiter *Steuerung* unter **KI** lässt sich Claude zuschalten. Die harten
Sicherheitsfilter (RugCheck-Gefahrenflags, Liquidität, Altersfenster) bleiben
immer davor: Das Modell sieht nur Kandidaten, die sie bestanden haben, und
bekommt deren Kennzahlen, die RugCheck-Zusammenfassung und das Urteil der
Regeln. Es antwortet strukturiert mit `buy` / `watch` / `skip`, einer
Vertrauenszahl, bis zu drei Gründen und Warnzeichen.

| Modus | Was passiert |
| --- | --- |
| **Aus** | Nur die Regeln entscheiden. |
| **Beraten** | Die Regeln entscheiden, das KI-Urteil wird bei jedem Kandidaten mitprotokolliert. |
| **Entscheiden** | Das KI-Urteil ersetzt die Regel-Entscheidung; gekauft wird nur ab der eingestellten Mindest-Vertrauenszahl. |

Der Punkt ist die Messung: Der Edge-Report in der Übersicht lässt sich auf
**Bot / Regeln / KI** umschalten und zeigt die Vorwärtsrendite derselben
Kandidaten nach dem jeweiligen Urteil. Fang mit *Beraten* an. Erst wenn die
KI-Spalte über Wochen klar vor den Regeln liegt, ist *Entscheiden* mehr als
ein Gefühl. Ein Sprachmodell kann Kurse nicht vorhersagen; es kann Warnzeichen
lesen, die starre Regeln übersehen – ob das Geld wert ist, sagt nur der Report.

Einrichtung:

```bash
pip install anthropic            # offizielles SDK, einzige Zusatzabhängigkeit
```

Schlüssel: `ANTHROPIC_API_KEY` in der Umgebung, ein `ant auth login`-Profil,
oder auf dem Mac über die Steuerseite in den Schlüsselbund speichern. Dann
einmal prüfen, ob die Verbindung steht – ein echter Aufruf mit einem
Beispiel-Token, Urteil und Kosten werden ausgegeben:

```bash
python3 -m bot.ai
```

Technik: Modell `claude-opus-5-5` (einstellbar), adaptives Denken mit
einstellbarer Tiefe (`effort`), strukturierte JSON-Ausgabe per Schema,
serverseitige Fallbacks bei Sicherheitsablehnungen, Prompt-Caching für den
festen Systemteil. Kostenbremse über *Max. Anfragen pro Stunde*; der laufende
Verbrauch steht auf der Steuerseite. Jeder Fehler (ungültiger Schlüssel,
Rate-Limit, Modell nicht gefunden) landet im Protokoll, und die Regeln
entscheiden dann allein weiter.

**Sicherheitsprüfung mit Ersatz:** Zuerst wird RugCheck gefragt. Antwortet
RugCheck nicht (ausgefallen, gedrosselt, Domain nicht erreichbar – Stand
19.10.2026 existiert `rugcheck.xyz` im DNS gar nicht mehr), prüft der Bot
selbst über die Solana-Blockchain (`getAccountInfo` auf den Mint, öffentlicher
RPC oder `SOLANA_RPC_URL`): aktive Freeze-Authority, aktive Mint-Authority und
Token-2022-Fallen (Permanent Delegate, Transfer-Hook, pausierbar, eingefrorene
Konten, Transfergebühr) und die **Halter-Konzentration**: Hält eine Wallet
≥ 25 % oder halten die zehn größten Wallets ≥ 60 % der Menge, gilt das als
Gefahr (ab 10 % bzw. 35 % als Warnung). Konten, die Programmen gehören – die
pump.fun-Kurve, Pools, Locker –, zählen nicht mit; man erkennt sie wie auf der
Chain selbst daran, dass ihre Adresse nicht auf der Ed25519-Kurve liegt. Diese
Eigenprüfung sieht keine LP-Locks und keine Insider-Verbindungen und bekommt
deshalb nur die Hälfte der Score-Punkte. Erst wenn beide nichts liefern, wird
nur beobachtet. Die Halter-Abfrage (`getTokenLargestAccounts`) drosselt der
öffentliche RPC hart, und kein freier öffentlicher Knoten beantwortet sie ohne
Schlüssel (geprüft: publicnode, drpc, ankr, onfinality, omniatech); auch die
Abfrage aller Token-Konten eines Coins (`getProgramAccounts`) wird gedrosselt,
und GeckoTerminal hat für frische Coins keine Halterzahlen (geprüft Oktober
2026). Auf einem VPS mit eigener IP-Adresse kann die öffentliche Abfrage
klappen – der Selbsttest zeigt es. Nach einer Drosselung (429) ruht sie 30
Sekunden, statt das Limit mit jedem Token weiter auszureizen; solange prüft
der Bot nur den Ersteller. Ohne
Antwort prüft der Bot bei pump.fun-Coins wenigstens den **Ersteller**: Sein
Kurvenkonto nennt ihn, daraus folgt die Adresse seines Token-Kontos, und beides
lässt sich mit gewöhnlichen, nicht gedrosselten Abfragen lesen. Hält der
Ersteller noch ≥ 15 % der Menge, ist das Gefahr (≥ 5 % Warnung) – er kann
jederzeit auf alle Käufer abverkaufen. Die übrige Verteilung bleibt dann
„unbekannt“ (Warnung). Viele Starts teilen ihre Ersteller-Gebühren; dann
steht im Kurvenkonto statt der Wallet das Gebührenkonto von pump.fun, und das
nennt Verwalter und Teilhaber – ihr Anteil zusammen zählt wie der des
Erstellers. Der Bot nimmt dieses Konto nur, wenn es genau diesen Coin nennt
und die Anteile zusammen exakt 100 % ergeben; sonst bleibt es bei
„unbekannt“, nie bei einer falschen Zahl. Live-Stichprobe (Oktober 2026):
Ergebnis für 7 von 8 Coins.

**Nur mit geprüften Haltern kaufen** (Einstellung, ab Werk an): Weiß der Bot
weder die Halterverteilung noch den Anteil des Erstellers, kauft er nicht,
sondern beobachtet nur (Grund „Halter unbekannt“) und schaut nach fünf
Minuten wieder hin. Die meisten schnellen Abstürze direkt nach dem Kauf
kommen von großen Haltern, die abverkaufen – blind in so einen Coin zu gehen,
war der teuerste Fehler im Paper-Lauf (−90 % und −56 % binnen Sekunden). Wer einen
kostenlosen Schlüssel hat (z. B. Helius), trägt den Knoten in
`SOLANA_HOLDER_RPCS` ein (mehrere mit Komma); der Bot probiert sie der Reihe
nach und bleibt beim ersten, der antwortet.

**Verschwundene Paare:** Liefert DexScreener für eine offene Position keinen Kurs
mehr, während andere Kurse kommen, ist das Paar meist entfernt worden (Rug). Ist
ihr Zeit-Stop abgelaufen und fehlt der Kurs seit 30 Minuten, wird der Rest als
Verlust abgeschrieben (Grund `no_price`) – sonst bliebe sie für immer offen.
Bei einem allgemeinen Ausfall passiert das nicht.

## Paper-Live auf GitHub — zuschauen, ohne den Mac

Der Workflow **Paper-Live** lässt denselben Bot im Paper-Modus gegen die echten
Märkte laufen (bis zu 5,5 Stunden pro Lauf, macOS-Runner) und veröffentlicht
alle zwei Minuten einen Schnappschuss im Branch `paper-live`:

- `REPORT.md` – Bankroll, offene Positionen, geschlossene Trades, Edge-Report,
  Filtergründe, Protokoll; GitHub zeigt die Datei direkt an:
  https://github.com/sebastian10099/Agar.io-bot/blob/paper-live/REPORT.md
- `index.html` – dieselben Zahlen als Seite, die sich jede Minute neu lädt.
  Als Fenster im Browser: einmal unter *Settings → Pages* „Deploy from a
  branch“, Branch `paper-live`, Ordner `/ (root)` wählen; danach steht sie unter
  https://sebastian10099.github.io/Agar.io-bot/
- `state.json` – die Rohdaten, `bot.sqlite.gz` – das Paper-Konto. Der nächste
  Lauf setzt es fort, Bankroll und Edge-Report wachsen also über mehrere Läufe.

Gestartet wird ein Lauf durch eine Änderung an `.github/paper-live.json`
(`{"hours": 5, "profile": "★ Locker – mehr Kandidaten (Paper)"}` – `profile` ist
ein Name aus `bot/presets.json` und wählt die Filter des Laufs, ohne ihn gilt
der Standard) auf dem Branch des Bots, oder – sobald der Workflow auf dem
Hauptbranch liegt – über *Actions → Paper-Live → Run workflow*. Ein neuer
Start ersetzt einen laufenden; das Konto wird vorher gesichert. Steuern lässt
sich der Bot dort nicht: Die Seite ist eine reine Ansicht. Auf dem Mac läuft
derselbe Paper-Modus dauerhaft, mit der vollen Steuerseite.

## Der Edge-Report — der wichtigste Teil

**Ehrliche Messung:** Kurse für fällige Ergebnisse werden gesammelt abgefragt
(bis zu 30 Paare pro Anfrage), damit auch bei vielen Kandidaten jeder Wert
pünktlich gemessen wird. Ein Paar, das nicht mehr bepreist wird, während die
anderen Kurse kommen, wurde entfernt (Rug) und zählt als **−100 %** – sonst
würden gerade die Totalverluste aus der Statistik fallen. Bei einem
allgemeinen Ausfall wird dagegen nie ein Verlust gebucht, sondern nach einer
Stunde „unbekannt“.

Der Tracker merkt sich **jeden** bewerteten Token, auch die abgelehnten, und
holt nach 5, 15 und 60 Minuten den Kurs. Das Dashboard zeigt dann pro
Entscheidung die durchschnittliche Vorwärtsrendite:

| decision | 15 min | n | Ø Rendite | Treffer |
| --- | --- | --- | --- | --- |
| buy | 15 | 42 | +11 % | 57 % |
| watch | 15 | 130 | −4 % | 41 % |
| skip | 15 | 610 | −23 % | 22 % |

So sollte es aussehen, wenn die Filter etwas taugen. Wenn `buy` nicht klar
besser abschneidet als `watch` und `skip`, hat die Strategie keine Kante —
dann helfen auch keine schöneren Trades. Lass den Bot **mindestens zwei
Wochen** laufen, bevor du dem Report traust; vorher ist n zu klein.

## Ideen, die drinstecken — und die nächsten

Eingebaut:
1. Rug-Filter vor allem anderen. Das allein sortiert den Großteil der Verlierer aus.
2. „Zu früh" und „zu spät" sind beides Fehler — das Alters- und Momentum-Fenster ist eng.
3. Kaufdruck statt Kursanstieg als Signal: Käufe/Verkäufe sagt mehr als die Prozentzahl.
4. Kosten pessimistisch simulieren, damit die Zahlen auf Echtgeld übertragbar sind.
5. Kontrollgruppe mitlaufen lassen (watch/skip), sonst ist jede Gewinnkurve Zufall.

Als Nächstes sinnvoll, in dieser Reihenfolge:
- **Echtzeit-Discovery per Solana-RPC/Websocket** (Raydium, PumpSwap) – noch einen Schritt näher an der Chain als der pump.fun-Feed, braucht aber einen RPC-Anbieter mit Websocket. Die Feed-Schnittstelle in `bot/discovery.py` ist dafür gedacht: `discover(chains)` liefern, fertig.
- **Holder-Analyse**: Top-10-Anteil und Dev-Wallet-Verhalten direkt aus der Chain.
- **Live-Adapter** (`bot/live.py`): Jupiter-Quote + Swap, lokal signiert — erst, wenn der Edge-Report über Wochen positiv ist, und nur mit Geld, das weg sein darf.

## Projektstruktur

```
bot/
  main.py        Einstieg, Konfiguration, Dashboard-Server starten
  engine.py      Poll-Schleife: entdecken -> bewerten -> handeln -> Exits
  strategy.py    Filter und Score
  paper.py       Paper-Engine mit Gebühren, Slippage und allen Exit-Regeln
  tracker.py     Vorwärtsrenditen für den Edge-Report
  sweep.py       Rückblick: Filterwerte gegen die eigene Historie
  store.py       SQLite
  server.py      Lokales Dashboard und Steuer-API (nur 127.0.0.1)
  settings.py    Parameter-Schema: Validierung + Formular aus einer Quelle
  demo.py        Offline-Markt für Demo und Tests
  ai.py          Claude-Anbindung: zweiter Blick auf gefilterte Kandidaten
  live.py        Schnittstelle für Echtgeld — bewusst nicht implementiert
  discovery.py   Discovery-Quellen zusammenführen, Status je Quelle
  doctor.py      Selbsttest: Erreichbarkeit und Parser aller Quellen
  preflight.py   Startcheck: HTTPS/CA-Zertifikate und Anthropic-SDK, repariert per pip
  sources/       DexScreener, GeckoTerminal, pump.fun, RugCheck, Solana-RPC (Eigenprüfung, Kurven-Reserven)
deploy/
  vps-install.sh Linux-Server: Installation/Aktualisierung als systemd-Dienst
tests/           python3 -m unittest tests.test_bot tests.test_control tests.test_ai tests.test_sources tests.test_preflight
```

## Tests

```bash
python3 -m unittest -v tests.test_bot tests.test_control tests.test_ai tests.test_sources tests.test_preflight
```

Strategie-Entscheidungen, alle Exit-Regeln, der Tracker, ein kompletter
Zyklus gegen den Demo-Markt, die Parameter-Validierung, Live-Änderungen,
manuelles Schließen, Resets und jede API-Route sind abgedeckt.

**Browser-Prüfung der Steuerseite** – klickt gegen einen laufenden Demo-Server
jede Funktion durch (Formular, Validierung, Persistenz, Schließen, Pause,
Filter, Reset), prüft auf Konsolenfehler und auf Überhang am Telefon, und legt
Screenshots in `tests/ui/shots/` ab:

```bash
python3 -m bot.main --demo --no-open --port 8797 &
npm install playwright          # einmalig, lädt Chromium
node tests/ui/verify.js
```

Der Demo-Markt listet seine Tokens jede simulierte Stunde neu (eine reale
Minute im 60×-Zeitraffer), damit dauerhaft frische Kandidaten kommen.
