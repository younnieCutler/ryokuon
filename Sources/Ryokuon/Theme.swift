import SwiftUI

/// Layout constants only — no custom palette, no custom type. The brief is
/// explicit: look like a stock Apple app (Voice Memos / Finder / System
/// Settings), not a branded product. System colors (`.accentColor`,
/// `.secondary`, `.red`) and system text styles (`.headline`, `.caption`)
/// already do that and adapt to light/dark and the user's accent color
/// preference for free — a custom token set would fight both.
///
/// The one place ME/REMOTE still need to read apart at a glance (level
/// meters, gain sliders, transcript speaker tags) uses `.accentColor` for
/// me and `.secondary` for remote — not a second brand color, just "the
/// active/primary one" vs "the other one," the same distinction System
/// Settings makes between a selected and unselected row.
enum RTheme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
    }

    /// Only used for the thin level-meter/progress tracks — everything
    /// else (buttons, rows, sheets) uses system defaults with no radius
    /// override.
    static let meterCornerRadius: CGFloat = 2
}
