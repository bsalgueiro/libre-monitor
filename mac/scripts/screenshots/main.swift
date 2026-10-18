import AppKit
import SwiftUI

// Draws the website and README images from the app's real widget view. See make-screenshots.sh.
// The glucose curves are made up for the pictures; nothing here is real data.

// MARK: - Glucose curves

/// A smooth 12 hour history (15 minute spacing, like the service) through the given (hours ago, mg/dL) points.
func history(now: Date, through points: [(Double, Double)], trend: Trend) -> GlucoseSnapshot {
    let keys = points.sorted { $0.0 > $1.0 } // oldest first
    func value(atHoursAgo h: Double) -> Double {
        if h >= keys.first!.0 { return keys.first!.1 }
        if h <= keys.last!.0 { return keys.last!.1 }
        let i = keys.firstIndex { $0.0 <= h }! // first key at or after h in time
        let (t1, v1) = keys[i - 1], (t2, v2) = keys[i]
        let p0 = i >= 2 ? keys[i - 2].1 : v1
        let p3 = i + 1 < keys.count ? keys[i + 1].1 : v2
        let u = (t1 - h) / (t1 - t2)
        // Catmull-Rom between the two surrounding points, so the line is smooth without overshooting much.
        let a = -0.5 * p0 + 1.5 * v1 - 1.5 * v2 + 0.5 * p3
        let b = p0 - 2.5 * v1 + 2 * v2 - 0.5 * p3
        let c = -0.5 * p0 + 0.5 * v2
        return ((a * u + b) * u + c) * u + v1
    }

    var readings: [GlucoseReading] = []
    for step in stride(from: 48, through: 1, by: -1) {
        let hours = Double(step) * 0.25
        let jitter = 1.6 * sin(Double(step) * 1.7) + 1.1 * sin(Double(step) * 0.7)
        let v = (value(atHoursAgo: hours) + jitter).rounded()
        readings.append(GlucoseReading(timestamp: now.addingTimeInterval(-hours * 3600), mgPerDl: v, value: v, trend: .unknown,
                                       isHigh: v > 180, isLow: v < 70))
    }
    let latest = keys.last!.1.rounded()
    let current = GlucoseReading(timestamp: now, mgPerDl: latest, value: latest, trend: trend, isHigh: latest > 180, isLow: latest < 70)
    return GlucoseSnapshot(current: current, history: readings)
}

// The curves are flat just before the 6 hour mark: the graph pins the one reading older than its window to the left edge, and
// a flat start keeps that from showing as a small hook.

/// Overnight steady, a breakfast rise that stays in range, then easing back down.
func inRangeCurve(now: Date) -> GlucoseSnapshot {
    history(now: now, through: [
        (12, 104), (10, 99), (8, 103), (7, 108), (6, 108), (5.5, 118), (5, 138), (4.5, 157), (4, 166), (3.5, 158),
        (3, 142), (2.5, 127), (2, 114), (1.5, 106), (1, 104), (0.5, 110), (0, 118),
    ], trend: .stable)
}

func lowCurve(now: Date) -> GlucoseSnapshot {
    history(now: now, through: [
        (12, 112), (10, 104), (8, 108), (7, 110), (6, 110), (5, 122), (4.5, 138), (4, 142), (3.5, 132), (3, 118),
        (2, 100), (1.5, 92), (1, 84), (0.5, 73), (0, 62),
    ], trend: .downSlow)
}

func highCurve(now: Date) -> GlucoseSnapshot {
    history(now: now, through: [
        (12, 118), (8, 112), (7, 114), (6, 114), (5, 126), (4, 146), (3, 170), (2, 192), (1.5, 202), (1, 210),
        (0.5, 216), (0, 221),
    ], trend: .upSlow)
}

// MARK: - The widget as a card

@MainActor
func makeModel(_ snapshot: GlucoseSnapshot, now: Date, showGraph: Bool = true, hours: Int = 6, zone: AlertKind? = nil,
               insulin: InsulinSettings? = nil) -> AppModel {
    var settings = WidgetSettings()
    settings.showGraph = showGraph
    settings.hours = hours
    if let insulin { settings.insulin = insulin }
    let model = AppModel(settings: settings)
    model.apply(MonitorUpdate(patient: Patient(patientId: "p", firstName: "A", lastName: "B"), snapshot: snapshot, fetchedAt: now))
    model.now = now // after tick(), which would set the real time
    model.alertZone = zone
    return model
}

func stubActions() -> WidgetActions {
    WidgetActions(
        close: {}, moveToCorner: { _ in }, hideToMenuBar: {}, showAlerts: {}, toggleInsulin: {}, pauseAlerts: {},
        refreshNow: {}, snoozeAlerts: { _ in }, resumeAlerts: {}, checkForUpdates: {}, showAbout: {}, signOut: {}, quit: {})
}

