import Foundation
import Testing
@testable import MarsDawnKit

/// kit #164 G1, G5: which documents are Japanese, and what reaches the marker.
struct ContentLanguageTests {
    static let marker = "<md-content-lang data-lang=\"ja\"></md-content-lang>"

    static func withLang(_ value: String, body: String) -> String {
        "---\nlang: \(value)\n---\n\(body)"
    }

    /// A Chinese paragraph with one katakana word: 3 kana letters against 40 Han, under 20%.
    static let chineseWithOneKatakanaWord = "我昨天晚上和朋友一起在家裡看了一部很長的日本「アニメ」電影，大家都覺得故事非常感人而且畫面十分漂亮。\n"

    // MARK: G1 — front matter decides first

    @Test(arguments: ["ja", "\"ja-JP\"", "'ja'", "JA", "ja-Hira-JP", "\"ja\" "])
    func aJapaneseLangIsTheAnswer(_ value: String) {
        // No kana in the body: the answer can only have come from the front matter.
        let expected = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        #expect(ContentLanguage.detect(markdown: Self.withLang(value, body: "Plain English.\n")) == expected)
    }

    @Test(arguments: ["zh-Hant", "en", "tr", "zh-Hans", "\"en-US\""])
    func anotherLangIsNilEvenWithKana(_ value: String) {
        #expect(ContentLanguage.detect(markdown: Self.withLang(value, body: "ひらがなとカタカナだけのぶんしょうです。\n")) == nil)
    }

    /// An invalid or empty value is as if there were no `lang:`: the kana decide.
    @Test(arguments: ["<x>", "Ｊa", "ja--JP", "-ja", "ja-", "j", "jpan", "ja_JP", "\"\"", "''", "\"ja'", "ja JP",
                      String(repeating: "a", count: 2) + "-" + String(repeating: "abcdefgh-", count: 3) + "abcdef" /* 36 bytes */])
    func anInvalidLangFallsBackToTheKana(_ value: String) {
        #expect(ContentLanguage.detect(markdown: Self.withLang(value, body: "かなかな\n")) == "ja", "\(value)")
        #expect(ContentLanguage.detect(markdown: Self.withLang(value, body: "漢字只有中文。\n")) == nil, "\(value)")
    }

    @Test func theThirtySixByteValueIsThirtySixBytes() {
        let value = "aa-" + String(repeating: "abcdefgh-", count: 3) + "abcdef"
        #expect(value.utf8.count == 36)
        let thirtyFive = String(value.dropLast())
        #expect(ContentLanguage.isValidTag(thirtyFive.utf8), "control: 35 bytes of the same shape are valid")
        #expect(!ContentLanguage.isValidTag(value.utf8))
    }

    /// The key is read as the front-matter table reads it: exactly `lang`, first occurrence.
    @Test func theKeyRuleIsTheTables() {
        #expect(ContentLanguage.detect(markdown: "---\nLang: ja\n---\nEnglish.\n") == nil)
        #expect(ContentLanguage.detect(markdown: "---\n  lang: ja\n---\nEnglish.\n") == nil)
        #expect(ContentLanguage.detect(markdown: "---\nlang: en\nlang: ja\n---\nEnglish.\n") == nil)
        #expect(ContentLanguage.detect(markdown: "---\nlang: ja\nlang: en\n---\nEnglish.\n") == "ja")
        // A block the table can't show as pairs (a list in it) still has its `lang:` line read.
        #expect(ContentLanguage.detect(markdown: "---\ntags:\n  - a\nlang: ja\n---\nEnglish.\n") == "ja")
        // `lang:` in the body is not front matter.
        #expect(ContentLanguage.detect(markdown: "# Doc\n\nlang: ja\n") == nil)
    }

    // MARK: G1 — otherwise the kana decide

    @Test func kanaAloneIsJapanese() {
        #expect(ContentLanguage.detect(markdown: "かなかな\n") == "ja")
        #expect(ContentLanguage.detect(markdown: "日本語のテキストです。\n") == "ja")
        #expect(ContentLanguage.detect(markdown: "ｶﾀｶﾅ\n") == "ja")
    }

