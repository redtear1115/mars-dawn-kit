import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Footnotes (`[^label]` references and `[^label]: text` definitions, as GitHub has them), lifted
/// out of the body before it is parsed, the way `MathExtractor` lifts out math (#44).
///
/// swift-markdown never turns cmark-gfm's footnote option on, and any cmark node type it doesn't
/// know ends in a `fatalError`, so footnotes can't come through its tree. cmark-gfm itself parses
/// them, so this parses the body once more with that option and reads off where every reference
/// and definition is. Then:
///   - each reference becomes a placeholder, `U+E002 <index>:<nonce> U+E003`, expanded only in
///     text (`segments(in:)`), like math's; one that isn't this extraction's comes back as text;
///   - each definition's lines are emptied, keeping any `>` of a block quote around it, so the
///     body keeps its line count and every `data-line` still addresses the file;
///   - each definition's own Markdown is kept, to be rendered by the same renderer.
///
/// What cmark calls a footnote decides everything here: a reference in code, or one with no
/// definition, is left alone, and `[^x]: https://…` is a footnote, not the link reference
/// definition it becomes without the option (#44: it rendered as a hidden link).
///
/// cmark drops a definition nothing refers to. To still list those (owner, 2026-09-22: listed,
/// unnumbered), the parse is given one extra paragraph after the body that refers to every
/// `[^label]:` the text contains; references on those lines are never counted.
///
/// A body without `[^` isn't parsed again and comes back unchanged.
struct FootnoteExtraction: Sendable {
    /// A piece of a `Text` node after placeholder expansion. Neither case is HTML-escaped.
    enum Segment: Equatable, Sendable {
        case text(String)
        /// The `occurrence`-th reference (from 1) to footnote `number`.
        case reference(number: Int, occurrence: Int)
    }

    struct Note: Equatable, Sendable {
        let number: Int
        /// The definition's own Markdown, with its references already placeholders.
        let markdown: String
        /// How many references point here; one backlink each.
        let referenceCount: Int
    }

    /// The body to parse.
    let markdown: String
    let nonce: String
    /// By placeholder index.
    let references: [(number: Int, occurrence: Int, label: String)]
    /// Numbered footnotes, in number order.
    let notes: [Note]
    /// Definitions nothing refers to, in source order: their Markdown.
    let unreferenced: [String]

    var isEmpty: Bool { notes.isEmpty && unreferenced.isEmpty }

    func segments(in text: String) -> [Segment] {
        guard !references.isEmpty, text.unicodeScalars.contains(FootnoteExtractor.placeholderStart) else { return [.text(text)] }
        let scalars = Array(text.unicodeScalars)
        var result: [Segment] = []
        var pending = String.UnicodeScalarView()
        var position = 0
        while position < scalars.count {
            if scalars[position] == FootnoteExtractor.placeholderStart,
               let (index, end) = FootnoteExtractor.parsePlaceholder(scalars, at: position, nonce: nonce),
               index < references.count {
                if !pending.isEmpty { result.append(.text(String(pending))); pending = String.UnicodeScalarView() }
                result.append(.reference(number: references[index].number, occurrence: references[index].occurrence))
                position = end
            } else {
                pending.append(scalars[position])
                position += 1
            }
        }
        if !pending.isEmpty { result.append(.text(String(pending))) }
        return result
    }

    /// `text` with this extraction's placeholders written back as the `[^label]` they stood
    /// for: for a heading's slug, which must not change between renders or from before (#14).
    func sourceBack(_ text: String) -> String {
        guard !references.isEmpty else { return text }
        return segments(in: text).reduce(into: "") { result, segment in
            switch segment {
            case .text(let string): result += string
            case .reference(let number, let occurrence):
                let label = references.first { $0.number == number && $0.occurrence == occurrence }?.label ?? ""
                result += "[^" + label + "]"
            }
        }
    }
}

enum FootnoteExtractor {
    static let placeholderStart: Unicode.Scalar = "\u{E002}"
    static let placeholderEnd: Unicode.Scalar = "\u{E003}"
    /// More `[^label]:` candidates than this are not given the extra paragraph: past it, a
    /// definition nothing refers to is dropped, as cmark (and GitHub) drop it.
    static let candidateLimit = 2_000

