import Foundation

/// Date and time in the format of the Mac's region settings, for the insulin messages.
func formatDateTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

/// "just now" / "x min ago", as on the Windows widget.
func formatAge(_ age: TimeInterval) -> String {
    age < 60 ? "just now" : "\(Int(age / 60)) min ago"
}
