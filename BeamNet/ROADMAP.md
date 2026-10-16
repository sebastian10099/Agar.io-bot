# BeamNet – Roadmap

## Die nächsten 40 Punkte (Stand Werkzeug 1.34 / Plugin 1.19)

Reihenfolge = Priorität. Zuerst kommt, was bei 30+ Spielern gleichzeitig am meisten bringt. Danach folgen Community,
Rennen, Moderation und Betrieb. Punkte mit 🤖 eignen sich für die lokale KI (Werkstatt); ich prüfe dann nur noch.

**A. Stabil bei vielen Spielern**
1. [x] Bestenliste aus einem Index (`players-index.tsv`, schreibt der Wächter jede Minute) statt aus allen
       Spielerdateien: bei 10 000 Spielern 0,07 s statt 1,4 s je Liste. Ohne frischen Index liest das Plugin wie
       früher alle Dateien (Plugin 1.13, Werkzeug 1.21).
2. [x] Wochen- und Saisonwertung aus demselben Index (alle drei Listen teilen sich eine Lesung pro Minute).
3. [x] Gestaffeltes Speichern: Jeder Spieler hat seine eigene Sekunde in der Minute. Bei 64 Spielern sind es
       höchstens ein paar Dateien je Takt statt 64 auf einmal (Plugin 1.14).
4. [–] Lebenszeichen seltener schreiben: geprüft und verworfen. 12 Server schreiben je 4 kleine Dateien pro Minute,
       das ist vernachlässigbar, und Wächter, `/server` und Hänge-Erkennung brauchen ein frisches Lebenszeichen.
5. [ ] Wächter misst CPU und RAM je Server (systemd) und warnt bei Dauerlast über 90 %.
6. [ ] „Server voll“-Hilfe: Ein voller Server lässt niemanden mehr herein, das Plugin sieht diese Spieler also nicht.
       Machbar ist: `/server` und Statusseite markieren freie Server mit derselben Map, und bei 90 % Auslastung des
       ganzen Netzwerks geht eine Meldung an Discord/Telegram („Server 7 hat noch Platz“).
7. [x] Tägliche Sicherung der Spielerdaten (ab 4 Uhr, 14 Tage aufbewahrt) und `beamnet restore [datum]`.
       Gesichert werden nur reguläre Dateien, ohne Symlinks. Beim Zurückholen wird jedes Archiv-Mitglied geprüft und der
       bisherige Stand beiseitegelegt (Werkzeug 1.26).
8. [ ] Der doctor prüft die Größe von Server.log und Journal und richtet eine Protokoll-Rotation ein.
9. [ ] Lasttest in der CI mit echtem BeamMP-Server und vielen simulierten Spielerdateien.
10. [x] Der Wächter erkennt hängende Server: Der Dienst läuft, aber BeamNetCore meldet sich seit 3 Minuten nicht
        (`HANG_MIN`). Antwortet der Port auch nicht, folgt mit `AUTO_RESTART=1` ein Neustart. Antwortet er noch, gibt
        es nur eine Meldung, denn dann können die Spieler weiterfahren (Werkzeug 1.22).

**B. Community, Discord und Telegram**
11. [ ] Telegram-Bot antwortet auf `/online`, `/top`, `/rekord` und `/server` (der Wächter liest neue Nachrichten jede
        Minute).
12. [ ] Discord-Meldungen als Embeds (farbig, mit Feldern) statt reinem Text.
13. [x] Statusseite: Diagramm „Spieler je Stunde“ über die letzten 7 Tage, mit Tooltip je Stunde und
        Wochenspitze, ohne Skripte, hell/dunkel, fürs Handy. Steht auch in `api.json` (`peak.hours`, Werkzeug 1.23).
14. [x] Statusseite: Die Namen unter jedem Server sind auf die Profile verlinkt (Plugin 1.15 meldet die IDs mit;
        Gäste und Neue ohne Profil bleiben ohne Link; Werkzeug 1.24).
