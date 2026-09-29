import Foundation

/// WCAG 2.x contrast between `#RRGGBB` colours, and the sRGB `color-mix` the stylesheet uses.
/// Only ever called with colours `ThemeGrammar.isHexColor` accepted.
package enum ThemeContrast {
    static func components(_ hex: String) -> [Double] {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return [Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF)].map { $0 / 255 }
    }

    package static func luminance(_ hex: String) -> Double {
        let linear = components(hex).map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    package static func ratio(_ a: String, _ b: String) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// `color-mix(in srgb, a, b amount)`: interpolation of the gamma-encoded components, rounded
    /// to the nearest 8-bit value, as WebKit paints it.
    package static func mix(_ a: String, _ b: String, _ amount: Double) -> String {
        let mixed = zip(components(a), components(b)).map { ($0 * (1 - amount) + $1 * amount) * 255 }
        return String(format: "#%02X%02X%02X", Int(mixed[0].rounded()), Int(mixed[1].rounded()), Int(mixed[2].rounded()))
    }

    /// A ratio for a message: two decimals, truncated (not rounded) so a failing 4.496 never
    /// prints as a passing-looking "4.50".
    package static func format(_ ratio: Double) -> String {
        let hundredths = Int((ratio * 100).rounded(.down))
        let fraction = hundredths % 100
        return "\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}
