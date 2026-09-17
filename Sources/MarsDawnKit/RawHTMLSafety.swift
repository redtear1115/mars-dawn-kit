import Foundation

/// Tags that raw HTML may not create for real; they are renamed with an `x-md-` prefix.
///
/// - `link`: `rel=dns-prefetch` or `rel=preconnect` opens a connection that the page's CSP
///   doesn't stop.
/// - `iframe`, `frame`, `object`, `embed`, `portal`, `fencedframe`: they create nested documents
///   (an `<iframe srcdoc>` can hold an entity-encoded `<link>` that this rename can't see).
///
/// The content rule lists block these connections too; this is a second layer.
let neutralizedRawHTMLTags = ["link", "iframe", "frame", "object", "embed", "portal", "fencedframe"]

/// Renames the start and end tags in `neutralizedRawHTMLTags` in raw HTML, e.g. `<iframe` to
/// `<x-md-iframe` and `</LINK` to `</x-md-link`.
///
/// The match is on the tag name as the HTML tokenizer ends it (whitespace, `/` or `>`), in any
/// case, so longer names such as `<frameset>` or `<objective>` are left alone. Attributes are not
/// parsed and other HTML is left alone. (The name predates the tags other than `link`.)
func neutralizingLinkTags(_ html: String) -> String {
    guard neutralizedTagHints.contains(where: { html.range(of: $0, options: .caseInsensitive) != nil }) else {
        return html
    }
    let source = html as NSString
    var result = ""
    var copied = 0
    for match in neutralizedTagPattern.matches(in: html, range: NSRange(location: 0, length: source.length)) {
        let slash = source.substring(with: match.range(at: 1))
        let name = source.substring(with: match.range(at: 2)).lowercased()
        result += source.substring(with: NSRange(location: copied, length: match.range.location - copied))
        result += "<\(slash)x-md-\(name)"
        copied = match.range.location + match.range.length
    }
    result += source.substring(from: copied)
    return result
}

/// Every neutralized tag name contains one of these, for a quick skip.
private let neutralizedTagHints = ["link", "frame", "object", "embed", "portal"]

// Tag names end at tab, line feed, form feed, carriage return (normalised to a line feed), space, '/' or '>'.
private let neutralizedTagPattern = try! NSRegularExpression(
    pattern: #"<(/?)("# + neutralizedRawHTMLTags.joined(separator: "|") + #")(?=[\t\n\f\r />])"#,
    options: [.caseInsensitive]
)
