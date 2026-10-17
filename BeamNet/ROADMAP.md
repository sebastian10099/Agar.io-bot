# BeamNet – Roadmap

## Runde 3: mehr Überblick für Spieler und Betreiber (Stand Werkzeug 2.04 / Plugin 1.83)

- [x] `/heute` im Spiel: Tagesaufgabe, XP-Event oder XP-Abend, Bonus-Map, Serie und Wochenziel auf einen Blick; `/event`
      zeigt die Bonus-Map jetzt auch während eines XP-Events (Plugin 1.79).
- [x] Statusseite: Tagesaufgabe unter „Demnächst“ (neben Bonus-Map und XP-Abend) und Bonus-Map in der Servertabelle
      (Werkzeug 2.00).
- [x] Telegram `/heute`: dieselbe Übersicht für den Chat; die Tagesaufgabe steht dafür im Lebenszeichen der Server
      (Plugin 1.80, Werkzeug 1.99).
- [x] Erfolge „Entdecker“ (25 km) und „Pionier“ (100 km) auf Bonus-Maps (Plugin 1.81).
- [x] Meilensteine an Discord/Telegram: Level 25/50/75/100 und 1.000/5.000/10.000/25.000 km, nur echte Fortschritte
      (`MILESTONE_NOTIFY=0` = aus; Plugin 1.82, Werkzeug 2.02).
- [x] Prüfung der Runde 3 (4 kleine Funde, behoben in Plugin 1.83 / Werkzeug 2.03): Meilensteine werden beim Speichern
      erkannt (kein doppelter Meilenstein bei schnellem Serverwechsel), Tagesaufgabe in `/heute` und auf der Statusseite
      nur in bekannter Form, `MODLOG_NOTIFY` und `MILESTONE_NOTIFY` unabhängig, Update-Hinweis erst nach erfolgreichem
      Senden gemerkt, `setMyCommands` höchstens einmal am Tag versucht.
- [x] Statusseite: Kopfzeile nennt die neuen Fahrer der letzten 7 Tage (Werkzeug 2.04).
- [x] `beamnet doctor`: Plugin-Version aller Server mit der Version des Werkzeugs vergleichen und auf `beamnet update`
      hinweisen (Werkzeug 1.98).

## Runde 2: mehr Spaß, mehr Plätze (Stand Werkzeug 1.97 / Plugin 1.78)

- [x] Freundesliste `/freund`: Nachricht, sobald ein Freund irgendwo im Netzwerk online kommt (Plugin 1.30).
- [x] Tages-Serie: jeden Tag ab 1 km fahren gibt ab Tag 2 Bonus-XP, bis +60 ab Tag 7; Erinnerung beim Betreten (1.31).
- [x] Vierte Sicherheitsprüfung: 14 Funde, alle bearbeitet (Plugin 1.32/1.35, Werkzeug 1.50/1.52).
- [x] Spielerplätze nach Beliebtheit: `beamnet slots`, der Wächter erhöht MaxPlayers für oft volle Server und die
      beliebtesten Maps automatisch, nur wenn der Server leer ist (Werkzeug 1.51).
- [x] Fahraufträge `/auftrag`: Krankenhaus, Schule, Feuerwache, Polizei, Taxi, Lieferungen – Orte legen Admins mit
      `/ort neu` an; Zeitlimit und XP nach Entfernung, nur echte Fahrt zählt (1.33), mit Abholung (1.36).
- [x] Wochenziel für alle `/ziel`: gemeinsam Kilometer sammeln, alle Mitfahrer bekommen Bonus-XP (1.34).
- [x] Aufträge-Bestenliste `/top auftraege`, Statusseite mit „Meiste Aufträge“ und Wochenziel-Balken (1.37 / 1.53).
- [x] Verfolgungsjagd `/fangen`: einer flüchtet, alle jagen ihn – XP fürs Fangen und Entkommen (1.38).
- [x] Fünfte Sicherheitsprüfung: 12 Funde (u. a. XP-Farming bei Aufträgen und Verfolgungsjagd), behoben (1.42 / 1.55).
- [x] `/resetspeed <Name>` für Admins (1.39), Aufträge in der Tageszusammenfassung (1.40), Tipps im Chat (1.41).
- [x] Duell `/duell <Name> <Strecke>` (1.44), Aufträge im Wochenbericht (1.43), Profilseite mit Aufträgen und
      Tages-Serie, Streckenseiten, Orte je Map auf der Statusseite (Werkzeug 1.56–1.59).
