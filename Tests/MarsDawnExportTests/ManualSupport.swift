#if os(macOS)
import AppKit
import Testing
import Foundation
import PDFKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// Instruments for the manual layout's tests (mars-dawn#432 S2). Every one reads the PDF itself
/// — PDFKit text, annotations, outline, CoreGraphics resources, the CMaps' own bytes — never the
/// layout or the exporter's own idea of where things went.
@MainActor
enum ManualProbe {
    /// One manual export through the real `exportPDF` path, with its report.
    struct Run {
        var url: URL
        var document: PDFDocument
        var data: Data
        var report: ManualReport
        var pageTexts: [String]
        var directory: URL
    }

    /// Exports `markdown` in the manual layout into a fresh folder (kept until `cleanUp`).
    static func export(
        _ markdown: String, baseDirectory: URL? = nil, scopeRoot: URL? = nil, allowRemoteImages: Bool = false,
        tocTitle: String = "Contents", hooks: ManualHooks = ManualHooks()
    ) async throws -> Run {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manual-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("out.pdf")
        var report: ManualReport?
        var hooks = hooks
        let outer = hooks.report
        hooks.report = { report = $0; outer?($0) }
        _ = try await DocumentExporter.exportPDF(
            markdown: markdown, to: url, theme: .dawn, baseDirectory: baseDirectory, allowRemoteImages: allowRemoteImages,
            scopeRoot: scopeRoot, layout: .manual, tocTitle: tocTitle, inspect: nil, hooks: hooks
        )
        let document = try #require(PDFDocument(url: url))
        return Run(
            url: url, document: document, data: try Data(contentsOf: url), report: try #require(report),
            pageTexts: pageTexts(document), directory: directory
        )
    }

