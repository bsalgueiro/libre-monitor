import Foundation
import LibreMonitorKit

/// Date and time in the format of the Mac's region settings, for the insulin messages.
func formatDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func plural(_ count: Int, _ unit: String) -> String { count == 1 ? "1 \(unit)" : "\(count) \(unit)s" }

/// One line for the menu: "Sensor ends in about 6 days (Fri 23 Oct)".
func sensorSummary(_ sensor: SensorInfo, now: Date, durationDays: Int) -> String {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
    let date = formatter.string(from: SensorSchedule.endsAt(sensor, durationDays: durationDays))
    let left = SensorSchedule.remaining(sensor, now: now, durationDays: durationDays)

    if left <= 0 { return "Sensor due to have ended (\(date))" }
    if left < 24 * 3600 { return "Sensor ends in about \(plural(max(1, Int((left / 3600).rounded())), "hour"))" }
    return "Sensor ends in about \(plural(Int((left / 86400).rounded()), "day")) (\(date))"
}

/// The hover message on the unit and age text, in the system date and time format.
func sensorDetail(_ sensor: SensorInfo, now: Date, durationDays: Int) -> String {
    let ends = formatDateTime(SensorSchedule.endsAt(sensor, durationDays: durationDays))
    let line = SensorSchedule.remaining(sensor, now: now, durationDays: durationDays) <= 0 ? "Due to have ended about \(ends)." : "Ends about \(ends)."
    return "Sensor started \(formatDateTime(sensor.activatedAt)).\n\(line)"
}

/// "just now" / "x min ago", as on the Windows widget.
func formatAge(_ age: TimeInterval) -> String {
    age < 60 ? "just now" : "\(Int(age / 60)) min ago"
}
