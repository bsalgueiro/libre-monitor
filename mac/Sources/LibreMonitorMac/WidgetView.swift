import AppKit
import LibreMonitorKit
import SwiftUI

enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }

    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

/// What the widget's right-click menu can ask the app to do. Settings that are plain values (units, range,
/// appearance, always on top, menu bar icon) are bound directly to the model instead.
struct WidgetActions {
    var close: () -> Void
    var moveToCorner: (Corner) -> Void
    var hideToMenuBar: () -> Void
    var showAlerts: () -> Void
    var toggleInsulin: () -> Void
    var snoozeAlerts: (Int) -> Void
    var resumeAlerts: () -> Void
    var checkForUpdates: () -> Void
    var showAbout: () -> Void
    var signOut: () -> Void
    var quit: () -> Void
}

/// The widget content: current value, trend arrow, age, and the graph. Laid out for 280 x 172 points and scaled
/// with the window, like the Windows widget.
struct WidgetView: View {
    @ObservedObject var model: AppModel
    let actions: WidgetActions

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    @State private var overCloseButton = false
    @State private var overInsulin = false

    private static let defaultWidth: CGFloat = 280
    private static let defaultHeight: CGFloat = 172

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    // With the graph hidden, the header is scaled to fill the card. These describe the two arrangements at scale 1:
    // the widest case is a 4-character value ("10.0") beside the longest status text ("sign-in needed").
    //   side by side: value and arrow on the left, unit and status on the right (suits a wide, short card)
    //   stacked:      value and arrow, with unit and status on one line underneath (lets the value grow on a small card)
    private static let sideBySideDesign = CGSize(width: 250, height: 62)
    private static let stackedDesign = CGSize(width: 175, height: 78)
    private static let compactPadding = CGSize(width: 20, height: 14) // total, both sides
    /// The graph draws its "now" dot this far past its plot, so the plot itself can end exactly at the card padding.
    private static let graphDotOverhang: CGFloat = 5

