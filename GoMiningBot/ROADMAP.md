# Roadmap

Arbeitsliste für die laufende Weiterentwicklung. Updates erscheinen **gebündelt**: Jede neue Version enthält mehrere
zusammengehörige, getestete Verbesserungen (mindestens drei spürbare Punkte oder ein großes Feature plus Ergänzungen),
keine Einzelkleinigkeiten. Erledigte Punkte wandern ins [CHANGELOG](CHANGELOG.md).

Grundsätze, die für jede Version gelten:
- Papierhandel bleibt Papierhandel: keine echten Orders, keine Shorts, keine Hebel.
- Jede Änderung an der Strategie wird mit echten BingX-Kerzen belegt (Rauchtest „Strategievergleich“), nicht nach Gefühl.
- Alle Tests grün, Rauchtest gegen die Live-Schnittstelle bestanden, Bilder der Oberfläche geprüft – erst dann Release.
- Bestehende Daten (`simulation.json`, Einstellungen, Schlüsselbund) werden immer übernommen.
- Ausnahme vom Bündeln: dringende Fehlerbehebungen (z. B. App startet nicht) erscheinen sofort als x.y.z-Version.

## Paket 4.2 – Realistischere Simulation und Auswertung
- [ ] Backtest mit echten Spreads und Orderbuchtiefen aus dem eigenen Marktprotokoll (Replay statt Annahmen).
- [ ] Walk-forward-Optimierung über mehrere Zeitfenster mit Robustheitswert; „Übernehmen“ nur bei Plus im Test.
- [ ] Limit-Orders am Bid als Option (Maker-Gebühr, Füllwahrscheinlichkeit aus echten Trades) statt nur Taker.
- [ ] Schattenkonten: mehrere Einstellungs-Profile laufen parallel im Papierhandel und werden live verglichen.

## Paket 4.3 – Bedienung
- [ ] Diagramm: Zoomen und Verschieben, frei wählbarer Zeitraum, Tooltips an den Trade-Marken.
- [ ] Profile: Einstellungen speichern, laden, teilen; Vorlagen „vorsichtig / ausgewogen / aktiv“.
- [ ] Tages- und Wochenbericht (HTML/PDF) und Tageszusammenfassung als Mitteilung.
- [ ] Oberfläche auch auf Englisch; Dunkelmodus in den CI-Bildern prüfen.

## Paket 4.4 – Zuverlässigkeit und Daten
- [ ] Selbstdiagnose mit Hinweis bei hängenden Daten, deutlicher Offline-Modus.
- [ ] Langzeittest (Speicher und CPU über Stunden) in der CI, Fuzz-Tests für die Parser.
- [ ] Sicherungen importieren; Verlauf über Monate (Datenbank statt JSON, wenn nötig).

## Später
- [ ] Weitere BingX-Spot-Paare wählbar, mehrere Bots gleichzeitig.
- [ ] Kontrollkurs aus einer zweiten Quelle zur Plausibilisierung.
