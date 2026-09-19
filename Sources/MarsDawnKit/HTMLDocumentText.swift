import CoreFoundation
import Foundation

/// Turns the bytes of a local HTML file into the page the HTML scheme handler serves.
///
/// The text is decoded (see `decode`), the frame/embedding tags and every `<link` except a plain
/// stylesheet are renamed (`neutralizingHTMLDocumentTags`), and the result is UTF-8. The page is
/// served as `text/html; charset=utf-8`, which outranks any `<meta charset>` left in it.
public enum HTMLDocumentText {
    public struct Prepared: Sendable, Equatable {
        /// The page as UTF-8.
        public let html: Data
        /// Whether the page might run something: a `<script` element or an inline event handler.
        /// **For the affordance and the copy only; never a control.** It decides whether the
        /// window offers to run the document at all, so that a file with no script never spends
        /// the one signal the design rests on.
        public let mightRunScript: Bool
        /// Whether the page asks for code from the web. **Copy only, never a control** — the CSP
        /// refuses remote code whatever this says; this is only what lets the bar explain the
        /// refusal instead of leaving a page silently half-working.
        public let asksForRemoteScript: Bool
        /// The WHATWG name of the encoding the file was read with.
        public let encoding: String
    }

    /// Files larger than this aren't prepared.
    nonisolated static let maximumInputBytes = 16 << 20

    /// Prepares `data` off the main thread. Nil if the file is over 16 MB.
    public static func prepare(_ data: Data) async -> Prepared? {
        await Task.detached(priority: .userInitiated) {
            prepareNow(data)
        }.value
    }

    nonisolated static func prepareNow(_ data: Data) -> Prepared? {
        guard data.count <= maximumInputBytes else { return nil }
        let (text, encoding) = decode(Array(data))
        return Prepared(
            html: Data(neutralizingHTMLDocumentTags(text).utf8),
            mightRunScript: mightRunScript(text),
            asksForRemoteScript: asksForRemoteScript(text),
            encoding: encoding
        )
    }

    // MARK: Decoding

