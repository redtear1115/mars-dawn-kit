#if canImport(PDFKit)
import Foundation
import OSLog
import PDFKit

/// Makes an exported PDF's text layer say 頁面, not ⾴⾯ (mars-dawn-kit#18).
///
/// macOS CJK fonts draw an ideograph and its CJK radical twin (示 and ⽰) with one glyph. WebKit's
/// print path hands CoreGraphics bare glyph runs, so CoreGraphics works out each glyph's Unicode
/// from the font, and for a shared glyph it writes the radical into the font's ToUnicode CMap.
/// Copying, searching or reading the PDF then gets the radical. This rewrites those CMap
/// destinations to their unified ideographs (UCD EquivalentUnifiedIdeograph), except for a
/// radical the document itself contains, where the shared glyph really is ambiguous.
///
/// It touches nothing else. The new CMaps are appended as a PDF incremental update, so the
/// original bytes stay an exact prefix of the file. Anything it doesn't fully understand (an
/// xref stream, an earlier update, a filter other than Flate, CMap syntax beyond `bfchar` and
/// `bfrange`) leaves the PDF as it is, and so does a result PDFKit can't open with the same page
/// count: it never trades a wrong text layer for a broken file.
enum ToUnicodeRepair {
    private static let log = Logger(subsystem: "dev.southern-light.marsdawn-kit", category: "ToUnicodeRepair")

    enum Outcome: Equatable {
        /// The PDF was left exactly as it was, for the reason given.
        case unchanged(String)
        /// `cmaps` CMaps were rewritten, changing `mappings` destinations.
        case repaired(cmaps: Int, mappings: Int)
    }

    /// Repairs the PDF at `url` in place (atomically). Never leaves a broken or partial file.
    @discardableResult
    static func repairFile(at url: URL, source: String) -> Outcome {
        guard let data = try? Data(contentsOf: url) else { return .unchanged("unreadable") }
        let (repaired, outcome) = repair(data, source: source)
        guard case .repaired = outcome else { return outcome }
        do {
            try repaired.write(to: url, options: .atomic)
        } catch {
            log.error("Could not write the repaired PDF: \(error.localizedDescription, privacy: .public)")
            return .unchanged("write failed")
        }
        return outcome
    }