    static func pageTexts(_ document: PDFDocument) -> [String] {
        (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    static func pageTexts(_ data: Data) -> [String] {
        PDFDocument(data: data).map(pageTexts) ?? []
    }

    /// Lines of a page's text, trimmed, without empty ones.
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Footer

    static let footerPattern = /^(\d+) \/ (\d+)$/

    /// The footer line of a page, if its last line reads "n / N".
    static func footer(_ text: String) -> (n: Int, total: Int)? {
        guard let last = lines(text).last, let match = last.wholeMatch(of: footerPattern),
              let n = Int(match.1), let total = Int(match.2) else { return nil }
        return (n, total)
    }

    /// Page text without its footer line.
    static func withoutFooter(_ text: String) -> String {
        var all = lines(text)
        if let last = all.last, last.wholeMatch(of: footerPattern) != nil { all.removeLast() }
        return all.joined(separator: "\n")
    }

    // MARK: Truth: where headings start in the PDF

    /// The page index each heading starts on, found in the PDF's own (repaired) text: heading
    /// `k` is the first unused run of lines, at or after heading `k - 1`'s page, on a body page,
    /// that reads exactly its text. Repeated heading texts are matched in order. Nil when none.
    static func truthPages(headings: [ManualLayout.Heading], pageTexts: [String], bodyStart: Int) -> [Int?] {
        var used: [Int: Set<Int>] = [:]
        var from = bodyStart
        return headings.map { heading in
            let wanted = collapse(heading.text)
            for page in from..<pageTexts.count {
                let pageLines = lines(pageTexts[page]).map(collapse)
                for start in pageLines.indices where !(used[page]?.contains(start) ?? false) {
                    var joined = ""
                    for end in start..<min(pageLines.count, start + 4) {
                        joined = joined.isEmpty ? pageLines[end] : joined + " " + pageLines[end]
                        if joined == wanted {
                            used[page, default: []].insert(start)
                            from = page
                            return page
                        }
                        if !wanted.hasPrefix(joined) { break }
                    }
                }
            }
            return nil
        }
    }

    // MARK: Links

    struct Links: Equatable, CustomStringConvertible {
        var perPage: [Int]
        var urls: [String]
        var destinations: [String]
        var description: String { "perPage \(perPage), \(urls.count) urls, \(destinations.count) destinations" }
    }

    static func links(_ document: PDFDocument) -> Links {
        var perPage: [Int] = [], urls: [String] = [], destinations: [String] = []
        for index in 0..<document.pageCount {
            var count = 0
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Link" {
                count += 1
                if let url = annotation.url {
                    urls.append("\(index)|\(url.absoluteString)")
                } else if let destination = annotation.destination, let page = destination.page {
                    destinations.append("\(index)->\(document.index(for: page))@\(Int(destination.point.y.rounded()))")
                } else if let action = annotation.action as? PDFActionGoTo, let page = action.destination.page {
                    destinations.append("\(index)->\(document.index(for: page))@\(Int(action.destination.point.y.rounded()))")
                } else {
                    destinations.append("\(index)->?")
                }
            }
            perPage.append(count)
        }
        return Links(perPage: perPage, urls: urls.sorted(), destinations: destinations.sorted())
    }

    /// The internal links on pages `pages`, in reading order (top to bottom), as target page indexes.
    static func internalLinkTargets(_ document: PDFDocument, pages: Range<Int>) -> [Int] {
        var result: [Int] = []
        for index in pages {
            guard let page = document.page(at: index) else { continue }
            let links = page.annotations.filter { $0.type == "Link" && $0.url == nil }
                .sorted { $0.bounds.maxY > $1.bounds.maxY }
            for link in links {
                if let target = link.destination?.page { result.append(document.index(for: target)) }
            }
        }
        return result
    }

    // MARK: Outline

    struct OutlineEntry: Equatable {
        var label: String
        var depth: Int
        var page: Int
    }

    static func outline(_ document: PDFDocument) -> [OutlineEntry] {
        var result: [OutlineEntry] = []
        func walk(_ node: PDFOutline, depth: Int) {
            for index in 0..<node.numberOfChildren {
                guard let child = node.child(at: index) else { continue }
                let page = child.destination?.page.map { document.index(for: $0) } ?? -1
                result.append(OutlineEntry(label: child.label ?? "", depth: depth, page: page))
                walk(child, depth: depth + 1)
            }
        }
        if let root = document.outlineRoot { walk(root, depth: 0) }
        return result
    }

    // MARK: Images and pixels

    /// Image XObjects drawn on one page (0-based), recursing into forms.
    static func imageXObjects(_ data: Data, page index: Int) -> Int {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: index + 1), let dictionary = page.dictionary else { return 0 }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return 0 }
        var total = 0
        func count(_ resources: CGPDFDictionaryRef) {
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
            var forms: [CGPDFDictionaryRef] = []
            CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let streamDictionary = CGPDFStreamGetDictionary(stream) else { return true }
                var subtype: UnsafePointer<Int8>?
                if CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" { total += 1 }
                var inner: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(streamDictionary, "Resources", &inner), let inner { forms.append(inner) }
                return true
            }, nil)
            forms.forEach(count)
        }
        count(resources)
        return total
    }

    /// Whether page `index` shows a pixel within `tolerance` of `color` (0–255 RGB), rendered at 2x.
    static func showsColor(_ document: PDFDocument, page index: Int, red: Int, green: Int, blue: Int, tolerance: Int = 12) -> Bool {
        guard let page = document.page(at: index) else { return false }
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width * 2), height = Int(box.height * 2)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 2, y: 2)
        page.draw(with: .mediaBox, to: context)
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            if abs(Int(pixels[offset]) - red) <= tolerance, abs(Int(pixels[offset + 1]) - green) <= tolerance,
               abs(Int(pixels[offset + 2]) - blue) <= tolerance { return true }
        }
        return false
    }

    // MARK: CMaps

    /// Every ToUnicode CMap's destinations (the newest revision of each), by its font's BaseFont
    /// without the subset tag: what a text extractor that trusts the CMap reads.
    static func cmapDestinations(_ pdf: Data) -> [(font: String, destinations: Set<UInt32>)] {
        let bytes = [UInt8](pdf)
        guard let start = ToUnicodeRepair.lastStartXref(bytes) else { return [] }
        var tables: [ToUnicodeRepair.XrefTable] = []
        var at: Int? = start
        while let offset = at, let table = ToUnicodeRepair.XrefTable(bytes, at: offset) {
            tables.append(table)
            at = table.trailer.range(of: #"/Prev\s+\d+"#, options: .regularExpression)
                .flatMap { Int(table.trailer[$0].split(separator: " ").last ?? "") }
        }
        let names = ToUnicodeRepair.baseFontNames(forToUnicodeIn: bytes)
        var result: [(String, Set<UInt32>)] = []
        for (number, generation) in ToUnicodeRepair.toUnicodeReferences(bytes) {
            guard let table = tables.first(where: { $0.entries[number]?.generation == generation }),
                  let entry = table.entries[number],
                  let cmap = ToUnicodeRepair.streamContents(bytes, object: number, at: entry.offset, table: table) else { continue }
            var destinations = Set<UInt32>()
            let ns = cmap as NSString
            let blocks = try! NSRegularExpression(pattern: #"begin(bfchar|bfrange)\s(.*?)\bend\1"#, options: [.dotMatchesLineSeparators])
            let hexPattern = try! NSRegularExpression(pattern: #"<([0-9a-fA-F]+)>"#)
            for match in blocks.matches(in: cmap, range: NSRange(location: 0, length: ns.length)) {
                let kind = ns.substring(with: match.range(at: 1))
                let body = ns.substring(with: match.range(at: 2)) as NSString
                let hex = hexPattern.matches(in: body as String, range: NSRange(location: 0, length: body.length))
                    .map { body.substring(with: $0.range(at: 1)) }
                let step = kind == "bfchar" ? 2 : 3
                var i = 0
                while i + step <= hex.count {
                    let destination = hex[i + step - 1]
                    if destination.count >= 4, let value = UInt32(destination.prefix(4), radix: 16) {
                        if kind == "bfrange", let low = UInt32(hex[i], radix: 16), let high = UInt32(hex[i + 1], radix: 16),
                           high >= low, high - low < 4096 {
                            for k in 0...(high - low) { destinations.insert(value + k) }
                        } else {
                            destinations.insert(value)
                        }
                    }
                    i += step
                }
            }
            result.append((names[number] ?? "?", destinations))
        }
        return result
    }

    /// A font dictionary as written in the file (uncompressed objects only, as WebKit and PDFKit
    /// write them): its BaseFont without the subset tag, whether it has a ToUnicode CMap, its
    /// `/Encoding` name and its code range.
    struct FontDictionary: Equatable {
        var baseFont: String
        var hasToUnicode: Bool
        var encoding: String?
        var subtype: String?
        var firstChar: Int?
        var lastChar: Int?
    }

    static func fontDictionaries(_ pdf: Data) -> [FontDictionary] {
        let text = String(decoding: pdf, as: UTF8.self)
        var result: [FontDictionary] = []
        for match in text.matches(of: /\d+ \d+ obj\s*<<((?:(?!endobj).)*?\/Type \/Font(?:(?!endobj).)*?)>>/.dotMatchesNewlines()) {
            let body = String(match.1)
            guard let base = body.firstMatch(of: /\/BaseFont\s*\/(?:[A-Z]{6}\+)?([^\s\/<>\[\]()]+)/) else { continue }
            result.append(FontDictionary(
                baseFont: String(base.1),
                hasToUnicode: body.contains("/ToUnicode"),
                encoding: body.firstMatch(of: /\/Encoding\s*\/(\w+)/).map { String($0.1) },
                subtype: body.firstMatch(of: /\/Subtype\s*\/(\w+)/).map { String($0.1) },
                firstChar: body.firstMatch(of: /\/FirstChar\s+(\d+)/).flatMap { Int($0.1) },
                lastChar: body.firstMatch(of: /\/LastChar\s+(\d+)/).flatMap { Int($0.1) }
            ))
        }
        return result
    }

    static func radicals(in destinations: Set<UInt32>) -> Set<UInt32> {
        destinations.filter { RadicalEquivalents.unifiedIdeograph[$0] != nil }
    }

    // MARK: Files

    /// A PNG of one flat colour.
    static func png(red: Int, green: Int, blue: Int, size: Int = 40) -> Data {
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
        return rep.representation(using: .png, properties: [:])!
    }

    /// The `src` attribute of the first `<img>` in `html`, as written.
    static func firstImageSource(_ html: String) -> String? {
        guard let match = html.firstMatch(of: /<img src="([^"]*)"/) else { return nil }
        return String(match.1)
    }
}
#endif
