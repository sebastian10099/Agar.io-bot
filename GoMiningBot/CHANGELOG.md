# Änderungen

Jede Version erscheint automatisch als GitHub-Release mit der fertigen App (`GoMining-Bot.zip`).
Die Abschnitte hier werden als Release-Notizen und in der App unter „Was ist neu“ angezeigt.

## 4.4 – 14.10.2026

**Selbstdiagnose und Offline-Modus**
- Ampel in der Statusleiste (grün, orange, rot); ein Klick zeigt die Details: Livestream, Orderbuch, Kerzen, Netzwerk,
  Fehlerhäufigkeit, Abweichung der Mac-Uhr und ruhiger Markt – jeweils mit Erklärung und was man tun kann.
- Offline-Modus: Ist kein Netz da oder kommen eine Minute lang keine Marktdaten, zeigt ein rotes Banner das deutlich an,
  mit „Jetzt neu verbinden“. Beim Übergang kommt eine Mitteilung (Schalter „Bei erreichter Schutzgrenze“).
- Die App erkennt Netzwerkwechsel sofort über den macOS-Netzwerkstatus und verbindet sich automatisch neu, sobald das
  Netz zurück ist.
- „Diagnose kopieren“ enthält jetzt die Selbstdiagnose sowie Speicher- und CPU-Verbrauch der App.

**Sicherungen wiederherstellen**
- Einstellungen → Daten & Wartung → „Sicherungen wiederherstellen“: die automatischen Sicherungen (alle 30 Minuten,
  12 bleiben) und die Sicherungen vor Zurücksetzen und Updates, mit Vorschau (Trades, realisiertes Ergebnis, Bargeld,
  Bestand, letzter Trade) vor dem Wiederherstellen.
- „Aus Datei wiederherstellen“ für exportierte Sicherungen oder eine `simulation.json`.
- Vor jeder Wiederherstellung wird der aktuelle Stand selbst gesichert – es geht nichts verloren.

**Robuster gegen kaputte Daten**
- Neue Fuzz-Tests schicken Tausende verfälschte Antworten durch alle Leser (BingX-Kerzen, Orderbuch, Trades,
  Livestream, Konto, Updates, Marktprotokoll, Profile, Sicherungen, Kerzenspeicher). Dabei wurden vier Stellen gefunden,
  an denen die App hätte abstürzen können, und behoben: riesige Zahlen (Fehlercodes, Trade-IDs, Folgenummern),
  unsinnige Zeitstempel bei Kerzen, absurde Datumsangaben in beschädigten Dateien – und ein Fehler in Apples
  JSON-Leser, der bei einem Steuerzeichen oder einem ungültigen Zeichen (kaputtes UTF-8) in einer beschädigten
  `simulation.json` abstürzt, statt einen Fehler zu melden (die App wäre dann bei jedem Start abgestürzt). Alle Dateien
  – auch importierte Profile und der Schlüsselbund-Eintrag – werden jetzt vorher Byte für Byte geprüft; eine kaputte
  Datei wird wie bisher beiseitegelegt und die letzte Sicherung geladen.
- Kerzen und Trades mit Zeitstempeln außerhalb von 2000 bis 2100 werden verworfen.
- Dauertest der Engine: 48.000 Marktmomente mit Zufallskurs, Sprüngen und dünnen Orderbüchern, mit und ohne Limit-Kauf.
  Nach jedem Schritt wird geprüft: Bargeld nie negativ, Bestand gleich Summe der Lose, Vermögen endlich, begrenzte Listen.
- Langzeittest der App in der CI: 30 Minuten mit Live-Daten und Schattenkonten, misst Speicher und CPU (startet von Hand
  oder mit `[soak]` in der Commit-Nachricht).

**Schneller und mehr Verlauf**
- Der Kerzenverlauf liegt jetzt in einem kompakten Binärformat statt JSON (rund 6 MB für 90 Tage, lädt in
  Millisekunden) – die App startet schneller. Die alte Datei wird beim ersten Speichern übernommen.
- Der lokale Verlauf reicht 90 statt 45 Tage.
- Das Diagramm lädt beim Start die letzten 12 Stunden 1-Minuten-Kerzen nach; Herauszoomen geht sofort.

## 4.3 – 13.10.2026

**Diagramm zum Zoomen und Verschieben**
- Zoomen mit zwei Fingern auf dem Trackpad oder mit den Lupen-Knöpfen, Verschieben durch Ziehen, „Live“ springt zur
  neuesten Kerze, „Alles“ zeigt den ganzen geladenen Verlauf, Doppelklick stellt die Standardansicht wieder her.
