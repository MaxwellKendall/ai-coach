import SwiftUI
import UIKit

/// FIT-297: design system v2 (https://claude.ai/artifact/VwER3yUGiQf7xJF6hxVcQL). Steel neutrals, one plate colour
/// per theme (competition bumper plates).
enum Plate: String, CaseIterable, Identifiable {
    case blue, red, yellow, green
    static let key = "plate"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .blue: "Blue 20"
        case .red: "Red 25"
        case .yellow: "Yellow 15"
        case .green: "Green 10"
        }
    }

    /// The plate as a fill: Start, checked ticks, the active step.
    var accent: Color {
        switch self {
        case .blue: Color(light: 0x1747d6, dark: 0x5f86ff)
        case .red: Color(light: 0xd21f2f, dark: 0xff5a62)
        case .yellow: Color(light: 0xf2c200, dark: 0xffd21f)
        case .green: Color(light: 0x0f7d43, dark: 0x2fc774)
        }
    }

    /// The plate as a line or text on the page, 3:1 or better everywhere (yellow on white needs the darker one).
    var mark: Color {
        self == .yellow ? Color(light: 0x7a5f00, dark: 0xffd21f) : accent
    }

    /// Text and glyphs on an accent fill.
    var onAccent: Color {
        switch self {
        case .yellow: Color(light: 0x0e1013, dark: 0x0e1013)
        default: Color(light: 0xffffff, dark: 0x0f1012)
        }
    }

    static var current: Plate { Plate(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .blue }
}

extension Color {
    /// Rows, cards and inputs on the page.
    static let fill = Color(light: 0xeef0f2, dark: 0x1b1d21)
    /// The page behind cards, and the cards on it.
    static let canvas = Color(light: 0xf5f6f7, dark: 0x08090a)
    static let surface = Color(light: 0xffffff, dark: 0x16181b)
    static let fillStrong = Color(light: 0xe1e4e8, dark: 0x2a2d32)
    static let ink = Color(light: 0x0e1013, dark: 0xf1f2f4)
    /// Secondary text, 4.5:1 on the page and on fill in both modes.
    static let inkMuted = Color(light: 0x575c64, dark: 0xa2a7af)
    /// Chevrons and empty rings only.
    static let inkFaint = Color(light: 0x80858d, dark: 0x6f747c)
    static let good = Color(light: 0x0f7d43, dark: 0x4fd68a)

    init(light: UInt32, dark: UInt32) {
        func ui(_ hex: UInt32) -> UIColor {
            UIColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
    }
}

extension Font {
    /// Titles (bold) and big numbers (semibold), in sentence case at normal width: the author dropped the condensed
    /// caps after using them (2026-10-30). Scales with Dynamic Type.
    static func display(_ size: CGFloat, weight: Font.Weight = .bold, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        .system(size: UIFontMetrics(forTextStyle: style.uiKit).scaledValue(for: size), weight: weight)
    }
}

// MARK: The look every screen shares (author, 2026-10-30: Today's grey page, white cards with a soft shadow, plenty of
// room, little text). Colours come from the tokens above and the plate colour, so light, dark and each plate follow.

extension View {
    /// A screen's page: the canvas behind its cards, edge to edge.
    func screenBackground() -> some View { background(Color.canvas.ignoresSafeArea()) }

    /// A raised card: white on the canvas, a soft shadow rather than a border.
    func card(padding: CGFloat = 20) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
    }

    /// The card's white and shadow alone, for a view that sets its own padding and size.
    func cardBackground() -> some View {
        background { RoundedRectangle(cornerRadius: 24).fill(Color.surface).shadow(color: .black.opacity(0.06), radius: 18, y: 8) }
    }

    /// A row's white and lighter shadow, for a choice or list row sitting on the canvas.
    func rowBackground() -> some View {
        background { RoundedRectangle(cornerRadius: 18).fill(Color.surface).shadow(color: .black.opacity(0.04), radius: 10, y: 4) }
    }

    /// A List or Form on the canvas, its sections as white cards.
    func themedList() -> some View {
        scrollContentBackground(.hidden).background(Color.canvas.ignoresSafeArea())
    }
}

/// The one plate-coloured action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Filled(configuration: configuration) }

    private struct Filled: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 56)
                .foregroundStyle(Plate.current.onAccent)
                .background(.tint, in: .rect(cornerRadius: 18))
                .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
        }
    }
}

/// Actions beside or under the primary one: white on the canvas.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(Color.ink)
            .background(configuration.isPressed ? Color.fillStrong : Color.surface, in: .rect(cornerRadius: 14))
    }
}

/// A choice or list row that's tapped as a whole: a white card on the canvas.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18).fill(configuration.isPressed ? Color.fillStrong : Color.surface)
                    .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
            }
            .contentShape(.rect)
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle { static var primary: PrimaryButtonStyle { .init() } }
extension ButtonStyle where Self == SecondaryButtonStyle { static var secondary: SecondaryButtonStyle { .init() } }
extension ButtonStyle where Self == RowButtonStyle { static var row: RowButtonStyle { .init() } }

private extension Font.TextStyle {
    var uiKit: UIFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .footnote: .footnote
        case .caption: .caption1
        default: .body
        }
    }
}