    @Test func chineseMarksAreNotKana() {
        #expect(ContentLanguage.detect(markdown: "「哈利・波特」\n") == nil)
        #expect(ContentLanguage.detect(markdown: "「哈利・波特」是一部小說，作者是英國人。\n") == nil)
        // Each Common or Inherited scalar on its own counts as neither kana nor Han.
        for value: UInt32 in [0x30FB, 0x30A0, 0x30FC, 0x3099, 0x309A, 0x309B, 0x309C, 0xFF65, 0xFF70, 0xFF9E, 0xFF9F] {
            let text = String(Character(Unicode.Scalar(value)!))
            let counts = ContentLanguage.counts(text)
            #expect(counts.kana == 0 && counts.han == 0, "U+\(String(value, radix: 16, uppercase: true))")
        }
        #expect(ContentLanguage.detect(markdown: "ー\n") == nil)
        #expect(ContentLanguage.detect(markdown: "ーー゛゜゠･ｰﾞﾟ\n") == nil)
        #expect(ContentLanguage.detect(markdown: "Plain English, no CJK at all.\n") == nil)
        #expect(ContentLanguage.detect(markdown: "") == nil)
    }

    @Test func oneKatakanaWordInChineseIsNotJapanese() {
        let counts = ContentLanguage.counts(Self.chineseWithOneKatakanaWord)
        #expect(counts.kana == 3 && counts.kana * 5 < counts.kana + counts.han, "fixture: \(counts)")
        #expect(ContentLanguage.detect(markdown: Self.chineseWithOneKatakanaWord) == nil)
    }

    @Test func theThresholdIsTwentyPercentInclusive() {
        func text(kana: Int, han: Int) -> String {
            String(repeating: "か", count: kana) + String(repeating: "漢", count: han) + "\n"
        }
        #expect(ContentLanguage.detect(markdown: text(kana: 1, han: 4)) == "ja", "1 of 5: 20.0%")
        #expect(ContentLanguage.detect(markdown: text(kana: 40, han: 160)) == "ja", "40 of 200: 20.0%")
        #expect(ContentLanguage.detect(markdown: text(kana: 39, han: 161)) == nil, "39 of 200: 19.5%")
        #expect(ContentLanguage.detect(markdown: text(kana: 199, han: 801)) == nil, "199 of 1000: 19.9%")
        #expect(ContentLanguage.detect(markdown: text(kana: 1, han: 5)) == nil, "1 of 6: 16.7%")
        // The mixed-CJK corpus fixture: Chinese, Japanese and Korean paragraphs, 39 kana of 263 (14.8%).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let cjk = try? String(contentsOf: root.appendingPathComponent("MarsDawnExportTests/Corpus/cjk/document.md"), encoding: .utf8)
        let counts = ContentLanguage.counts(cjk ?? "")
        #expect(counts.kana == 39 && counts.han == 224, "fixture: \(counts)")
        #expect(ContentLanguage.detect(markdown: cjk ?? "") == nil)
    }

    /// Kana count wherever they are, code blocks included (the choice `detect` documents).
    @Test func kanaInsideCodeCount() {
        #expect(ContentLanguage.detect(markdown: "# Strings\n\n```swift\nlet s = \"こんにちは\"\n```\n") == "ja")
    }