- [x] Wiederholungstäter an die Admins melden (`REPEAT_WARN`, 1.58), Sicherung wöchentlich probeweise
      wiederherstellen (`beamnet restore check`, 1.60).
- [x] Saison-Rückblick beim ersten Besuch im neuen Monat (1.45), Aufstiegsmeldungen in der Bestenliste (1.46).
- [x] Ansagen aus Telegram für `TELEGRAM_ADMINS` (1.61), „Demnächst“ auf der Statusseite (1.62), neue
      Streckenrekorde sofort an Discord/Telegram (1.63).
- [x] Sechste Sicherheitsprüfung: 10 Funde (Duell-Sperre, Rekord-Flut, Streckenseiten, Telegram-Feinheiten …), behoben
      (Plugin 1.47, Werkzeug 1.64).
- [x] `/hilfe` in Gruppen (1.48), „Neu seit deinem letzten Besuch“ (1.49), Einsteiger-Pfad `/start` (1.50),
      `beamnet doctor` meldet Maps ohne Orte für Aufträge.
- [x] Rennserien `/serie` (1.51) mit Bestenliste im Spiel und auf der Statusseite (1.65).
- [x] Ort-Vorschläge von Spielern `/ort vorschlag` (1.52, auch an Discord/Telegram), Einsatz-Alarm für alle (1.53),
      `tests/alle.sh` (alle Prüfungen, nur bei „ALLES GRÜN“ committen).
- [x] Siebte Sicherheitsprüfung: 9 Funde, behoben (Plugin 1.54). Einsatz-Alarm nur mit echter Fahrt (kein Teleport,
      kein Zurücksetzen, kein zweites Fahrzeug, Gäste zählen nicht mit). Ort-Vorschläge in eigener Datei mit fester
      Nummer, eine kaputte Orte-Datei wird nie überschrieben. Serien-XP nur für eine neue eigene Bestzeit, keine
      doppelten Strecken und Befehlsnamen. Beim Löschen einer Strecke verschwinden ihre Serien. Kein Einsteiger-Pfad
      für erfahrene Fahrer, deren Datei beim Beitritt nicht lesbar war. Nachprüfung (1.55): Serien-XP höchstens einmal
      am Tag je Serie und nur für eine um mindestens 2 % bessere Bestzeit; jedes Fahrzeug zählt beim Alarm für sich
      (ein geparktes Zweitauto stört nicht). Offene Vorschläge aus 1.52/1.53 (noch in `places/<Map>.json`) werden
      nicht übernommen und müssen neu vorgeschlagen werden.
- [x] Konvoi-Bonus `/konvoi`: zusammen fahren gibt Bonus-XP, `/konvoi` zeigt, wer in der Nähe ist; Konvoi-Kilometer
      im Profil der Statusseite (Plugin 1.56, Werkzeug 1.67).
- [x] Netzwerk-Übersicht alle 10 Minuten an Telegram/Discord: Spieler je Server (Konten mit Namen, Gäste gezählt),
      leere Server, Auslastung je Map mit 🔥 ab 80 %; auch auf `/server` im Telegram-Chat (Werkzeug 1.68).
- [x] Automatische XP-Abende `beamnet event auto fr,sa 20:00 2 2h` mit Ankündigung eine Stunde vorher (Spiel,
      Discord/Telegram); `beamnet event start|stop` von der Konsole (Werkzeug 1.70). Achte Prüfung (1.71): Map-Namen
      aus ServerConfig.toml werden bereinigt (ältere Bash hätten sie in Rechenausdrücken ausgeführt), Abende kurz nach
      Mitternacht schon am Vorabend angekündigt, Zeitumstellung und Schreibfehler gemeldet, Warten auf laufende Events.
- [x] Schicht: Aufträge in Folge (höchstens 3 min Pause) bringen beim 3., 5. und ab dem 10. Auftrag Bonus-XP,
      im Stundenlimit für Auftrags-XP (Plugin 1.64). Nachprüfung (1.65): nur Aufträge ab 1 km zählen, Abbrechen beendet
      die Serie, eine neue Stunde nicht. `/event` im Telegram-Chat (Stand für alle, Starten/Beenden für Admins,
      Werkzeug 1.74).
