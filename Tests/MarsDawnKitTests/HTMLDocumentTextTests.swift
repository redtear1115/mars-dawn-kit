import Foundation
import Testing
@testable import MarsDawnKit

@Suite(.timeLimit(.minutes(1)))
struct HTMLDocumentTagTests {
    private func kept(_ tag: String) -> Bool {
        neutralizingHTMLDocumentTags(tag) == tag
    }

    private func renamed(_ tag: String) -> Bool {
        let result = neutralizingHTMLDocumentTags(tag)
        return result.hasPrefix("<x-md-link") && result.dropFirst("<x-md-".count) == tag.dropFirst(1)
    }

    @Test func keepsOnlyAPlainStylesheetLink() {
        for tag in [
            "<link rel=stylesheet href=a.css>",
            #"<link rel="StyleSheet " href="a.css">"#,
            "<LINK REL='stylesheet' href=a.css>",
            "<link\trel=stylesheet\nhref=a.css/>",
            "<link href=a.css rel=stylesheet >",
            "<link rel=\" stylesheet\t\" href=a.css>",
            #"<link rel=stylesheet title="a>b" href="a.css">"#,
            "<link rel=stylesheet href=a.css as=font imagesrcset=x.png blocking=render>",
            "<link rel=stylesheet disabled>",
            "<link rel=stylesheet / >",
        ] {
            #expect(kept(tag), "\(tag)")
        }
    }

    @Test func renamesEveryOtherLink() {
        for tag in [
            "<link rel=preconnect href=https://x>",
            "<link rel=dns-prefetch href=//x>",
            "<link rel=stylesheet rel=stylesheet href=a.css>",
            "<link rel=stylesheet REL=preconnect href=https://x>",
            #"<link rel="preconnect stylesheet" href=https://x>"#,
            #"<link rel="alternate stylesheet" href=a.css>"#,
            "<link rel=stylesheet/rel=preconnect href=https://x>",
            "<link rel=stylesheet/>",
            "<link =rel=stylesheet href=a.css>",
            #"<link "rel=stylesheet href=a.css>"#,
            "<link 'rel=stylesheet href=a.css>",
            "<link rel=&#115;tylesheet href=a.css>",
            "<link rel=\"stylesheet&#x20;\" href=a.css>",
            "<link r&#101;l=stylesheet href=a.css>",
            "<link rel=\"\u{A0}stylesheet\u{A0}\" href=a.css>",
            "<link rel=\u{17F}tylesheet href=a.css>",
            "<link rel=\"stylesheet\u{0}\" href=a.css>",
            "<link rel=\"style sheet\" href=a.css>",
            "<link rel href=a.css>",
            "<link rel= href=a.css>",
            "<link href=a.css>",
            "<link>",
            "<link rel=stylesheet href=\"a<b.css\">",
            "<link rel=stylesheet href=a.css",
            #"<link rel="stylesheet>"#,
        ] {
            #expect(renamed(tag), "\(tag) → \(neutralizingHTMLDocumentTags(tag))")
        }
    }

