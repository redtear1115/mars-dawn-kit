import Foundation

/// HackMD's embed tags, `{%youtube id %}` and the like, as plain links (#134).
///
/// Nothing is embedded: no iframe, no request, so the preview's content security policy and
/// privacy stay as they are. A tag on its own line becomes a link to the canonical https URL
/// of what it names, with a short label. A tag this does not know, one whose argument is not
/// valid for its service, and any URL that is not https (or not on the service's own host)
/// stays as the text the author wrote.
///
/// Every character of the output is checked or escaped: ids come from a strict character set,
/// URLs must be printable ASCII without markup characters, and `escapeAttribute` and
/// `escapeHTML` are applied to what is written.
enum HackMDEmbeds {
    /// The links for a paragraph's lines, joined by `<br>`, when every line is a valid embed
    /// tag; `nil` otherwise, so a paragraph that is only partly embeds is left as it is.
    static func html(forLines lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }
        var links: [String] = []
        for line in lines {
            guard let link = link(forLine: line) else { return nil }
            links.append(link)
        }
        return links.joined(separator: "<br>\n")
    }

    private static func link(forLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{%"), trimmed.hasSuffix("%}") else { return nil }
        let words = trimmed.dropFirst(2).dropLast(2).split(whereSeparator: \.isWhitespace)
        guard words.count == 2 else { return nil }
        let argument = String(words[1])
        let target: (label: String, url: String)?
        switch words[0].lowercased() {
        case "youtube": target = youtube(argument)
        case "vimeo": target = vimeo(argument)
        case "gist": target = gist(argument)
        case "slideshare": target = hosted(argument, service: "SlideShare", hosts: ["slideshare.net"])
        case "speakerdeck": target = hosted(argument, service: "Speaker Deck", hosts: ["speakerdeck.com"])
        case "pdf": target = hosted(argument, service: "PDF", hosts: nil)
        default: target = nil
        }
        guard let target, sanitizedURL(target.url, allowData: false) == target.url else { return nil }
        return "<a href=\"\(escapeAttribute(target.url))\">\(escapeHTML(target.label))</a>"
    }

    // MARK: Services

    private static func youtube(_ argument: String) -> (String, String)? {
        var id = argument
        if argument.contains("/") {
            guard let url = httpsURL(argument, hosts: ["youtube.com", "youtu.be"]) else { return nil }
            if url.host == "youtu.be" {
                id = url.path.split(separator: "/").first.map(String.init) ?? ""
            } else {
                id = url.queryItems?.first { $0.name == "v" }?.value ?? ""
            }
        }
        guard id.utf8.count == 11, id.utf8.allSatisfy(isIDByte) else { return nil }
        return ("YouTube: \(id)", "https://www.youtube.com/watch?v=\(id)")
    }

    private static func vimeo(_ argument: String) -> (String, String)? {
        var id = argument
        if argument.contains("/") {
            guard let url = httpsURL(argument, hosts: ["vimeo.com"]) else { return nil }
            id = url.path.split(separator: "/").last.map(String.init) ?? ""
        }
        guard (1...12).contains(id.utf8.count), id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return ("Vimeo: \(id)", "https://vimeo.com/\(id)")
    }

    /// `hash`, `user/hash` or a gist.github.com URL.
    private static func gist(_ argument: String) -> (String, String)? {
        var path = argument
        if argument.hasPrefix("https://") || argument.hasPrefix("http") {
            guard let url = httpsURL(argument, hosts: ["gist.github.com"]) else { return nil }
            path = url.path.split(separator: "/").joined(separator: "/")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let hash = parts.last, (1...64).contains(hash.utf8.count), hash.utf8.allSatisfy(isHexByte) else { return nil }
        switch parts.count {
        case 1: return ("Gist: \(hash)", "https://gist.github.com/\(hash)")
        case 2:
            let user = parts[0]
            guard (1...39).contains(user.utf8.count), user.utf8.allSatisfy({ isIDByte($0) && $0 != UInt8(ascii: "_") }) else { return nil }
            return ("Gist: \(user)/\(hash)", "https://gist.github.com/\(user)/\(hash)")
        default: return nil
        }
    }

    /// A service that is given as a URL: the https URL as written, on the service's host (`nil`
    /// allows any), labelled with where it points.
    private static func hosted(_ argument: String, service: String, hosts: [String]?) -> (String, String)? {
        guard let url = httpsURL(argument, hosts: hosts), let host = url.host else { return nil }
        var shown = host + (url.path == "/" ? "" : url.path)
        if shown.count > 60 { shown = String(shown.prefix(59)) + "…" }
        return ("\(service): \(shown)", argument)
    }

    // MARK: Validation

    /// The URL's parts when `text` is an https URL with a host (one of `hosts` or a subdomain
    /// of one, when given), no credentials or port, and nothing but printable ASCII that cannot
    /// open markup. `nil` otherwise.
    private static func httpsURL(_ text: String, hosts: [String]?) -> (host: String?, path: String, queryItems: [URLQueryItem]?)? {
        guard (1...2_000).contains(text.utf8.count),
              text.utf8.allSatisfy({ (0x21...0x7E).contains($0) && !"<>\"'`\\{}|^".utf8.contains($0) }),
              text.lowercased().hasPrefix("https://"),
              let components = URLComponents(string: text), components.scheme?.lowercased() == "https",
              components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(), !host.isEmpty,
              host.utf8.allSatisfy({ isIDByte($0) && $0 != UInt8(ascii: "_") || $0 == UInt8(ascii: ".") }) else { return nil }
        if let hosts, !hosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return nil }
        return (host, components.path, components.queryItems)
    }

    /// Letters, digits, `-` and `_`.
    private static func isIDByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
    }

    private static func isHexByte(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}
