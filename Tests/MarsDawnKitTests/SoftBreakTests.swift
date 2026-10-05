import Testing
@testable import MarsDawnKit

/// #129: `softBreaksAsLineBreaks`, and no space where a soft break joins two CJK characters.
struct SoftBreakTests {
    private static let breaks = MarkdownRenderer.Options(softBreaksAsLineBreaks: true)

    /// The body of the only paragraph `markdown` renders to.
    private func inline(_ markdown: String, options: MarkdownRenderer.Options = .init()) -> String {
        let html = MarkdownRenderer.render(markdown, options: options)
        guard let open = html.range(of: "<p "), let start = html.range(of: ">", range: open.lowerBound..<html.endIndex),
              let end = html.range(of: "</p>", options: .backwards)
        else { return html }
        return String(html[start.upperBound..<end.lowerBound])
    }

    // MARK: Option off (CommonMark)

    @Test func latinLinesKeepTheirNewline() {
        let html = MarkdownRenderer.render("first line\nsecond line\n")
        #expect(html == "<p data-line=\"1\">first line\nsecond line</p>\n")
    }

    @Test func cjkLinesAreJoinedWithNothingInBetween() {
        let html = MarkdownRenderer.render("第一行中文\n第二行中文\n")
        #expect(html == "<p data-line=\"1\">第一行中文第二行中文</p>\n")
        let body = inline("第一行中文\n第二行中文")
        #expect(html.components(separatedBy: "<p ").count == 2 && !html.contains("<br>"))
        #expect(!body.contains(" ") && !body.contains("\n"), "no whitespace at all: \(body.debugDescription)")
    }

    @Test(arguments: [
        ("日本語\nです", "日本語です"),                 // Han then Hiragana
        ("ひらがな\nカタカナ", "ひらがなカタカナ"),      // Hiragana then Katakana
        ("ｶﾀｶﾅ\nｶﾀｶﾅ", "ｶﾀｶﾅｶﾀｶﾅ"),                  // halfwidth Katakana
        ("한국어\n문장", "한국어문장"),                  // Hangul syllables
        ("ㄱㄴㄷ\nㅏㅓ", "ㄱㄴㄷㅏㅓ"),                  // Hangul compatibility Jamo
        ("你好。\n再见", "你好。再见"),                  // ideographic full stop
        ("你好\n「再见」", "你好「再见」"),              // corner brackets
        ("你好、\n再见", "你好、再见"),                  // ideographic comma
        ("你好，\n再见", "你好，再见"),                  // fullwidth comma
        ("你好\n（再见）", "你好（再见）"),              // fullwidth parentheses
        ("你好！\nＡＢ", "你好！ＡＢ"),                  // fullwidth Latin letters count as fullwidth forms
        ("𠀀\n𠀁", "𠀀𠀁"),                              // Extension B, outside the BMP
    ])
    func cjkOnBothSidesJoin(markdown: String, expected: String) {
        #expect(inline(markdown) == expected)
    }

    /// Mixed CJK and Latin keeps what CommonMark does: the break stays, and a browser shows a
    /// space. The same for digits, and for a CJK character beside the ideographic space.
    @Test(arguments: [
        "日本語\nabc", "abc\n日本語", "日本語\n123", "第 3\n日本語", "日本語\n\u{3000}日本語", "日本語\u{3000}\n日本語",
        "日本語\n😀", "😀\n日本語", "日本語\n$x$",
    ])
    func mixedOrNonCJKKeepsTheNewline(markdown: String) {
        #expect(inline(markdown).contains("\n"), "\(markdown.debugDescription) -> \(inline(markdown).debugDescription)")
    }

    @Test func everyLineOfALongCJKParagraphJoins() {
        #expect(inline("一二三\n四五六\n七八九\n十") == "一二三四五六七八九十")
    }

    /// A break at the edge of an emphasis, strong, link or strikethrough looks through it to the
    /// character it touches.
    @Test func theBreakLooksThroughInlineMarkup() {
        #expect(inline("**加粗**\n中文") == "<strong>加粗</strong>中文")
        #expect(inline("中文\n**加粗**") == "中文<strong>加粗</strong>")
        #expect(inline("*一*\n*二*") == "<em>一</em><em>二</em>")
        #expect(inline("~~一~~\n[二](https://x.y)") == #"<del>一</del><a href="https://x.y">二</a>"#)
        #expect(inline("**一\n二**") == "<strong>一二</strong>")
        #expect(inline("**abc**\n中文").contains("\n"))
        #expect(inline("`代码`\n中文") == "<code>代码</code>中文")
        #expect(inline("中文\n![图](a.png)").contains("\n"))
        #expect(inline("中文\n<b>中</b>").contains("\n"))
    }

