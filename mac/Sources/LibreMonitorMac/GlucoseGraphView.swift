import LibreMonitorKit
import SwiftUI

// Port of windows/src/LibreMonitor.App/GlucoseGraph.cs: smooth line coloured by range, shaded in-range band,
// a 100 reference line, and a dot on a dashed "now" line. Hovering shows the nearest reading's value and time.

struct GlucoseGraphView: View {
    let readings: [GlucoseReading]
    let hours: Int
    let unit: GlucoseUnit
    let now: Date
    let theme: WidgetTheme

    @State private var hoverX: CGFloat?

    var body: some View {
        Canvas { context, size in
            let renderer = GraphRenderer(
                readings: readings, hours: hours, unit: unit, now: now, theme: theme, hoverX: hoverX)
            renderer.draw(&context, size: size)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let location): hoverX = location.x
            case .ended: hoverX = nil
            }
        }
    }
}

struct GraphRenderer {
    let readings: [GlucoseReading]
    let hours: Int
    let unit: GlucoseUnit
    let now: Date
    let theme: WidgetTheme
    let hoverX: CGFloat?

    private let padRight: CGFloat = 5 // room for the "now" dot; the card padding supplies the rest, matching the left side
    private let padTop: CGFloat = 6
    private let padBottom: CGFloat = 14
    // History arrives every ~15 minutes and the newest reading can trail it by a while, so only a real outage breaks the line.
    private let gapBreak: TimeInterval = 40 * 60
    private let staleAfter: TimeInterval = 10 * 60