15. [ ] Profilseite: Kilometer je Woche als kleines Diagramm, letzte Rekorde.
16. [ ] Geplante Ansagen: `beamnet ansage "Event um 20 Uhr" --um 19:45`, auf allen Servern im Chat.
17. [x] XP-Event: `/event 2 2h` (Admins) gibt auf allen Servern doppelte XP (Faktor 1,5–5, höchstens 24 h). Start und
        Ende werden im Chat angesagt, beim Betreten gibt es einen Hinweis, Discord/Telegram bekommen eine Meldung, und es
        zählt in die Saison (Plugin 1.17, Werkzeug 1.33).
18. [x] Neue Spieler werden beim ersten Besuch begrüßt, bekommen die Regeln und werden den anderen vorgestellt. Dazu
        `/regeln` (englisch `/rules`); eigene Regeln stehen in `config.json` (Plugin 1.18).
19. [x] `/wo <Name>` (englisch `/where`): Auf welchem Server fährt ein Freund gerade? (Plugin 1.14)
20. [x] Wochenbericht montags: Sieger plus „📈 Die Woche: Fahrer · km · Spitze gleichzeitig (Tag, Uhrzeit) · neue
        Fahrer“ (Werkzeug 1.29). Aktivster Server und Map der Woche brauchen Wochenwerte je Server/Map im Plugin – später.

**C. Rennen und Spielspaß**
21. [ ] Geister-Vergleich: Zwischenzeiten auch gegen den Streckenrekord, nicht nur gegen die eigene Bestzeit.
22. [ ] Gemeinsame Rennen: `/rennen start <Strecke>` mit Countdown für alle Teilnehmer und Ergebnisliste.
23. [ ] Strecke der Woche: wechselt automatisch, Bonus-XP für Teilnahme und Top 3.
24. [ ] Blitzer: Höchstgeschwindigkeit je Map als eigene Bestenliste (mit Plausibilitätsprüfung).
25. [ ] Teams/Clans: `/team gründen|beitreten`, mit Team-Kilometern und Team-Wertung auf der Statusseite.
26. [ ] Neue Erfolge: alle Maps befahren, Nachtfahrer, 1000 km, 10 Rekorde, Marathon (2 h am Stück). 🤖
27. [ ] Saison-Titel: Die Top 3 der Saison bekommen einen Titel in `/stats` und auf der Statusseite.
28. [ ] Tagesaufgaben je Map, z. B. „fahre 10 km auf Utah“. 🤖

**D. Moderation und Sicherheit**
29. [ ] Zeitlich begrenzter Bann (`/ban <Name> 3d`), prüfen und übernehmen aus Werkstatt-Aufgabe 03. 🤖
30. [x] `/melden <Name> <Grund>` (englisch `/report`): sofort an Admins auf dem Server, über den Wächter an
        Discord/Telegram mit Server und Uhrzeit; höchstens alle 2 Minuten je Spieler; im Moderationsprotokoll.
31. [x] Admin-Benachrichtigung an Discord/Telegram bei Bann, Kick, Stummschaltung (auch Spam) und Verwarnung,
        aus dem Moderationsprotokoll (Werkzeug 1.27). Offen: auffällige Rekorde.
32. [ ] Wortfilter (einstellbare Liste), mit Verwarnung statt sofortigem Kick.
33. [x] Schutz gegen Verbindungs-Spam: Mehr als 6 Versuche pro Minute je IP oder Konto führen zu 2 Minuten Abweisung,
        mit Meldung an Discord/Telegram. Admins sind ausgenommen, Werte einstellbar (`joinLimit`, `joinWindowSec`,
        `joinBlockSec`) (Plugin 1.19).
34. [x] Dritte Sicherheitsprüfung durch einen Prüf-Agenten: 8 Funde + 5 Fehler, alle behoben (Werkzeug 1.30–1.32).