- [x] Aufträge auf jeder Map: Lieferpunkte aus echten Fahrten, wenn Admins (noch) keine Orte angelegt haben;
      Richtungshinweise unterwegs (Plugin 1.62).
- [x] Bonus-Map des Tages: die am wenigsten gefahrene Map (7 Tage) bekommt +50 % XP beim Fahren – verteilt die
      Spieler auf die Server (Werkzeug 1.86, Plugin 1.72); läuft sie nach Rotation/Abstimmung nirgends mehr, wird
      sofort neu gewählt (Werkzeug 1.87); steht auf der Statusseite, in der Netzwerk-Übersicht und bei `/event`
      (Werkzeug 1.88); `/server` im Spiel markiert die Server mit der Bonus-Map (Plugin 1.73).
      Prüfung: der Wächter merkt sich die Wahl selbst (nicht in der vom Dienst beschreibbaren Datei), wählt höchstens
      dreimal am Tag neu und läuft bei nur einer Map nicht jede Minute erneut los (Werkzeug 1.89).
- [x] Wochen-Rückblick: beim ersten Besuch in einer neuen Woche Kilometer und Platz der Vorwoche (Plugin 1.74).
- [x] `/woche` im Telegram-Chat: Top 5 der Kalenderwoche und Stand des Wochenziels (Werkzeug 1.90).
- [x] Tagesaufgabe „Fahre heute 3/5/8 km auf der Bonus-Map“ (`beamnet config aufgaben … bonus`, Plugin 1.75).
- [x] Prüfung von Wochen-Rückblick und `/woche`: Hinweis auf `/top vorwoche`, beide Rückblicke am Monatsanfang, Bonus-Map
      nach einem fehlgeschlagenen Schreibversuch erneut (Plugin 1.76, Werkzeug 1.91).
- [x] Sechste Sicherheitsprüfung: 9 Funde, behoben (Plugin 1.77, Werkzeug 1.92) – Lieferpunkte erst nach 300 m echter
      Fahrt seit Sprung/Zurücksetzen/neuem Fahrzeug (kein Teleport-Müll), Serverliste nur mit gültigen Einträgen (kein
      Chat-Text über gefälschte Statusdateien), Konvoi zählt höchstens die Strecke des Partners, Stundengrenzen für
      Aufträge und Konvoi gelten netzweit; ServerConfig.toml ohne Symlinks und mit Zeitlimit gelesen (eine
      untergeschobene FIFO hielt den Wächter an), Telegram-Flutschutz, Statusseite und `beamnet config` robust gegen
      unendliche Werte und Steuerzeichen, Namen in der Tageszusammenfassung ohne Zeilenumbrüche.
- [x] Update-Hinweis: der Wächter meldet einmal je neuer Version, dass `sudo beamnet update` etwas Neues bringt
      (installiert nichts selbst, `UPDATE_CHECK=0` = aus; Werkzeug 1.93).
- [x] Meldungen und Statusseite zeigen Bonus-Map und XP-Abend nur nach den eigenen Angaben des Wächters – vom Dienst
      geänderte Dateien im gemeinsamen Ordner können keine falschen Ankündigungen auslösen (Werkzeug 1.94).
- [x] Tageszusammenfassung nennt neue Spieler des Tages („· 2 neue Spieler 👋“, Werkzeug 1.95).
- [x] Wochen- und Saison-Rückblick werden sofort als gezeigt gespeichert – kein doppelter Rückblick bei schnellem
      Serverwechsel (Plugin 1.78).
- [x] Telegram-Befehlsliste trägt der Wächter selbst ein (`setMyCommands`, einmal je Version) – Telegram schlägt die
      Befehle beim Tippen von „/“ vor (Werkzeug 1.96).
- [x] `beamnet doctor` zeigt, wie lange ein Lauf des Wächters dauert, und warnt ab 40 s (Werkzeug 1.97).
- [x] `/plaetze` im Telegram-Chat: Auslastung der letzten 30 Tage je Server und Vorschlag der Plätze-Automatik
      (Werkzeug 1.85).
- [x] Bestenlisten-Index Format 4 mit Konvoi-km und gewonnenen Jagden: `/top konvoi`, `/top jagd` im Spiel, „Meiste
      Konvoi-km“ auf der Statusseite (Plugin 1.71, Werkzeug 1.84; ältere Plugins lesen dann wie früher alle Dateien).
