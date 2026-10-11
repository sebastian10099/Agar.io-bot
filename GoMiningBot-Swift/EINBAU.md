# Einbau in deine GoMining-Bot-App (Swift / SwiftUI, Xcode)

Diese Dateien sind passend zu den Typen aus deiner App `GoMining Bot.app` 3.5 geschrieben
(`PriceCandle`, `BotSettings.maxOpenPositions`, `PositionLot`, BingX-Kline).
Ich hatte nur die fertig kompilierte App, nicht deinen Xcode-Quellcode. Deshalb sind die
Dateien **neu und eigenstaendig**, und die Schritte unten sagen dir genau, wo du die
vier bestehenden Stellen anfasst.

**Was geprueft ist:** `PriceCandle.swift`, `MoveDetector.swift` und `PositionLimit.swift` habe ich
mit Swift 5.10.1 (Linux) uebersetzt und die 13 Tests in `Tests/MoveDetectorTests.swift` laufen
durch (0 Fehler). **Was nicht geprueft ist:** `CandleChartView.swift` (SwiftUI gibt es nur auf dem Mac)
und die Verbindung zu deiner `BotEngine`/`BingXPublicAPI`. Bau also einmal in Xcode (Cmd+B)
und lass die Tests laufen (Cmd+U).

## 0. Dateien ins Projekt

In Xcode die vier Dateien aus `Sources/` in deine App ziehen (Haken bei Target *GoMiningBot*),
`Tests/MoveDetectorTests.swift` in dein Test-Target (legst du an, falls es noch keins gibt:
File -> New -> Target -> Unit Testing Bundle).

| Datei | Zweck |
|---|---|
| `PriceCandle.swift` | **ersetzt** deine bisherige `PriceCandle` (jetzt mit open/high/low) |
| `MoveDetector.swift` | Anstieg/Fall in 6/8/20/60 min, Signal zum Verkaufen/Kaufen |
| `CandleChartView.swift` | Kerzen-Chart gruen/rot, ganzer Verlauf im Bild |
| `PositionLimit.swift` | 10 statt 4 Positionen |

## 1. Alte `PriceCandle` loeschen

Such in deinem Projekt `struct PriceCandle` und **loesche die alte Definition**
(sonst "invalid redeclaration"). Der alte Aufruf `PriceCandle(openedAt:close:volume:)`
bleibt gueltig. Alte gespeicherte Daten (Marktprotokoll, Zustand) laden weiter, fehlende
Werte werden mit dem Schlusskurs gefuellt.

## 2. Kerzen mit open/high/low von BingX einlesen

Das ist der eigentliche Grund, warum dein Chart keine echten Kerzen zeigen konnte:
bisher wurde nur `close` uebernommen. Such in `BingXPublicAPI` die Stelle, die
`/openApi/spot/v2/market/kline` auswertet und `PriceCandle(openedAt:close:volume:)` baut,
und ersetze sie durch:

```swift
// row ist eine Zeile der Kline-Antwort: [openTime, open, high, low, close, volume, ...]
if let candle = PriceCandle(bingXRow: row) { candles.append(candle) }
```

* Pruefe in einer echten Antwort, dass die Reihenfolge `open, high, low, close` ist
  (steht in der BingX-Doku zu `kline`). Falls deine App die Zeit bisher in
  **Millisekunden** speichert, nimm `PriceCandle(bingXRow: row, openedAtDivisor: 1)`.
* Kommt die Antwort als Objekte statt als Listen, nimm den Initialisierer
  `PriceCandle(openedAt:open:high:low:close:volume:)`.

## 3. Chart austauschen

Dort, wo dein Dashboard `PriceChart(...)` anzeigt:

```swift
let detector = MoveDetector()
CandleChartView(candles: snapshot.candles,
                moves: detector.analyze(snapshot.candles),
                entryPrices: state.lots.map(\.buyPriceUSDT))
    .frame(minHeight: 260)
```

## 4. Anstieg/Fall in die Engine einbauen

In `BotEngine`, an der Stelle, wo pro Marktdurchlauf entschieden wird (dort stehen
`maxSpreadBps`, `minSecondsBetweenTrades`, `minNetProfitBps`), **zusaetzlich** abfragen:

```swift
let detector = MoveDetector()
let move = detector.signal(snapshot.candles)   // nil = kein Signal

// Kauf nur, wenn dein bisheriges Kaufsignal gilt UND kein Anstieg gerade laeuft:
//   Anstieg erkannt (move?.action == .sell)  -> NICHT kaufen (nicht in den Pump hinein)
//   Fall + gruene Kerze (move?.action == .buy) -> Kauf bevorzugt/erlaubt
// Verkauf (Teilverkauf nach Orderbuchtiefe, Gewinnmitnahme):
//   move?.action == .sell  -> offene Lots verkaufen, wenn dein minNetProfitBps erreicht ist
```

Wichtig: `.sell` bedeutet im **Spot** "Bestand abbauen", nicht "shorten".
BingX Spot kann nicht leerverkaufen. Echte Shorts brauchen Futures, das ist eine andere API,
und ich habe es bewusst nicht eingebaut. Schreib mir, wenn du das willst.

Alle deine vorhandenen Schutzgrenzen (Spread, Tagesverlustgrenze, Stop-Loss, Mindestmenge,
Orderbucheinfluss) gelten weiter. Das Signal ist nur ein zusaetzlicher Filter.

## 5. 10 Positionen

Ueberall dort, wo die Engine die Zahl offener Lots prueft, nur noch dieses Limit benutzen:

```swift
guard PositionLimit.canOpenAnother(openCount: state.lots.count,
                                   limit: settings.openPositionLimit) else { /* "Positionen belegt" */ return }
```

Und beim Laden gespeicherter Einstellungen einmal:

```swift
settings.maxOpenPositions = PositionLimit.migrated(settings.maxOpenPositions)
```

Das macht aus dem alten Standard **4 -> 10**, laesst aber eine bewusst gesetzte andere
Zahl (z.B. 2 oder 7) unveraendert. Im Einstellungs-Bereich "Gleichzeitig offene Positionen"
den Stepper auf mindestens `1...20` stellen.

**Kapital pruefen:** `maxPositionFraction` und `maxTradeUSDT` begrenzen, wie viel pro Position
eingesetzt wird. Bei 10 Positionen muss `10 x Einsatz` in dein virtuelles Guthaben (1.000 USDT)
passen, sonst bleibt die 10. Position wegen "zu wenig USDT" gesperrt.

## 6. Pruefen

1. Cmd+B baut ohne Fehler (bei Fehlern: Meldung an mich schicken, ich passe es an).
2. Cmd+U: 13 Tests (Erkennung, Kerze einlesen, alte Daten laden, Limit 10).
3. Erst im **Papierhandel** laufen lassen und im Chart pruefen, ob Verkauf nach
   Anstiegen und Kauf nach Faellen passt. Echtgeld erst danach.