**E. Betrieb und Werkzeug**
35. [ ] `beamnet update` mit Rückfall: Meldet das Plugin nach dem Update Fehler, kommt automatisch die alte Version
        zurück.
36. [ ] Vorab-Update auf einem Server: `beamnet update --test 1`, die übrigen erst nach 10 Minuten ohne Fehler.
37. [ ] `metrics.txt` (Prometheus-Format) für Grafana: Spieler, km/h, Fehler und Neustarts je Server.
38. [ ] Werkstatt: Die CI prüft `lokal/*`-Branches automatisch (Tests, shellcheck) vor meiner Durchsicht. 🤖
39. [ ] README und Befehlshilfe auch auf Englisch (für internationale Admins). 🤖
40. [ ] Spieler-Hilfeseite auf der Statusseite: alle Chatbefehle, Ligen, Erfolge und Regeln. 🤖

Außerdem, sobald der Server-Zugang steht: `beamnet doctor` auf dem echten Server, Ausgabe prüfen, Reparaturen
übernehmen.

Erledigt (Werkzeug 1.30–1.32) – dritte Sicherheitsprüfung (Agent), alle Funde behoben:
- [x] root liest JSON im beammp-Ordner nie über Symlinks oder FIFOs (Statusseite, Saison, admin, bans, unban,
      Lebenszeichen, Index über Ordner-Deskriptor); Lebenszeichen mit `08` oder Zeit aus der Zukunft bringen den
      Wächter nicht mehr zum Absturz; Zeitlimit für Wächter- und Statusseiten-Dienst.
- [x] Datensicherung: keine harten Links (sonst Platte voll), Obergrenze 1 GB, keine Reste, nur Namen, die die
      Wiederherstellung annimmt; Wiederherstellung startet die Server bei jedem Fehler wieder.
- [x] Discord/Telegram: lange Meldungen werden geteilt (Discord-Grenze 2000 Zeichen), Spielertexte können in Discord
      keine getarnten Links bauen (Markdown maskiert, keine Vorschau); `beamnet setup` zeigt Token nicht mehr in `ps`.
- [x] Moderationsprotokoll: nach `restore` keine alte Geschichte noch einmal; eine Riesenzeile hält nicht auf.

Erledigt (Werkzeug 1.28) – Sicherheit:
- [x] Discord-Webhook-Adresse und Telegram-Token stehen nicht mehr auf der curl-Befehlszeile (die kann jeder Benutzer
      auf dem Server mit `ps` lesen, auch `beammp`), sondern gehen über eine Konfigurationsdatei (`-K`) an curl.
      Webhook-Adressen werden vollständig geprüft.

Erledigt (Werkzeug 1.20):
- [x] Wächter meldet auch per **Telegram** (Bot-Token und Chat-ID in `/etc/beamnet.conf`, Abfrage im Setup); alle
      Meldungen gehen an Discord und Telegram, je nachdem, was eingetragen ist.
- [x] **Wer ist online** mit Spielernamen je Server: alle 60 Minuten (`ONLINE_REPORT`), nur bei Änderung; Namen auch
      in der Rekordmeldung; `beamnet players` zeigt eine lesbare Übersicht statt JSON (`players json` = Rohdaten).
- [x] Lasttest im Plugin: 64 Spieler gleichzeitig kosten etwa 4 ms je Takt (Budget 1000 ms); alle km, Fahrzeiten und
      Dateien stimmen. Bestenliste bei 3000 Spielerdateien ≈ 0,4 s je Neuberechnung (alle 60 s) – siehe Punkt 1.

Erledigt (Werkzeug 1.19):
- [x] Spielerrekord: der Wächter zählt jede Minute die Spieler aller Server zusammen, meldet einen neuen Rekord nach
      Discord (ab 5 Spielern, höchstens alle 30 Minuten), hängt die Tagesspitze an die Tageszusammenfassung und zeigt
      den Rekord auf der Statusseite und in `api.json` (`peak`).