    static func extract(from body: String) -> FootnoteExtraction {
        var generator = SystemRandomNumberGenerator()
        return extract(from: body, using: &generator)
    }

    /// `placeholders: false` removes the references instead, for counting text.
    static func extract(from body: String, using generator: inout some RandomNumberGenerator, placeholders: Bool = true) -> FootnoteExtraction {
        let hex = String(generator.next(), radix: 16)
        let nonce = String(repeating: "0", count: 16 - hex.count) + hex
        let unchanged = FootnoteExtraction(markdown: body, nonce: nonce, references: [], notes: [], unreferenced: [])
        guard body.contains("[^") else { return unchanged }

        var lines = splitLines(body)
        let bodyLineCount = lines.count
        let found = scan(body, lines: lines, candidates: definitionCandidates(body))
        guard !found.definitions.isEmpty else { return unchanged }

        // Number by first reference, in the order cmark meets them.
        var numberOf: [String: Int] = [:]
        var occurrences: [String: Int] = [:]
        var references: [(number: Int, occurrence: Int, label: String)] = []
        var edits: [Int: [(start: Int, end: Int, replacement: [UInt8])]] = [:]
        for reference in found.references {
            let number: Int
            if let known = numberOf[reference.label] {
                number = known
            } else {
                number = numberOf.count + 1
                numberOf[reference.label] = number
            }
            let occurrence = occurrences[reference.label, default: 0] + 1
            occurrences[reference.label] = occurrence
            let replacement = placeholders ? placeholder(index: references.count, nonce: nonce) : []
            references.append((number, occurrence, reference.originalLabel))
            edits[reference.line, default: []].append((reference.startColumn - 1, reference.endColumn, replacement))
        }
        for (line, lineEdits) in edits where line - 1 < lines.count {
            for edit in lineEdits.sorted(by: { $0.start > $1.start }) {
                let content = lines[line - 1].content
                guard edit.start >= 0, edit.end <= content.count, edit.start < edit.end else { continue }
                lines[line - 1].content.replaceSubrange(edit.start..<edit.end, with: edit.replacement)
            }
        }

        var notesByNumber: [Int: FootnoteExtraction.Note] = [:]
        var unreferenced: [String] = []
        var takenThrough = 0
        for definition in found.definitions {
            // A definition cmark found inside another one's lines is part of that one's text.
            guard definition.startLine > takenThrough else { continue }
            takenThrough = definition.lastLine
            let markdown = takeDefinition(definition, from: &lines)
            if let number = numberOf[definition.label] {
                notesByNumber[number] = FootnoteExtraction.Note(number: number, markdown: markdown, referenceCount: occurrences[definition.label] ?? 0)
            } else {
                unreferenced.append(markdown)
            }
        }
        let notes = notesByNumber.keys.sorted().compactMap { notesByNumber[$0] }
        let rewritten = String(decoding: lines.flatMap { $0.content + $0.ending }, as: UTF8.self)
        return FootnoteExtraction(markdown: rewritten, nonce: nonce, references: references, notes: notes, unreferenced: unreferenced)
    }

    // MARK: Parsing

    private struct Reference {
        let line: Int, startColumn: Int, endColumn: Int
        /// The definition's label as cmark normalises it (the key), and as written.
        let label: String, originalLabel: String
    }

    private struct Definition {
        let label: String
        let startLine: Int, contentColumn: Int, endLine: Int, endColumn: Int
        /// The last line holding any of it: cmark ends a block at column 0 of the next line.
        var lastLine: Int { endColumn == 0 ? endLine - 1 : endLine }
    }

