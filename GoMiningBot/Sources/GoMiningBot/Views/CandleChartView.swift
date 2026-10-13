import SwiftUI
import GoMiningCore

/// Marke fuer einen Trade im Diagramm.
struct ChartMarker: Hashable {
    var time: Double
    var price: Double
    var isBuy: Bool
    /// Text fuer den Tooltip (Aktion, Menge, Preis, Ergebnis).
    var label: String = ""
}

/// Kerzen-Diagramm (gruen/rot) mit Volumen, Einstiegslinien, Trade-Marken und den Analysefenstern.
/// Zoomen per Zwei-Finger-Geste oder Knopf, Verschieben per Ziehen; der Preisbereich passt sich den sichtbaren Kerzen an.
struct CandleChartView: View {
    var candles: [PriceCandle]
    var moves: [Move] = []
    var entryPrices: [Double] = []
    var markers: [ChartMarker] = []
    var targetPrice: Double?
    var buyPrice: Double?
    var candleMinutes = 1
    /// So viele Kerzen zeigt das Diagramm ohne Zoom (nil = alle).
    var defaultVisible: Int?

    @State private var hoverX: CGFloat?
    /// Zahl der sichtbaren Kerzen (nil = Standard).
    @State private var zoomCount: Int?
    /// Ende des sichtbaren Bereichs als Zeit der letzten sichtbaren Kerze (nil = immer die neueste).
    @State private var anchorEnd: Double?
    @State private var dragStart: (end: Int, count: Int)?
    @State private var pinchStart: Int?

    static let minVisible = 20