Erledigt (Werkzeug 1.18):
- [x] Discord-Tageszusammenfassung zählt einen Tag erst als erledigt, wenn es etwas zu melden gab.
- [x] Statusseite: `api.json` auch von anderen Webseiten abrufbar (CORS); strengere Prüfung der Spieler-IDs.

Erledigt (Plugin 1.12) – Gesamtprüfung des Plugins, von einem Agenten-Team umgesetzt:
- [x] Rundkurs-Rekorde nicht mehr erschummelbar: ein Lauf braucht eine Mindest-Fahrstrecke (80 % der Streckenlänge;
      die Länge kommt aus der Admin-Fahrt zwischen `/rennen neu` und `/rennen ziel`, sonst vom ersten gültigen Lauf,
      ohne Länge auf Rundkursen mindestens 400 m – `raceMinLapM`).
- [x] Lkw mit Anhänger oder mehrere Fahrzeuge zählen km nicht mehr doppelt; Fahrzeit nur, wenn man sich in den letzten
      30 s bewegt hat (kein XP fürs Parken).
- [x] Nicht lesbare Spielerdatei wird nie mehr überschrieben (Zuwächse bleiben erhalten); kaputte Datei wird als
      `<id>.json.kaputt-<Zeit>` aufgehoben. Sprachwahl springt nach Serverwechsel nicht mehr zurück.
- [x] Abstimmung: Stimmen verschwundener Spieler verfallen; gescheiterter Map-Wechsel wird nach 3 Minuten gemeldet.
- [x] Zwischenzeiten bei Rennen (Vergleich mit der eigenen Bestzeit alle 500 m, `raceSplitM`); keine Zwischenzeit
      hinter der Ziellinie.
- [x] Kalenderwoche ohne `%G/%V` (lief auf Windows-Servern nicht), Emojis in Namen auf dem Mac.

Erledigt (Werkzeug 1.17) – Sicherheitsprüfung der neuen Funktionen:
- [x] root folgt nie mehr Symlinks in Ordnern, die `beammp` gehören (vorher konnte ein manipuliertes Plugin über
      vorbereitete Symlinks root dazu bringen, fremde Dateien zu überschreiben): Lebenszeichen, Map-Umstellung,
      `install-core`, `admin`, `unban` und Ordnerrechte schreiben über einen Helfer mit exklusiven Zwischendateien;
      Sicherungen von Konfiguration und Plugin liegen nur noch in `/root/beamnet-backups` (je Server die letzten 20).
- [x] Discord: keine @-Erwähnungen, keine Steuerzeichen, kein ungeprüfter Text aus Abstimmungen.
- [x] Nicht umgesetzte Abstimmungen werden gemeldet; Rotation: doppelte Maps und „all“ abgelehnt.
- [x] Angriffstests mit Symlinks auf eine „Opferdatei“ (schlagen beim alten Werkzeug an).

Erledigt (Plugin 1.11, Werkzeug 1.15):
- [x] Kilometer je Map: das Plugin zählt sie pro Fahrer mit; Statusseite „Beliebteste Maps“, Profil mit Lieblingsmap
      und km je Map. Neue Datensätze laufen jetzt immer durch dieselbe Ergänzung wie geladene (kein Fehlen neuer Felder).

Erledigt (Werkzeug 1.14):
- [x] Tägliche Map-Rotation je Server (`beamnet rotation`): Wechsel ab `ROTATE_HOUR`, nur wenn der Server leer ist,
      einmal am Tag, Meldung nach Discord.

Erledigt (Werkzeug 1.13):
- [x] Statusseite: Profilseite je Fahrer (Level, Liga, Rang, km, Fahrzeit, Spitze, Saison, Erfolge, Maps, Bestzeiten);
      Namen in allen Tabellen verlinkt; Seiten verschwundener Fahrer werden entfernt.

Erledigt (Werkzeug 1.12):
- [x] Saisonsieger am 1. jedes Monats nach Discord (aus dem Saisonarchiv, sonst aus den Spielerdaten).

