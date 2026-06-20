# Kernel-Log-Analyse

## Zusammenfassung der Auffälligkeiten

- **ACPI-Fehler:** Mehrfache Einträge zu fehlgeschlagenen _OSC-Auswertungen für CPUs und Versuche mit _PDC.
- **GPT-Fehler:** Warnungen zur Korrektur von GPT-Fehlern mit GNU Parted.
- **RAS-Initialisierung:** Hinweise auf die Initialisierung des Collectors für korrigierbare Fehler.

## Detaillierte Ereignisse

- **2026-06-08:** Erste ACPI- und GPT-Fehler nach Systemstart.
- **2026-06-16 14:23:59:** Wiederholung der ACPI- und GPT-Fehler.
- **2026-06-16 19:52:45:** Erneute ACPI- und GPT-Fehler.

## Empfehlungen

- Überprüfen Sie die ACPI-Konfiguration und ggf. BIOS-Einstellungen.
- Verifizieren Sie die Partitionstabelle mit `gdisk` oder `parted`.
- Überwachen Sie weiterhin die RAS-Meldungen auf korrigierbare Speicherfehler.