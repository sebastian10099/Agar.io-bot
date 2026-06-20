#!/bin/bash

# file_permissions_check.sh - Überprüft Dateiberechtigungen im Workspace auf potenzielle Sicherheitsprobleme

WORKSPACE_DIR="$(pwd)"

# Welt-beschreibbare Dateien finden (nur aktuelle Ebene)
echo "Prüfe auf welt-beschreibbare Dateien..."
find "$WORKSPACE_DIR" -maxdepth 1 -type f -perm -002 2>/dev/null | while read file; do
  echo "[WARNUNG] Welt-beschreibbare Datei gefunden: $file"
done

# Welt-ausführbare Dateien finden (nur aktuelle Ebene)
echo "Prüfe auf welt-ausführbare Dateien..."
find "$WORKSPACE_DIR" -maxdepth 1 -type f -perm -001 2>/dev/null | while read file; do
  echo "[INFO] Welt-ausführbare Datei gefunden: $file"
done

# Dateien ohne Besitzer oder Gruppe finden (nur aktuelle Ebene)
echo "Prüfe auf Dateien ohne Besitzer oder Gruppe..."
find "$WORKSPACE_DIR" -maxdepth 1 -nouser -o -nogroup 2>/dev/null | while read file; do
  echo "[WARNUNG] Datei ohne Besitzer oder Gruppe gefunden: $file"
done

# Übermäßig restriktive Berechtigungen (nur Besitzer lesbar) (nur aktuelle Ebene)
echo "Prüfe auf stark restriktive Dateien..."
find "$WORKSPACE_DIR" -maxdepth 1 -type f -perm 0400 2>/dev/null | while read file; do
  echo "[INFO] Stark restriktive Datei (nur Besitzer lesbar): $file"
done

echo "Überprüfung abgeschlossen."
