# Änderungen

Jede Version erscheint automatisch als GitHub-Release mit der fertigen App (`GoMining-Bot.zip`).
Die Abschnitte hier werden als Release-Notizen und in der App unter „Was ist neu“ angezeigt.

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
