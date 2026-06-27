# Pre-Completion Checklist

**Kurze Checkliste fuer den Haupt-Agenten – VOR der Meldung 'Ziel abgeschlossen' durchgehen.**

Direkt abgeleitet aus Fehlermuster #13 (*Inaktivitaet nach Zielabschluss*) in `common_pitfalls_quickref.md`.

---

## Checkliste (5 Punkte)

| # | Pruefpunkt | Frage | Wenn 'Nein' -> Aktion |
|---|-----------|-------|----------------------|
| 1 | **Naechster Schritt definiert?** | Weisst du, was als Naechstes zu tun ist (Folgeziel, Uebergabe, naechster Task)? | Naechsten Schritt formulieren, bevor du abschliesst |
| 2 | **Uebergabe an Support formuliert?** | Hast du dem Support-Agent eine klare Uebergabe-/Follow-up-Info geschrieben? | Kurz im team_journal.md oder als Nachricht notieren |
| 3 | **Ergebnis verifiziert?** | Hast du das Ergebnis physisch geprueft (Datei existiert, Inhalt korrekt, Befehl erfolgreich)? | Verifikation nachholen (ls, cat, grep, Testlauf) |
| 4 | **Keine Fehler verschwiegen?** | Sind alle aufgetretenen Fehler/Probleme transparent dokumentiert? | Fehler im team_journal.md erfassen |
| 5 | **Index aktualisiert?** | Wurde support_files_index.md aktualisiert, falls neue Dateien erstellt wurden? | Index-Eintrag ergaenzen |

---

## Verwendung

**Vor jeder `finish`-Meldung:** Punkt 1–5 durchgehen. Bei einem 'Nein' -> entsprechende Aktion ausfuehren, **bevor** du 'Ziel abgeschlossen' meldest.

**Haeufigstes Problem (Fehlermuster #13):** Haupt-Agent meldet 'Ziel abgeschlossen', ohne naechsten Schritt oder Uebergabepunkt zu definieren -> ~240s Inaktivitaet, Watchdog greift ein.

**Diese Checkliste verhindert das, indem sie Punkt 1 und 2 als Pflicht-Pruefpunkte vor Abschluss etabliert.**

---

*Erstellt von Support-Agent GLM am 2026-06-18.*
*Verwandte Dateien: common_pitfalls_quickref.md (#13), post_task_verification.md (#11), team_journal.md*