Erledigt (Plugin 1.10, Werkzeug 1.11):
- [x] Map-Abstimmung im Chat: `/vote map <Name>`, `/vote ja|nein`, Mehrheit der Spieler online; der Wächter prüft die
      Map gegen die erlaubte Liste, stellt um, startet neu und meldet nach Discord (höchstens ein Wechsel je Server in
      5 Minuten). Das Plugin bietet die Abstimmung nur an, wenn der Wächter läuft (Lebenszeichen `watch.json`).

Erledigt (Plugin 1.9, Werkzeug 1.10) – 8 Funde einer zweiten Code-Prüfung behoben, jeweils mit Test:
- [x] Update im laufenden Betrieb: Sitzungen der alten Version werden um neue Felder ergänzt (vorher: Fehler in jedem
      Takt); jeder Spieler wird im Takt einzeln abgesichert, Fehler landen gedrosselt im Log.
- [x] Erfolge und Tagesaufgabe werden erst beim Speichern gutgeschrieben – und nur, wenn die Datei sie noch nicht kennt
      (vorher: doppelte XP bei schnellem Serverwechsel).
- [x] Saison-XP als echter Zähler statt Startwert; nachträglich vergebene Erfolge zählen nicht für die Saison;
      Datensätze von 1.8 werden automatisch umgestellt; verpasstes Saisonarchiv wird stündlich nachgeholt.
- [x] Maps zählen erst ab 100 m Fahrt (vorher reichte kurzes Vorbeischauen für Erfolge und die Tagesaufgabe).
- [x] Werkzeug: `self-update` meldet kein „aktualisiert“ mehr, wenn das Ersetzen scheitert; `update` lädt das Plugin
      immer frisch von GitHub; Zahlen in `config.json` werden geprüft (ganze XP-Werte, sinnvolle Untergrenzen).

Erledigt (Plugin 1.8, Werkzeug 1.9):
- [x] Saisons: Monats-XP, `/saison`, Sieger und Archiv beim Monatswechsel, Statusseite.

Erledigt (Werkzeug 1.8):
- [x] `beamnet update` (Werkzeug + Plugin in einem Schritt, sicher gegen leere Downloads); `doctor` zeigt die
      Plugin-Version je Server und warnt bei unterschiedlichen Versionen.

Erledigt (Plugin 1.7):
- [x] Tagesaufgaben: täglich eine netzwerkweit gleiche Aufgabe mit Bonus-XP, `/aufgabe`, Hinweis bei der Begrüßung.

Erledigt (Plugin 1.6, Werkzeug 1.7):
- [x] Erfolge: 13 Stück (km, Fahrzeit, Tempo, Rennen, Rekorde, Maps, Level) mit Bonus-XP, `/erfolge`, Anzeige auf
      der Statusseite.

Erledigt (Plugin 1.5, Werkzeug 1.6) – 15 Funde einer unabhängigen Code-Prüfung behoben, jeweils mit Test:
- [x] Volle Platte: Dateien werden nur ersetzt, wenn das Schreiben vollständig geklappt hat (vorher: leere Spieler-
      oder Bann-Dateien möglich); Hilfsdateien je Server eindeutig.
- [x] Rundkurs: Wackeln an der Linie zählt nicht mehr als Runde (man muss sich mindestens 36 m entfernen).
- [x] `/ban Name`: genauer Name (auch offline) vor Teilname; Bann umfasst auch die IP (kein Zurückkommen als Gast).
- [x] Stummschaltung gilt auch für „/…“-Nachrichten, netzweit und nach Neu-Verbinden; `/mute 0.33` stürzt nicht mehr
      ab; Chat-Verarbeitung abgesichert; Befehls-Bremse; Wochenrangliste zwischengespeichert.
