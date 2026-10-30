import SwiftUI
import UIKit

/// FIT-297: design system v2 (https://claude.ai/artifact/VwER3yUGiQf7xJF6hxVcQL). Steel neutrals, one plate colour
/// per theme (competition bumper plates), condensed heavy numbers like a plate's markings.
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
    /// Titles and big numbers: Archivo Condensed when bundled, else the system face condensed. Scales with Dynamic Type.
    static func display(_ size: CGFloat, weight: Font.Weight = .black, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
        let name = switch weight {
        case .black, .heavy: "ArchivoCondensed-Black"
        case .bold: "ArchivoCondensed-Bold"
        default: "ArchivoCondensed-ExtraBold"
        }
        if UIFont(name: name, size: size) != nil { return .custom(name, size: size, relativeTo: style) }
        return .system(size: UIFontMetrics(forTextStyle: style.uiKit).scaledValue(for: size), weight: weight).width(.condensed)
    }
}

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
