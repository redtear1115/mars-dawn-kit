import Foundation

/// "Open this file at line N", sent from the `marsdawn` command-line tool to the app.
///
/// The initializer validates; an invalid path is rejected, never rewritten into a valid one.
/// The command-line tool resolves the path (including symlinks) before building a request.
public struct RevealRequest: Equatable, Sendable {
    /// Absolute path of at most `maxPathBytes` UTF-8 bytes, with no `.`/`..` segments, no `//`,
    /// no trailing `/`, and no control characters, bidi controls or line/paragraph separators.
    public let path: String
    /// 1-based line, 1...999,999,999.
    public let line: Int

    public static let lineRange = 1...999_999_999
    /// Longest accepted path in UTF-8 bytes (`PATH_MAX`).
    public static let maxPathBytes = 1024

    /// Returns nil when `path` or `line` is not acceptable (see the property docs).
    public init?(path: String, line: Int) {
        guard Self.isValidPath(path), Self.lineRange.contains(line) else { return nil }
        self.path = path
        self.line = line
    }

    /// Bidi controls (which can disguise how a path reads) and line/paragraph separators.
    /// Other format characters, such as the ZWJ in emoji sequences, stay allowed.
    static let forbiddenScalars: Set<UInt32> = Set([0x200E, 0x200F, 0x061C, 0x2028, 0x2029])
        .union(0x202A...0x202E)
        .union(0x2066...0x2069)

    static func isValidPath(_ path: String) -> Bool {
        // Segments are checked on UTF-8 bytes, not Characters: a combining mark after a `/`
        // joins it into one grapheme and would hide `..`, `.` or `//` from Character checks.
        let bytes = Array(path.utf8)
        guard bytes.first == slash, bytes.last != slash, bytes.count <= maxPathBytes else { return false }
        guard !path.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control || forbiddenScalars.contains($0.value)
        }) else { return false }
        let segments = bytes.dropFirst().split(separator: slash, omittingEmptySubsequences: false)
        return !segments.contains { $0.isEmpty || $0.elementsEqual([dot]) || $0.elementsEqual([dot, dot]) }
    }

    private static let slash = UInt8(ascii: "/")
    private static let dot = UInt8(ascii: ".")

    // MARK: Command-line arguments

    /// Splits a command-line argument into a path and an optional line.
    ///
    /// - An argument naming an existing file is always a plain path, even if it ends in
    ///   `:digits`.
    /// - Otherwise `path:N` is split when `path` exists, and `path:N:M` (a column, ignored)
    ///   when `path:N` does not exist but `path` does.
    /// - `N` and `M` must each be 1–9 ASCII digits. Anything else, including a 10-digit
    ///   column, means no line: the whole argument is returned as the path.
    /// - `N` is returned as written, so `a.md:0` yields line 0 for `init?(path:line:)` to reject.
    public static func parseArgument(_ arg: String, fileExists: (String) -> Bool) -> (path: String, line: Int?) {
        if fileExists(arg) { return (arg, nil) }
        if let (head, number) = splitNumericSuffix(arg) {
            if fileExists(head) { return (head, number) }
            if let (path, line) = splitNumericSuffix(head), fileExists(path) { return (path, line) }
        }
        return (arg, nil)
    }

    /// Splits at the last ASCII `:`, on UTF-8 bytes rather than `Character`s: a `:` that a
    /// Prepend scalar (U+0600, say) or a combining mark has joined into one grapheme is
    /// invisible to `lastIndex(of: ":")`, which would then hand the whole argument back as
    /// a path. The colon and the digits are ASCII, so both sides are whole UTF-8.
    private static func splitNumericSuffix(_ string: String) -> (String, Int)? {
        let bytes = Array(string.utf8)
        guard let colon = bytes.lastIndex(of: UInt8(ascii: ":")) else { return nil }
        let digits = bytes[(colon + 1)...]
        guard (1...9).contains(digits.count),
              digits.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        guard let number = Int(String(decoding: digits, as: UTF8.self)) else { return nil }
        return (String(decoding: bytes[..<colon], as: UTF8.self), number)
    }
}