- [x] Werkzeug: Wartungsmarker endet, sobald der Server läuft; `watch test` meldet Fehler; Assistent läuft nach einem
      Fehler weiter und akzeptiert Kommas; `unban` mit kaputter Datei; „außerhalb von systemd“ über die cgroup;
      gemeinsamer Ordner immer mit Rechten für `beammp`; Sicherung im laufenden Betrieb.

Erledigt (Plugin 1.4):
- [x] Deutsch und Englisch je Spieler (`/lang`), Rundmeldungen in der Sprache jedes Empfängers, englische Befehlsnamen;
      Test prüft, dass jede Übersetzung dieselben Platzhalter hat.

Erledigt (Tests):
- [x] Integrationstest in der CI mit dem echten BeamMP-Server 3.9.3: Plugin lädt (Lua 5.3.5), onInit, Takt läuft,
      alle fünf BeamMP-Funktionen vorhanden, keine Fehler.

Erledigt (Werkzeug 1.5):
- [x] Einrichtungs-Assistent `beamnet setup`; `beamnet admin add/remove/list` (wirksam ohne Neustart).
- [x] Fehler behoben: `start/stop/restart all` brach ab, wenn im Server-Ordner ein Nicht-Server-Ordner (z. B. `shared`)
      als letzter lag – von einem neuen Test gefunden.

Erledigt (Plugin 1.3, Werkzeug 1.4):
- [x] Moderation: `/kick`, `/ban` (auf allen Servern, mit Dauer, Gäste per IP, auch offline), `/unban`, `/bans`,
      `/warn`, `/mute`, `/ansage` an alle Server, Spamschutz, Moderationsprotokoll; `beamnet bans/unban/modlog`.

Erledigt (Werkzeug 1.3):
- [x] Statusseite `beamnet web`: Server, wer fährt, Bestenliste, Wochenkilometer, Rekorde; jede Minute neu,
      kleiner abgeschotteter Webserver, hell/dunkel, fürs Handy.

Erledigt (Werkzeug 1.2):
- [x] Wächter `beamnet watch`: Ausfälle und Rückkehr melden, Discord-Webhook, optionaler Neustart (Limit 3/Stunde,
      nicht bei Wartung oder OpenClaw-Stopp), Wochensieger montags nach Discord.
- [x] Plugin prüft beim Start die BeamMP-Funktionen; `doctor` warnt bei zu alten Servern.

Erledigt (Plugin 1.2):
- [x] Rennen geben XP (Lauf, Bestzeit, Rekord) und zählen damit für Level und Liga.
- [x] Wochensieger: Verkündung beim Wochenwechsel, `/top vorwoche`.

Erledigt (Version 1.1):
- [x] `beamnet report`: Bericht zum Teilen (IP-Adressen und AuthKeys unkenntlich), `doctor` prüft, ob BeamNetCore
      auf jedem Server läuft und ob es Fehler meldet.
- [x] Zeitrennen: Strecken im Spiel anlegen (`/rennen neu`, `/rennen ziel`), Zeitmessung mit Spieluhr und
      Interpolation, Rundkurse, Rekordliste je Strecke, ungültig bei Reset/Teleport.

Erledigt (Version 1.0):
- [x] `beamnet`: Status, Diagnose (inkl. OpenClaw, cron, SSH-Schlüssel), Reparatur, Maps, Sicherung, Protokolle,
      Plugins ab-/einschalten, OpenClaw anhalten/fortsetzen, Selbst-Update – getestet in einer nachgebauten Umgebung.
- [x] Plugin BeamNetCore: Kilometer, Fahrzeit, XP/Level, Ligen, Bestenliste (gesamt, km, Woche), `/server`,
      serverübergreifend, getestet unter Lua 5.3, 5.4 und LuaJIT.

Als Nächstes (sobald der Server-Zugang wieder steht und die Ausgabe von `beamnet doctor` vorliegt):
- [ ] Auf dem echten Server prüfen: `beamnet doctor`, `beamnet fix`, BeamNetCore installieren, alte Plugins vergleichen.

Ideen: siehe „Die nächsten 40 Punkte“ ganz oben.