/// The widget in a rounded card like the real window (which is a blur; this is its flat equivalent), at the given size.
@MainActor
func card(_ model: AppModel, dark: Bool, width: CGFloat, height: CGFloat) -> some View {
    let fill = dark ? Color(red: 21 / 255, green: 26 / 255, blue: 32 / 255) : Color(red: 238 / 255, green: 240 / 255, blue: 243 / 255)
    let line = dark ? Color.white.opacity(0.12) : Color.black.opacity(0.12)
    return WidgetView(model: model, actions: stubActions())
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 16).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, dark ? .dark : .light)
}

// MARK: - The desktop scene

/// An illustrated desktop with the widget in a corner: an abstract wallpaper, a menu bar, two generic windows and a dock.
/// Nothing in it is a real app, a real screenshot or personal; it only shows where the widget sits.
struct DesktopScene<Widget: View>: View {
    let widget: Widget
    let value: String
    /// The whole scene follows one theme: dark windows with a dark widget, or light windows with a light one.
    let dark: Bool

    private var windowFill: Color { dark ? Color(red: 0.12, green: 0.13, blue: 0.16).opacity(0.95) : Color.white.opacity(0.94) }
    private var sidebarFill: Color { dark ? Color.white.opacity(0.04) : Color.black.opacity(0.035) }
    private var barColor: Color { dark ? Color.white : Color.black }
    private var accentFill: Color { dark ? Color.blue.opacity(0.18) : Color.blue.opacity(0.10) }

    private func blob(_ colors: [Color], _ size: CGFloat, _ x: CGFloat, _ y: CGFloat) -> some View {
        Circle()
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .blur(radius: size * 0.18)
            .position(x: x, y: y)
    }

    private func skeleton(_ width: CGFloat, _ height: CGFloat = 9, _ opacity: Double = 0.16) -> some View {
        RoundedRectangle(cornerRadius: height / 2).fill(barColor.opacity(dark ? opacity * 1.1 : opacity)).frame(width: width, height: height)
    }

    private func trafficLights() -> some View {
        HStack(spacing: 7) {
            Circle().fill(Color(red: 1, green: 0.37, blue: 0.34)).frame(width: 11, height: 11)
            Circle().fill(Color(red: 1, green: 0.74, blue: 0.18)).frame(width: 11, height: 11)
            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25)).frame(width: 11, height: 11)
        }
    }

    private var documentWindow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { trafficLights(); Spacer() }.padding(14).frame(height: 40)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(0..<7, id: \.self) { i in skeleton(i % 3 == 0 ? 90 : 120, 8, 0.12) }
                }
                .frame(width: 170, alignment: .leading)
                .padding(22)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(sidebarFill)

                VStack(alignment: .leading, spacing: 14) {
                    skeleton(280, 18, 0.2)
                    ForEach(0..<11, id: \.self) { i in skeleton(i % 4 == 3 ? 360 : 520, 8, 0.1) }
                    RoundedRectangle(cornerRadius: 10).fill(accentFill).frame(height: 120)
                    ForEach(0..<4, id: \.self) { i in skeleton(i % 2 == 0 ? 480 : 400, 8, 0.1) }
                }
                .padding(34)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 800, height: 520)
        .background(windowFill)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 28, y: 14)
    }

    private func tableCell(row: Int, col: Int) -> some View {
        let width: CGFloat = CGFloat(34 + ((row * 7 + col * 13) % 5) * 12)
        let isHeader = row == 0
        let background: Color = isHeader ? barColor.opacity(0.06) : Color.clear
        let barOpacity: Double = isHeader ? 0.22 : 0.12
        return ZStack(alignment: .leading) {
            Rectangle().fill(background)
            skeleton(width, 7, barOpacity).padding(.leading, 12)
        }
        .frame(height: 38)
        .overlay(Rectangle().stroke(barColor.opacity(0.06), lineWidth: 0.5))
    }

    private func tableRow(_ row: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<5, id: \.self) { col in tableCell(row: row, col: col) }
        }
    }

    private var tableGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<9, id: \.self) { row in tableRow(row) }
        }
        .padding(.horizontal, 16)
    }

    private var tableWindow: some View {
        VStack(spacing: 0) {
            HStack { trafficLights(); Spacer() }.padding(14).frame(height: 40)
            tableGrid
            Spacer()
        }
        .frame(width: 600, height: 400)
        .background(windowFill)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 26, y: 12)
    }

    private var menuBar: some View {
        HStack(spacing: 18) {
            Circle().fill(Color.white.opacity(0.9)).frame(width: 11, height: 11)
            Text("Notes").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            // The menu bar item the app adds: the value on a coloured tile.
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(red: 0.07, green: 0.16, blue: 0.1))
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color(red: 0.36, green: 0.84, blue: 0.54)))
            Image(systemName: "battery.100")
            Image(systemName: "wifi")
            Text("Tue 9:41").font(.system(size: 13))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(Color.black.opacity(0.28))
    }

    private var dock: some View {
        let palette: [[Color]] = [
            [.blue, .cyan], [.orange, .yellow], [.pink, .purple], [.green, .mint], [.indigo, .blue], [.red, .orange], [.teal, .green], [.gray, .white],
        ]
        return HStack(spacing: 14) {
            ForEach(0..<palette.count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 13)
                    .fill(LinearGradient(colors: palette[i], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 54, height: 54)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color.white.opacity(0.22)))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.white.opacity(0.25), lineWidth: 1))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.12, blue: 0.28), Color(red: 0.25, green: 0.17, blue: 0.47),
                         Color(red: 0.55, green: 0.23, blue: 0.5), Color(red: 0.95, green: 0.54, blue: 0.37)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            blob([Color(red: 0.2, green: 0.55, blue: 0.95), Color(red: 0.35, green: 0.2, blue: 0.8)], 620, 250, 200)
            blob([Color(red: 1.0, green: 0.55, blue: 0.4), Color(red: 0.9, green: 0.3, blue: 0.5)], 560, 1260, 720)
            blob([Color(red: 0.3, green: 0.85, blue: 0.75), Color(red: 0.2, green: 0.5, blue: 0.9)], 420, 980, 120)

            documentWindow.position(x: 520, y: 400)
            tableWindow.position(x: 860, y: 600)
            widget.position(x: 1440 - 24 - 140, y: 28 + 20 + 86)
            menuBar.frame(width: 1440, alignment: .top)
            dock.position(x: 720, y: 900 - 52)
        }
        .frame(width: 1440, height: 900)
        .clipped()
    }
}

