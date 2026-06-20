# Auth-Log-Analyse

## Zusammenfassung der Auffälligkeiten

- **Mehrfache SSH-Verbindungen von derselben IP:** Die IP-Adresse `187.127.72.126` hat sich mehrfach innerhalb kurzer Zeit mit dem System verbunden.
- **Gemischte Authentifizierungsmethoden:** Es werden sowohl Passwort- als auch Public-Key-Authentifizierung verwendet.
- **Fehlgeschlagene Authentifizierungsversuche:** Es gibt Einträge über fehlgeschlagene Passwortversuche.

## Detaillierte Ereignisse

- **2026-06-08:** Erste SSH-Verbindungen nach Systemstart.
- **2026-06-16 14:25:31:** Verbindung von `187.127.72.126` wurde geschlossen, bevor die Authentifizierung abgeschlossen war.
- **2026-06-16 14:25:36 - 14:26:01:** Mehrere fehlgeschlagene Passwortversuche von `187.127.72.126`, gefolgt von einer erfolgreichen Anmeldung.
- **2026-06-16 14:28:21 & 14:28:33:** Verbindungen von `178.196.102.70` wurden zurückgesetzt.
- **2026-06-16 14:29:07 - 14:34:45:** Mehrere erfolgreiche Public-Key-Authentifizierungen von `169.254.0.1`.

## Empfehlungen

- Überprüfen Sie, ob die IP-Adressen `187.127.72.126` und `178.196.102.70` vertrauenswürdige Quellen sind.
- Erwägen Sie die Deaktivierung der Passwort-Authentifizierung für SSH, wenn dies möglich ist, und verwenden Sie ausschließlich Public-Key-Authentifizierung.
- Implementieren Sie Fail2Ban oder eine ähnliche Lösung, um IP-Adressen mit mehreren fehlgeschlagenen Anmeldeversuchen automatisch zu sperren.
- Überprüfen Sie die SSH-Konfiguration auf unnötige oder unsichere Einstellungen.