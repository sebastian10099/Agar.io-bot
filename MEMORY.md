# Memory - Wissensbasis für zukünftige Aufgaben

## Hardware-Limitierungen

- System hat nur 15GB RAM
- Swap mit nur 99MB viel zu klein für große Modelle
- 67GB Modelle sind für CPU-only Inference zu groß und fehlschlagen - massive Diskrepanz
- Vor Treiberinstallation Hardware-Verfügbarkeit prüfen - lspci zeigt keine GPU und Host ist AMD, nicht Intel
- PyTorch + intel-extension Installation reicht nicht - ohne GPU-Treiber zeigt torch.xpu.is_available() False
- Modelle mit mehr als 10GB RAM-Anforderungen sind auf Systemen mit begrenztem Arbeitsspeicher nicht praktikabel
- Für zukünftige Modell-Tests ist besonders die Disk-Auslastung zu beachten, da diese mit 82% bereits kritisch ist

## Modell-Empfehlungen

- Kleinere Modelle wie phi3 bieten eine bessere Leistungsfähigkeit unter Ressourcenbeschränkungen und sollten bevorzugt werden
- command-a:111b ist 67GB - Start schlägt fehl, wahrscheinlich OOM (Out of Memory)
- Pull-Befehle für grosse Modelle timeouten bei 120s - Hintergrundprozess nötig
- Lange while-Schleifen mit sleep überschreiten Zeitlimits - besser kurze einzelne Prüfungen
- Selbst erstelltes Werkzeug 'wait_for_ollama_download': Wartet bis der Ollama-Modell-Download abgeschlossen ist, indem 'ollama list' wiederholt abgefragt wird bis das Modell erscheint

## Sicherheits-Lessons

- GitHub Tokens sollten niemals in Chats, Screenshots oder öffentlichen Dokumenten geteilt werden - Sicherheitsrisiko
- Ein GitHub-Token wurde versehentlich öffentlich geteilt. In solchen Fällen ist es wichtig, den Nutzer darauf hinzuweisen, den Token umgehend zu widerrufen und einen neuen zu erstellen, um Sicherheitsrisken zu minimieren
- Es ist wichtig, bei Sicherheitsvorfällen wie dem versehentlichen Offenlegen von Tokens umgehend zu handeln und klare, hilfreiche Hinweise zu geben
- Die Erstellung einer strukturierten Datei mit Warnung und Best Practices ist eine effektive Maßnahme, um den Nutzer zu sensibilisieren und zur sofortigen Korrektur zu bewegen

## Skript- und Entwicklungshinweise

- Skript in ~/bin kopieren reicht nicht - PATH muss ~/bin enthalten oder man nutzt vollständigen Pfad
- Skriptausgabe wurde abgeschnitten - vollständigen Durchlauf anzeigen lassen
- Das Skript funktioniert korrekt und zeigt alle gewünschten Systemressourcen an

## Lessons Learned (aus LESSONS_LEARNED.md)

### Rekursive Verzeichnisstrukturen

- Rekursive Verzeichnisstrukturen, wie z.B. ein Verzeichnis `agent_versions` innerhalb eines gleichnamigen Verzeichnisses, können in Skripten, die Dateien traversieren, zu unendlichen Schleifen führen.
- Solche Strukturen können auch bei der Ausführung von Tests zu Timeouts führen (Exit-Code 124).
- Um solche Probleme zu identifizieren, kann man mehrere Verschachtelungsebenen überprüfen. Oft wiederholt sich das Muster mit denselben Verzeichnisnamen.
- Um mit rekursiven Strukturen umzugehen, sollten Skripte so angepasst werden, dass sie bekannte problematische Verzeichnisse überspringen oder die Rekursionstiefe begrenzen.
- Es ist wichtig, Skripte in Umgebungen mit potenziellen rekursiven Strukturen zu testen, um Timeouts und Leistungsprobleme zu vermeiden.

### Performance-Optimierung

- Ein einzelner Prozess kann die CPU stark belasten (z.B. 94%). Dieser sollte der Hauptansatzpunkt für Leistungsverbesserungen sein.
- Die Verwendung von Hardlinks kann die Leistung bei Dateioperationen erheblich verbessern, insbesondere wenn viele identische Dateien kopiert werden.
- Kombinierte Ansätze aus Profiling und gezielter Optimierung führen zu messbaren Verbesserungen.
- Interaktive Profiling-Sitzungen funktionieren im Agent-Modus nicht, daher sollten nicht-interaktive Befehle verwendet werden.

### Sichere Skript-Entwicklung

- Es ist effizienter, direkt zu prüfen, ob eine Datei existiert und lesbar ist, bevor man versucht, sie auszuführen oder ihren Inhalt zu analysieren. Dies spart Zeit und vermeidet unnötige Schritte.
- Ein effektiver Einzeiler zur Prüfung ist: `test -r datei.sh && echo lesbar || echo nicht_lesbar`
- Modulare Struktur in Skripten (z.B. separate Module für Metriken, Benchmarks und Versionierung) erlaubt unabhängige Entwicklung und Testung.
- Die Integration von Health-Checks mit einfachen Schwellenwerten verbessert die Aussagekraft von Überwachungsskripten erheblich.
- Das Erstellen, Ausführen und Verifizieren einer Python-Datei funktioniert zuverlässig mit write_file, run_shell und read_file.
- Timeout-Probleme bei Skripten mit dem `timeout` Befehl begrenzen können auf unendliche Schleifen oder Leistungsengpässe im Code hinweisen.

## Sichere Systemdiagnose-Alternativen

- Wenn klassische Diagnosewerkzeuge wie `parted` oder `fdisk` blockiert sind, kann `cat /proc/partitions` als sichere Alternative verwendet werden, um Partitionstabellen anzuzeigen.
- Für die Analyse von Systemlogs ist `journalctl` eine zuverlässige Methode, insbesondere wenn andere Logging-Tools nicht verfügbar sind.