- Die 1-Minuten-Ansicht reicht jetzt bis zu 12 Stunden zurück (aus dem gespeicherten Verlauf), die längeren Zeiträume
  bis zu 1.000 Kerzen. Der Preisbereich passt sich den sichtbaren Kerzen an.
- Tooltips zeigen neben Eröffnung/Hoch/Tief/Schluss auch die Trades in der Kerze (Zeit, Menge, Preis, Ergebnis).

**Profile & Vorlagen (Einstellungen)**
- Aktuelle Einstellungen unter einem Namen speichern, später wieder laden, löschen, als Datei exportieren und
  importieren (auch Einstellungen aus einer Sicherung oder `simulation.json`).
- „Als Schattenkonto testen“ prüft ein Profil live neben dem Hauptkonto.
- Vorlagen „Vorsichtig“, „Ausgewogen (Standard)“ und „Aktiv“ jetzt auch fürs Hauptkonto.
- Laden ändert nur die Strategie: Startkapital, Gebühren und Papierkonto bleiben unverändert.

**Berichte**
- Neue Karte „Bericht“ auf der Statistik-Seite für heute, gestern und die letzten 7 Tage: Vermögensänderung, Vergleich
  mit Halten, realisiertes Ergebnis, Käufe/Verkäufe, Gewinnquote, Gebühren.
- „Als HTML-Bericht speichern“: eigenständige Seite mit Vermögensverlauf, allen Trades und den Einstellungen – im
  Browser auch als PDF druckbar.
- Tageszusammenfassung von gestern als Mitteilung nach Mitternacht (abschaltbar unter Benachrichtigungen).

**Vergleichsseite**
- Neues Diagramm: Rendite aller Schattenkonten seit ihrem Start, das Hauptkonto auf denselben Zeitraum umgerechnet.
- Schattenkonten führen dafür einen eigenen Vermögensverlauf (ein Punkt pro Minute, ältere Punkte werden ausgedünnt).

**Sonstiges**
- Die CI prüft die Oberfläche jetzt auch im Dunkelmodus (Bilder `7-dunkel-uebersicht` und `8-dunkel-vergleich`).
- Neue Tests für Profile, Berichte und den Verlauf der Schattenkonten.

## 4.2 – 12.10.2026

**Mindest-Kaufabstand 80 bp (neu, Standard) – der Bot kauft nicht mehr jeden kleinen Rücksetzer**
- Bisher hing die Kaufschwelle vor allem am Spread. Beim echten, engen Spread von GOMINING (5–12 bp) kaufte der Bot
  schon nach Rückgängen von rund 30 bp – und zahlte mit Gebühren und Stop-Loss drauf.
- Neu: Die Schwelle ist mindestens 80 bp (einstellbar unter *Einstieg*, 0 = Verhalten wie 4.1, auch im Optimierer).
- Beleg (Strategievergleich auf 7 Tagen echter BingX-Kerzen, 12.10.2026, Halten −6,5 %):
  mit dem live gemessenen Spread (12 bp) **+0,35 USDT statt −18,02 USDT** (Teil 1 ±0,00 statt −17,74, Teil 2 +0,35
  statt −2,75, größter Rückgang 1,9 statt 20,3 USDT); mit angenommenem Spread (20 bp) +0,18 statt −3,49 USDT.
  60 bp war uneinheitlich, 100 bp in dieser Woche noch etwas besser (+2,00) – gewählt wurde trotzdem der vorher
  festgelegte Wert 80, um nicht einer einzelnen Woche hinterherzulaufen. Der Bot handelt damit seltener (6 statt 21
  Käufe in 7 Tagen). Die Vorlage „Aktuelle ohne Mindest-Kaufabstand (wie 4.1)“ auf der Seite *Vergleich* prüft das live.

**Backtest rechnet standardmäßig mit dem echten Live-Spread**
- Bisher galten feste 20 bp – deutlich mehr als der echte Spread. Weil die Kaufschwelle vom Spread abhängt, sah der
  Backtest dadurch besser aus als der Livebetrieb (7 Tage, Version 4.1: −3,5 USDT im Backtest, −18 USDT mit echtem
  Spread). Jetzt werden Spread und Tiefe vor jedem Lauf aus dem Live-Markt übernommen (abschaltbar).

