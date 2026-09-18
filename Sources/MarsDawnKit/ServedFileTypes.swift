import Foundation

/// The only file types the document scheme handlers serve, by explicit extension.
///
/// UTType is never consulted. The extension is the text after the last `.` of the file name
/// (a leading `.` doesn't count), must be ASCII, and is compared after ASCII lowercasing.
/// Anything not listed (html, xhtml, js, mjs, json, xml, pdf, m3u8, m3u, …) is never served.
enum ServedFileType {
    enum Kind: Sendable, Equatable {
        case image, style, font, media, textTrack
    }

    struct Entry: Sendable, Equatable {
        let mimeType: String
        let kind: Kind
    }

    static let table: [String: Entry] = [
        "png": Entry(mimeType: "image/png", kind: .image),
        "jpg": Entry(mimeType: "image/jpeg", kind: .image),
        "jpeg": Entry(mimeType: "image/jpeg", kind: .image),
        "gif": Entry(mimeType: "image/gif", kind: .image),
        "webp": Entry(mimeType: "image/webp", kind: .image),
        "avif": Entry(mimeType: "image/avif", kind: .image),
        "heic": Entry(mimeType: "image/heic", kind: .image),
        "heif": Entry(mimeType: "image/heif", kind: .image),
        "bmp": Entry(mimeType: "image/bmp", kind: .image),
        "ico": Entry(mimeType: "image/x-icon", kind: .image),
        "svg": Entry(mimeType: "image/svg+xml", kind: .image),
        "css": Entry(mimeType: "text/css", kind: .style),
        "woff": Entry(mimeType: "font/woff", kind: .font),
        "woff2": Entry(mimeType: "font/woff2", kind: .font),
        "ttf": Entry(mimeType: "font/ttf", kind: .font),
        "otf": Entry(mimeType: "font/otf", kind: .font),
        "mp4": Entry(mimeType: "video/mp4", kind: .media),
        "m4v": Entry(mimeType: "video/x-m4v", kind: .media),
        "mov": Entry(mimeType: "video/quicktime", kind: .media),
        "webm": Entry(mimeType: "video/webm", kind: .media),
        "mp3": Entry(mimeType: "audio/mpeg", kind: .media),
        "m4a": Entry(mimeType: "audio/mp4", kind: .media),
        "aac": Entry(mimeType: "audio/aac", kind: .media),
        "wav": Entry(mimeType: "audio/wav", kind: .media),
        "ogg": Entry(mimeType: "audio/ogg", kind: .media),
        "oga": Entry(mimeType: "audio/ogg", kind: .media),
        "opus": Entry(mimeType: "audio/ogg", kind: .media),
        "flac": Entry(mimeType: "audio/flac", kind: .media),
        "vtt": Entry(mimeType: "text/vtt", kind: .textTrack),
    ]

    /// The entry for a file name, or nil if its type is not served.
    static func entry(forFileName name: String) -> Entry? {
        let bytes = Array(name.utf8)
        guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0 else { return nil }
        var ext: [UInt8] = []
        for byte in bytes[(dot + 1)...] {
            guard byte < 0x80 else { return nil }
            ext.append((0x41...0x5A).contains(byte) ? byte + 0x20 : byte)
        }
        guard !ext.isEmpty else { return nil }
        return table[String(decoding: ext, as: UTF8.self)]
    }
}
