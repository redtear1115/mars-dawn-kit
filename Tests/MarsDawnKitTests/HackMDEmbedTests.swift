import Testing
@testable import MarsDawnKit

/// HackMD's `{%youtube id %}` family, as plain https links (#134).
struct HackMDEmbedTests {
    private func render(_ markdown: String) -> String {
        MarkdownRenderer.render(markdown)
    }

    private func paragraph(_ link: String) -> String {
        "<p data-line=\"1\">\(link)</p>\n"
    }

    @Test func youtube() {
        let expected = paragraph(#"<a href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">YouTube: dQw4w9WgXcQ</a>"#)
        #expect(render("{%youtube dQw4w9WgXcQ %}\n") == expected)
        #expect(render("{%youtube https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=5 %}\n") == expected)
        #expect(render("{%youtube https://youtu.be/dQw4w9WgXcQ %}\n") == expected)
        #expect(render("{%YouTube dQw4w9WgXcQ%}\n") == expected)
    }

    @Test func vimeo() {
        let expected = paragraph(#"<a href="https://vimeo.com/123456">Vimeo: 123456</a>"#)
        #expect(render("{%vimeo 123456 %}\n") == expected)
        #expect(render("{%vimeo https://vimeo.com/123456 %}\n") == expected)
    }

    @Test func gist() {
        #expect(render("{%gist ab12cd34 %}\n") == paragraph(#"<a href="https://gist.github.com/ab12cd34">Gist: ab12cd34</a>"#))
        #expect(render("{%gist octocat/ab12cd34 %}\n") == paragraph(#"<a href="https://gist.github.com/octocat/ab12cd34">Gist: octocat/ab12cd34</a>"#))
        #expect(render("{%gist https://gist.github.com/octocat/ab12cd34 %}\n") == paragraph(#"<a href="https://gist.github.com/octocat/ab12cd34">Gist: octocat/ab12cd34</a>"#))
    }

    @Test func urlServices() {
        #expect(render("{%slideshare https://www.slideshare.net/u/deck %}\n")
            == paragraph(#"<a href="https://www.slideshare.net/u/deck">SlideShare: www.slideshare.net/u/deck</a>"#))
        #expect(render("{%speakerdeck https://speakerdeck.com/u/deck %}\n")
            == paragraph(#"<a href="https://speakerdeck.com/u/deck">Speaker Deck: speakerdeck.com/u/deck</a>"#))
        #expect(render("{%pdf https://example.com/a/b.pdf %}\n")
            == paragraph(#"<a href="https://example.com/a/b.pdf">PDF: example.com/a/b.pdf</a>"#))
    }

    @Test func linesInOneParagraphAreAllLinks() {
        let html = render("{%vimeo 1 %}\n{%vimeo 2 %}\n")
        #expect(html.contains(#"<a href="https://vimeo.com/1">Vimeo: 1</a><br>"#))
        #expect(html.contains(#"<a href="https://vimeo.com/2">Vimeo: 2</a></p>"#))
    }

    @Test func unknownAndInvalidTagsStayLiteral() {
        let sources = [
            "{%foo bar %}", "{%youtube %}", "{%youtube a b %}", "{%youtube short %}", "{%youtube a\"b %}",
            "{%vimeo abc %}", "{%gist zz %}", "{%gist a/b/c %}",
            "{%pdf javascript:alert(1) %}", "{%pdf http://example.com/a.pdf %}", "{%pdf data:text/html,x %}",
            "{%pdf https://user:pw@example.com/a.pdf %}", "{%pdf https://example.com:8080/a.pdf %}",
            "{%pdf https://example.com/a\".pdf %}", "{%pdf https://exa<mple.com/a.pdf %}",
            "{%slideshare https://evil.example/u/deck %}", "{%speakerdeck https://speakerdeck.com.evil.example/x %}",
            "{%youtube https://evil.example/watch?v=dQw4w9WgXcQ %}", "{%vimeo http://vimeo.com/1 %}",
            "text {%vimeo 1 %}", "{%vimeo 1 %} text", "{%vimeo 1 %}\nother line",
        ]
        for source in sources {
            let html = render(source + "\n")
            #expect(!html.contains("<a "), "\(source)")
        }
        #expect(render("{%foo bar %}\n").contains("{%foo bar %}"))
    }

    @Test func insideCodeIsUntouched() {
        #expect(render("`{%vimeo 1 %}`\n").contains("<code>{%vimeo 1 %}</code>"))
        #expect(render("```\n{%vimeo 1 %}\n```\n").contains("{%vimeo 1 %}\n</code>"))
        #expect(!render("    {%vimeo 1 %}\n").contains("<a "))
    }

    @Test func worksInListsAndQuotes() {
        #expect(render("- {%vimeo 1 %}\n").contains(#"<li data-line="1"><a href="https://vimeo.com/1">Vimeo: 1</a>"#))
        #expect(render("> {%vimeo 1 %}\n").contains(#"<a href="https://vimeo.com/1">"#))
    }
}
