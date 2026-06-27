# Timeout-Konfiguration fuer externe Requests

## Problem
- HTTPS-Request zu ollama.com mit read timeout=300s blockierte den Agent >240s (Watchdog-Timeout).

## Ursache
- Kein lokaler Ollama-Server (Port 11434 nicht erreichbar).
- Externe HTTPS-Requests mit 300s Timeout koennen den Agent einfrieren.

## Loesung
- Alle externen HTTPS-Requests: max-timeout 30s (curl: --max-time 30)
- Shell-Befehle immer mit `timeout 30` absichern.
- Bei API-Abhaengigkeit: lokalen Fallback oder Cache nutzen.

## Status
- Netzwerk zu ollama.com: OK (HTTP 200, 0.17s)
- Keine Aenderung an Python-Dateien noetig (keine Timeout-Configs gefunden).
- Empfehlung: Bei zukuenftigen externen Requests immer --connect-timeout 5 --max-time 30 verwenden.
