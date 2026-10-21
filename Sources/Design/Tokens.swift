import SwiftUI

/// Design tokens. One warm accent on warm neutrals, 8pt grid, serif display type.
/// No gradient washes, no neon-on-dark, no emoji-as-icon.
enum Tokens {
    // MARK: Color

    /// Burnt sienna — the single accent. Used for the active route, primary actions, focus rings.
    static let accent = Color(light: 0xB4462A, dark: 0xE8765A)
    /// Deep pine, reserved for "live / connected" state. Never used as decoration.
    static let live = Color(light: 0x2C5A44, dark: 0x6FBF95)

    static let canvas = Color(light: 0xF7F4EF, dark: 0x14120F)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1E1B17)
    static let surfaceRaised = Color(light: 0xFBF8F3, dark: 0x262219)

    static let ink = Color(light: 0x1C1A17, dark: 0xF3EFE8)
    static let inkSecondary = Color(light: 0x6A625A, dark: 0xA79E92)
    static let hairline = Color(light: 0xE2DCD2, dark: 0x322D26)

    static let danger = Color(light: 0xA32E2E, dark: 0xE07A7A)

    // MARK: Spacing (8pt grid)

    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 16
    static let s4: CGFloat = 24
    static let s5: CGFloat = 32
    static let s6: CGFloat = 48

    // MARK: Radius

    static let rSmall: CGFloat = 8
    static let rMedium: CGFloat = 12
    static let rLarge: CGFloat = 18

    // MARK: Type

    /// Serif display face (New York on Apple platforms) for screen titles and numbers that matter.
    static func display(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .serif)
    }

    static func heading(_ size: CGFloat = 17) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    static func body(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    static func mono(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    static let caption = Font.system(size: 12, weight: .medium, design: .default)
}

extension Color {
    /// Light/dark pair from hex literals, resolved at draw time.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
