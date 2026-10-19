#!/bin/bash
# Doppelklick-Starter fuer macOS. Sucht einen Python mit funktionierenden
# HTTPS-Zertifikaten (der python.org-Build hat oft keine), startet den Bot im
# Paper-Modus und oeffnet das Dashboard im Browser.
cd "$(dirname "$0")" || exit 1
exec bash ./launch.sh ${1+"$@"}