// MARK: - Output

@MainActor
func write<V: View>(_ view: V, to path: String, scale: CGFloat, jpeg: Bool = false) {
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    renderer.isOpaque = jpeg
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: jpeg ? .jpeg : .png, properties: jpeg ? [.compressionFactor: 0.88] : [:])
    else {
        print("could not render \(path)")
        return
    }
    try? data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(Int(image.size.width * scale)) x \(Int(image.size.height * scale)))")
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
// Always 09:41, so the time labels on the graph and the clock in the desktop scene agree.
let now = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date())!

MainActor.assumeIsolated {
    let inRange = inRangeCurve(now: now)

    write(card(makeModel(inRange, now: now), dark: true, width: 280, height: 172), to: "\(out)/widget-dark.png", scale: 3)
    write(card(makeModel(inRange, now: now), dark: false, width: 280, height: 172), to: "\(out)/widget-light.png", scale: 3)
    write(card(makeModel(inRange, now: now, showGraph: false), dark: true, width: 260, height: 132), to: "\(out)/widget-compact.png", scale: 3)
    write(card(makeModel(lowCurve(now: now), now: now, zone: .low), dark: true, width: 280, height: 172), to: "\(out)/alert-low.png", scale: 3)
    write(card(makeModel(highCurve(now: now), now: now, zone: .high), dark: true, width: 280, height: 172), to: "\(out)/alert-high.png", scale: 3)

    for dark in [true, false] {
        let onDesktop = card(makeModel(inRange, now: now), dark: dark, width: 280, height: 172)
            .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        write(DesktopScene(widget: onDesktop, value: "118", dark: dark), to: "\(out)/desktop-\(dark ? "dark" : "light").jpg", scale: 1.5, jpeg: true)
    }

    // The insulin reminder's syringe: amber with "!" once the dose is due, green with a tick once it is marked as administered.
    let due = InsulinSettings(enabled: true, dosesPerDay: 1, firstDoseMinutes: 9 * 60)
    var done = InsulinSettings(enabled: true, dosesPerDay: 1, firstDoseMinutes: 8 * 60)
    done.lastAdministeredAt = Calendar.current.date(bySettingHour: 8, minute: 12, second: 0, of: now)
    write(card(makeModel(inRange, now: now, insulin: due), dark: true, width: 280, height: 172), to: "\(out)/insulin-due.png", scale: 3)
    write(card(makeModel(inRange, now: now, insulin: done), dark: true, width: 280, height: 172), to: "\(out)/insulin-done.png", scale: 3)
}