    @Test func aHardBreakIsStillABreak() {
        #expect(inline("中文  \n中文") == "中文<br>\n中文")
        #expect(inline("中文\\\n中文") == "中文<br>\n中文")
    }

    @Test func listsQuotesAndFootnotesJoinToo() {
        let html = MarkdownRenderer.render("- 一\n  二\n\n> 三\n> 四\n\n五[^n]\n六\n\n[^n]: 七\n    八\n")
        #expect(html.contains("一二"))
        #expect(html.contains("三四"))
        #expect(html.contains("七八"))
        #expect(html.contains("五") && html.contains("</sup>\n六"), "a break after a reference stays: \(html)")
    }

    @Test func tablesAndHeadingsHaveNoSoftBreaksToJoin() {
        let html = MarkdownRenderer.render("# 标题\n\n| 一 | 二 |\n|--|--|\n| 三 | 四 |\n")
        #expect(html.contains(">标题</h1>") && html.contains("<td>四</td>"))
    }

    @Test func codeIsNotJoined() {
        #expect(MarkdownRenderer.render("```\n一\n二\n```\n").contains("一\n二"))
        #expect(MarkdownRenderer.render("    一\n    二\n").contains("一\n二"))
    }

    // MARK: Option on

    @Test func everyNewlineBecomesALineBreakWhenOn() {
        #expect(inline("first\nsecond\nthird", options: Self.breaks) == "first<br>\nsecond<br>\nthird")
        #expect(MarkdownRenderer.render("a\nb\n", options: Self.breaks) == "<p data-line=\"1\">a<br>\nb</p>\n")
    }

    /// With the option on the author asked for a break at every newline, so CJK lines keep theirs.
    @Test func cjkLinesKeepTheirBreaksWhenOn() {
        #expect(inline("第一行中文\n第二行中文", options: Self.breaks) == "第一行中文<br>\n第二行中文")
        #expect(inline("日本語\nabc", options: Self.breaks) == "日本語<br>\nabc")
    }

    @Test func breaksCarryIntoNestedContainersAndNotes() {
        let html = MarkdownRenderer.render("- a\n  b\n\n**c\nd**\n\ne[^n]\n\n[^n]: f\n    g\n", options: Self.breaks)
        #expect(html.contains("a<br>\nb"))
        #expect(html.contains("<strong>c<br>\nd</strong>"))
        #expect(html.contains("f<br>\ng"))
    }

    @Test func aHardBreakAndABlankLineAreUnchangedWhenOn() {
        #expect(inline("a  \nb", options: Self.breaks) == "a<br>\nb")
        #expect(MarkdownRenderer.render("a\n\nb\n", options: Self.breaks).components(separatedBy: "<p ").count == 3)
        #expect(!MarkdownRenderer.render("a\n\nb\n", options: Self.breaks).contains("<br>"))
    }

    @Test func theOptionDefaultsToOffAndIsPartOfOptions() {
        #expect(MarkdownRenderer.Options().softBreaksAsLineBreaks == false)
        #expect(MarkdownRenderer.Options(softBreaksAsLineBreaks: true).softBreaksAsLineBreaks)
        var options = MarkdownRenderer.Options()
        options.softBreaksAsLineBreaks = true
        #expect(inline("a\nb", options: options) == "a<br>\nb")
    }

    /// Raw HTML still goes through the same rules, and no break is made inside a tag.
    @Test func rawHTMLIsUntouched() {
        #expect(inline("<span\ntitle=\"x\">中\n文</span>", options: Self.breaks).contains("<span\ntitle=\"x\">"))
    }

    /// Cheap, whatever the paragraph: a long run of lines is one linear pass, not one that
    /// looks siblings up by index each time.
    @Test func aVeryLongParagraphStaysFast() {
        let document = String(repeating: "一二三\n", count: 40_000)
        let clock = ContinuousClock()
        var html = ""
        let elapsed = clock.measure { html = MarkdownRenderer.render(document) }
        #expect(html.hasPrefix("<p data-line=\"1\">一二三一二三"))
        #expect(elapsed < .seconds(20), "\(elapsed)")
    }
}
