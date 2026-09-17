import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves images referenced by a document (`![](img/a.png)`, `![](/abs/b.jpg)`) to the preview.
///
/// A request is served only if, after resolving symlinks, it names a regular image file inside
/// the handler's `scopeRoot` (the document's folder, or a granted folder containing it). The
/// sandbox still decides whether the file can actually be read. Files are read off the main thread.
public final class DocumentAssetSchemeHandler: NSObject, WKURLSchemeHandler {
    public nonisolated static let scheme = "marsdawn-asset"
    nonisolated static let relativeHost = "doc"
    nonisolated static let absoluteHost = "abs"
    nonisolated static let maximumFileSize = 32 * 1024 * 1024

    /// Folder that relative image paths resolve against — the document's directory.
    public var baseDirectory: URL?
    /// Only files under this folder are served. Defaults to `baseDirectory` when nil.
    public var scopeRoot: URL?

    /// Requests in flight; a stopped request is removed and must not be answered.
    private var activeTasks: [ObjectIdentifier: any WKURLSchemeTask] = [:]
    private let readQueue = DispatchQueue(label: "dev.southern-light.marsdawn.assets", qos: .userInitiated, attributes: .concurrent)

    override public init() {}

    // MARK: Mapping image sources

    /// The preview URL for an image source as written in Markdown, or nil to leave it untouched.
    /// Relative paths need a saved document (`hasBaseDirectory`) to resolve.
    public nonisolated static func previewURL(forImageSource source: String, hasBaseDirectory: Bool) -> String? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // Scalars, not Characters, so a combining mark can't hide a ':', '?' or '#' (and so this
        // agrees with `sanitizedURL` about what has a scheme).
        let scalars = trimmed.unicodeScalars
        guard let first = scalars.first, first != "#" else { return nil }
        if let colon = scalars.firstIndex(of: ":"),
           !scalars[..<colon].contains(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            return nil  // has a scheme (https:, data:, …): leave it to the sanitizer
        }
        var path = trimmed
        if let cut = scalars.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(scalars[..<cut])
        }
        path = path.removingPercentEncoding ?? path

        let host: String
        if path.hasPrefix("/") {
            host = absoluteHost
            path.removeFirst()
        } else {
            guard hasBaseDirectory else { return nil }
            host = relativeHost
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "\(scheme)://\(host)/\(encoded)"
    }

    /// The file a preview URL refers to, if it resolves (symlinks included) to an image inside `scopeRoot`.
    public nonisolated static func fileURL(for requestURL: URL, baseDirectory: URL?, scopeRoot: URL?) -> URL? {
        guard requestURL.scheme == scheme else { return nil }
        let path = requestURL.path  // percent-decoded
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let file: URL
        switch requestURL.host {
        case relativeHost:
            guard let baseDirectory else { return nil }
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            file = baseDirectory.appendingPathComponent(relative)
        case absoluteHost:
            file = URL(fileURLWithPath: path)
        default:
            return nil
        }
        guard let root = scopeRoot ?? baseDirectory else { return nil }

        // Check the file that will actually be read, not the name that was asked for.
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { return nil }
        guard let type = UTType(filenameExtension: resolved.pathExtension), type.conforms(to: .image) else {
            return nil
        }
        return resolved
    }

    /// Reads an image file if it is a regular file of known size within the limit.
    nonisolated static func readImage(at file: URL) -> Data? {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= maximumFileSize,
              let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }
        // A plain read, not a memory map: a file truncated mid-read must not crash the app.
        return try? handle.readToEnd()
    }

    // MARK: WKURLSchemeHandler

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url,
              let file = Self.fileURL(for: requestURL, baseDirectory: baseDirectory, scopeRoot: scopeRoot)
        else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        activeTasks[id] = urlSchemeTask
        readQueue.async { [weak self] in
            let data = Self.readImage(at: file)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let task = self?.activeTasks.removeValue(forKey: id) else { return }
                    Self.respond(to: task, url: requestURL, file: file, data: data)
                }
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        activeTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
    }

    private static func respond(to task: any WKURLSchemeTask, url: URL, file: URL, data: Data?) {
        guard let data else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mimeType,
                "Content-Length": "\(data.count)",
                "Cache-Control": "no-cache",
                "X-Content-Type-Options": "nosniff",
            ]
        ) else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
}
