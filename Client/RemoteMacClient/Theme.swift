import SwiftUI

enum OrielTheme {
    /// The single accent from the mark.
    static let amber = Color(red: 0.949, green: 0.710, blue: 0.267)
    static let ink = Color(red: 0.055, green: 0.067, blue: 0.086)
    static let panel = Color.white.opacity(0.08)
    static let panelStrong = Color.white.opacity(0.16)
    static let hairline = Color.white.opacity(0.12)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