    /// The repaired PDF, or `pdf` itself with the reason it was left alone.
    static func repair(_ pdf: Data, source: String) -> (Data, Outcome) {
        func leave(_ reason: String) -> (Data, Outcome) {
            if reason != "no radical destinations" { log.info("ToUnicode left as is: \(reason, privacy: .public)") }
            return (pdf, .unchanged(reason))
        }
        let bytes = [UInt8](pdf)
        guard let startXref = lastStartXref(bytes) else { return leave("no startxref") }
        guard let table = XrefTable(bytes, at: startXref) else { return leave("no classic xref table") }
        let trailer = table.trailer
        guard !trailer.contains("/Prev"), !trailer.contains("/XRefStm") else { return leave("already updated") }
        guard let size = firstInt(after: "/Size", in: trailer),
              let root = firstMatch(#"/Root\s+\d+\s+\d+\s+R"#, in: trailer) else { return leave("trailer") }

        let keep = Set(source.unicodeScalars.map(\.value).filter { RadicalEquivalents.unifiedIdeograph[$0] != nil })
        var rewritten: [(number: Int, generation: Int, text: String)] = []
        var changedMappings = 0
        for (number, generation) in toUnicodeReferences(bytes) {
            guard let entry = table.entries[number], entry.generation == generation,
                  let stream = streamContents(bytes, object: number, at: entry.offset, table: table) else {
                return leave("CMap object \(number) unreadable")
            }
            guard let (text, changes) = rewriteCMap(stream, keeping: keep) else {
                return leave("CMap object \(number) has syntax this doesn't handle")
            }
            if changes > 0 {
                rewritten.append((number, generation, text))
                changedMappings += changes
            }
        }
        guard !rewritten.isEmpty else { return leave("no radical destinations") }

        // The incremental update: the new CMap objects, an xref section for them, and a trailer
        // pointing back at the original one.
        var out = pdf
        if out.last != UInt8(ascii: "\n") { out.append(UInt8(ascii: "\n")) }
        var offsets: [(number: Int, generation: Int, offset: Int)] = []
        for object in rewritten.sorted(by: { $0.number < $1.number }) {
            offsets.append((object.number, object.generation, out.count))
            let body = Data(object.text.utf8)
            out.append(Data("\(object.number) \(object.generation) obj\n<< /Length \(body.count) >>\nstream\n".utf8))
            out.append(body)
            out.append(Data("\nendstream\nendobj\n".utf8))
        }
        let xrefOffset = out.count
        var xref = "xref\n"
        for object in offsets {
            xref += "\(object.number) 1\n" + String(format: "%010d %05d n\r\n", object.offset, object.generation)
        }
        var trailerEntries = "/Size \(size) \(root)"
        if let info = firstMatch(#"/Info\s+\d+\s+\d+\s+R"#, in: trailer) { trailerEntries += " \(info)" }
        if let id = firstMatch(#"/ID\s*\[[^\]]*\]"#, in: trailer) { trailerEntries += " \(id)" }
        xref += "trailer\n<< \(trailerEntries) /Prev \(startXref) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        out.append(Data(xref.utf8))

        guard let before = PDFDocument(data: pdf), let after = PDFDocument(data: out),
              after.pageCount == before.pageCount else { return leave("the result didn't open as the same PDF") }
        return (out, .repaired(cmaps: rewritten.count, mappings: changedMappings))
    }

    // MARK: CMap

    /// `cmap` with every single-code-point destination that is a radical (and not one in `keep`)
    /// replaced by its unified ideograph, and how many changed. Its `bfchar`/`bfrange` blocks are
    /// written back as `bfchar` blocks of at most 100 entries; everything around them is kept.
    /// Nil for anything else between the first and last mapping block.
    static func rewriteCMap(_ cmap: String, keeping keep: Set<UInt32>) -> (String, Int)? {
        let blockPattern = #"(\d+)\s+begin(bfchar|bfrange)\s(.*?)\bend\2"#
        guard let regex = try? NSRegularExpression(pattern: blockPattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = cmap as NSString
        let matches = regex.matches(in: cmap, range: NSRange(location: 0, length: ns.length))
        guard let first = matches.first, let last = matches.last else { return (cmap, 0) }
        // Only whitespace may sit between blocks.
        for (a, b) in zip(matches, matches.dropFirst()) {
            let gap = ns.substring(with: NSRange(location: a.range.upperBound, length: b.range.location - a.range.upperBound))
            guard gap.allSatisfy(\.isWhitespace) else { return nil }
        }
        var width = 0
        var mappings: [(code: UInt32, units: [UInt16])] = []
        for match in matches {
            let kind = ns.substring(with: match.range(at: 2))
            let tokens = cmapTokens(ns.substring(with: match.range(at: 3)))
            guard let tokens else { return nil }
            var i = 0
            if kind == "bfchar" {
                while i < tokens.count {
                    guard i + 1 < tokens.count, case .hex(let src, let digits) = tokens[i], case .hex(_, _) = tokens[i + 1],
                          let code = codeValue(src), let units = utf16Units(tokens[i + 1]) else { return nil }
                    width = max(width, digits)
                    mappings.append((code, units))
                    i += 2
                }
            } else {
                while i < tokens.count {
                    guard i + 2 < tokens.count, case .hex(let loHex, let digits) = tokens[i], case .hex(let hiHex, _) = tokens[i + 1],
                          let lo = codeValue(loHex), let hi = codeValue(hiHex), hi >= lo, hi - lo < 65_536 else { return nil }
                    width = max(width, digits)
                    switch tokens[i + 2] {
                    case .hex:
                        guard var units = utf16Units(tokens[i + 2]), !units.isEmpty else { return nil }
                        for code in lo...hi {
                            mappings.append((code, units))
                            let (next, overflow) = units[units.count - 1].addingReportingOverflow(1)
                            if overflow && code < hi { return nil }
                            units[units.count - 1] = next
                        }
                    case .array(let items):
                        guard items.count == Int(hi - lo) + 1 else { return nil }
                        for (offset, item) in items.enumerated() {
                            guard let units = utf16Units(item) else { return nil }
                            mappings.append((lo + UInt32(offset), units))
                        }
                    }
                    i += 3
                }
            }
            guard mappings.count <= 200_000 else { return nil }
        }
        var changes = 0
        let mapped = mappings.map { mapping -> (UInt32, [UInt16]) in
            let scalars = String(decoding: mapping.units, as: UTF16.self).unicodeScalars
            guard scalars.count == 1, let scalar = scalars.first, !keep.contains(scalar.value),
                  let ideograph = RadicalEquivalents.unifiedIdeograph[scalar.value],
                  let replacement = Unicode.Scalar(ideograph) else { return (mapping.code, mapping.units) }
            changes += 1
            return (mapping.code, Array(String(replacement).utf16))
        }
        guard changes > 0 else { return (cmap, 0) }
        var blocks = ""
        let sorted = mapped.sorted { $0.0 < $1.0 }
        for start in stride(from: 0, to: sorted.count, by: 100) {
            let chunk = sorted[start..<min(start + 100, sorted.count)]
            blocks += "\(chunk.count) beginbfchar\n"
            for (code, units) in chunk {
                let src = String(code, radix: 16)
                blocks += "<" + String(repeating: "0", count: max(0, width - src.count)) + src + "> <"
                    + units.map { String(format: "%04x", $0) }.joined() + ">\n"
            }
            blocks += "endbfchar\n"
        }
        let prefix = ns.substring(to: first.range.location)
        let suffix = ns.substring(from: last.range.upperBound)
        return (prefix + blocks + suffix.drop(while: { $0 == "\n" || $0 == "\r" }), changes)
    }

    enum CMapToken: Equatable {
        case hex(String, digits: Int)
        case array([CMapToken])
    }

    /// `<hex>` strings and `[ … ]` arrays of them; nil for anything else.
    static func cmapTokens(_ text: String) -> [CMapToken]? {
        var tokens: [CMapToken] = []
        var array: [CMapToken]?
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isWhitespace { i = text.index(after: i); continue }
            if c == "<" {
                guard let close = text[i...].firstIndex(of: ">") else { return nil }
                let hex = String(text[text.index(after: i)..<close]).filter { !$0.isWhitespace }
                guard hex.allSatisfy(\.isHexDigit) else { return nil }
                let token = CMapToken.hex(hex, digits: hex.count)
                if array != nil { array!.append(token) } else { tokens.append(token) }
                i = text.index(after: close)
            } else if c == "[" {
                guard array == nil else { return nil }
                array = []
                i = text.index(after: i)
            } else if c == "]" {
                guard let items = array else { return nil }
                tokens.append(.array(items))
                array = nil
                i = text.index(after: i)
            } else {
                return nil
            }
        }
        return array == nil ? tokens : nil
    }

    private static func codeValue(_ hex: String) -> UInt32? {
        hex.count <= 8 ? UInt32(hex, radix: 16) : nil
    }

    private static func utf16Units(_ token: CMapToken) -> [UInt16]? {
        guard case .hex(let hex, _) = token, hex.count % 4 == 0 else { return nil }
        var units: [UInt16] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 4)
            guard let unit = UInt16(hex[index..<next], radix: 16) else { return nil }
            units.append(unit)
            index = next
        }
        return units
    }

    // MARK: PDF structure

    /// The offset `startxref` names in the file's last 1 KiB.
    static func lastStartXref(_ bytes: [UInt8]) -> Int? {
        let tail = String(decoding: bytes.suffix(1024), as: UTF8.self)
        guard let range = tail.range(of: "startxref", options: .backwards) else { return nil }
        let digits = tail[range.upperBound...].drop(while: \.isWhitespace).prefix(while: \.isNumber)
        guard let offset = Int(digits), offset < bytes.count else { return nil }
        return offset
    }

    /// A classic cross-reference table and the trailer after it.
    struct XrefTable {
        var entries: [Int: (offset: Int, generation: Int)] = [:]
        var trailer = ""

        init?(_ bytes: [UInt8], at offset: Int) {
            let text = String(decoding: bytes[offset..<min(bytes.count, offset + 4_000_000)], as: UTF8.self)
            guard text.hasPrefix("xref") else { return nil }
            var lines = text.split(omittingEmptySubsequences: true) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }.makeIterator()
            _ = lines.next()
            while let line = lines.next() {
                let fields = line.split(separator: " ")
                if line.hasPrefix("trailer") {
                    guard let start = text.range(of: "trailer"), let dict = Self.dictionary(in: text[start.upperBound...]) else { return nil }
                    trailer = String(dict)
                    return
                }
                guard fields.count == 2, let first = Int(fields[0]), let count = Int(fields[1]) else { return nil }
                for number in first..<(first + count) {
                    guard let entry = lines.next() else { return nil }
                    let parts = entry.split(separator: " ")
                    guard parts.count >= 3, let at = Int(parts[0]), let generation = Int(parts[1]) else { return nil }
                    if parts[2].hasPrefix("n") { entries[number] = (at, generation) }
                }
            }
            return nil
        }

        /// The `<< … >>` dictionary at the start of `text`, with nested dictionaries and hex strings.
        static func dictionary(in text: Substring) -> Substring? {
            guard let open = text.range(of: "<<") else { return nil }
            var depth = 0
            var i = open.lowerBound
            while i < text.endIndex {
                let rest = text[i...]
                if rest.hasPrefix("<<") { depth += 1; i = text.index(i, offsetBy: 2); continue }
                if rest.hasPrefix(">>") {
                    depth -= 1
                    i = text.index(i, offsetBy: 2)
                    if depth == 0 { return text[open.lowerBound..<i] }
                    continue
                }
                if text[i] == "<" {
                    guard let close = rest.firstIndex(of: ">") else { return nil }
                    i = text.index(after: close)
                    continue
                }
                i = text.index(after: i)
            }
            return nil
        }
    }