**Neue Seite „Vergleich“: Schattenkonten**
- Bis zu fünf Schattenkonten handeln mit eigenen Einstellungen und eigenem Papierkonto auf genau denselben Live-Daten
  wie das Hauptkonto. Die Seite zeigt Ergebnis, Vergleich mit Halten, Käufe/Verkäufe, Gewinnquote, offene Positionen
  und die Unterschiede zum Hauptkonto.
- Vorlagen: Aktuelle Einstellungen, Vorsichtig, Ausgewogen (Standard), Aktiv, Aktuelle mit Limit-Kauf am Bid,
  Aktuelle ohne Trendfilter. Startkapital, Gebühren und Slippage übernimmt jedes Konto vom Hauptkonto.
- Je Konto: Einstellungen ins Hauptkonto übernehmen, zurücksetzen, entfernen; „Alle zurücksetzen“ für einen fairen
  gemeinsamen Neustart. Gespeichert in `shadow-accounts.json`.

**Backtest mit echten Orderbüchern (Replay aus dem Marktprotokoll)**
- Neue Datenquelle im Backtest: die Orderbücher (beste zehn Stufen) und Käuferanteile, die die App alle 5 Sekunden
  selbst aufzeichnet – statt angenommenem Spread und angenommener Tiefe. Lücken, in denen die App aus war, werden
  übersprungen.
- „Aus Marktprotokoll messen“ übernimmt den typischen Spread und die typische Tiefe der letzten 7 Tage in den
  Kerzen-Backtest (Median, dazu der Spread, der in 90 % der Zeit nicht überschritten wurde).

**Robustere Optimierung**
- Jede Kombination wird zusätzlich in vier aufeinanderfolgenden Zeitabschnitten mit frischem Konto gerechnet; die Tabelle
  zeigt „x/4 im Plus“ und lässt sich nach Robustheit sortieren (Standard) statt nur nach dem Trainingsergebnis.
- Walk-forward-Prüfung: Für jeden Abschnitt wird die Kombination gewählt, die vorher am besten war, und nur ihr Ergebnis
  im neuen Abschnitt gezählt – so hätte der Optimierer in Echtzeit abgeschnitten. Ist das nicht positiv, sagt die App es.
- „Übernehmen“ ist nur noch möglich, wenn die Kombination im Testabschnitt im Plus liegt.

**Limit-Kauf am Bid (Maker) – als Option, standardmäßig aus**
- Statt sofort zum Ask zu kaufen, legt der Bot eine virtuelle Kauforder auf den besten Bid. Ausgeführt gilt sie erst,
  wenn echte Verkäufe zu diesem Preis die Warteschlange davor und die eigene Menge abgearbeitet haben, der Bid darunter
  fällt oder der Ask sie erreicht. Teilausführungen werden vorsichtshalber nicht angerechnet.
- Eigene Maker-Gebühr (mit verbundenem Konto per „Kontosatz übernehmen“), Zeitlimit, Abbruch wenn der Kurs davonläuft,
  bei Schutzgrenzen, Anstiegssignal oder Abwärtstrend; Pausieren streicht wartende Orders. Die wartende Order steht in
  der Übersicht.
- Bleibt aus: Im Strategievergleich war der Limit-Kauf mit dem neuen Standard schlechter (−0,65 statt +0,35 USDT);
  ohne Mindest-Kaufabstand und mit echtem Spread war er besser (−13,4 statt −18,0 USDT). Wer ihn ausprobieren will:
  Schattenkonto mit der Vorlage „Aktuelle mit Limit-Kauf am Bid“.

**Sonstiges**
- Rauchtest in der CI erweitert: Replay, Walk-forward, Schattenkonten und Strategievergleich mit angenommenem und live
  gemessenem Spread.
- Ehrlich festgehalten: Die Walk-forward-Prüfung des Optimierers lag auch mit den neuen Standardwerten nicht im Plus
  (−0,12 USDT). Die App rät dann selbst, die Standardwerte zu behalten. Der Trendfilter bringt zusammen mit dem
  Mindest-Kaufabstand in dieser Woche kaum noch etwas (ein Trade Unterschied); er bleibt als Schutz an.
- Neue Tests für Walk-forward, Replay, Protokoll-Leser, Limit-Kauf und Schattenkonten.

## 4.1.1 – 11.10.2026

**Dringende Korrektur: Die App heißt jetzt „GoMining Bot Pro“ und wird nicht mehr mit der alten App verwechselt**
- Bis 4.1 hatte die App denselben Namen, dieselbe Bundle-ID, dasselbe Programm und dasselbe Symbol wie die alte
  „GoMining Bot“ 3.9. macOS hielt beide für dieselbe App: Beim Öffnen sprang oft die alte an, besonders wenn sie noch
  im Hintergrund oder in der Menüleiste lief.
