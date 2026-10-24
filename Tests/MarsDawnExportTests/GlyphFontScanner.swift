#if os(macOS)
import CoreGraphics
import Foundation

/// Which font drew which character, read from a PDF's content streams (kit #164 G3).
///
/// Walks every page's text operators (`Tf`, `Tj`, `TJ`, `'`, `"`) and, for a simple font with a
/// named single-byte encoding (MacRoman or WinAnsi, what WebKit writes for Latin faces), decodes
/// each byte to its character. CID fonts (`Type0`, which is how WebKit writes Hiragino) are
/// recorded as used, but their codes are glyph ids, not characters; for those the per-character
/// answer comes from PDFKit's text runs or the ToUnicode CMaps (`ManualProbe.cmapDestinations`).
enum GlyphFontScanner {
    struct Result {
        /// Every character a simple font drew, with the fonts (BaseFont, subset tag removed).
        var characters: [Character: Set<String>] = [:]
        /// Every font a text operator selected, in the order first used.
        var fonts: [String] = []
    }

    private final class Context {
        var result = Result()
        var stream: CGPDFContentStreamRef?
        var font: (name: String, encoding: String.Encoding?)?

        func show(_ string: CGPDFStringRef) {
            guard let font, let encoding = font.encoding, let bytes = CGPDFStringGetBytePtr(string) else { return }
            let data = Data(bytes: bytes, count: CGPDFStringGetLength(string))
            guard let text = String(data: data, encoding: encoding) else { return }
            for character in text { result.characters[character, default: []].insert(font.name) }
        }
    }

    static func scan(_ pdf: Data) -> Result {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider) else { return Result() }
        let context = Context()
        guard let table = CGPDFOperatorTableCreate() else { return Result() }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            let context = Unmanaged<Context>.fromOpaque(info!).takeUnretainedValue()
            var size: CGPDFReal = 0
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopNumber(scanner, &size), CGPDFScannerPopName(scanner, &name), let name,
                  let stream = context.stream, let object = CGPDFContentStreamGetResource(stream, "Font", name) else {
                context.font = nil
                return
            }
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { context.font = nil; return }
            func nameValue(_ key: String) -> String? {
                var value: UnsafePointer<CChar>?
                return CGPDFDictionaryGetName(dictionary, key, &value) ? value.map { String(cString: $0) } : nil
            }
            var base = nameValue("BaseFont") ?? "?"
            if base.count > 7, base.dropFirst(6).first == "+", base.prefix(6).allSatisfy(\.isUppercase) {
                base = String(base.dropFirst(7))
            }
            let subtype = nameValue("Subtype")
            var encoding: String.Encoding?
            if subtype == "TrueType" || subtype == "Type1" {
                switch nameValue("Encoding") {
                case "MacRomanEncoding": encoding = .macOSRoman
                case "WinAnsiEncoding": encoding = .windowsCP1252
                default: encoding = nil
                }
            }
            context.font = (base, encoding)
            if !context.result.fonts.contains(base) { context.result.fonts.append(base) }
        }
        let showString: CGPDFOperatorCallback = { scanner, info in
            let context = Unmanaged<Context>.fromOpaque(info!).takeUnretainedValue()
            var string: CGPDFStringRef?
            if CGPDFScannerPopString(scanner, &string), let string { context.show(string) }
        }
        CGPDFOperatorTableSetCallback(table, "Tj", showString)
        CGPDFOperatorTableSetCallback(table, "'", showString)
        CGPDFOperatorTableSetCallback(table, "\"", showString)
        CGPDFOperatorTableSetCallback(table, "TJ") { scanner, info in
            let context = Unmanaged<Context>.fromOpaque(info!).takeUnretainedValue()
            var array: CGPDFArrayRef?
            guard CGPDFScannerPopArray(scanner, &array), let array else { return }
            for index in 0..<CGPDFArrayGetCount(array) {
                var string: CGPDFStringRef?
                if CGPDFArrayGetString(array, index, &string), let string { context.show(string) }
            }
        }
        for number in 1...max(document.numberOfPages, 1) {
            guard let page = document.page(at: number) else { continue }
            let stream = CGPDFContentStreamCreateWithPage(page)
            context.stream = stream
            context.font = nil
            let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(context).toOpaque())
            CGPDFScannerScan(scanner)
            CGPDFScannerRelease(scanner)
            CGPDFContentStreamRelease(stream)
        }
        CGPDFOperatorTableRelease(table)
        return context.result
    }
}
#endif