    /// Every distinct `/ToUnicode n g R` in the file, in order.
    static func toUnicodeReferences(_ bytes: [UInt8]) -> [(Int, Int)] {
        let text = String(decoding: bytes, as: UTF8.self)
        guard let regex = try? NSRegularExpression(pattern: #"/ToUnicode\s+(\d+)\s+(\d+)\s+R"#) else { return [] }
        var seen = Set<String>()
        var result: [(Int, Int)] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let n = Range(match.range(at: 1), in: text), let g = Range(match.range(at: 2), in: text),
                  let number = Int(text[n]), let generation = Int(text[g]), seen.insert("\(number) \(generation)").inserted else { continue }
            result.append((number, generation))
        }
        return result
    }

    /// The decoded contents of the stream object `object` at `offset`, if it is unfiltered or
    /// Flate-encoded with no parameters.
    static func streamContents(_ bytes: [UInt8], object: Int, at offset: Int, table: XrefTable) -> String? {
        guard offset < bytes.count else { return nil }
        let head = String(decoding: bytes[offset..<min(bytes.count, offset + 4096)], as: UTF8.self)
        guard head.hasPrefix("\(object) "), let dictionary = XrefTable.dictionary(in: head[...]),
              let streamWord = head.range(of: "stream", range: dictionary.endIndex..<head.endIndex) else { return nil }
        guard !dictionary.contains("/DecodeParms") else { return nil }
        let filter = firstMatch(#"/Filter\s*/?\[?\s*/?(\w+)"#, in: String(dictionary))
        let flate: Bool
        switch filter {
        case nil: flate = false
        case let f? where f.hasSuffix("FlateDecode") && !f.contains("["): flate = true
        default: return nil
        }
        var length = firstInt(after: "/Length", in: String(dictionary))
        if let reference = firstMatch(#"/Length\s+(\d+)\s+(\d+)\s+R"#, in: String(dictionary)) {
            let parts = reference.split(separator: " ")
            guard parts.count >= 4, let number = Int(parts[1]), let entry = table.entries[number] else { return nil }
            let lengthHead = String(decoding: bytes[entry.offset..<min(bytes.count, entry.offset + 64)], as: UTF8.self)
            guard let obj = lengthHead.range(of: "obj") else { return nil }
            length = Int(lengthHead[obj.upperBound...].drop(while: \.isWhitespace).prefix(while: \.isNumber))
        }
        guard let length, length >= 0 else { return nil }
        // The data starts after `stream` and its end-of-line (CR LF or LF).
        var dataStart = offset + head.utf8.distance(from: head.startIndex, to: streamWord.upperBound)
        if dataStart < bytes.count, bytes[dataStart] == 0x0D { dataStart += 1 }
        if dataStart < bytes.count, bytes[dataStart] == 0x0A { dataStart += 1 }
        guard dataStart + length <= bytes.count else { return nil }
        let data = Data(bytes[dataStart..<(dataStart + length)])
        if !flate { return String(decoding: data, as: UTF8.self) }
        // Flate is zlib: a 2-byte header, a raw deflate stream, an Adler-32 checksum.
        guard data.count > 6, data[data.startIndex] & 0x0F == 8,
              let inflated = try? (data.dropFirst(2) as NSData).decompressed(using: .zlib) else { return nil }
        return String(decoding: inflated as Data, as: UTF8.self)
    }

    private static func firstInt(after key: String, in text: String) -> Int? {
        guard let range = text.range(of: key) else { return nil }
        return Int(text[range.upperBound...].drop(while: \.isWhitespace).prefix(while: \.isNumber))
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return match.numberOfRanges > 1 && pattern.hasPrefix("/Filter")
            ? Range(match.range(at: 1), in: text).map { String(text[$0]) }
            : String(text[range])
    }
}
#endif
