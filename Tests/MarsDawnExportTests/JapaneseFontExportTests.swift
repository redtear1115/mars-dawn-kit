#if os(macOS)
import AppKit
import CoreText
import Foundation
import PDFKit
import Testing
@testable import MarsDawnExport
@testable import MarsDawnKit

/// kit #164 G3: in an exported Japanese document, every kanji and kana is drawn by a Hiragino face
/// of the theme's design, and every other character by exactly the font it had before.
///
/// "Before" is the same export with `#content`'s `lang` taken away just before printing, so the
/// Japanese rules don't apply; nothing else differs. Three instruments, because no one of them
/// sees every font: PDFKit's text runs name the Hiragino faces per character (they are CID fonts
/// without a ToUnicode CMap), the ToUnicode CMaps name the PingFang and Songti faces per character
/// (PDFKit can't name those hidden system faces), and the content-stream scan names the Latin,
/// mono and KaTeX faces per character.
///
/// The control (the `#content:lang(ja)` rules taken out of preview.css) goes red where the
/// process language is Chinese, as on the owner's Mac (zh-Hant): there 直骨次 fall back to PingFang
/// or Songti. Where the process language is English (CI), WebKit's own fallback may already pick
/// Hiragino for a `lang="ja"` element, and the control may stay green; the test prints both
/// languages so a run says which case it was.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct JapaneseFontExportTests {
    static let fixture = """
    # 直骨次 Heading 123

    ## 直骨次の見出し

    本文の直骨次です。Heading 123

    | 見出し | 値 |
    |---|---|
    | 直骨次 | かな |

    ```
    let code = "Heading 123"
    ```

    Math $x^2 + y$ here.

    """

    static let targets: [Character] = ["直", "骨", "次", "の", "見", "出", "し", "本", "文", "で", "す", "値", "か", "な"]

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { ContentLanguage.counts(String($0)) != (0, 0) || (0x3000...0x303F).contains($0.value) }
    }

    struct Export {
        var data: Data
        var text: String
        /// Per CJK character, the fonts PDFKit's text runs name for it.
        var runFonts: [Character: Set<String>]
        /// Per character, the fonts whose ToUnicode CMap maps to it.
        var cmapFonts: [Character: Set<String>]
        var scan: GlyphFontScanner.Result
        var navigatorLanguages: String
    }

    static func export(theme: PreviewTheme, removingLang: Bool) async throws -> Export {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ja-fonts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("out.pdf")
        var languages = "?"
        _ = try await DocumentExporter.exportPDF(
            markdown: fixture, to: url, theme: theme, baseDirectory: nil, allowRemoteImages: false,
            inspect: { exporter in
                languages = (try? await exporter.webView.evaluateJavaScript("JSON.stringify(navigator.languages)") as? String) ?? "?"
                let lang = try await exporter.webView.evaluateJavaScript("document.getElementById('content').lang") as? String
                #expect(lang == "ja", "precondition: the export's content is marked Japanese")
                if removingLang {
                    _ = try await exporter.webView.evaluateJavaScript(
                        "document.getElementById('content').removeAttribute('lang'); document.fonts.ready.then(() => 0); 0")
                    _ = try await exporter.webView.callAsyncJavaScript("await document.fonts.ready; return 0;", contentWorld: .page)
                }
            }
        )
        let data = try Data(contentsOf: url)
        let document = try #require(PDFDocument(data: data))
        var runFonts: [Character: Set<String>] = [:]
        for index in 0..<document.pageCount {
            guard let attributed = document.page(at: index)?.attributedString else { continue }
            attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                let name = (value as? NSFont)?.fontName ?? "?"
                for character in (attributed.string as NSString).substring(with: range) where isCJK(character) {
                    runFonts[character, default: []].insert(name)
                }
            }
        }
        var cmapFonts: [Character: Set<String>] = [:]
        for (font, destinations) in ManualProbe.cmapDestinations(data) {
            for value in destinations {
                guard let scalar = Unicode.Scalar(value) else { continue }
                cmapFonts[Character(scalar), default: []].insert(font)
            }
        }
        return Export(data: data, text: document.string ?? "", runFonts: runFonts, cmapFonts: cmapFonts,
                      scan: GlyphFontScanner.scan(data), navigatorLanguages: languages)
    }

    static func describe(_ export: Export) -> String {
        let cjk = targets.map { c in
            "\(c)→runs \(export.runFonts[c]?.sorted() ?? []) cmaps \(export.cmapFonts[c]?.sorted() ?? [])"
        }
        let latin = export.scan.characters.filter { !isCJK($0.key) && !$0.key.isWhitespace }
            .sorted { String($0.key) < String($1.key) }.map { "\($0.key)→\($0.value.sorted())" }
        return "CJK: " + cjk.joined(separator: "; ") + "\n  other: " + latin.joined(separator: "; ")
            + "\n  fonts: \(export.scan.fonts)"
    }

    /// The Hiragino faces each design may use.
    static func expectedFaces(_ theme: PreviewTheme) -> Set<String> {
        switch theme.fontDesign {
        case .serif: ["HiraMinProN-W3", "HiraMinProN-W6"]
        case .rounded: ["HiraMaruProN-W4", "HiraginoSans-W6"]
        case .sans: ["HiraginoSans-W3", "HiraginoSans-W6"]
        }
    }

    @Test(arguments: ["dawn", "classic", "modern", "vivid"])
    func kanjiAndKanaTakeHiraginoAndNothingElseMoves(_ id: String) async throws {
        let theme = try #require([PreviewTheme.dawn, .classic, .modern, .vivid].first { $0.id == id })
        let head = try await Self.export(theme: theme, removingLang: false)
        let base = try await Self.export(theme: theme, removingLang: true)
        print("G3 \(id) Locale.preferredLanguages=\(Locale.preferredLanguages) navigator.languages=\(head.navigatorLanguages)")
        print("G3 \(id) with the fix:\n  \(Self.describe(head))")
        print("G3 \(id) without (lang removed):\n  \(Self.describe(base))")

        let faces = Self.expectedFaces(theme)
        for character in Self.targets {
            let runs = head.runFonts[character] ?? []
            #expect(!runs.isEmpty && runs.isSubset(of: faces), "\(id): \(character) drawn by \(runs.sorted()), expected \(faces.sorted())")
            // A face with a ToUnicode CMap (PingFang, Songti) drew none of them.
            #expect(head.cmapFonts[character] == nil, "\(id): \(character) also in \(head.cmapFonts[character]?.sorted() ?? [])")
        }
        // Every other character: the same fonts as without the Japanese rules. Latin words, code
        // (the mono face) and math (KaTeX's faces) alike.
        let headOther = head.scan.characters.filter { !Self.isCJK($0.key) }
        let baseOther = base.scan.characters.filter { !Self.isCJK($0.key) }
        #expect(!baseOther.isEmpty && ["H", "1", "l", "x"].allSatisfy { baseOther[$0] != nil }, "positive fixture: Latin, code and math were read")
        #expect(headOther == baseOther, "\(id): non-CJK characters moved")
        let nonCJKFonts = { (e: Export) -> Set<String> in
            Set(e.scan.fonts.filter { !$0.contains("Hira") && !$0.contains("PingFang") && !$0.contains("Songti") })
        }
        #expect(nonCJKFonts(head) == nonCJKFonts(base), "\(id): \(nonCJKFonts(head).sorted()) vs \(nonCJKFonts(base).sorted())")
        #expect(nonCJKFonts(head).contains { $0.hasPrefix("KaTeX") }, "positive fixture: math drawn by KaTeX")
        // A heading's text is in the text layer once: no synthesized bold drawn over itself.
        #expect(head.text.components(separatedBy: "直骨次の見出し").count == 2, "\(id): \(head.text)")
        #expect(head.text == base.text, "\(id): the text layer reads the same")
    }

    /// The faces `preview.css` names exist on this system (macOS 15 and 26 on CI).
    @Test func theNamedFacesAreInstalled() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/preview.css")
        let css = try String(contentsOf: url, encoding: .utf8)
        let names = Set(css.matches(of: /local\("([^"]+)"\)/).map { String($0.output.1) })
        #expect(names == ["HiraginoSans-W3", "HiraginoSans-W6", "HiraMinProN-W3", "HiraMinProN-W6", "HiraMaruProN-W4"])
        let installed = Set(CTFontManagerCopyAvailablePostScriptNames() as? [String] ?? [])
        print("G3 OS \(ProcessInfo.processInfo.operatingSystemVersionString): \(names.sorted().map { "\($0)=\(installed.contains($0))" })")
        for name in names { #expect(installed.contains(name), "\(name) is not installed") }
    }
}
#endif