    @Test func keepsEndTagsAndOtherTagsInLine() {
        #expect(neutralizingHTMLDocumentTags("</link>") == "</x-md-link>")
        #expect(neutralizingHTMLDocumentTags("</LINK rel=stylesheet>") == "</x-md-link rel=stylesheet>")
        #expect(neutralizingHTMLDocumentTags("<linkfoo rel=preconnect>") == "<linkfoo rel=preconnect>")
        #expect(neutralizingHTMLDocumentTags("<link") == "<link")
        #expect(neutralizingHTMLDocumentTags("<p>link</p>") == "<p>link</p>")
        #expect(neutralizingHTMLDocumentTags("a <link rel=stylesheet href=a.css> b <link rel=preconnect> c")
            == "a <link rel=stylesheet href=a.css> b <x-md-link rel=preconnect> c")
    }

    @Test func aKeptTagNeverHidesMarkupFromTheRename() {
        // In a real parse the comment ends at `-->`, so the second link is a real tag.
        let hidden = #"<!-- <link rel=stylesheet x="--> <link rel=dns-prefetch href=//evil> ">"#
        let result = neutralizingHTMLDocumentTags(hidden)
        #expect(result.contains("<x-md-link rel=dns-prefetch"), "\(result)")
        let unterminated = #"<!-- <link a=" --> <link rel=preconnect href=https://x> <iframe srcdoc=x>"#
        let result2 = neutralizingHTMLDocumentTags(unterminated)
        #expect(result2.contains("<x-md-link rel=preconnect"), "\(result2)")
        #expect(result2.contains("<x-md-iframe"), "\(result2)")
    }

    @Test func renamesFrameTags() {
        let srcdoc = #"<iframe srcdoc="&lt;link rel=preconnect href=&quot;https://x&quot;&gt;"></iframe>"#
        #expect(neutralizingHTMLDocumentTags(srcdoc) == #"<x-md-iframe srcdoc="&lt;link rel=preconnect href=&quot;https://x&quot;&gt;"></x-md-iframe>"#)
        #expect(neutralizingHTMLDocumentTags("<FRAME src=a><Object data=b><embed/><portal src=c><fencedframe>")
            == "<x-md-frame src=a><x-md-object data=b><x-md-embed/><x-md-portal src=c><x-md-fencedframe>")
        #expect(neutralizingHTMLDocumentTags("<frameset><objective><iframes>") == "<frameset><objective><iframes>")
    }

    @Test func staysLinearOnUnterminatedTags() {
        let input = String(repeating: #"<link a=""#, count: 1_000_000 / 9)
        let start = ContinuousClock.now
        let output = neutralizingHTMLDocumentTags(input)
        let elapsed = ContinuousClock.now - start
        #expect(output.hasPrefix(#"<x-md-link a="<x-md-link"#))
        #expect(elapsed < .seconds(5), "took \(elapsed)")
        let quoted = String(repeating: #"<link rel=stylesheet title="x"#, count: 30_000)
        let start2 = ContinuousClock.now
        _ = neutralizingHTMLDocumentTags(quoted)
        #expect(ContinuousClock.now - start2 < .seconds(5))
    }

    @Test func scannerFindsRemoteReferences() {
        for html in [
            "<img src=http://x/a.png>", "<img SRC='https://x/a.png'>", "<img srcset=\"a.png 1x, https://x/b.png 2x\">",
            "<a href=//x/>", "<video poster=\"https://x/p.png\">", "<object data=https://x/o>", "<body background=http://x/b.png>",
            "<form action=https://x/f>", "<a ping=\"https://x/p\" href=a.html>", "<link imagesrcset=\"https://x/a.png 1x\">",
            "<svg><use xlink:href=\"https://x/s.svg#a\"/></svg>", "<img src=\" https://x/a.png\">",
            "<div style=\"background:url(https://x/a.png)\">", "<style>p{background:url( 'http://x/a.png' )}</style>",
            "<style>@import 'https://x/s.css';</style>", "<style>@import url(//x/s.css);</style>",
            "<style>p{background-image:image-set(\"a.png\" 1x, \"https://x/b.png\" 2x)}</style>",
            "<script src=wss://x/s></script>", "<img src=\\\\x\\a.png>",
        ] {
            #expect(referencesRemoteContent(html), "\(html)")
        }
    }

    @Test func scannerIgnoresLocalReferences() {
        for html in [
            "<img src=a.png>", "<img src=\"img/https.png\">", "<a href=#top>", "<a href=mailto:x@y>",
            "<img data-src=https://x/a.png>", "<p>see https://x/ for more</p>", "<img src=data:image/png;base64,AA>",
            "<style>p{background:url(img/a.png)}</style>", "<img srcset=\"a.png 1x, b.png 2x\">", "<img alt='http://x'>",
        ] {
            #expect(!referencesRemoteContent(html), "\(html)")
        }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct HTMLDocumentDecodingTests {
    private typealias Text = HTMLDocumentText

    @Test func decodesEveryWindows1252Byte() {
        let bytes = (0...255).map { UInt8($0) }
        let text = Text.decodeWindows1252(bytes)
        let scalars = Array(text.unicodeScalars)
        #expect(scalars.count == 256)
        let high: [UInt32] = [
            0x20AC, 0x81, 0x201A, 0x192, 0x201E, 0x2026, 0x2020, 0x2021, 0x2C6, 0x2030, 0x160, 0x2039, 0x152, 0x8D, 0x17D, 0x8F,
            0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x2DC, 0x2122, 0x161, 0x203A, 0x153, 0x9D, 0x17E, 0x178,
        ]
        for byte in 0...255 {
            let expected = (0x80...0x9F).contains(byte) ? high[byte - 0x80] : UInt32(byte)
            #expect(scalars[byte].value == expected, "byte \(byte)")
        }
        // A file with every byte (invalid UTF-8, no meta) falls back to windows-1252.
        let decoded = Text.decode(bytes)
        #expect(decoded.encoding == "windows-1252")
        #expect(decoded.text == text)
    }

    private func document(meta: String, body: [UInt8]) -> [UInt8] {
        Array("<!doctype html><html><head>\(meta)</head><body>".utf8) + body + Array("</body></html>".utf8)
    }

    @Test func honoursAllowListedMetaCharsets() throws {
        let big5 = try #require("中文".data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0A06)))))
        let decodedBig5 = Text.decode(document(meta: "<meta charset=big5>", body: Array(big5)))
        #expect(decodedBig5.encoding == "big5")
        #expect(decodedBig5.text.contains("<body>中文</body>"))

        let sjis = try #require("日本語".data(using: .shiftJIS))
        let decodedSJIS = Text.decode(document(meta: #"<meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS">"#, body: Array(sjis)))
        #expect(decodedSJIS.encoding == "shift_jis")
        #expect(decodedSJIS.text.contains("日本語"))

        let cyrillic = try #require("Привет".data(using: .windowsCP1251))
        #expect(Text.decode(document(meta: "<meta charset=' CP1251 '>", body: Array(cyrillic))).text.contains("Привет"))
        #expect(Text.decode(document(meta: "<!-- <meta charset=big5> --><meta charset=koi8-r>", body: [0xF0])).encoding == "koi8-r")
        #expect(Text.decode(document(meta: "<meta charset=iso-8859-1>", body: [0x80])).encoding == "windows-1252")
        #expect(Text.decode(document(meta: "<meta charset=iso-8859-1>", body: [0x80])).text.contains("\u{20AC}"))
    }

    @Test func ignoresOtherLabelsAndPragmaLessContent() {
        let body: [UInt8] = [0xE9]
        #expect(Text.decode(document(meta: "<meta charset=utf-7>", body: body)).encoding == "windows-1252")
        #expect(Text.decode(document(meta: "<meta charset=x-user-defined>", body: body)).encoding == "windows-1252")
        #expect(Text.decode(document(meta: "<meta charset=hz-gb-2312>", body: body)).encoding == "windows-1252")
        #expect(Text.decode(document(meta: "<meta charset=\"big\u{FF15}\">", body: body)).encoding == "windows-1252")
        #expect(Text.decode(document(meta: "<meta content='text/html; charset=big5'>", body: body)).encoding == "windows-1252")
        #expect(Text.decode(document(meta: "<meta charset=utf-16>", body: body)).encoding == "utf-8")
        #expect(Text.decode(document(meta: "<meta charset=UTF-16LE>", body: body)).text.contains("\u{FFFD}"))
        // Past the first 1024 bytes the meta is not seen.
        let late = Array(repeating: UInt8(ascii: " "), count: 1100)
        #expect(Text.decode(late + Array("<meta charset=big5>".utf8) + body).encoding == "windows-1252")
    }

    @Test func everyAllowListedEncodingIsAvailable() {
        #expect(Text.labels.count == 203) // change detector for the label table
        for (label, encoding) in Text.labels {
            if case .foundation(_, let cf) = encoding {
                #expect(CFStringIsEncodingAvailable(cf), "\(label)")
            }
        }
        #expect(Text.allowedEncoding(forLabel: Array("Windows-1252".utf8)) == .windows1252)
        #expect(Text.allowedEncoding(forLabel: Array("utf-8".utf8)) == nil)
        #expect(Text.allowedEncoding(forLabel: Array("utf-7".utf8)) == nil)
        #expect(Text.allowedEncoding(forLabel: Array("koi8-r\u{212A}".utf8)) == nil)
    }

    @Test func byteOrderMarksWin() {
        let meta = Array("<meta charset=big5>".utf8)
        let utf8 = Text.decode([0xEF, 0xBB, 0xBF] + meta + Array("é".utf8))
        #expect(utf8.encoding == "utf-8")
        #expect(utf8.text == "<meta charset=big5>é")
        let leBytes: [UInt8] = [0xFF, 0xFE] + "<meta charset=big5>é".utf16.flatMap { unit -> [UInt8] in [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        let le = Text.decode(leBytes)
        #expect(le.encoding == "utf-16le")
        #expect(le.text == "<meta charset=big5>é")
        let beBytes: [UInt8] = [0xFE, 0xFF] + "é中".utf16.flatMap { unit -> [UInt8] in [UInt8(unit >> 8), UInt8(unit & 0xFF)] } + [0x41]
        let be = Text.decode(beBytes)
        #expect(be.encoding == "utf-16be")
        #expect(be.text == "é中\u{FFFD}")
    }

    @Test func validUTF8BeatsAMetaCharset() {
        let decoded = Text.decode(Array("<meta charset=windows-1251><p>é</p>".utf8))
        #expect(decoded.encoding == "utf-8")
        #expect(decoded.text == "<meta charset=windows-1251><p>é</p>")
    }

    @Test func prepareDecodesBeforeRenamingAndScans() async throws {
        // In UTF-16 the tag bytes aren't ASCII-contiguous, so the rename must run on decoded text.
        let source = "<link rel=preconnect href=https://x><img src=https://x/a.png><p>é</p>"
        let bytes: [UInt8] = [0xFF, 0xFE] + source.utf16.flatMap { unit -> [UInt8] in [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        let prepared = try #require(await Text.prepare(Data(bytes)))
        #expect(prepared.encoding == "utf-16le")
        #expect(String(decoding: prepared.html, as: UTF8.self) == "<x-md-link rel=preconnect href=https://x><img src=https://x/a.png><p>é</p>")
        #expect(prepared.referencesRemoteContent)
        let local = try #require(await Text.prepare(Data("<img src=a.png>".utf8)))
        #expect(!local.referencesRemoteContent)
        #expect(await Text.prepare(Data(count: (16 << 20) + 1)) == nil)
    }
}