- [x] `beamnet setup` fragt nach der Telegram-Admin-ID und bietet XP-Abende an (Werkzeug 1.83).
- [x] Hilfeseite: alle Bonus-XP-Quellen mit den echten Werten aus config.json (Aufträge/Schicht, Konvoi,
      Einsatz-Alarm, Jagd, Tages-Serie, Wochenziel, Rückkehrer, nächster XP-Abend; ausgeschaltete fehlen) (Werkzeug 1.82).
- [x] `beamnet config`: Spiel-Einstellungen ansehen und ändern ohne JSON (Typ- und Grenzprüfung, Tagesaufgaben wählen,
      `standard`); ein Test vergleicht die Standardwerte mit dem Plugin (Werkzeug 1.81).
- [x] Tageszusammenfassung nennt den nächsten XP-Abend, wenn er in höchstens 3 Tagen ist (Werkzeug 1.80).
- [x] `beamnet doctor` zeigt, was noch eingeschaltet werden kann: XP-Abende (mit Befehl), Netzwerk-Übersicht,
      fehlende Telegram-Admins für /ansage und /event (Werkzeug 1.79).
- [x] Gesamtprüfung der Runde (Plugin 1.70): ein Einsatz-Alarm im alten Format nach einem Live-Update ließ Positionen
      hängen und zählte falsche Kilometer – behoben (Position wird jetzt zuerst gemerkt, alter Alarm verworfen);
      nachträgliche Erfolge nur an den Spieler selbst; Abstiege werden nicht als Aufstieg gemeldet.
- [x] Tagesaufgabe „Erledige heute 2/3/5 Aufträge“ (`jobs`, in `challengeTypes` einschalten; Plugin 1.69).
- [x] Liga-Aufstiege an Discord/Telegram (Plugin 1.68, Werkzeug 1.78).
- [x] Rückkehrer-Bonus: nach mindestens 14 Tagen Pause einmal +50 XP beim Wiederkommen (Plugin 1.67).
- [x] `/spieler <Name>` im Telegram-Chat: Level, Liga, XP, Platz, Kilometer, Fahrzeit, Spitze, Aufträge (Werkzeug 1.76).
- [x] Nächster XP-Abend für alle sichtbar: `/event` im Spiel, Hinweis beim Betreten am selben Tag, „Demnächst“ auf
      der Statusseite (Plugin 1.66, Werkzeug 1.75).
- [x] „Wo ist was los?“: Wer fast allein auf einem Server fährt, bekommt den vollsten anderen Server genannt
      (Plugin 1.59).
- [x] Erfolge für Aufträge, Verfolgungsjagden und Konvois: 7 neue (Plugin 1.57, Statusseite 1.69). Die Erfolge der
      Werkstatt-Aufgabe 07 (5000 km, 50 Stunden, 50 Rennen, 5 Rekorde) folgten in Plugin 1.60.

## Die nächsten 40 Punkte (Stand Werkzeug 1.48 / Plugin 1.29)

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
5. [x] Der Wächter misst CPU und RAM je Server (systemd-Abrechnung) und warnt einmal bei Dauerlast (5 min über 90 %)
       oder hohem RAM, mit Entwarnung (Werkzeug 1.41).
6. [x] „Server voll“-Hilfe: `/server` markiert volle Server. Ab 90 % Auslastung des ganzen Netzwerks geht eine
       Meldung mit den freien Servern an Discord/Telegram (oder „Zeit für einen weiteren Server?“), mit Entwarnung
       (Plugin 1.23, Werkzeug 1.43).
7. [x] Tägliche Sicherung der Spielerdaten (ab 4 Uhr, 14 Tage aufbewahrt) und `beamnet restore [datum]`.
       Gesichert werden nur reguläre Dateien, ohne Symlinks. Beim Zurückholen wird jedes Archiv-Mitglied geprüft und der
       bisherige Stand beiseitegelegt (Werkzeug 1.26).
8. [x] Der doctor meldet sehr große `Server.log` (ab 200 MB) und eine fehlende Rotation. `beamnet fix` richtet
       logrotate ein: wöchentlich oder ab 100 MB, 4 Stände, copytruncate, sodass der Server weiterläuft (Werkzeug 1.42).
