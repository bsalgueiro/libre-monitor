import LibreMonitorKit
import SwiftUI

/// What the widget's right-click menu can ask the app to do. Grows as menu items are added.
struct WidgetActions {
    var signOut: () -> Void
    var quit: () -> Void
}

/// The widget content: current value, trend arrow, age, and the graph. Laid out for 280 x 172 points and scaled
/// with the window, like the Windows widget.
struct WidgetView: View {
    @ObservedObject var model: AppModel
    let actions: WidgetActions

    @Environment(\.colorScheme) private var colorScheme

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
        .contextMenu {
            Button("Sign out and quit") { actions.signOut() }
            Button("Quit") { actions.quit() }
        }
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
