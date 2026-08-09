import SwiftUI

/// Visual identity for ryokuon, referenced against dskit-swiftui's token
/// approach (color/spacing/typography/corner-radius as named constants, not
/// scattered literals) — https://github.com/imodeveloper/dskit-swiftui.
/// Not a dependency: this app stays at zero external packages, borrowing
/// only the *shape* of a token system, sized for five small screens.
///
/// The one real design decision here: **me is always mint, remote is
/// always sky** — in the level meter, the gain sliders, and the speaker
/// tag in the transcript. Channel separation is this app's entire reason
/// to exist (that's the whole grilling brief), so the one place worth
/// spending a deliberate color choice is making that separation visible
/// everywhere at a glance, not just readable in a label.
enum RTheme {
    // MARK: Color

    static let me = Color(red: 0.33, green: 0.78, blue: 0.65) // mint — matches the app icon
    static let remote = Color(red: 0.35, green: 0.58, blue: 0.86) // sky — matches the app icon
    static let ink = Color(red: 0.11, green: 0.16, blue: 0.19) // primary text — warm near-black, not pure black
    static let slate = Color(red: 0.36, green: 0.45, blue: 0.50) // secondary text
    static let mist = Color(red: 0.94, green: 0.97, blue: 0.96) // card/surface background
    static let record = Color(red: 0.90, green: 0.29, blue: 0.32) // recording indicator — stays conventional red
    static let warning = Color(red: 0.95, green: 0.61, blue: 0.31) // silence warning / recovered badge

    // MARK: Spacing

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    static let cornerRadius: CGFloat = 12
    static let actionHeight: CGFloat = 36

    // MARK: Typography

    /// Rounded display face for headings — the mic-emoji icon and the
    /// "친근한 개인용 도구" brief called for something a little softer than
    /// default San Francisco, without going full playful/maximalist.
    static func heading(_ size: CGFloat) -> Font {
        .system(size: size, weight: .bold, design: .rounded)
    }

    /// Transcript lines are literally structured data
    /// (`startMs|speaker|text`) — monospacing the timestamp is information,
    /// not decoration, the same way TranscriptBuilder's own format is
    /// column-aligned on paper.
    static let mono = Font.system(.callout, design: .monospaced)
}

extension View {
    func rCard() -> some View {
        padding(RTheme.Spacing.md)
            .background(RTheme.mist, in: RoundedRectangle(cornerRadius: RTheme.cornerRadius))
    }
}
