# Disk Usage Alert Testbericht

## Testdatum
2024-05-21

## Testmethode
Ausführung des Skripts `disk_usage_alert.sh` mit der `--test` Flag zur Simulation verschiedener Speicherbelegungszustände.

## Testergebnisse

| Partition | Belegung | Status | Verhalten |
|-----------|----------|--------|-----------|
| /dev/test1 | 95% | KRITISCH | Korrekt erkannt, Alarm ausgegeben |
| /dev/test2 | 85% | WARNUNG | Korrekt erkannt, Warnung ausgegeben |
| /dev/test3 | 70% | OK | Korrekt erkannt, keine Warnung |

## Exit-Codes
- Exit-Code 2: Wird korrekt bei kritischem Zustand zurückgegeben

## Fazit
Die Testausführung hat bestätigt, dass die Warnlogik des Skripts `disk_usage_alert.sh` korrekt funktioniert. Alle drei Zustände (KRITISCH, WARNUNG, OK) wurden korrekt erkannt und die entsprechenden Meldungen ausgegeben. Der Test ist erfolgreich abgeschlossen.

## Empfehlung
Das Skript ist betriebsbereit und kann in den produktiven Einsatz überführt werden.