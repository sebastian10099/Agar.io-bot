import SwiftUI

/// Kerzen-Chart (gruen/rot) fuer macOS. Ersetzt/ergaenzt dein `PriceChart`.
///
///     CandleChartView(candles: model.snapshot?.candles ?? [],
///                     moves: detector.analyze(candles),
///                     lots: state.lots)
///         .frame(minHeight: 260)
///
/// Der Preisbereich wird aus Hoch/Tief ALLER Kerzen (plus Kauflinien) berechnet,
/// darum bleibt der ganze Kursverlauf im Bild - auch die Dochte.
struct CandleChartView: View {
    var candles: [PriceCandle]
    var moves: [Move] = []
    /// Offene Positionen: werden als Einstiegslinie gezeichnet.
    var entryPrices: [Double] = []
    var candleMinutes = 1

    @State private var hoverX: CGFloat?

    private let up = Color(red: 0.13, green: 0.77, blue: 0.37)
    private let down = Color(red: 0.94, green: 0.27, blue: 0.27)
    private let axisWidth: CGFloat = 70
    private let bottomHeight: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size) }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p): hoverX = p.x
                        case .ended: hoverX = nil
                        }
                    }
                if let tip = tooltip(width: geo.size.width) {
                    Text(tip.text)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .offset(x: tip.x, y: 8)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay {
            if candles.isEmpty {
                Text("Keine Kurskerzen").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Geometrie

    private func priceRange() -> (lo: Double, hi: Double) {
        var lo = candles.map(\.low).min() ?? 0
        var hi = candles.map(\.high).max() ?? 1
        for p in entryPrices { lo = min(lo, p); hi = max(hi, p) }
        if hi == lo { hi *= 1.001; lo *= 0.999 }
        let pad = (hi - lo) * 0.08
        return (lo - pad, hi + pad)
    }

    private func niceStep(range: Double, ticks: Int) -> Double {
        let raw = range / Double(max(1, ticks))
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let nice: Double = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10
        return nice * mag
    }

    private func priceText(_ p: Double) -> String {
        let digits = p >= 1000 ? 2 : p >= 1 ? 4 : p >= 0.01 ? 6 : 8
        return p.formatted(.number.precision(.fractionLength(min(digits, 2)...digits)))
    }

    private func timeText(_ t: Double) -> String {
        Date(timeIntervalSince1970: t).formatted(.dateTime.hour().minute())
    }

    // MARK: - Zeichnen

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard let last = candles.last else { return }
        let (lo, hi) = priceRange()
        let left: CGFloat = 4, top: CGFloat = 8
        let plotW = size.width - left - axisWidth
        let plotH = size.height - top - bottomHeight
        guard plotW > 10, plotH > 10 else { return }
        let slot = plotW / CGFloat(candles.count)
        let bodyW = max(1, min(14, slot * 0.7))
        func y(_ v: Double) -> CGFloat { top + CGFloat((hi - v) / (hi - lo)) * plotH }
        func x(_ i: Int) -> CGFloat { left + slot * (CGFloat(i) + 0.5) }

        // Raster + Preisachse
        let step = niceStep(range: hi - lo, ticks: max(3, Int(size.height / 60)))
        var v = (lo / step).rounded(.up) * step
        while v <= hi {
            var line = Path()
            line.move(to: CGPoint(x: left, y: y(v)))
            line.addLine(to: CGPoint(x: left + plotW, y: y(v)))
            ctx.stroke(line, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)
            ctx.draw(Text(priceText(v)).font(.system(size: 10)).foregroundColor(.secondary),
                     at: CGPoint(x: left + plotW + 6, y: y(v)), anchor: .leading)
            v += step
        }

        // Zeitachse (von rechts, nichts ragt links aus dem Bild)
        let every = max(1, Int((70 / slot).rounded(.up)))
        var i = candles.count - 1
        while i >= 0 {
            if x(i) - 18 < left { break }
            ctx.draw(Text(timeText(candles[i].openedAt)).font(.system(size: 10)).foregroundColor(.secondary),
                     at: CGPoint(x: x(i), y: size.height - bottomHeight + 6), anchor: .top)
            i -= every
        }

        // Analyse-Fenster (6/8/20/60 min) als Schattierung von rechts
        for (k, m) in moves.sorted(by: { $0.windowMinutes > $1.windowMinutes }).enumerated() {
            let n = min(candles.count, Int((Double(m.windowMinutes) / Double(max(1, candleMinutes))).rounded(.up)))
            let x0 = left + slot * CGFloat(candles.count - n)
            let color: Color = m.triggered ? (m.direction == .up ? up : down) : .gray
            ctx.fill(Path(CGRect(x: x0, y: top, width: left + plotW - x0, height: plotH)),
                     with: .color(color.opacity(m.triggered ? 0.10 : 0.04)))
            ctx.draw(Text("\(m.windowMinutes)m").font(.system(size: 10)).foregroundColor(.secondary),
                     at: CGPoint(x: x0 + 3, y: top + 2 + 13 * CGFloat(k)), anchor: .topLeading)
        }

        // Kerzen: gruen = Schluss >= Eroeffnung, rot = darunter
        for (idx, c) in candles.enumerated() {
            let color = c.isGreen ? up : down
            let cx = x(idx).rounded() + 0.5
            var wick = Path()
            wick.move(to: CGPoint(x: cx, y: y(c.high)))
            wick.addLine(to: CGPoint(x: cx, y: y(c.low)))
            ctx.stroke(wick, with: .color(color), lineWidth: 1)
            let yo = y(c.open), yc = y(c.close)
            let rect = CGRect(x: cx - bodyW / 2, y: min(yo, yc), width: bodyW, height: max(1, abs(yc - yo)))
            ctx.fill(Path(rect), with: .color(color))
        }

        // Einstiege offener Positionen
        for p in entryPrices {
            var line = Path()
            line.move(to: CGPoint(x: left, y: y(p)))
            line.addLine(to: CGPoint(x: left + plotW, y: y(p)))
            ctx.stroke(line, with: .color(.blue), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }

        // Aktueller Kurs als Label an der Achse
        let tagRect = CGRect(x: left + plotW + 1, y: y(last.close) - 8, width: axisWidth - 2, height: 16)
        ctx.fill(Path(tagRect), with: .color(last.isGreen ? up : down))
        ctx.draw(Text(priceText(last.close)).font(.system(size: 10)).foregroundColor(.white),
                 at: CGPoint(x: left + plotW + 6, y: y(last.close)), anchor: .leading)

        // Fadenkreuz
        if let hx = hoverX, hx >= left, hx <= left + plotW {
            let idx = hoverIndex(hx, slot: slot, left: left)
            var cross = Path()
            cross.move(to: CGPoint(x: x(idx), y: top))
            cross.addLine(to: CGPoint(x: x(idx), y: top + plotH))
            ctx.stroke(cross, with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func hoverIndex(_ hx: CGFloat, slot: CGFloat, left: CGFloat) -> Int {
        min(candles.count - 1, max(0, Int((hx - left) / slot)))
    }

    private func tooltip(width: CGFloat) -> (text: String, x: CGFloat)? {
        guard let hx = hoverX, !candles.isEmpty else { return nil }
        let left: CGFloat = 4
        let plotW = width - left - axisWidth
        guard plotW > 10, hx >= left, hx <= left + plotW else { return nil }
        let slot = plotW / CGFloat(candles.count)
        let idx = hoverIndex(hx, slot: slot, left: left)
        let c = candles[idx]
        let chg = c.open > 0 ? (c.close - c.open) / c.open * 100 : 0
        let text = "\(timeText(c.openedAt))\nO \(priceText(c.open))  H \(priceText(c.high))\nL \(priceText(c.low))  C \(priceText(c.close))\n" +
            String(format: "%+.2f%%", chg)
        let cx = left + slot * (CGFloat(idx) + 0.5)
        return (text, cx + 150 > width ? cx - 160 : cx + 12)
    }
}
