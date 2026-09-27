import Foundation

/// The bounded numbers of design §4.3, and the one way the kit writes a number into CSS
/// (kit #125, security review L3).
///
/// The validator accepts a number only if it is finite and, once snapped to its option's step,
/// inside its option's range; the snapped value is what a `ValidatedTheme` carries. The generator
/// checks the same limits again before it writes anything, and writes every number through
/// `css(_:)`: integer arithmetic on thousandths, so no locale, `printf` or `NumberFormatter`
/// setting can ever change a byte of the stylesheet.
package enum ThemeNumber: String, CaseIterable, Sendable {
    case bodySize, lineHeight, headingWeight, radius, maxWidth
    case h1Size = "h1.size"
    case h1LetterSpacing = "h1.letterSpacing"
    case h2LetterSpacing = "h2.letterSpacing"
    case blockquoteBarWidth = "blockquote.style.width"
    case hrThickness = "hr.style.thickness"

    /// Design §4.3's ranges.
    package var range: ClosedRange<Double> {
        switch self {
        case .bodySize: 14...18
        case .lineHeight: 1.4...1.9
        case .headingWeight: 400...900
        case .radius: 0...16
        case .maxWidth: 600...1000
        case .h1Size: 1.8...2.4
        case .h1LetterSpacing, .h2LetterSpacing: -0.03...0.03
        case .blockquoteBarWidth: 2...4
        case .hrThickness: 1...4
        }
    }

    /// Every value is snapped to a multiple of this. All steps are whole thousandths, so every
    /// snapped value prints exactly with `css(_:)`'s three decimals.
    package var step: Double {
        switch self {
        case .bodySize, .radius, .maxWidth, .blockquoteBarWidth, .hrThickness: 1
        case .lineHeight: 0.05
        case .headingWeight: 50
        case .h1Size: 0.1
        case .h1LetterSpacing, .h2LetterSpacing: 0.005
        }
    }

    /// Anything this far outside every range is refused before any arithmetic on it, so snapping
    /// can't overflow (`1e308 / 0.005` is infinite).
    private static let sanityBound = 1_000_000.0

    /// The value snapped to `step`, or nil if it isn't finite or the snapped value is outside
    /// `range`. `-0` becomes `0`. A value off-step by any amount snaps to the nearest step.
    package func snapped(_ value: Double) -> Double? {
        guard value.isFinite, abs(value) <= Self.sanityBound else { return nil }
        let steps = (value / step).rounded()
        var result = steps * step
        // Re-derive from thousandths so e.g. 35 × 0.05 is exactly the double nearest 1.75.
        result = Double(Int((result * 1000).rounded())) / 1000
        if result == 0 { result = 0 } // -0 → 0
        guard result >= range.lowerBound, result <= range.upperBound else { return nil }
        return result
    }

    /// The generator's own check (defence in depth): finite, inside `range`, on a step.
    package func isAcceptable(_ value: Double) -> Bool {
        guard let snapped = snapped(value) else { return false }
        return abs(snapped - value) <= 1e-9
    }

    /// The single CSS number formatter: fixed-point, at most three decimals, `.` as the separator,
    /// no exponent, no trailing zeros, never `-0`. Only ever called with a value that passed
    /// `isAcceptable`, so the thousandths always fit in an `Int`.
    package static func css(_ value: Double) -> String {
        let thousandths = Int((value * 1000).rounded())
        if thousandths == 0 { return "0" }
        let sign = thousandths < 0 ? "-" : ""
        let magnitude = thousandths.magnitude
        let whole = magnitude / 1000
        var fraction = magnitude % 1000
        guard fraction != 0 else { return "\(sign)\(whole)" }
        var digits = 3
        while fraction % 10 == 0 {
            fraction /= 10
            digits -= 1
        }
        let fractionText = String(fraction)
        let padded = String(repeating: "0", count: digits - fractionText.count) + fractionText
        return "\(sign)\(whole).\(padded)"
    }
}
