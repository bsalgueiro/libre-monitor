import Foundation

/// "just now" / "x min ago", as on the Windows widget.
func formatAge(_ age: TimeInterval) -> String {
    age < 60 ? "just now" : "\(Int(age / 60)) min ago"
}