9. [x] Lasttest in der CI mit echtem BeamMP-Server: 5000 Spielerdateien und ein frischer Index. Das Plugin muss die
       Bestenliste über den Index lesen und daraus das Saisonarchiv bauen, ohne Fehler und mit laufendem Takt.
10. [x] Der Wächter erkennt hängende Server: Der Dienst läuft, aber BeamNetCore meldet sich seit 3 Minuten nicht
        (`HANG_MIN`). Antwortet der Port auch nicht, folgt mit `AUTO_RESTART=1` ein Neustart. Antwortet er noch, gibt
        es nur eine Meldung, denn dann können die Spieler weiterfahren (Werkzeug 1.22).

**B. Community, Discord und Telegram**
11. [x] Telegram-Bot antwortet im eingetragenen Chat auf `/online`, `/top`, `/rekord`, `/server` und `/hilfe`.
        Der Wächter holt jede Minute neue Nachrichten, beantwortet höchstens 5 pro Lauf und ignoriert fremde Chats
        (Werkzeug 1.35).
12. [–] Discord-Embeds: geprüft und zurückgestellt. Reiner Text lässt sich sicher teilen und maskieren, sieht in
        Telegram genauso aus, und Embeds haben eigene Grenzen (6000 Zeichen, 25 Felder), die Meldungen verschlucken
        können.
13. [x] Statusseite: Diagramm „Spieler je Stunde“ über die letzten 7 Tage, mit Tooltip je Stunde und
        Wochenspitze, ohne Skripte, hell/dunkel, fürs Handy. Steht auch in `api.json` (`peak.hours`, Werkzeug 1.23).
14. [x] Statusseite: Die Namen unter jedem Server sind auf die Profile verlinkt (Plugin 1.15 meldet die IDs mit;
        Gäste und Neue ohne Profil bleiben ohne Link; Werkzeug 1.24).
15. [x] Profilseite: Diagramm „Kilometer je Woche“ für die letzten 12 Wochen. Das Plugin führt dafür den
        Wochenverlauf (Plugin 1.29, Werkzeug 1.48).
16. [x] Geplante Ansagen: `/ansage 19:45 Text` im Spiel oder `beamnet ansage 19:45 Text` auf der Konsole. Alle Server
        sagen sie zur Uhrzeit an, auch nach einem Neustart; `beamnet ansage` zeigt die geplanten (Plugin 1.22, Werkzeug 1.40).
17. [x] XP-Event: `/event 2 2h` (Admins) gibt auf allen Servern doppelte XP (Faktor 1,5–5, höchstens 24 h). Start und
        Ende werden im Chat angesagt, beim Betreten gibt es einen Hinweis, Discord/Telegram bekommen eine Meldung, und es
        zählt in die Saison (Plugin 1.17, Werkzeug 1.33).
18. [x] Neue Spieler werden beim ersten Besuch begrüßt, bekommen die Regeln und werden den anderen vorgestellt. Dazu
        `/regeln` (englisch `/rules`); eigene Regeln stehen in `config.json` (Plugin 1.18).
19. [x] `/wo <Name>` (englisch `/where`): Auf welchem Server fährt ein Freund gerade? (Plugin 1.14)
20. [x] Wochenbericht montags: Sieger plus „📈 Die Woche: Fahrer · km · Spitze gleichzeitig (Tag, Uhrzeit) · neue
        Fahrer“ (Werkzeug 1.29). Aktivster Server und Map der Woche brauchen Wochenwerte je Server/Map im Plugin – später.

**C. Rennen und Spielspaß**
21. [x] Zwischenzeiten auch gegen den Streckenrekord: „Zwischenzeit 2: 0:51.3 (−0.4 s, Rekord +1.2 s)“; ohne eigene
        Bestzeit nur der Rekord-Abstand (Plugin 1.24).
22. [x] Gruppenrennen: `/rennen gruppe <Strecke>` und `/rennen mit`, mit Countdown, Fehlstart, Zieleinlauf für alle,
        Ergebnisliste und Bonus-XP für die Top 3 (Plugin 1.27).
23. [x] Strecke der Woche: wechselt automatisch und ist auf allen Servern dieselbe. Der erste gültige Lauf der Woche
        bringt 50 Bonus-XP; sie steht in `/rennen`, beim Betreten der Map und auf der Statusseite (Plugin 1.26,
        Werkzeug 1.46). Später: Bonus für die Top 3.