    /// Every `[^label]` of a `[^label]:` in the text, once each, in order. A superset of the
    /// definitions: cmark decides which really are.
    static func definitionCandidates(_ body: String) -> [String] {
        let bytes = Array(body.utf8)
        var seen = Set<[UInt8]>()
        var result: [String] = []
        var index = 0
        while index + 3 < bytes.count, result.count < candidateLimit {
            guard bytes[index] == UInt8(ascii: "["), bytes[index + 1] == UInt8(ascii: "^") else { index += 1; continue }
            var end = index + 2
            while end < bytes.count, bytes[end] != UInt8(ascii: "]"), bytes[end] != UInt8(ascii: "\n"), bytes[end] != UInt8(ascii: "\r"), bytes[end] != UInt8(ascii: "[") {
                end += 1
            }
            if end < bytes.count - 1, bytes[end] == UInt8(ascii: "]"), bytes[end + 1] == UInt8(ascii: ":"), end > index + 2 {
                let label = Array(bytes[(index + 2)..<end])
                if seen.insert(label).inserted { result.append(String(decoding: label, as: UTF8.self)) }
                index = end + 2
            } else {
                index += 2
            }
        }
        return result
    }

    private static func scan(_ body: String, lines: [Line], candidates: [String]) -> (references: [Reference], definitions: [Definition]) {
        let bodyLineCount = lines.count
        // The extra paragraph goes after a line break the body may lack, then a blank line.
        let tail = "\n\n" + candidates.map { "[^" + $0 + "]" }.joined(separator: " ") + "\n"
        let source = candidates.isEmpty ? body : body + tail
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_FOOTNOTES | CMARK_OPT_SOURCEPOS) else { return ([], []) }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "tasklist"] {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        cmark_parser_feed(parser, source, source.utf8.count)
        guard let root = cmark_parser_finish(parser) else { return ([], []) }
        defer { cmark_node_free(root) }
        guard let iterator = cmark_iter_new(root) else { return ([], []) }
        defer { cmark_iter_free(iterator) }

        var references: [Reference] = []
        var definitions: [Definition] = []
        while true {
            let event = cmark_iter_next(iterator)
            if event == CMARK_EVENT_DONE { break }
            guard event == CMARK_EVENT_ENTER, let node = cmark_iter_get_node(iterator) else { continue }
            let type = cmark_node_get_type(node)
            let line = Int(cmark_node_get_start_line(node))
            if type == CMARK_NODE_FOOTNOTE_REFERENCE, line <= bodyLineCount,
               let definition = cmark_node_parent_footnote_def(node) {
                let key = literal(definition)
                references.append(Reference(line: line, startColumn: Int(cmark_node_get_start_column(node)),
                                            endColumn: Int(cmark_node_get_end_column(node)), label: key,
                                            originalLabel: writtenLabel(lines, line: line, start: Int(cmark_node_get_start_column(node)),
                                                                        end: Int(cmark_node_get_end_column(node))) ?? key))
            } else if type == CMARK_NODE_FOOTNOTE_DEFINITION, line <= bodyLineCount {
                definitions.append(Definition(label: literal(node), startLine: line,
                                              contentColumn: Int(cmark_node_get_start_column(node)),
                                              endLine: Int(cmark_node_get_end_line(node)),
                                              endColumn: Int(cmark_node_get_end_column(node))))
            }
        }
        definitions.sort { $0.startLine < $1.startLine }
        return (references, definitions)
    }

    private static func literal(_ node: UnsafeMutablePointer<cmark_node>) -> String {
        cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
    }

    /// The label as the author wrote it at a reference (`[^Note]` for a key cmark folds).
    private static func writtenLabel(_ lines: [Line], line: Int, start: Int, end: Int) -> String? {
        guard line - 1 < lines.count else { return nil }
        let content = lines[line - 1].content
        guard start >= 1, end <= content.count, end - start >= 3 else { return nil }
        return String(decoding: content[(start + 1)..<(end - 1)], as: UTF8.self)
    }

    // MARK: Rewriting

    struct Line {
        var content: [UInt8]
        let ending: [UInt8]
    }

    /// Lines as cmark reads them: ended by `\n`, `\r\n` or `\r`.
    static func splitLines(_ text: String) -> [Line] {
        let bytes = Array(text.utf8)
        var lines: [Line] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\n") {
                lines.append(Line(content: Array(bytes[start..<index]), ending: [UInt8(ascii: "\n")]))
                index += 1
                start = index
            } else if bytes[index] == UInt8(ascii: "\r") {
                let crlf = index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "\n")
                lines.append(Line(content: Array(bytes[start..<index]), ending: crlf ? Array("\r\n".utf8) : [UInt8(ascii: "\r")]))
                index += crlf ? 2 : 1
                start = index
            } else {
                index += 1
            }
        }
        if start < bytes.count { lines.append(Line(content: Array(bytes[start...]), ending: [])) }
        return lines
    }

    /// Takes a definition's Markdown out of `lines` and empties them. What stood before the
    /// marker on its first line is the container's prefix (`> `, `- `): a line that starts with
    /// it loses it, and the emptied lines don't keep it either. A quote or list item that held
    /// only the definition then disappears, rather than staying as an empty quote bar or bullet;
    /// one with more in it is split around the blank lines.
    private static func takeDefinition(_ definition: Definition, from lines: inout [Line]) -> String {
        let first = definition.startLine - 1
        let last = min(definition.lastLine, lines.count) - 1
        guard first >= 0, first < lines.count, last >= first else { return "" }
        let firstContent = lines[first].content
        let contentStart = min(max(definition.contentColumn - 1, 0), firstContent.count)
        let markerStart = lastMarker(in: firstContent, before: contentStart) ?? 0
        let prefix = Array(firstContent[..<markerStart])
        // The prefix without its trailing spaces: `>` for a quote's lazy `>` line.
        let keptTrimmed = Array(prefix.reversed().drop { $0 == UInt8(ascii: " ") }.reversed())

        var markdown: [[UInt8]] = [Array(firstContent[contentStart...])]
        lines[first].content = []
        if last > first {
            for index in (first + 1)...last {
                var content = lines[index].content
                if !prefix.isEmpty, content.starts(with: prefix) {
                    content.removeFirst(prefix.count)
                } else if !prefix.isEmpty, content.starts(with: keptTrimmed), !keptTrimmed.isEmpty {
                    content.removeFirst(keptTrimmed.count)
                }
                markdown.append(dedent(content))
                lines[index].content = []
            }
        }
        while let tail = markdown.last, tail.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }), markdown.count > 1 {
            markdown.removeLast()
        }
        return String(decoding: Array(markdown.joined(separator: [UInt8(ascii: "\n")])), as: UTF8.self)
    }

    /// Where `[^` starts, the last one before `limit`.
    private static func lastMarker(in content: [UInt8], before limit: Int) -> Int? {
        var index = min(limit, content.count) - 2
        while index >= 0 {
            if content[index] == UInt8(ascii: "["), content[index + 1] == UInt8(ascii: "^") { return index }
            index -= 1
        }
        return nil
    }

    /// Up to four columns of leading indentation, which is what a continuation line of a
    /// definition carries.
    private static func dedent(_ content: [UInt8]) -> [UInt8] {
        var columns = 0
        var index = 0
        while index < content.count, columns < 4 {
            if content[index] == UInt8(ascii: " ") { columns += 1 }
            else if content[index] == UInt8(ascii: "\t") { columns = 4 }
            else { break }
            index += 1
        }
        return Array(content[index...])
    }

    // MARK: Placeholders

    static func placeholder(index: Int, nonce: String) -> [UInt8] {
        Array("\u{E002}\(index):\(nonce)\u{E003}".utf8)
    }

    /// Parses `U+E002 <index>:<nonce> U+E003` at `start`; returns the index and the end offset.
    static func parsePlaceholder(_ scalars: [Unicode.Scalar], at start: Int, nonce: String) -> (Int, Int)? {
        guard start < scalars.count, scalars[start] == placeholderStart else { return nil }
        var position = start + 1
        var index = 0
        var digits = 0
        while position < scalars.count, ("0"..."9").contains(scalars[position]) {
            index = index * 10 + Int(scalars[position].value - 48)
            digits += 1
            position += 1
            if digits > 9 { return nil }
        }
        guard digits > 0, position < scalars.count, scalars[position] == ":" else { return nil }
        position += 1
        for expected in nonce.unicodeScalars {
            guard position < scalars.count, scalars[position] == expected else { return nil }
            position += 1
        }
        guard position < scalars.count, scalars[position] == placeholderEnd else { return nil }
        return (index, position + 1)
    }
}