    private let axisWidth: CGFloat = 74
    private let bottomHeight: CGFloat = 22
    private let left: CGFloat = 4
    private let top: CGFloat = 8

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
                    .gesture(panGesture(width: geo.size.width))
                    .simultaneousGesture(pinchGesture)
                    .onTapGesture(count: 2) { resetZoom() }
                zoomControls
                    .padding(.leading, 6)
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
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
            if candles.isEmpty { Text("Kursdaten werden geladen …").foregroundStyle(.secondary) }
        }
        .onChange(of: candleMinutes) { _, _ in resetZoom() }
    }

    // MARK: Zoom und Verschieben

    /// Sichtbarer Bereich: Ende (exklusiv) und Anzahl.
    private var window: (end: Int, count: Int) {
        let n = candles.count
        guard n > 0 else { return (0, 0) }
        let count = min(n, max(min(n, Self.minVisible), zoomCount ?? defaultVisible ?? n))
        var end = n
        if let anchor = anchorEnd, let idx = candles.lastIndex(where: { $0.openedAt <= anchor + 1 }) { end = idx + 1 }
        end = min(n, max(count, end))
        return (end, count)
    }

    private var visible: ArraySlice<PriceCandle> {
        let w = window
        return candles[(w.end - w.count)..<w.end]
    }

    /// `true`, wenn die neueste Kerze sichtbar ist (Analysefenster nur dann einblenden).
    private var showsLatest: Bool { window.end == candles.count }

    private func setWindow(end: Int, count: Int) {
        let n = candles.count
        guard n > 0 else { return }
        let c = min(n, max(min(n, Self.minVisible), count))
        let e = min(n, max(c, end))
        zoomCount = c
        anchorEnd = e >= n ? nil : candles[e - 1].openedAt
    }

    private func zoom(by factor: Double) {
        let w = window
        setWindow(end: w.end, count: Int((Double(w.count) * factor).rounded()))
    }

    private func resetZoom() {
        zoomCount = nil
        anchorEnd = nil
    }

    private func panGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                let start = dragStart ?? window
                if dragStart == nil { dragStart = start }
                let plotW = max(10, width - left - axisWidth)
                let slot = plotW / CGFloat(max(1, start.count))
                let shift = Int((value.translation.width / slot).rounded())
                setWindow(end: start.end - shift, count: start.count)
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? window.count
                if pinchStart == nil { pinchStart = start }
                let w = window
                setWindow(end: w.end, count: Int((Double(start) / max(0.1, value.magnification)).rounded()))
            }
            .onEnded { _ in pinchStart = nil }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { zoom(by: 0.6) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Hineinzoomen (auch mit zwei Fingern auf dem Trackpad)")
                .disabled(window.count <= min(candles.count, Self.minVisible))
            Button { zoom(by: 1 / 0.6) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Herauszoomen")
                .disabled(window.count >= candles.count)
            if window.count < candles.count {
                Button("Alles") { zoomCount = candles.count; anchorEnd = nil }.help("Den ganzen geladenen Verlauf zeigen")
            }
            if zoomCount != nil || anchorEnd != nil {
                Button("Standard") { resetZoom() }.help("Standardansicht (auch per Doppelklick ins Diagramm)")
            }
            if anchorEnd != nil {
                Button { anchorEnd = nil } label: { Label("Live", systemImage: "forward.end.fill") }
                    .help("Zur neuesten Kerze springen")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.caption)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .opacity(candles.count > Self.minVisible ? 1 : 0)
    }

    // MARK: Geometrie

    private func priceRange() -> (lo: Double, hi: Double) {
        let candles = visible
        var lo = candles.map(\.low).min() ?? 0
        var hi = candles.map(\.high).max() ?? 1
        for p in entryPrices + [targetPrice, buyPrice].compactMap({ $0 }) where p > 0 {
            // Linien weit ausserhalb des Kursbereichs nicht erzwingen (sonst werden die Kerzen winzig).
            if p > lo * 0.9 && p < hi * 1.1 { lo = min(lo, p); hi = max(hi, p) }
        }
        if hi <= lo { hi = lo * 1.001 + 0.000001; lo *= 0.999 }
        let pad = (hi - lo) * 0.08
        return (lo - pad, hi + pad)
    }

    private func niceStep(range: Double, ticks: Int) -> Double {
        let raw = range / Double(max(1, ticks))
        guard raw > 0 else { return 1 }
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let nice: Double = norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 2.5 ? 2.5 : norm <= 5 ? 5 : 10
        return nice * mag
    }

    private func timeText(_ t: Double) -> String { Fmt.shortTime(t) }

    // MARK: Zeichnen

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let candles = Array(visible)
        let moves = showsLatest ? self.moves : []
        guard let last = candles.last else { return }
        let (lo, hi) = priceRange()
        let plotW = size.width - left - axisWidth
        let volumeHeight = max(0, (size.height - top - bottomHeight) * 0.16)
        let plotH = size.height - top - bottomHeight
        guard plotW > 10, plotH > 10, hi > lo else { return }
        let slot = plotW / CGFloat(candles.count)
        let bodyW = max(1, min(14, slot * 0.7))
        let priceH = plotH - volumeHeight
        func y(_ v: Double) -> CGFloat { top + CGFloat((hi - v) / (hi - lo)) * priceH }
        func x(_ i: Int) -> CGFloat { left + slot * (CGFloat(i) + 0.5) }

        // Raster und Preisachse
        let step = niceStep(range: hi - lo, ticks: max(3, Int(size.height / 60)))
        var v = (lo / step).rounded(.up) * step
        var guardCount = 0
        while v <= hi, guardCount < 40 {
            var line = Path()
            line.move(to: CGPoint(x: left, y: y(v)))
            line.addLine(to: CGPoint(x: left + plotW, y: y(v)))
            ctx.stroke(line, with: .color(.gray.opacity(0.22)), lineWidth: 0.5)
            ctx.draw(Text(Fmt.price(v)).font(.system(size: 10)).foregroundColor(.secondary),
                     at: CGPoint(x: left + plotW + 6, y: y(v)), anchor: .leading)
            v += step
            guardCount += 1
        }

        // Zeitachse (von rechts, nichts ragt links aus dem Bild)
        let every = max(1, Int((74 / slot).rounded(.up)))
        var i = candles.count - 1
        while i >= 0 {
            if x(i) - 20 < left { break }
            ctx.draw(Text(timeText(candles[i].openedAt)).font(.system(size: 10)).foregroundColor(.secondary),
                     at: CGPoint(x: x(i), y: size.height - bottomHeight + 6), anchor: .top)
            i -= every
        }

        // Analysefenster (6/8/20/60 min) als Schattierung von rechts
        for (k, m) in moves.sorted(by: { $0.windowMinutes > $1.windowMinutes }).enumerated() {
            let n = min(candles.count, Int((Double(m.windowMinutes) / Double(max(1, candleMinutes))).rounded(.up)))
            let x0 = left + slot * CGFloat(candles.count - n)
            let color: Color = m.triggered ? (m.direction == .up ? .candleUp : .candleDown) : .gray
            ctx.fill(Path(CGRect(x: x0, y: top, width: left + plotW - x0, height: plotH)),
                     with: .color(color.opacity(m.triggered ? 0.10 : 0.035)))
            ctx.draw(Text("\(m.windowMinutes)m").font(.system(size: 10)).foregroundColor(.secondary),
                     at: CGPoint(x: x0 + 3, y: top + 2 + 13 * CGFloat(k)), anchor: .topLeading)
        }

        // Volumen
        let maxVolume = candles.map(\.volume).max() ?? 0
        if maxVolume > 0, volumeHeight > 4 {
            for (idx, c) in candles.enumerated() where c.volume > 0 {
                let h = CGFloat(c.volume / maxVolume) * (volumeHeight - 2)
                let rect = CGRect(x: x(idx) - bodyW / 2, y: top + plotH - h, width: bodyW, height: h)
                ctx.fill(Path(rect), with: .color((c.isGreen ? Color.candleUp : Color.candleDown).opacity(0.30)))
            }
        }

        // Kerzen
        for (idx, c) in candles.enumerated() {
            let color = c.isGreen ? Color.candleUp : Color.candleDown
            let cx = x(idx).rounded() + 0.5
            var wick = Path()
            wick.move(to: CGPoint(x: cx, y: y(c.high)))
            wick.addLine(to: CGPoint(x: cx, y: y(c.low)))
            ctx.stroke(wick, with: .color(color), lineWidth: 1)
            let yo = y(c.open), yc = y(c.close)
            let rect = CGRect(x: cx - bodyW / 2, y: min(yo, yc), width: bodyW, height: max(1, abs(yc - yo)))
            ctx.fill(Path(rect), with: .color(color))
        }

        // Einstiege offener Positionen, Kauf- und Verkaufsschwelle
        for p in entryPrices where p > lo && p < hi {
            horizontalLine(ctx, y: y(p), from: left, to: left + plotW, color: .blue, dash: [4, 3])
        }
        if let t = targetPrice, t > lo, t < hi {
            horizontalLine(ctx, y: y(t), from: left, to: left + plotW, color: .candleUp.opacity(0.8), dash: [2, 3])
            ctx.draw(Text("Verkauf ab").font(.system(size: 9)).foregroundColor(.candleUp), at: CGPoint(x: left + 4, y: y(t) - 7), anchor: .leading)
        }
        if let b = buyPrice, b > lo, b < hi {
            horizontalLine(ctx, y: y(b), from: left, to: left + plotW, color: .candleDown.opacity(0.8), dash: [2, 3])
            ctx.draw(Text("Kauf ab").font(.system(size: 9)).foregroundColor(.candleDown), at: CGPoint(x: left + 4, y: y(b) + 7), anchor: .leading)
        }

        // Trade-Marken
        let bucket = Double(max(1, candleMinutes)) * 60
        for m in markers {
            guard let first = candles.first, m.time >= first.openedAt, m.time < last.openedAt + bucket else { continue }
            let idx = candles.lastIndex(where: { $0.openedAt <= m.time }) ?? 0
            let cx = x(idx)
            let cy = y(m.price)
            var tri = Path()
            if m.isBuy {
                tri.move(to: CGPoint(x: cx, y: cy + 3))
                tri.addLine(to: CGPoint(x: cx - 5, y: cy + 12))
                tri.addLine(to: CGPoint(x: cx + 5, y: cy + 12))
            } else {
                tri.move(to: CGPoint(x: cx, y: cy - 3))
                tri.addLine(to: CGPoint(x: cx - 5, y: cy - 12))
                tri.addLine(to: CGPoint(x: cx + 5, y: cy - 12))
            }
            tri.closeSubpath()
            ctx.fill(tri, with: .color(m.isBuy ? .blue : .orange))
        }

        // Aktueller Kurs als Etikett an der Achse
        let tagRect = CGRect(x: left + plotW + 1, y: y(last.close) - 8, width: axisWidth - 2, height: 16)
        ctx.fill(Path(roundedRect: tagRect, cornerRadius: 3), with: .color(last.isGreen ? .candleUp : .candleDown))
        ctx.draw(Text(Fmt.price(last.close)).font(.system(size: 10, weight: .semibold)).foregroundColor(.white),
                 at: CGPoint(x: left + plotW + 6, y: y(last.close)), anchor: .leading)

        // Fadenkreuz
        if let hx = hoverX, hx >= left, hx <= left + plotW {
            let idx = hoverIndex(hx, slot: slot, count: candles.count)
            var cross = Path()
            cross.move(to: CGPoint(x: x(idx), y: top))
            cross.addLine(to: CGPoint(x: x(idx), y: top + plotH))
            ctx.stroke(cross, with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func horizontalLine(_ ctx: GraphicsContext, y: CGFloat, from x0: CGFloat, to x1: CGFloat, color: Color, dash: [CGFloat]) {
        var line = Path()
        line.move(to: CGPoint(x: x0, y: y))
        line.addLine(to: CGPoint(x: x1, y: y))
        ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1, dash: dash))
    }

    private func hoverIndex(_ hx: CGFloat, slot: CGFloat, count: Int) -> Int {
        min(count - 1, max(0, Int((hx - left) / slot)))
    }

    private func tooltip(width: CGFloat) -> (text: String, x: CGFloat)? {
        let candles = Array(visible)
        guard let hx = hoverX, !candles.isEmpty else { return nil }
        let plotW = width - left - axisWidth
        guard plotW > 10, hx >= left, hx <= left + plotW else { return nil }
        let slot = plotW / CGFloat(candles.count)
        let idx = hoverIndex(hx, slot: slot, count: candles.count)
        let c = candles[idx]
        let change = c.open > 0 ? (c.close - c.open) / c.open : 0
        var text = "\(timeText(c.openedAt))\nO \(Fmt.price(c.open))  H \(Fmt.price(c.high))\nL \(Fmt.price(c.low))  C \(Fmt.price(c.close))\n"
            + "\(Fmt.percent(change, digits: 2, signed: true))  Vol \(Fmt.quantity(c.volume))"
        // Trades in dieser Kerze.
        let bucket = Double(max(1, candleMinutes)) * 60
        let inside = markers.filter { $0.time >= c.openedAt && $0.time < c.openedAt + bucket && !$0.label.isEmpty }
        for m in inside.prefix(4) { text += "\n\(m.isBuy ? "▲" : "▼") \(m.label)" }
        if inside.count > 4 { text += "\n… und \(inside.count - 4) weitere" }
        let cx = left + slot * (CGFloat(idx) + 0.5)
        let boxWidth: CGFloat = inside.isEmpty ? 200 : 290
        return (text, cx + boxWidth - 10 > width ? cx - boxWidth : cx + 12)
    }
}
