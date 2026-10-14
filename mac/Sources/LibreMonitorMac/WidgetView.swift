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

    private static let defaultWidth: CGFloat = 280
    private static let defaultHeight: CGFloat = 172

    var body: some View {
        let theme = WidgetTheme.forScheme(colorScheme)

        GeometryReader { geometry in
            let scale = min(max(min(geometry.size.width / Self.defaultWidth, geometry.size.height / Self.defaultHeight), 0.75), 2.4)
            let small = min(max(scale, 1), 1.7)
            let tint = valueTint(theme)
            let status = statusText(theme)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 8) {
                    Text(valueText)
                        .font(.system(size: 46 * scale, weight: .semibold))
                        .foregroundColor(tint)
                        .opacity(model.isStale ? 0.5 : 1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)

                    Text(model.current?.trend.arrow ?? "")
                        .font(.system(size: 30 * scale))
                        .foregroundColor(tint)

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 0) {
                        Text(model.settings.unit.label)
                            .font(.system(size: 11 * small))
                            .foregroundColor(theme.muted)
                        Text(status.text)
                            .font(.system(size: 11 * small))
                            .foregroundColor(status.color)
                    }
                }

                GlucoseGraphView(
                    readings: model.readings, hours: model.settings.hours, unit: model.settings.unit,
                    now: model.now, theme: theme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.leading, 16)
            .padding(.trailing, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        // Without a content shape only drawn pixels (the graph) are clickable, so the menu opened nowhere else.
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .overlay(alignment: .topLeading) {
            if hovering { closeButton(theme) }
        }
        .contextMenu { menuContent }
    }

    /// Top-left, like the close button of a macOS window. Appears while the pointer is over the widget.
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
            return problem == .signInNeeded ? ("sign-in needed", theme.low) : ("reconnecting", theme.high)
        }

        if let age = model.age {
            return (formatAge(age), model.isStale ? theme.high : theme.muted)
        }

        return (model.realUpdate == nil ? "connecting" : "no reading", theme.muted)
    }
}
