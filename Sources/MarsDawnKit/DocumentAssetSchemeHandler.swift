import Foundation
import WebKit

/// Serves images referenced by a document (`![](img/a.png)`, `![](/abs/b.jpg)`) to the preview.
///
/// A request is served only if its lexically standardized path is inside the handler's
/// `scopeRoot` (the document's folder, or a granted folder containing it), has an image
/// extension from `ServedFileType`, and opens as a regular file through `ScopedFileReader`,
/// which never follows a symlink, even one inside the scope. The sandbox still decides whether
/// the file can actually be read. Files are mapped and read off the main thread.
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
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if let colon = trimmed.firstIndex(of: ":"),
           !trimmed[..<colon].contains(where: { "/?#".contains($0) }) {
            return nil  // has a scheme (https:, data:, …): leave it to the sanitizer
        }
        var path = trimmed
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[..<cut])
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

    /// The file a preview URL refers to, if it is an image inside `scopeRoot` that opens without
    /// following a symlink. The path is the lexical one; symlinks are never resolved.
    public nonisolated static func fileURL(for requestURL: URL, baseDirectory: URL?, scopeRoot: URL?) -> URL? {
        guard let target = resolve(requestURL, baseDirectory: baseDirectory, scopeRoot: scopeRoot),
              (try? ScopedFileReader.withDatalessFilesNotMaterialized({ () throws(ScopedFileReader.Failure) in
                  _ = try target.reader.open(components: target.components, maxSize: Int64(maximumFileSize))
              })) != nil
        else { return nil }
        return URL(fileURLWithPath: target.path)
    }

    /// Maps a preview URL to its lexical absolute path and the reader and components that open it.
    nonisolated static func resolve(_ requestURL: URL, baseDirectory: URL?, scopeRoot: URL?) -> (reader: ScopedFileReader, components: [String], path: String)? {
        guard requestURL.scheme == scheme else { return nil }
        let path = requestURL.path  // percent-decoded
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let file: String
        switch requestURL.host {
        case relativeHost:
            guard let baseDirectory else { return nil }
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            file = baseDirectory.appendingPathComponent(relative).standardizedFileURL.path
        case absoluteHost:
            file = URL(fileURLWithPath: path).standardizedFileURL.path
        default:
            return nil
        }
        // Only the final path is checked, against both spellings of the root.
        guard let root = scopeRoot ?? baseDirectory,
              let reader = try? ScopedFileReader(root: root),
              let components = reader.components(forAbsolutePath: file),
              let name = components.last,
              ServedFileType.entry(forFileName: name)?.kind == .image
        else { return nil }
        return (reader, components, file)
    }

    /// Reads the image a preview URL refers to, with its MIME type. Fails with
    /// `noPermissionsToReadFile` if the URL isn't an image in the scope, and with
    /// `fileDoesNotExist` if the file can't be read (missing, a symlink, not regular, too large).
    nonisolated static func loadImage(for requestURL: URL, baseDirectory: URL?, scopeRoot: URL?) -> Result<(data: Data, mimeType: String), URLError> {
        guard let target = resolve(requestURL, baseDirectory: baseDirectory, scopeRoot: scopeRoot),
              let name = target.components.last,
              let type = ServedFileType.entry(forFileName: name)
        else { return .failure(URLError(.noPermissionsToReadFile)) }
        guard let data = try? ScopedFileReader.withDatalessFilesNotMaterialized({ () throws(ScopedFileReader.Failure) -> Data in
            try target.reader.open(components: target.components, maxSize: Int64(maximumFileSize)).readAll()
        }) else { return .failure(URLError(.fileDoesNotExist)) }
        return .success((data, type.mimeType))
    }

    /// Reads a regular file within the size limit, confined to its own folder (no symlinks).
    nonisolated static func readImage(at file: URL) -> Data? {
        guard let reader = try? ScopedFileReader(root: file.deletingLastPathComponent()) else { return nil }
        return try? reader.readFile(atPath: file.standardizedFileURL.path, maxSize: Int64(maximumFileSize))
    }

    // MARK: WKURLSchemeHandler

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url, requestURL.scheme == Self.scheme else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        activeTasks[id] = urlSchemeTask
        let baseDirectory = baseDirectory
        let scopeRoot = scopeRoot
        readQueue.async { [weak self] in
            let image = Self.loadImage(for: requestURL, baseDirectory: baseDirectory, scopeRoot: scopeRoot)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let task = self?.activeTasks.removeValue(forKey: id) else { return }
                    Self.respond(to: task, url: requestURL, image: image)
                }
            }
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        activeTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
    }

    private static func respond(to task: any WKURLSchemeTask, url: URL, image: Result<(data: Data, mimeType: String), URLError>) {
        let data: Data, mimeType: String
        switch image {
        case .success(let image):
            (data, mimeType) = image
        case .failure(let error):
            task.didFailWithError(error)
            return
        }
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
