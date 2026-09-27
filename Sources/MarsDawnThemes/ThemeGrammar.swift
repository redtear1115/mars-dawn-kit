import Foundation

/// The closed, byte-level patterns every theme token has to match (kit #125, security review M1).
///
/// Every check here walks the string's UTF-8 bytes and accepts ASCII only, instead of using a
/// regular expression: `NSRegularExpression`'s `$` also matches before a trailing `\n`, so
/// `^[a-z0-9-]+$` accepts `"dawn\n"`, and Swift's `Character`-based matching folds `"\r\n"` or a
/// base letter plus a combining mark into one grapheme. Bytes can't be folded or anchored loosely.
/// One predicate per token, used by the validator, the CSS generator, the CLI and (S3) the
/// registry's directory-name check, so none of them can drift from the others.
package enum ThemeGrammar {
    /// Design §4.2: at most 32 characters.
    package static let maxIDLength = 32

    /// `^[a-z0-9]+(-[a-z0-9]+)*$`, 1...32 bytes, ASCII only: lowercase letters and digits in
    /// runs separated by single hyphens, no leading or trailing hyphen.
    package static func isThemeID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= maxIDLength else { return false }
        var previousWasHyphen = true // a leading hyphen is refused like a doubled one
        for byte in bytes {
            if byte == UInt8(ascii: "-") {
                if previousWasHyphen { return false }
                previousWasHyphen = true
            } else if isLowerAlnum(byte) {
                previousWasHyphen = false
            } else {
                return false
            }
        }
        return !previousWasHyphen
    }

    /// Exactly `#` followed by six ASCII hex digits (either case): 7 bytes, nothing else. No
    /// three-digit shorthand, no alpha, no names, no `var(…)`, no full-width or other-script digits.
    package static func isHexColor(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 7, bytes[0] == UInt8(ascii: "#") else { return false }
        return bytes.dropFirst().allSatisfy(isHexDigit)
    }

    /// `MAJOR.MINOR.PATCH`, each 1–4 ASCII digits.
    package static func isVersion(_ text: String) -> Bool {
        let parts = Array(text.utf8).split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { (1...4).contains($0.count) && $0.allSatisfy(isDigit) }
    }

    /// An SPDX-style licence identifier or expression token: 1–64 bytes of ASCII letters, digits,
    /// `.`, `-` and `+`, starting with a letter (`Apache-2.0`, `MIT`, `CC-BY-4.0`, `GPL-3.0+`).
    package static func isLicense(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first, isLetter(first) else { return false }
        return bytes.allSatisfy { isLetter($0) || isDigit($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "+") }
    }

    /// GitHub's username rule: 1–39 ASCII letters, digits and single hyphens, no leading or
    /// trailing hyphen.
    package static func isGitHubUsername(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...39).contains(bytes.count) else { return false }
        var previousWasHyphen = true
        for byte in bytes {
            if byte == UInt8(ascii: "-") {
                if previousWasHyphen { return false }
                previousWasHyphen = true
            } else if isLetter(byte) || isDigit(byte) {
                previousWasHyphen = false
            } else {
                return false
            }
        }
        return !previousWasHyphen
    }

    /// A language key in a `name`/`summary` map: a BCP-47 subset, `ll` or `lll`, then an
    /// optional `-Ssss` script and an optional `-RR` region (`en`, `zh-Hant`, `pt-BR`,
    /// `zh-Hant-TW`).
    package static func isLocaleKey(_ text: String) -> Bool {
        let parts = Array(text.utf8).split(separator: UInt8(ascii: "-"), omittingEmptySubsequences: false)
        guard let language = parts.first, (2...3).contains(language.count), language.allSatisfy(isLowerLetter) else { return false }
        var rest = parts.dropFirst()
        if let script = rest.first, script.count == 4 {
            guard isUpperLetter(script.first!), script.dropFirst().allSatisfy(isLowerLetter) else { return false }
            rest = rest.dropFirst()
        }
        if let region = rest.first {
            guard region.count == 2, region.allSatisfy(isUpperLetter) else { return false }
            rest = rest.dropFirst()
        }
        return rest.isEmpty
    }

    // MARK: - Bytes

    private static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    private static func isLowerLetter(_ b: UInt8) -> Bool { b >= 0x61 && b <= 0x7A }
    private static func isUpperLetter(_ b: UInt8) -> Bool { b >= 0x41 && b <= 0x5A }
    private static func isLetter(_ b: UInt8) -> Bool { isLowerLetter(b) || isUpperLetter(b) }
    private static func isLowerAlnum(_ b: UInt8) -> Bool { isLowerLetter(b) || isDigit(b) }
    private static func isHexDigit(_ b: UInt8) -> Bool {
        isDigit(b) || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46)
    }
}