- Neu: eigener Name **GoMining Bot Pro**, eigene Bundle-ID, eigenes Programm und ein neues Symbol (blau-violett mit
  Kerzen und goldenem „PRO“). Die alte App kann daneben liegen bleiben oder in den Papierkorb.
- Eigener Datenordner (`~/Library/Application Support/GoMining Bot Pro/`): Beim ersten Start werden Papierkonto, Verlauf,
  Sicherungen und Einstellungen aus dem bisherigen Ordner **kopiert**. Der alte Ordner bleibt unverändert, damit sich die
  beiden Apps nicht gegenseitig überschreiben.
- Der Installationsbefehl beendet eine laufende „GoMining Bot Pro“, ersetzt sie durch die neueste und startet sie;
  die alte „GoMining Bot“ fasst er nicht an. Beendet die App ein Signal (z. B. der Installationsbefehl), speichert sie
  vorher wie beim normalen Beenden.
- Der Updater erkennt die App im Archiv an der Bundle-ID statt am Dateinamen.
- Hinweis: Version 4.1 kann sich wegen der neuen Bundle-ID nicht selbst auf 4.1.1 aktualisieren. Einmal den
  Installationsbefehl von der Startseite benutzen; ab 4.1.1 laufen Updates wieder aus der App.

## 4.1 – 11.10.2026

**Updates direkt aus der App**
- Neue Versionen erscheinen als GitHub-Release; ein fester Link lädt immer die neueste App.
- Die App sucht selbst nach Updates (beim Start und alle 6 Stunden, abschaltbar), meldet sie per Banner und Mitteilung
  und installiert sie auf Knopfdruck: laden, Bundle-ID, Version und Signatur prüfen, austauschen, neu starten.
  Papierkonto, Einstellungen und Verlauf bleiben erhalten; schlägt etwas fehl, bleibt die alte App unverändert.
- Nach einem Update zeigt „Was ist neu“ einmalig die Neuerungen.

**Trendfilter (neu, standardmäßig an, abschaltbar)**
- Vergleicht einen schnellen und einen langsamen gleitenden Durchschnitt (30/120 Minuten). Im Abwärtstrend löst der
  Bot keine Neukäufe aus; Verkäufe und Stop-Loss laufen normal weiter. Anzeige des Trends in der Übersicht.
- Gemessen auf 7 Tagen echter GOMINING-Kerzen (Halten: −7,3 %): Ergebnis −3,88 statt −5,19 USDT, größter Rückgang
  6,43 statt 8,87 USDT, in beiden Hälften des Zeitraums mindestens gleich gut. Kein Gewinnversprechen – der Filter
  begrenzt vor allem Verluste in fallenden Phasen. Abschalten: Einstellungen → Trendfilter.
- Backtest und Optimierer berücksichtigen den Trendfilter; der Rauchtest vergleicht die Varianten auf echten Kerzen.

**Verlauf und Backtest**
- BingX liefert 1-Minuten-Kerzen nur 7 Tage zurück: bereits geladene Seiten bleiben erhalten, die App erklärt die
  Grenze und sammelt längeren Verlauf selbst (bis 45 Tage).
- Live-Kerzen passen sich der Länge des Trendfilters an.

**Zuverlässigkeit**
- Ist `simulation.json` nicht lesbar, nennt die Meldung den genauen Grund; die Originaldatei bleibt erhalten.

## 4.0 – 11.10.2026

- Quellcode der App aus Version 3.9 rekonstruiert und als Swift-Paket neu aufgebaut (Papierhandel, echte BingX-Daten).
- Kerzendiagramm mit Open/High/Low/Close, Volumen, Trade-Marken und Zeiträumen bis 4 Stunden.
- Anstiegs- und Fall-Erkennung über 6/8/20/60 Minuten; 10 Positionen als Standard.
- Backtest und Optimierer mit Trainings-/Testaufteilung; Statistik mit Gewinnquote, Profit-Faktor und Drawdown.
- Trailing-Stop, Zeit-Ausstieg, Abkühlphase, Drawdown-Grenze, Zusammenfassen von Kleinstresten.
- Robuster Livestream (Wiederverbindung, Wächter), REST nur als Ersatz; atomares Speichern mit Sicherungen.
- Menüleiste, Benachrichtigungen, Preisalarme, CSV-/JSON-Export, Autostart.