    /// One pass over the scalars: a 16 MiB document (the renderer's default byte limit) is scanned
    /// in well under a second in release, and its time grows with its length, not faster.
    @Test func sixteenMebibytesIsLinear() {
        #if DEBUG
        let slack = 10.0
        #else
        let slack = 1.0
        #endif
        let unit = "日本語のテキスト、English text 123. 漢字漢字漢字。\n"
        func document(bytes: Int) -> String { String(repeating: unit, count: bytes / unit.utf8.count) }
        let clock = ContinuousClock()
        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }
        func time(_ text: String) -> Double {
            (0..<3).map { _ in seconds(clock.measure { _ = ContentLanguage.detect(markdown: text) }) }.min()!
        }
        let small = document(bytes: 2 << 20), large = document(bytes: 16 << 20)
        #expect(large.utf8.count > 16_000_000)
        #expect(ContentLanguage.detect(markdown: large) == "ja")
        let t2 = time(small), t16 = time(large)
        // 8x the input: linear is about 8x the time.
        expectWithinBudget(t16, max(24 * t2, 0.02 * slack), "2 MiB \(t2)s, 16 MiB \(t16)s")
        expectWithinBudget(t16, 0.5 * slack, "16 MiB")
    }

    // MARK: G5 — only a validated tag reaches the marker

    /// The `ja-…` ones pass a primary-subtag check, so only the shape check stops them.
    @Test(arguments: ["ja-\"><script>x</script>", "ja-x\" onclick=\"y", "ja-<b>", "'ja-\"><i>'", "ja-JP\u{301}",
                      "ja\"><script>x</script>", "ja\" onclick=\"x", "\"ja\"><b>", "ja'><i>", "ja&quot;", "ja\u{0}", "ja\n"])
    func aHostileLangNeverReachesTheMarker(_ value: String) {
        for body in ["かなかな\n", "English.\n"] {
            let markdown = Self.withLang(value, body: body)
            let detected = ContentLanguage.detect(markdown: markdown)
            #expect(detected == nil || detected == "ja", "\(value): \(String(describing: detected))")
            let html = MarkdownRenderer.render(markdown)
            if html.hasPrefix("<md-content-lang") {
                #expect(html.hasPrefix(Self.marker), "\(value): \(html.prefix(80))")
            }
            #expect(html.components(separatedBy: "data-lang=").count <= 2, "\(value): one marker attribute at most")
        }
    }

    @Test func theMarkerIsOnlyEverAValidJapaneseTag() {
        #expect(ContentLanguage.markerHTML("ja") == Self.marker)
        #expect(ContentLanguage.markerHTML("ja-JP") == "<md-content-lang data-lang=\"ja-JP\"></md-content-lang>")
        for bad in ["en", "zh-Hant", "ja\"", "<x>", ""] {
            #expect(ContentLanguage.markerHTML(bad) == "", "\(bad)")
        }
    }

    // MARK: Delivery — marker first when detected, output unchanged otherwise

    @Test func aJapaneseDocumentStartsWithTheMarkerAndIsOtherwiseUnchanged() {
        for markdown in ["# 見出し\n\n本文です。\n", Self.withLang("ja", body: "# Title\n"), "---\ntitle: x\n---\nかなの本文\n",
                         "<div>かな</div>\n", "- かな\n- かな\n"] {
            let html = MarkdownRenderer.render(markdown)
            #expect(html.hasPrefix(Self.marker), "\(markdown)")
            #expect(MarkdownRenderer.renderResult(markdown).fallback == nil)
            #expect(String(html.dropFirst(Self.marker.count)).hasPrefix("<"), "the next node is the renderer's own")
            #expect(html.components(separatedBy: "md-content-lang").count == 3, "one marker, open and close tag")
        }
        let tagged = MarkdownRenderer.render(Self.withLang("\"ja-JP\"", body: "Text.\n"))
        #expect(tagged.hasPrefix("<md-content-lang data-lang=\"ja-JP\"></md-content-lang><details class=\"front-matter\""))
    }

    @Test func otherDocumentsHaveNoMarker() async {
        for markdown in [Self.withLang("zh-Hans", body: "かなかな\n"), Self.withLang("tr", body: "かなかな\n"),
                         Self.chineseWithOneKatakanaWord, "# English\n", "「哈利・波特」\n", "日本語\n"] {
            #expect(!MarkdownRenderer.render(markdown).contains("md-content-lang"), "\(markdown)")
            #expect(await MarkdownRenderer.renderResult(markdown, options: .init())?.html.contains("md-content-lang") == false)
        }
    }

    @Test func theAsyncRenderMarksToo() async {
        #expect(await MarkdownRenderer.renderResult("かな\n", options: .init())?.html.hasPrefix(Self.marker) == true)
    }

    /// The fallbacks keep their own first node after the marker; a document over the byte limit is
    /// not scanned at all.
    @Test func fallbacks() {
        let deep = String(repeating: "> ", count: 600) + "かな\n"
        let deepResult = MarkdownRenderer.renderResult(deep)
        #expect(deepResult.fallback != nil, "fixture: the nesting fallback")
        #expect(deepResult.html.hasPrefix(Self.marker + "<pre class=\"source-fallback\""))

        var options = MarkdownRenderer.Options()
        options.maxBytes = 8
        let large = MarkdownRenderer.renderResult("かなかなかな\n", options: options)
        #expect(large.fallback == .tooLarge)
        #expect(!large.html.contains("md-content-lang"))
    }
}
