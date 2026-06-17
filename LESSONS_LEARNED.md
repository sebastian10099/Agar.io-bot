# Lessons Learned

## Rekursive Verzeichnisstrukturen

- Rekursive Verzeichnisstrukturen, wie z.B. ein Verzeichnis `agent_versions` innerhalb eines gleichnamigen Verzeichnisses, können in Skripten, die Dateien traversieren, zu unendlichen Schleifen führen.
- Solche Strukturen können auch bei der Ausführung von Tests zu Timeouts führen (Exit-Code 124).
- Um solche Probleme zu identifizieren, kann man mehrere Verschachtelungsebenen überprüfen. Oft wiederholt sich das Muster mit denselben Verzeichnisnamen.
- Um mit rekursiven Strukturen umzugehen, sollten Skripte so angepasst werden, dass sie bekannte problematische Verzeichnisse überspringen oder die Rekursionstiefe begrenzen.
- Es ist wichtig, Skripte in Umgebungen mit potenziellen rekursiven Strukturen zu testen, um Timeouts und Leistungsprobleme zu vermeiden.

## Performance-Optimierung

- Ein einzelner Prozess kann die CPU stark belasten (z.B. 94%). Dieser sollte der Hauptansatzpunkt für Leistungsverbesserungen sein.
- Die Verwendung von Hardlinks kann die Leistung bei Dateioperationen erheblich verbessern, insbesondere wenn viele identische Dateien kopiert werden.
- Kombinierte Ansätze aus Profiling und gezielter Optimierung führen zu messbaren Verbesserungen.
- Interaktive Profiling-Sitzungen funktionieren im Agent-Modus nicht, daher sollten nicht-interaktive Befehle verwendet werden.

## Sichere Skript-Entwicklung

- Es ist effizienter, direkt zu prüfen, ob eine Datei existiert und lesbar ist, bevor man versucht, sie auszuführen oder ihren Inhalt zu analysieren. Dies spart Zeit und vermeidet unnötige Schritte.
- Ein effektiver Einzeiler zur Prüfung ist: `test -r datei.sh && echo lesbar || echo nicht_lesbar`
- Modulare Struktur in Skripten (z.B. separate Module für Metriken, Benchmarks und Versionierung) erlaubt unabhängige Entwicklung und Testung.
- Die Integration von Health-Checks mit einfachen Schwellenwerten verbessert die Aussagekraft von Überwachungsskripten erheblich.
- Das Erstellen, Ausführen und Verifizieren einer Python-Datei funktioniert zuverlässig mit write_file, run_shell und read_file.
- Timeout-Probleme bei Skripten mit dem `timeout` Befehl begrenzen können auf unendliche Schleifen oder Leistungsengpässe im Code hinweisen.