    var body: some View {
        let theme = WidgetTheme.forScheme(colorScheme)

        GeometryReader { geometry in
            let tint = valueTint(theme)
            let status = statusText(theme)

            if model.settings.showGraph {
                graphLayout(geometry.size, theme: theme, tint: tint, status: status)
            } else {
                compactLayout(geometry.size, theme: theme, tint: tint, status: status)
            }
        }
        // Without a content shape only drawn pixels (the graph) are clickable, so the menu opened nowhere else.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay {
            // A coloured border while the reading is inside an alert zone, whether or not notifications are snoozed.
            if let zone = model.alertZone {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(zone == .low ? theme.low : theme.high, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            // Always in the view tree and only faded: if it were added and removed with the hover state, the state
            // flickering off as the pointer reaches the button would remove it from under the cursor.
            closeButton(theme)
                .opacity(hovering || overCloseButton ? 1 : 0)
                .animation(.easeInOut(duration: 0.12), value: hovering || overCloseButton)
        }
        .overlay(alignment: .bottom) {
            // The system tooltip does not appear reliably on a floating widget, so this one is drawn in the card, in
            // the same style as the graph's hover label.
            if overInsulin, let dose = model.insulinStatus {
                insulinTooltip(dose, theme: theme)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: overInsulin)
        .contextMenu { menuContent }
    }

    private func insulinColor(_ state: DoseState, theme: WidgetTheme) -> Color {
        switch state {
        case .administered: return theme.inRange
        case .due: return theme.high
        case .upcoming: return theme.muted
        }
    }

    /// What the syringe means right now, for the hover message.
    private func insulinMessage(_ status: DoseStatus) -> String {
        let next = stamp(InsulinSchedule.nextSlot(after: status.slot, settings: model.settings.insulin, calendar: .current))
        switch status.state {
        case .administered:
            return "Insulin administered on \(stamp(status.administeredAt ?? status.slot)).\nNext dose at \(next)."
        case .due:
            return "Insulin due since \(stamp(status.slot)), not administered yet.\nNext dose at \(next)."
        case .upcoming:
            return "Insulin not administered yet.\nNext dose at \(stamp(status.slot))."
        }
    }

    /// Date and time as dd/mm/yy hh:mm am/pm, the same on every Mac, for the syringe's hover message.
    private func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd/MM/yy hh:mm a"
        return formatter.string(from: date)
    }

    private func insulinTooltip(_ status: DoseStatus, theme: WidgetTheme) -> some View {
        Text(insulinMessage(status))
            .font(.system(size: 11))
            .foregroundColor(theme.text)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.pill)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(insulinColor(status.state, theme: theme).opacity(0.67), lineWidth: 1)))
    }

    /// The insulin check: grey = not due yet, amber ! = due, green tick = administered. Only shown while the
    /// reminder is on. Clicking asks to mark the dose as administered (or to undo that).
    private func insulinButton(_ status: DoseStatus, theme: WidgetTheme, scale: CGFloat = 1) -> some View {
        let color = insulinColor(status.state, theme: theme)
        let mark: String? = status.state == .administered ? "✓" : (status.state == .due ? "!" : nil)

        return Button { actions.toggleInsulin() } label: {
            ZStack(alignment: .bottomTrailing) {
                SyringeShape()
                    .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 26 * scale, height: 26 * scale)
                    .rotationEffect(.degrees(45))
                    .frame(width: 28 * scale, height: 28 * scale)

                if let mark {
                    // Never smaller than a legible mark, however small the syringe is drawn.
                    Circle().fill(color)
                        .frame(width: max(10, 12 * scale), height: max(10, 12 * scale))
                        .overlay(Text(mark).font(.system(size: max(7, 8.5 * scale), weight: .heavy)).foregroundColor(.white))
                }
            }
            .frame(width: 28 * scale, height: 28 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { overInsulin = $0 }
    }

    private func dayAndTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    /// Value, arrow and unit/status, shared by both layouts so they can never drift apart.
    /// `valueScale` and `infoScale` size the text; `spacingScale` keeps the gaps in proportion.
    private func header(
        valueScale: CGFloat, infoScale: CGFloat, spacingScale: CGFloat, arrowGap: CGFloat = 0, insulinInHeader: Bool = false,
        theme: WidgetTheme, tint: Color, status: (text: String, color: Color)) -> some View
    {
        HStack(alignment: .center, spacing: 8 * spacingScale) {
            Text(valueText)
                .font(.system(size: 46 * valueScale, weight: .semibold))
                .foregroundColor(tint)
                .opacity(model.isStale ? 0.5 : 1)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(model.current?.trend.arrow ?? "")
                .font(.system(size: 30 * valueScale))
                .foregroundColor(tint)
                .padding(.leading, arrowGap) // grows with the text, so a large value keeps a proportional gap to its arrow

            Spacer(minLength: 16 * spacingScale)

            // The syringe sits beside the two lines of text, centred on them, so it reads as one block with the unit
            // and age. The text has a fixed width, as wide as the longest normal age ("59 min ago"): otherwise
            // "just now" becoming "1 min ago" changes the width of this block and everything beside it moves.
            let dose = insulinInHeader ? model.insulinStatus : nil
            let iconScale = min(max(valueScale, 0.85), model.settings.showGraph ? 1.7 : 4) * 0.9

            HStack(alignment: .center, spacing: 8 * infoScale) {
                if let dose {
                    insulinButton(dose, theme: theme, scale: iconScale)
                }

                VStack(alignment: .trailing, spacing: 0) {
                    Text(model.settings.unit.label)
                        .font(.system(size: 11 * infoScale))
                        .foregroundColor(theme.muted)
                    Text(status.text)
                        .font(.system(size: 11 * infoScale))
                        .foregroundColor(status.color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false) // never break a word; the value shrinks instead
                }
                .frame(minWidth: Self.statusTextWidth(scale: infoScale), alignment: .trailing)
            }
            .layoutPriority(1)
        }
    }

    /// Width of the widest everyday text in the unit and age lines ("59 min ago", "mmol/L") at the given scale.
    private static func statusTextWidth(scale: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 11 * scale)
        func width(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        return max(width("59 min ago"), width("mmol/L"))
    }

    /// The normal layout: header on top, graph below. Text scales with the card.
    private func graphLayout(_ size: CGSize, theme: WidgetTheme, tint: Color, status: (text: String, color: Color)) -> some View {
        let scale = min(max(min(size.width / Self.defaultWidth, size.height / Self.defaultHeight), 0.75), 2.4)
        let small = min(max(scale, 1), 1.7)

        return VStack(alignment: .leading, spacing: 2) {
            header(valueScale: scale, infoScale: small, spacingScale: 1, insulinInHeader: true,
                   theme: theme, tint: tint, status: status)

            GlucoseGraphView(
                readings: model.readings, hours: model.settings.hours, unit: model.settings.unit,
                now: model.now, theme: theme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.trailing, -Self.graphDotOverhang) // the plot ends at the padding, matching the left side
        }
        .padding(.horizontal, 16) // the same on both sides, so the graph and the header line up evenly in the card
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    /// The graph is hidden: the header alone fills the card. Both arrangements are tried and the one that lets the
    /// value grow larger is used, so a small card is not left mostly empty beside a small value.
    private func compactLayout(_ size: CGSize, theme: WidgetTheme, tint: Color, status: (text: String, color: Color)) -> some View {
        let plan = compactPlan(for: size)

        // Only view construction in here: a view builder does not allow declarations such as local functions.
        return Group {
            if plan.stacked {
                stackedHeader(fit: plan.fit, theme: theme, tint: tint, status: status)
            } else {
                header(valueScale: plan.fit, infoScale: plan.fit, spacingScale: plan.fit, arrowGap: 6 * plan.fit,
                       insulinInHeader: true, theme: theme, tint: tint, status: status)
            }
        }
        .padding(.horizontal, Self.compactPadding.width / 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity) // centred in the card
    }

    /// Which arrangement lets the value be larger at this size, and the scale to use for it.
    private func compactPlan(for size: CGSize) -> (stacked: Bool, fit: CGFloat) {
        let available = CGSize(
            width: size.width - Self.compactPadding.width, height: size.height - Self.compactPadding.height)

        func fit(_ design: CGSize) -> CGFloat {
            min(max(min(available.width / design.width, available.height / design.height), 0.3), 8)
        }

        // The syringe sits in the value's row, so it adds to the width of both arrangements.
        let withInsulin = model.settings.insulin.enabled
        let sideBySide = fit(Self.sideBySideDesign)
        let stacked = fit(CGSize(width: Self.stackedDesign.width + (withInsulin ? 10 : 0), height: Self.stackedDesign.height))
        return stacked > sideBySide ? (true, stacked) : (false, sideBySide)
    }

    /// Value and arrow on top, unit and status on one line underneath, all scaled by `fit`.
    private func stackedHeader(fit: CGFloat, theme: WidgetTheme, tint: Color, status: (text: String, color: Color)) -> some View {
        VStack(spacing: 5 * fit) {
            HStack(alignment: .center, spacing: 14 * fit) {
                Text(valueText)
                    .font(.system(size: 46 * fit, weight: .semibold))
                    .foregroundColor(tint)
                    .opacity(model.isStale ? 0.5 : 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text(model.current?.trend.arrow ?? "")
                    .font(.system(size: 30 * fit))
                    .foregroundColor(tint)

                if let dose = model.insulinStatus {
                    insulinButton(dose, theme: theme, scale: min(max(fit, 0.6), 2))
                        .padding(.horizontal, -4 * fit)
                }
            }

            infoLine(fit: fit, theme: theme, status: status)
        }
    }

    /// "mg/dL  ·  just now" as one run of text. The separator is spaces and a dot inside the string, so the gaps are
    /// part of the font and grow exactly with it, however large the widget is made.
    private func infoLine(fit: CGFloat, theme: WidgetTheme, status: (text: String, color: Color)) -> some View {
        var line = AttributedString(model.settings.unit.label)
        line.foregroundColor = theme.muted

        var separator = AttributedString("   ·   ")
        separator.foregroundColor = theme.muted

        var state = AttributedString(status.text)
        state.foregroundColor = status.color

        line.append(separator)
        line.append(state)

        return Text(line)
            .font(.system(size: 11 * fit))
            .lineLimit(1)
    }

    /// Top-left, like the close button of a macOS window. Fades in while the pointer is over the widget.
    /// Hides it to the menu bar, or quits when the icon is off.
    private func closeButton(_ theme: WidgetTheme) -> some View {
        Button { actions.close() } label: {
            ZStack {
                Circle().fill(theme.muted.opacity(0.28))
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(theme.text.opacity(0.85))
            }
            .frame(width: 13, height: 13)
            .frame(width: 22, height: 22) // a more generous click area than the drawn circle
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { overCloseButton = $0 } // stays visible while the pointer is on it, whatever the card reports
        .padding(.top, 3)
        .padding(.leading, 4)
    }

    @ViewBuilder
    private var menuContent: some View {
        Menu("Time range") {
            Picker("Time range", selection: $model.settings.hours) {
                Text("Last 3 hours").tag(3)
                Text("Last 6 hours").tag(6)
                Text("Last 12 hours").tag(12)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(!model.settings.showGraph) // the range only affects the graph

        Toggle("Show graph", isOn: $model.settings.showGraph)

        Menu("Units") {
            Picker("Units", selection: $model.settings.unit) {
                ForEach(GlucoseUnit.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Menu("Appearance") {
            Picker("Appearance", selection: $model.settings.theme) {
                Text("Follow system").tag(ThemeChoice.system)
                Text("Light").tag(ThemeChoice.light)
                Text("Dark").tag(ThemeChoice.dark)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Divider()

        Button("Alerts…") { actions.showAlerts() }

        if let status = model.insulinStatus {
            Button(status.state == .administered ? "Insulin: undo “administered”" : "Insulin: mark as administered") {
                actions.toggleInsulin()
            }
            // Turning it off also forgets the last "administered" time, so nothing about it stays saved.
            Button("Turn off the insulin reminder") {
                model.settings.insulin.enabled = false
                model.settings.insulin.lastAdministeredAt = nil
            }
        } else {
            Button("Set up the insulin reminder…") { actions.showAlerts() }
        }

        let snoozed = model.snoozedUntil.flatMap { $0 > model.now ? $0 : nil }
        Menu(snoozed.map { "Snooze alerts (until \(Self.clock.string(from: $0)))" } ?? "Snooze alerts") {
            Button("For 30 minutes") { actions.snoozeAlerts(30) }
            Button("For 1 hour") { actions.snoozeAlerts(60) }
            Button("For 2 hours") { actions.snoozeAlerts(120) }
            Divider()
            Button("Resume alerts") { actions.resumeAlerts() }.disabled(snoozed == nil)
        }

        Divider()

        Menu("Move to corner") {
            ForEach(Corner.allCases, id: \.self) { corner in
                Button(corner.title) { actions.moveToCorner(corner) }
            }
        }

        Toggle("Always on top", isOn: $model.settings.alwaysOnTop)
        Toggle("Show menu bar icon", isOn: $model.settings.showStatusIcon)
        // Hiding the widget without the menu bar item would leave no way to bring it back.
        Button("Hide to menu bar") { actions.hideToMenuBar() }
            .disabled(!model.settings.showStatusIcon)

        #if DEBUG
        if model.devEnabled {
            Divider()
            Menu("Developer: simulate reading") {
                Picker("Scenario", selection: $model.simulationIndex) {
                    Text("Use real data").tag(-1)
                    ForEach(Array(Simulation.scenarios.enumerated()), id: \.offset) { index, scenario in
                        Text(scenario.name).tag(index)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        #endif

        Divider()

        Button("Check for updates…") { actions.checkForUpdates() }
        Button("About Libre Monitor") { actions.showAbout() }
        Button("Sign out and quit") { actions.signOut() }
        Button("Quit") { actions.quit() }
    }

    private var valueText: String {
        guard let current = model.current else { return "--" }
        return GlucoseUnits.format(current.mgPerDl, unit: model.settings.unit)
    }

    private func valueTint(_ theme: WidgetTheme) -> Color {
        guard let current = model.current else { return theme.muted }
        return model.isStale ? theme.muted : theme.color(forMgPerDl: current.mgPerDl)
    }

    private func statusText(_ theme: WidgetTheme) -> (text: String, color: Color) {
        if model.isSimulated {
            // Make it impossible to mistake a fake value for a real one.
            return ("SIMULATED", theme.high)
        }

        if let problem = model.problem {
            switch problem {
            case .signInNeeded: return ("sign-in needed", theme.low)
            case .serviceChanged: return ("service changed", theme.low)
            case .reconnecting:
                // The value on screen is getting old while we cannot reach the service: say how old.
                if let age = model.age, age >= 120 { return ("not updating · \(formatAge(age))", theme.high) }
                return ("reconnecting", theme.high)
            }
        }

        if let age = model.age {
            return (formatAge(age), model.isStale ? theme.high : theme.muted)
        }

        return (model.realUpdate == nil ? "connecting" : "no reading", theme.muted)
    }
}

/// A syringe drawn in a 24 x 24 box, upright: plunger at the top, needle at the bottom. The view rotates it.
struct SyringeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        func line(_ path: inout Path, _ a: CGPoint, _ b: CGPoint) { path.move(to: a); path.addLine(to: b) }

        var path = Path()
        path.move(to: p(9, 6))
        path.addLine(to: p(15, 6))
        path.addLine(to: p(15, 18))
        path.addLine(to: p(9, 18))
        path.closeSubpath()
        line(&path, p(7, 6), p(17, 6))    // flange
        line(&path, p(12, 6), p(12, 2))   // plunger
        line(&path, p(9, 2), p(15, 2))    // thumb rest
        line(&path, p(12, 18), p(12, 23)) // needle
        for y in [10, 13, 16] as [CGFloat] { line(&path, p(15, y), p(13, y)) } // markings
        return path
    }
}