    /// Decodes a file in this order: a UTF-8 or UTF-16 byte order mark; valid UTF-8; an
    /// allow-listed encoding named by `<meta>` in the first 1024 bytes (WHATWG prescan);
    /// otherwise windows-1252, which decodes every byte.
    nonisolated static func decode(_ bytes: [UInt8]) -> (text: String, encoding: String) {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return (String(decoding: bytes.dropFirst(3), as: UTF8.self), "utf-8")
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return (decodeUTF16(bytes.dropFirst(2), bigEndian: false), "utf-16le")
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return (decodeUTF16(bytes.dropFirst(2), bigEndian: true), "utf-16be")
        }
        let utf8 = String(decoding: bytes, as: UTF8.self)
        if utf8.utf8.elementsEqual(bytes) {
            return (utf8, "utf-8")
        }
        if let label = prescan(bytes.prefix(1024)), let encoding = allowedEncoding(forLabel: label) {
            switch encoding {
            case .utf8:
                // A `utf-16` label on a file without a byte order mark means UTF-8.
                return (utf8, "utf-8")
            case .windows1252:
                return (decodeWindows1252(bytes), "windows-1252")
            case .foundation(let name, let cfEncoding):
                let stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let text = String(data: Data(bytes), encoding: stringEncoding) {
                    return (text, name)
                }
            }
        }
        return (decodeWindows1252(bytes), "windows-1252")
    }

    private nonisolated static func decodeUTF16(_ bytes: ArraySlice<UInt8>, bigEndian: Bool) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var index = bytes.startIndex
        while index + 1 < bytes.endIndex {
            let first = UInt16(bytes[index]), second = UInt16(bytes[index + 1])
            units.append(bigEndian ? first << 8 | second : second << 8 | first)
            index += 2
        }
        var text = String(decoding: units, as: UTF16.self)
        if index < bytes.endIndex { text.append("\u{FFFD}") }
        return text
    }

    /// WHATWG windows-1252: 0x80–0x9F per the table, the five undefined bytes map to the C1
    /// control with the same value, and every other byte to the same code point.
    nonisolated static func decodeWindows1252(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes {
            let value = (0x80...0x9F).contains(byte) ? windows1252High[Int(byte) - 0x80] : UInt32(byte)
            scalars.append(Unicode.Scalar(value)!)
        }
        return String(scalars)
    }

    private nonisolated static let windows1252High: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]

    // MARK: Encoding labels

    enum AllowedEncoding: Equatable {
        case utf8
        case windows1252
        /// A WHATWG name and the Core Foundation encoding that decodes it.
        case foundation(String, CFStringEncoding)
    }

    /// The allow-listed encoding for a WHATWG label (ASCII whitespace trimmed, ASCII case
    /// ignored), or nil. `utf-16` labels mean UTF-8; any other label, UTF-8 and UTF-7 included,
    /// is ignored.
    nonisolated static func allowedEncoding(forLabel label: [UInt8]) -> AllowedEncoding? {
        var trimmed = label[...]
        while let first = trimmed.first, isASCIIWhitespace(first) { trimmed.removeFirst() }
        while let last = trimmed.last, isASCIIWhitespace(last) { trimmed.removeLast() }
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0 < 0x80 }) else { return nil }
        let key = String(decoding: trimmed.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
        return labels[key]
    }

    private nonisolated static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }

    /// WHATWG Encoding Standard labels for the allow-listed encodings.
    nonisolated static let labels: [String: AllowedEncoding] = {
        var table: [String: AllowedEncoding] = [:]
        func add(_ encoding: AllowedEncoding, _ names: [String]) {
            for name in names { table[name] = encoding }
        }
        func cf(_ name: String, _ value: CFIndex) -> AllowedEncoding { .foundation(name, CFStringEncoding(value)) }
        add(.utf8, ["csunicode", "iso-10646-ucs-2", "ucs-2", "unicode", "unicodefeff", "utf-16", "utf-16le", "unicodefffe", "utf-16be"])
        add(.windows1252, ["ansi_x3.4-1968", "ascii", "cp1252", "cp819", "csisolatin1", "ibm819", "iso-8859-1", "iso-ir-100",
                           "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987", "l1", "latin1", "us-ascii", "windows-1252", "x-cp1252"])
        add(cf("iso-8859-2", CFStringEncodings.isoLatin2.rawValue), ["csisolatin2", "iso-8859-2", "iso-ir-101", "iso8859-2", "iso88592", "iso_8859-2", "iso_8859-2:1987", "l2", "latin2"])
        add(cf("iso-8859-3", CFStringEncodings.isoLatin3.rawValue), ["csisolatin3", "iso-8859-3", "iso-ir-109", "iso8859-3", "iso88593", "iso_8859-3", "iso_8859-3:1988", "l3", "latin3"])
        add(cf("iso-8859-4", CFStringEncodings.isoLatin4.rawValue), ["csisolatin4", "iso-8859-4", "iso-ir-110", "iso8859-4", "iso88594", "iso_8859-4", "iso_8859-4:1988", "l4", "latin4"])
        add(cf("iso-8859-5", CFStringEncodings.isoLatinCyrillic.rawValue), ["csisolatincyrillic", "cyrillic", "iso-8859-5", "iso-ir-144", "iso8859-5", "iso88595", "iso_8859-5", "iso_8859-5:1988"])
        add(cf("iso-8859-6", CFStringEncodings.isoLatinArabic.rawValue), ["arabic", "asmo-708", "csiso88596e", "csiso88596i", "csisolatinarabic", "ecma-114", "iso-8859-6",
                                       "iso-8859-6-e", "iso-8859-6-i", "iso-ir-127", "iso8859-6", "iso88596", "iso_8859-6", "iso_8859-6:1987"])
        add(cf("iso-8859-7", CFStringEncodings.isoLatinGreek.rawValue), ["csisolatingreek", "ecma-118", "elot_928", "greek", "greek8", "iso-8859-7", "iso-ir-126",
                                       "iso8859-7", "iso88597", "iso_8859-7", "iso_8859-7:1987", "sun_eu_greek"])
        add(cf("iso-8859-8", CFStringEncodings.isoLatinHebrew.rawValue), ["csiso88598e", "csisolatinhebrew", "hebrew", "iso-8859-8", "iso-8859-8-e", "iso-ir-138",
                                       "iso8859-8", "iso88598", "iso_8859-8", "iso_8859-8:1988", "visual"])
        add(cf("iso-8859-8-i", CFStringEncodings.isoLatinHebrew.rawValue), ["csiso88598i", "iso-8859-8-i", "logical"])
        add(cf("iso-8859-10", CFStringEncodings.isoLatin6.rawValue), ["csisolatin6", "iso-8859-10", "iso-ir-157", "iso8859-10", "iso885910", "l6", "latin6"])
        add(cf("iso-8859-13", CFStringEncodings.isoLatin7.rawValue), ["iso-8859-13", "iso8859-13", "iso885913"])
        add(cf("iso-8859-14", CFStringEncodings.isoLatin8.rawValue), ["iso-8859-14", "iso8859-14", "iso885914"])
        add(cf("iso-8859-15", CFStringEncodings.isoLatin9.rawValue), ["csisolatin9", "iso-8859-15", "iso8859-15", "iso885915", "iso_8859-15", "l9"])
        add(cf("iso-8859-16", CFStringEncodings.isoLatin10.rawValue), ["iso-8859-16"])
        add(cf("windows-1250", CFStringEncodings.windowsLatin2.rawValue), ["cp1250", "windows-1250", "x-cp1250"])
        add(cf("windows-1251", CFStringEncodings.windowsCyrillic.rawValue), ["cp1251", "windows-1251", "x-cp1251"])
        add(cf("windows-1253", CFStringEncodings.windowsGreek.rawValue), ["cp1253", "windows-1253", "x-cp1253"])
        add(cf("windows-1254", CFStringEncodings.windowsLatin5.rawValue), ["cp1254", "csisolatin5", "iso-8859-9", "iso-ir-148", "iso8859-9", "iso88599", "iso_8859-9",
                                         "iso_8859-9:1989", "l5", "latin5", "windows-1254", "x-cp1254"])
        add(cf("windows-1255", CFStringEncodings.windowsHebrew.rawValue), ["cp1255", "windows-1255", "x-cp1255"])
        add(cf("windows-1256", CFStringEncodings.windowsArabic.rawValue), ["cp1256", "windows-1256", "x-cp1256"])
        add(cf("windows-1257", CFStringEncodings.windowsBalticRim.rawValue), ["cp1257", "windows-1257", "x-cp1257"])
        add(cf("windows-1258", CFStringEncodings.windowsVietnamese.rawValue), ["cp1258", "windows-1258", "x-cp1258"])
        add(cf("big5", CFStringEncodings.big5_HKSCS_1999.rawValue), ["big5", "big5-hkscs", "cn-big5", "csbig5", "x-x-big5"])
        add(cf("euc-jp", CFStringEncodings.EUC_JP.rawValue), ["cseucpkdfmtjapanese", "euc-jp", "x-euc-jp"])
        add(cf("iso-2022-jp", CFStringEncodings.ISO_2022_JP.rawValue), ["csiso2022jp", "iso-2022-jp"])
        add(cf("shift_jis", CFStringEncodings.dosJapanese.rawValue), ["csshiftjis", "ms932", "ms_kanji", "shift-jis", "shift_jis", "sjis", "windows-31j", "x-sjis"])
        add(cf("euc-kr", CFStringEncodings.dosKorean.rawValue), ["cseuckr", "csksc56011987", "euc-kr", "iso-ir-149", "korean", "ks_c_5601-1987", "ks_c_5601-1989",
                                   "ksc5601", "ksc_5601", "windows-949"])
        add(cf("gbk", CFStringEncodings.GB_18030_2000.rawValue), ["chinese", "csgb2312", "csiso58gb231280", "gb2312", "gb_2312", "gb_2312-80", "gbk", "iso-ir-58", "x-gbk"])
        add(cf("gb18030", CFStringEncodings.GB_18030_2000.rawValue), ["gb18030"])
        add(cf("koi8-r", CFStringEncodings.KOI8_R.rawValue), ["cskoi8r", "koi", "koi8", "koi8-r", "koi8_r"])
        add(cf("koi8-u", CFStringEncodings.KOI8_U.rawValue), ["koi8-ru", "koi8-u"])
        add(cf("macintosh", CFIndex(CFStringBuiltInEncodings.macRoman.rawValue)), ["csmacintosh", "mac", "macintosh", "x-mac-roman"])
        return table
    }()

    // MARK: WHATWG prescan

    /// The encoding label from the WHATWG "prescan a byte stream" algorithm, or nil. Labels that
    /// aren't allow-listed are skipped, as the algorithm skips unknown ones.
    nonisolated static func prescan(_ slice: ArraySlice<UInt8>) -> [UInt8]? {
        let bytes = Array(slice)
        var scanner = PrescanScanner(bytes: bytes)
        return scanner.run()
    }

    private struct PrescanScanner {
        let bytes: [UInt8]
        var position = 0

        private static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
        }

        private static func lower(_ byte: UInt8) -> UInt8 {
            (0x41...0x5A).contains(byte) ? byte + 0x20 : byte
        }

        private static func isLetter(_ byte: UInt8) -> Bool {
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
        }

        private func matches(_ text: String, at index: Int) -> Bool {
            let pattern = Array(text.utf8)
            guard index + pattern.count <= bytes.count else { return false }
            return pattern.indices.allSatisfy { Self.lower(bytes[index + $0]) == pattern[$0] }
        }

        mutating func run() -> [UInt8]? {
            while position < bytes.count {
                if matches("<!--", at: position) {
                    var index = position + 4
                    while index < bytes.count, !(bytes[index] == 0x3E && bytes[index - 1] == 0x2D && bytes[index - 2] == 0x2D) {
                        index += 1
                    }
                    guard index < bytes.count else { return nil }
                    position = index
                } else if matches("<meta", at: position), position + 5 < bytes.count,
                          Self.isSpace(bytes[position + 5]) || bytes[position + 5] == 0x2F {
                    position += 5
                    guard let result = metaCharset() else { return nil }
                    if let label = result { return label }
                } else if bytes[position] == 0x3C, position + 1 < bytes.count,
                          Self.isLetter(bytes[position + 1])
                            || (bytes[position + 1] == 0x2F && position + 2 < bytes.count && Self.isLetter(bytes[position + 2])) {
                    while position < bytes.count, !Self.isSpace(bytes[position]), bytes[position] != 0x3E { position += 1 }
                    while true {
                        guard let attribute = nextAttribute() else { return nil }
                        if attribute == nil { break }
                    }
                } else if matches("<!", at: position) || matches("</", at: position) || matches("<?", at: position) {
                    while position < bytes.count, bytes[position] != 0x3E { position += 1 }
                    guard position < bytes.count else { return nil }
                }
                position += 1
            }
            return nil
        }

        /// Handles one `<meta` tag. Outer nil: out of bytes. Inner nil: no usable label here.
        private mutating func metaCharset() -> [UInt8]?? {
            var seen: Set<[UInt8]> = []
            var gotPragma = false
            var needPragma: Bool?
            var charset: [UInt8]?
            while true {
                guard let next = nextAttribute() else { return nil }
                guard let (name, value) = next else { break }
                guard seen.insert(name).inserted else { continue }
                switch name {
                case Array("http-equiv".utf8):
                    if value == Array("content-type".utf8) { gotPragma = true }
                case Array("content".utf8):
                    if charset == nil, let found = Self.charsetFromContent(value) {
                        charset = found
                        needPragma = true
                    }
                case Array("charset".utf8):
                    charset = value
                    needPragma = false
                default:
                    break
                }
            }
            guard let needPragma, let charset, !(needPragma && !gotPragma),
                  HTMLDocumentText.allowedEncoding(forLabel: charset) != nil
            else { return .some(nil) }
            return .some(charset)
        }

        /// WHATWG "get an attribute". Outer nil: out of bytes. Inner nil: no more attributes.
        private mutating func nextAttribute() -> ([UInt8], [UInt8])?? {
            while position < bytes.count, Self.isSpace(bytes[position]) || bytes[position] == 0x2F { position += 1 }
            guard position < bytes.count else { return nil }
            if bytes[position] == 0x3E { return .some(nil) }
            var name: [UInt8] = []
            var value: [UInt8] = []
            nameLoop: while true {
                guard position < bytes.count else { return nil }
                let byte = bytes[position]
                if byte == 0x3D, !name.isEmpty {
                    position += 1
                    break nameLoop
                } else if Self.isSpace(byte) {
                    while position < bytes.count, Self.isSpace(bytes[position]) { position += 1 }
                    guard position < bytes.count else { return nil }
                    guard bytes[position] == 0x3D else { return .some((name, value)) }
                    position += 1
                    break nameLoop
                } else if byte == 0x2F || byte == 0x3E {
                    return .some((name, value))
                } else {
                    name.append(Self.lower(byte))
                    position += 1
                }
            }
            while position < bytes.count, Self.isSpace(bytes[position]) { position += 1 }
            guard position < bytes.count else { return nil }
            let first = bytes[position]
            if first == 0x22 || first == 0x27 {
                while true {
                    position += 1
                    guard position < bytes.count else { return nil }
                    if bytes[position] == first {
                        position += 1
                        return .some((name, value))
                    }
                    value.append(Self.lower(bytes[position]))
                }
            }
            if first == 0x3E { return .some((name, value)) }
            while true {
                guard position < bytes.count else { return nil }
                let byte = bytes[position]
                if Self.isSpace(byte) || byte == 0x3E { return .some((name, value)) }
                value.append(Self.lower(byte))
                position += 1
            }
        }

        /// WHATWG "extract a character encoding from a meta element" (value already lowercased).
        static func charsetFromContent(_ content: [UInt8]) -> [UInt8]? {
            let word = Array("charset".utf8)
            var index = 0
            while true {
                guard let found = (index..<max(index, content.count - word.count + 1)).first(where: {
                    Array(content[$0..<($0 + word.count)]) == word
                }) else { return nil }
                index = found + word.count
                while index < content.count, isSpace(content[index]) { index += 1 }
                guard index < content.count, content[index] == 0x3D else { continue }
                index += 1
                while index < content.count, isSpace(content[index]) { index += 1 }
                guard index < content.count else { return nil }
                let quote = content[index]
                if quote == 0x22 || quote == 0x27 {
                    guard let end = content[(index + 1)...].firstIndex(of: quote) else { return nil }
                    return Array(content[(index + 1)..<end])
                }
                // Both sides of the `??` come from the same slice. They have to: `firstIndex`
                // on a slice answers in the *parent's* index space, and Swift 6.1's type checker
                // will not unify `ArraySlice<UInt8>.Index?` with an `Int` taken from somewhere
                // else -- which is why this line built here on Xcode 27 and failed CI on 26.
                // `tail.endIndex` and `content.count` are the same number for an array, so this
                // is a compatibility fix and not a behaviour change; `ScopedFileReader` already
                // writes the same search this way.
                let tail = content[index...]
                let end = tail.firstIndex(where: { isSpace($0) || $0 == 0x3B }) ?? tail.endIndex
                return Array(content[index..<end])
            }
        }
    }
}
