import Foundation

/// Renames `<link` and `</link` tags in raw HTML to `<x-md-link` and `</x-md-link`.
///
/// A `<link rel=dns-prefetch>` or `rel=preconnect` opens a connection that neither the page's
/// CSP nor the content rule lists stop, so raw HTML never gets a real `link` element. The match
/// is on the tag name as the HTML tokenizer ends it (whitespace, `/` or `>`), in any case;
/// attributes are not parsed and other HTML is left alone.
func neutralizingLinkTags(_ html: String) -> String {
    guard html.range(of: "link", options: .caseInsensitive) != nil else { return html }
    let range = NSRange(html.startIndex..., in: html)
    return linkTagPattern.stringByReplacingMatches(in: html, range: range, withTemplate: "<$1x-md-link")
}

// Tag names end at tab, line feed, form feed, carriage return (normalised to a line feed), space, '/' or '>'.
private let linkTagPattern = try! NSRegularExpression(
    pattern: #"<(/?)link(?=[\t\n\f\r />])"#,
    options: [.caseInsensitive]
)