24. [x] Bestenliste Höchstgeschwindigkeit: `/top speed` im Spiel und „Schnellste Fahrer“ auf der Statusseite.
        Die Messung filtert Sprünge über 540 km/h, die Seite zeigt nichts über 600 km/h (Plugin 1.21, Werkzeug 1.39).
        Später: je Map.
25. [x] Teams: `/team gründen|beitreten|verlassen|liste`, netzweit in `teams.json`, Team-Kilometer = Summe der
        Mitglieder, Rangliste im Spiel und auf der Statusseite (Plugin 1.28, Werkzeug 1.47).
26. [x] Neue Erfolge (5000 km, 50 Stunden, 50 Rennen, 5 Rekorde) – Aufgabe 07; da die lokale KI sie nicht übernommen
       hat, selbst umgesetzt (Plugin 1.60).
27. [x] Saison-Titel: Die Top 3 jeder Saison tragen „Saisonsieger / Saison-Zweiter / Saison-Dritter <Monat>“ in
        `/stats` und auf ihrer Profilseite (Plugin 1.25, Werkzeug 1.44).
28. [x] Tagesaufgabe „X km auf einer Map“ (`mapkm`, in `challengeTypes` einschalten) – Aufgabe 09, selbst umgesetzt
       (Plugin 1.61).

**D. Moderation und Sicherheit**
29. [~] Zeitlich begrenzter Bann gibt es schon (`/ban <Name> 2h`, auch `m`/`d`). Feinschliff (`2H`, `1w`, riesige
        Zahlen) liegt als Aufgabe 03 bei der lokalen KI. 🤖
30. [x] `/melden <Name> <Grund>` (englisch `/report`): sofort an Admins auf dem Server, über den Wächter an
        Discord/Telegram mit Server und Uhrzeit; höchstens alle 2 Minuten je Spieler; im Moderationsprotokoll.
31. [x] Admin-Benachrichtigung an Discord/Telegram bei Bann, Kick, Stummschaltung (auch Spam) und Verwarnung,
        aus dem Moderationsprotokoll (Werkzeug 1.27). Offen: auffällige Rekorde.
32. [x] Wortfilter: Die Nachricht wird nicht gesendet und der Spieler bekommt einen Hinweis; beim dritten Mal in
        10 Minuten folgen 5 Minuten Stummschaltung mit Meldung. Die Liste ist einstellbar und erkennt Ersatzzeichen
        (Plugin 1.20).
33. [x] Schutz gegen Verbindungs-Spam: Mehr als 6 Versuche pro Minute je IP oder Konto führen zu 2 Minuten Abweisung,
        mit Meldung an Discord/Telegram. Admins sind ausgenommen, Werte einstellbar (`joinLimit`, `joinWindowSec`,
        `joinBlockSec`) (Plugin 1.19).
34. [x] Dritte Sicherheitsprüfung durch einen Prüf-Agenten: 8 Funde + 5 Fehler, alle behoben (Werkzeug 1.30–1.32).

**E. Betrieb und Werkzeug**
35. [x] Rückfall beim Update: Meldet sich der Testserver nicht mit der neuen Version, kommt dort automatisch die alte
        zurück und das Update bricht ab (Werkzeug 1.38).
36. [x] Update zuerst auf einem Server: dem laufenden mit den wenigsten Spielern. Die übrigen folgen erst, wenn er sich
        mit der neuen Version meldet (bis 60 s) (Werkzeug 1.38).
37. [x] `metrics.txt` im Prometheus-Format auf der Statusseite: Spieler und Plätze je Server, gesamt, Rekord,
        registrierte Fahrer, Kilometer (Werkzeug 1.45).
38. [x] Die CI läuft bei jedem Push auf jeden Branch mit BeamNet-Änderungen, also auch auf `lokal/*` der Werkstatt.
        Ich sehe das Ergebnis vor der Durchsicht.
39. [x] Englische Kurzanleitung `README.en.md` – Aufgabe 08, selbst umgesetzt (mit den neuen Befehlen).
40. [x] Hilfeseite `hilfe.html` mit Regeln (auch eigene aus `config.json`), allen Chat-Befehlen, XP-Regeln, Ligen
        und Erfolgen, verlinkt von der Statusseite (Werkzeug 1.37).

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