    init(readings: [GlucoseReading], hours: Int, unit: GlucoseUnit, now: Date, theme: WidgetTheme, hoverX: CGFloat?) {
        self.readings = readings
        self.hours = hours
        self.unit = unit
        self.now = now
        self.theme = theme
        self.hoverX = hoverX
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        let width = size.width
        let height = size.height
        guard width >= 40, height >= 30 else { return }

        let plotW = width - padRight
        let plotH = height - padTop - padBottom
        let windowSeconds = Double(hours) * 3600
        let start = now.addingTimeInterval(-windowSeconds)

        let points = readings
            .filter { $0.timestamp >= start.addingTimeInterval(-gapBreak) }
            .sorted { $0.timestamp < $1.timestamp }

        // Keep the target band visible even when the data is flat, and stretch to fit highs and lows.
        var lowest = 54.0
        var highest = 200.0
        if let minValue = points.map(\.mgPerDl).min(), let maxValue = points.map(\.mgPerDl).max() {
            lowest = min(lowest, minValue - 10)
            highest = max(highest, maxValue + 10)
        }
        let lo = max(lowest, 20)
        let hi = min(highest, 500)

        func x(_ t: Date) -> CGFloat {
            CGFloat(min(max(t.timeIntervalSince(start) / windowSeconds, 0), 1)) * plotW
        }
        func y(_ value: Double) -> CGFloat {
            padTop + CGFloat(1 - (min(max(value, lo), hi) - lo) / (hi - lo)) * plotH
        }

        drawBand(&ctx, plotW: plotW, y: y)
        drawTimeLabels(&ctx, start: start, plotW: plotW, height: height, x: x)

        guard !points.isEmpty else { return }

        let lineShading = rangeGradient(top: y(hi), bottom: y(lo), y: y)
        let baseline = padTop + plotH
        let areaShading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [theme.ink.opacity(theme.fillOpacity), theme.ink.opacity(0)]),
            startPoint: CGPoint(x: 0, y: padTop), endPoint: CGPoint(x: 0, y: baseline))

        for run in splitAtGaps(points) {
            let xy = run.map { CGPoint(x: x($0.timestamp), y: y($0.mgPerDl)) }
            if xy.count == 1 {
                let dot = CGRect(x: xy[0].x - 1.6, y: xy[0].y - 1.6, width: 3.2, height: 3.2)
                ctx.fill(Path(ellipseIn: dot), with: lineShading)
                continue
            }

            ctx.fill(spline(xy, closeTo: baseline), with: areaShading)
            ctx.stroke(
                spline(xy, closeTo: nil), with: lineShading,
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }

        if let latest = points.last {
            drawNow(&ctx, latest: latest, plotH: plotH, x: x, y: y)
        }

        if let hoverX {
            drawHover(&ctx, points: points, mouseX: hoverX, width: width, plotH: plotH, x: x, y: y)
        }
    }

    // MARK: - Pieces

    private func drawBand(_ ctx: inout GraphicsContext, plotW: CGFloat, y: (Double) -> CGFloat) {
        let top = y(Thresholds.highMgPerDl)
        let bottom = y(Thresholds.lowMgPerDl)
        ctx.fill(
            Path(roundedRect: CGRect(x: 0, y: top, width: plotW, height: bottom - top), cornerRadius: 3),
            with: .color(theme.inRange.opacity(0.12)))

        func label(_ mgPerDl: Double) -> String { GlucoseUnits.format(mgPerDl, unit: unit) }
        let labelColor = theme.muted.opacity(0.5)
        func text(_ value: String) -> Text { Text(value).font(.system(size: 8.5)).foregroundColor(labelColor) }

        ctx.draw(text(label(Thresholds.highMgPerDl)), at: CGPoint(x: 3, y: top - 11), anchor: .topLeading)
        ctx.draw(text(label(Thresholds.lowMgPerDl)), at: CGPoint(x: 3, y: bottom + 1), anchor: .topLeading)

        // Straight reference line, drawn under the curve so the data stays on top.
        let referenceY = y(Thresholds.referenceMgPerDl)
        var line = Path()
        line.move(to: CGPoint(x: 0, y: referenceY))
        line.addLine(to: CGPoint(x: plotW, y: referenceY))
        ctx.stroke(line, with: .color(theme.ink.opacity(0.37)), lineWidth: 1)
        ctx.draw(text(label(Thresholds.referenceMgPerDl)), at: CGPoint(x: 3, y: referenceY - 11), anchor: .topLeading)
    }

    private func drawTimeLabels(
        _ ctx: inout GraphicsContext, start: Date, plotW: CGFloat, height: CGFloat, x: (Date) -> CGFloat)
    {
        let step = hours <= 3 ? 1 : (hours <= 6 ? 2 : 3)
        let calendar = Calendar.current
        let hourStart = calendar.dateComponents([.year, .month, .day, .hour], from: start)
        guard let startOfHour = calendar.date(from: hourStart) else { return }

        var tick = startOfHour.addingTimeInterval(3600)
        while calendar.component(.hour, from: tick) % step != 0 {
            tick = tick.addingTimeInterval(3600)
        }

        while x(tick) < plotW - 16 {
            let px = x(tick)
            if px >= 10 {
                let hour = calendar.component(.hour, from: tick)
                ctx.draw(
                    Text(String(format: "%02dh", hour)).font(.system(size: 8.5)).foregroundColor(theme.muted.opacity(0.55)),
                    at: CGPoint(x: px, y: height - padBottom + 2), anchor: .top)
            }
            tick = tick.addingTimeInterval(Double(step) * 3600)
        }
    }

    private func drawNow(
        _ ctx: inout GraphicsContext, latest: GlucoseReading, plotH: CGFloat,
        x: (Date) -> CGFloat, y: (Double) -> CGFloat)
    {
        let stale = now.timeIntervalSince(latest.timestamp) > staleAfter
        let color = stale ? theme.muted : theme.color(forMgPerDl: latest.mgPerDl)
        let px = x(latest.timestamp)
        let py = y(latest.mgPerDl)

        var dash = Path()
        dash.move(to: CGPoint(x: px, y: padTop))
        dash.addLine(to: CGPoint(x: px, y: padTop + plotH))
        ctx.stroke(dash, with: .color(theme.ink.opacity(0.27)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        let dot = Path(ellipseIn: CGRect(x: px - 4.6, y: py - 4.6, width: 9.2, height: 9.2))
        ctx.fill(dot, with: .color(color))
        ctx.stroke(dot, with: .color(theme.ring), lineWidth: 2)
    }

    /// Highlights the reading nearest to the cursor and labels it with its value and time.
    private func drawHover(
        _ ctx: inout GraphicsContext, points: [GlucoseReading], mouseX: CGFloat, width: CGFloat, plotH: CGFloat,
        x: (Date) -> CGFloat, y: (Double) -> CGFloat)
    {
        guard let nearest = points.min(by: { abs(x($0.timestamp) - mouseX) < abs(x($1.timestamp) - mouseX) }) else {
            return
        }

        let px = x(nearest.timestamp)
        let py = y(nearest.mgPerDl)
        let color = theme.color(forMgPerDl: nearest.mgPerDl)

        var guide = Path()
        guide.move(to: CGPoint(x: px, y: padTop))
        guide.addLine(to: CGPoint(x: px, y: padTop + plotH))
        ctx.stroke(guide, with: .color(theme.ink.opacity(0.35)), lineWidth: 1)

        let dot = Path(ellipseIn: CGRect(x: px - 5.4, y: py - 5.4, width: 10.8, height: 10.8))
        ctx.fill(dot, with: .color(color))
        ctx.stroke(dot, with: .color(theme.ring), lineWidth: 2)

        let time = Self.timeFormatter.string(from: nearest.timestamp)
        let value = GlucoseUnits.format(nearest.mgPerDl, unit: unit)
        let resolved = ctx.resolve(
            Text("\(value)  ·  \(time)").font(.system(size: 11.5, weight: .semibold)).foregroundColor(theme.text))
        let textSize = resolved.measure(in: CGSize(width: 300, height: 60))

        let boxW = textSize.width + 16
        let boxH = textSize.height + 8
        let boxX = min(max(px - boxW / 2, 0), max(0, width - boxW))
        var boxY = py - boxH - 10
        if boxY < 0 { boxY = py + 12 } // not enough room above a high reading

        let box = Path(roundedRect: CGRect(x: boxX, y: boxY, width: boxW, height: boxH), cornerRadius: 6)
        ctx.fill(box, with: .color(theme.pill))
        ctx.stroke(box, with: .color(color.opacity(0.67)), lineWidth: 1)
        ctx.draw(resolved, at: CGPoint(x: boxX + 8, y: boxY + 4), anchor: .topLeading)
    }

    // MARK: - Geometry

    /// Vertical gradient that keeps the line amber above range, green inside it and red below, with soft transitions.
    private func rangeGradient(top: CGFloat, bottom: CGFloat, y: (Double) -> CGFloat) -> GraphicsContext.Shading {
        let span = bottom - top
        func offset(_ value: Double) -> CGFloat {
            span <= 0 ? 0 : min(max((y(value) - top) / span, 0), 1)
        }

        let high = offset(Thresholds.highMgPerDl)
        let low = offset(Thresholds.lowMgPerDl)
        let blend: CGFloat = 0.03
        let highEdge = min(1, high + blend)
        let lowStart = max(highEdge, low - blend)

        let stops: [Gradient.Stop] = [
            .init(color: theme.high, location: 0),
            .init(color: theme.high, location: max(0, high - blend)),
            .init(color: theme.inRange, location: highEdge),
            .init(color: theme.inRange, location: lowStart),
            .init(color: theme.low, location: min(1, low + blend)),
            .init(color: theme.low, location: 1),
        ]
        return .linearGradient(
            Gradient(stops: stops), startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: bottom))
    }

    /// Catmull-Rom spline through the points, converted to cubic Béziers. Optionally closed down to a baseline for the area fill.
    private func spline(_ p: [CGPoint], closeTo baseline: CGFloat?) -> Path {
        var path = Path()
        guard p.count >= 2 else { return path }

        if let baseline {
            path.move(to: CGPoint(x: p[0].x, y: baseline))
            path.addLine(to: p[0])
        } else {
            path.move(to: p[0])
        }

        for i in 0..<(p.count - 1) {
            let p0 = p[max(i - 1, 0)]
            let p1 = p[i]
            let p2 = p[i + 1]
            let p3 = p[min(i + 2, p.count - 1)]
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }

        if let baseline {
            path.addLine(to: CGPoint(x: p[p.count - 1].x, y: baseline))
            path.closeSubpath()
        }
        return path
    }

    private func splitAtGaps(_ points: [GlucoseReading]) -> [[GlucoseReading]] {
        var runs: [[GlucoseReading]] = []
        var run: [GlucoseReading] = []

        for point in points {
            if let last = run.last, point.timestamp.timeIntervalSince(last.timestamp) > gapBreak {
                runs.append(run)
                run = []
            }
            run.append(point)
        }

        if !run.isEmpty { runs.append(run) }
        return runs
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
