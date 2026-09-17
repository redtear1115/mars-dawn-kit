#if canImport(Darwin)
import Foundation
import OSLog
import Security
import WebKit

/// Serves one local HTML document, read-only, and the files it references from its scope.
///
/// Create one handler per web view and load only the URL `beginLoad` returns (never
/// `loadFileURL`, `loadHTMLString` or data loads).
///
/// - **Page URL:** `marsdawn-html://<token>/` + one `%2F` segment per folder between the scope
///   root and the document + `index.html`. It holds no file or folder names. The token is new
///   for every load; requests carrying an older token fail.
/// - **Page:** served from memory, only at its exact path, once per token.
/// - **Subresources:** only the types in `ServedFileType`, read through `ScopedFileReader`
///   (no symlinks), with per-file size caps, per-load request and byte budgets, and a bounded
///   read queue. Media is served in ranges of at most 8 MB.
/// - **Headers:** every response carries a CSP, `nosniff`, `no-referrer`, `no-store` and
///   `X-DNS-Prefetch-Control: off`.
@MainActor
public final class HTMLDocumentSchemeHandler: NSObject, WKURLSchemeHandler {
    public nonisolated static let scheme = "marsdawn-html"
    /// Stands for one real folder in page URLs. An encoded `/` can't be part of a file name.
    nonisolated static let placeholderSegment = "%2F"
    nonisolated static let pageName = "index.html"

    public enum LoadError: Error, Sendable {
        /// The document is over the size cap.
        case tooLarge
        /// The document isn't inside the scope root.
        case outsideScope
        /// The scope root can't be used.
        case scopeUnavailable
        /// No random token could be made.
        case randomUnavailable
    }

    struct Limits: Sendable {
        var documentBytes = 16 << 20
        var requestsPerLoad = 2_000
        var bytesPerLoad: Int64 = 512 << 20
        var concurrentReads = 6
        var queuedReads = 256
        /// Images, style sheets, fonts and text tracks.
        var fileBytes: Int64 = 32 << 20
        var mediaFileBytes: Int64 = 2 << 30
        /// The largest media response, ranged or whole.
        var mediaChunkBytes: Int64 = 8 << 20
    }

    // MARK: Content-Security-Policy

    nonisolated static let blockedCSP = "default-src 'none'; img-src marsdawn-html: data:; style-src marsdawn-html: 'unsafe-inline'; font-src marsdawn-html: data:; media-src marsdawn-html:; script-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; connect-src 'none'; manifest-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"
    nonisolated static let remoteAllowedCSP = "default-src 'none'; img-src marsdawn-html: data: https:; style-src marsdawn-html: 'unsafe-inline' https:; font-src marsdawn-html: data: https:; media-src marsdawn-html: https:; script-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; connect-src 'none'; manifest-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"

    /// P3-9: `sandbox` directive added to the page's CSP (nil: none). Not adopted: WebKit then
    /// refuses the app's own script in the page, which the media checks need.
    nonisolated static let documentSandboxDirective: String? = nil
    /// P3-9: whether the remote-allowed page CSP adds `upgrade-insecure-requests`. Adopted: http
    /// images, styles, fonts and media are fetched over https instead of being blocked.
    nonisolated static let upgradesInsecureRequests = true

    /// The CSP header for the page.
    nonisolated static func documentCSP(allowsRemoteContent: Bool) -> String {
        var policy = allowsRemoteContent ? remoteAllowedCSP : blockedCSP
        if allowsRemoteContent, upgradesInsecureRequests { policy += "; upgrade-insecure-requests" }
        if let documentSandboxDirective { policy += "; \(documentSandboxDirective)" }
        return policy
    }

    /// The CSP header for every subresource (an SVG or CSS file is never a live document).
    nonisolated static let subresourceCSP = blockedCSP + "; sandbox"

    // MARK: State

    private static let log = Logger(subsystem: "dev.southern-light.marsdawn", category: "HTMLDocument")

    /// One `beginLoad`: its token, scope and budgets.
    @MainActor
    final class Session {
        let token: String
        let reader: ScopedFileReader
        /// The folders from the scope root to the document's folder.
        let ancestors: [String]
        let document: Data
        let allowsRemoteContent: Bool
        var pageServed = false
        var requestCount = 0
        var bytesServed: Int64 = 0
        var loggedExhaustion = false

        init(token: String, reader: ScopedFileReader, ancestors: [String], document: Data, allowsRemoteContent: Bool) {
            self.token = token
            self.reader = reader
            self.ancestors = ancestors
            self.document = document
            self.allowsRemoteContent = allowsRemoteContent
        }
    }

    private struct QueuedRead {
        let id: ObjectIdentifier
        let start: () -> Void
    }

    let limits: Limits
    private var session: Session?
    /// Requests being read or waiting to be; a stopped request is removed and never answered.
    private var activeTasks: [ObjectIdentifier: any WKURLSchemeTask] = [:]
    private var waitingReads: [QueuedRead] = []
    private var runningReads = 0
    private let readQueue = DispatchQueue(label: "dev.southern-light.marsdawn.html-document", qos: .userInitiated, attributes: .concurrent)

    /// What happened to a request, for the test-only request log.
    enum LogOutcome: Equatable, Sendable {
        case page, served(status: Int, bytes: Int), refused(String), failed(ScopedFileReader.Failure)
    }

    struct LogEntry: Equatable, Sendable {
        let components: [String]?
        let outcome: LogOutcome
    }

    #if DEBUG
    /// Test-only record of each request: its components below the scope root (never full
    /// paths) and what happened to it.
    private(set) var requestLog: [LogEntry] = []
    /// Components of each read as it starts.
    private(set) var readLog: [[String]] = []
    #endif

    override public convenience init() {
        self.init(limits: Limits())
    }

    init(limits: Limits) {
        self.limits = limits
    }

    // MARK: Loading

    /// Starts a new load and returns the URL to load. Requests for any earlier load fail from now on.
    ///
    /// - Parameters:
    ///   - document: The page, already prepared (see `HTMLDocumentText`), at most 16 MB.
    ///   - documentURL: The document's file, which must be inside `scopeRoot`.
    ///   - scopeRoot: The folder whose files the page may use (the document's folder or a granted one).
    ///   - allowsRemoteContent: Whether the page's CSP allows https images, styles, fonts and media.
    public func beginLoad(document: Data, documentURL: URL, scopeRoot: URL, allowsRemoteContent: Bool) throws -> URL {
        session = nil
        guard document.count <= limits.documentBytes else { throw LoadError.tooLarge }
        guard documentURL.isFileURL else { throw LoadError.outsideScope }
        let reader: ScopedFileReader
        do {
            reader = try ScopedFileReader(root: scopeRoot)
        } catch {
            throw LoadError.scopeUnavailable
        }
        guard let components = reader.components(forAbsolutePath: documentURL.standardizedFileURL.path),
              !components.isEmpty
        else { throw LoadError.outsideScope }
        let token = try Self.makeToken()
        let ancestors = Array(components.dropLast())
        session = Session(token: token, reader: reader, ancestors: ancestors, document: document,
                          allowsRemoteContent: allowsRemoteContent)
        let path = String(repeating: Self.placeholderSegment + "/", count: ancestors.count) + Self.pageName
        return URL(string: "\(Self.scheme)://\(token)/\(path)")!
    }

    /// 32 lowercase hex characters from the system's secure random generator.
    private static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LoadError.randomUnavailable
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Mapping requests

    enum Mapping: Equatable, Sendable {
        case page
        case subresource([String])
        case refused(String)
    }

    /// Maps a raw (percent-encoded) request path for a page `ancestors.count` folders below the root.
    ///
    /// The leading run of up to `ancestors.count` `%2F` segments stands for those folders. Every
    /// other segment is percent-decoded on its own and must be a valid component; a `%2F` there,
    /// or anything else that decodes to a `/`, is refused.
    nonisolated static func map(rawPath: String, ancestors: [String]) -> Mapping {
        let bytes = Array(rawPath.utf8)
        guard bytes.first == UInt8(ascii: "/") else { return .refused("relative path") }
        let segments = bytes.dropFirst().split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        guard !segments.contains(where: \.isEmpty) else { return .refused("empty segment") }
        let placeholder = Array(placeholderSegment.utf8)

        let depth = ancestors.count
        if segments.count == depth + 1,
           segments.dropLast().allSatisfy({ $0.elementsEqual(placeholder) }),
           segments[segments.count - 1].elementsEqual(pageName.utf8) {
            return .page
        }

        var leading = 0
        while leading < depth, leading < segments.count, segments[leading].elementsEqual(placeholder) {
            leading += 1
        }
        let rest = segments[leading...]
        guard !rest.isEmpty else { return .refused("folder") }
        var components = Array(ancestors[..<leading])
        for segment in rest {
            guard !segment.elementsEqual(placeholder) else { return .refused("placeholder out of place") }
            guard let decoded = percentDecoded(Array(segment)),
                  let component = ScopedFileReader.validUTF8(decoded),
                  ScopedFileReader.isValidComponent(component)
            else { return .refused("invalid segment") }
            components.append(component)
        }
        return .subresource(components)
    }

    /// Strict percent-decoding: every `%` must start a two-digit hex escape.
    nonisolated static func percentDecoded(_ bytes: [UInt8]) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%") {
                guard index + 2 < bytes.count, let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) else {
                    return nil
                }
                output.append(high << 4 | low)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    private nonisolated static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    // MARK: Ranges

    enum RangeRequest: Equatable, Sendable {
        /// `bytes=a-` or `bytes=a-b`.
        case from(Int64, through: Int64?)
        /// `bytes=-n`.
        case suffix(Int64)
    }

    /// Parses a `Range` header: `bytes=` then `a-b`, `a-` or `-n`, ASCII digits only, at most 18
    /// of them per number, one range, no spaces. Nil if the header doesn't match.
    nonisolated static func parseRange(_ header: String) -> RangeRequest? {
        let bytes = Array(header.utf8)
        let prefix = Array("bytes=".utf8)
        guard bytes.starts(with: prefix) else { return nil }
        let spec = bytes[prefix.count...]
        guard let dash = spec.firstIndex(of: UInt8(ascii: "-")) else { return nil }
        let first = spec[..<dash]
        let second = spec[(dash + 1)...]
        func number(_ digits: ArraySlice<UInt8>) -> Int64? {
            guard !digits.isEmpty, digits.count <= 18,
                  digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
            else { return nil }
            return digits.reduce(Int64(0)) { $0 * 10 + Int64($1 - UInt8(ascii: "0")) }
        }
        if first.isEmpty {
            guard let count = number(second) else { return nil }
            return .suffix(count)
        }
        guard let start = number(first) else { return nil }
        if second.isEmpty { return .from(start, through: nil) }
        guard let end = number(second) else { return nil }
        return .from(start, through: end)
    }

    /// The inclusive byte range to send for a request on a file of `size` bytes, at most
    /// `chunk` bytes long, or nil if it can't be satisfied (416).
    nonisolated static func resolve(_ request: RangeRequest, size: Int64, chunk: Int64) -> ClosedRange<Int64>? {
        guard size > 0, chunk > 0 else { return nil }
        let start: Int64
        var end = size - 1
        switch request {
        case .from(let first, let last):
            guard first < size else { return nil }
            if let last {
                guard first <= last else { return nil }
                end = min(end, last)
            }
            start = first
        case .suffix(let count):
            guard count > 0 else { return nil }
            start = count >= size ? 0 : size - count
        }
        // start < size, so size - start can't overflow and is at least 1.
        end = min(end, start + min(chunk, size - start) - 1)
        return start...end
    }

    // MARK: WKURLSchemeHandler

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let request = urlSchemeTask.request
        guard let session, let url = request.url, url.scheme == Self.scheme,
              let host = url.host(percentEncoded: true), host.utf8.elementsEqual(session.token.utf8)
        else {
            refuse(urlSchemeTask, components: nil, reason: "unknown load")
            return
        }
        let mapping = Self.map(rawPath: url.path(percentEncoded: true), ancestors: session.ancestors)
        if mapping == .page {
            guard url.query(percentEncoded: true) == nil else {
                refuse(urlSchemeTask, components: nil, reason: "query on page")
                return
            }
            guard !session.pageServed else {
                refuse(urlSchemeTask, components: nil, reason: "page already served")
                return
            }
            session.pageServed = true
            let headers = Self.headers(
                contentType: "text/html; charset=utf-8", length: session.document.count,
                csp: Self.documentCSP(allowsRemoteContent: session.allowsRemoteContent)
            )
            respond(urlSchemeTask, status: 200, headers: headers, body: session.document)
            record(nil, .page)
            return
        }

        session.requestCount += 1
        guard session.requestCount <= limits.requestsPerLoad, session.bytesServed < limits.bytesPerLoad else {
            logExhaustion(session)
            refuse(urlSchemeTask, components: nil, reason: "budget")
            return
        }
        guard case .subresource(let components) = mapping else {
            if case .refused(let reason) = mapping { refuse(urlSchemeTask, components: nil, reason: reason) }
            return
        }
        guard let name = components.last, let type = ServedFileType.entry(forFileName: name) else {
            refuse(urlSchemeTask, components: components, reason: "type")
            return
        }

        let id = ObjectIdentifier(urlSchemeTask)
        activeTasks[id] = urlSchemeTask
        let reader = session.reader
        let limits = limits
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        let work = QueuedRead(id: id) { [weak self] in
            self?.readQueue.async { [weak self] in
                let result = Self.read(components: components, type: type, rangeHeader: rangeHeader, reader: reader, limits: limits)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.finishRead(id: id, session: session, components: components, type: type, result: result)
                    }
                }
            }
        }
        if runningReads < limits.concurrentReads {
            startRead(work, components: components)
        } else if waitingReads.count < limits.queuedReads {
            waitingReads.append(QueuedRead(id: id) { [weak self] in
                self?.startRead(work, components: components)
            })
        } else {
            activeTasks[id] = nil
            refuse(urlSchemeTask, components: components, reason: "queue full")
        }
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        activeTasks[id] = nil
        waitingReads.removeAll { $0.id == id }
    }

    private func startRead(_ work: QueuedRead, components: [String]) {
        runningReads += 1
        #if DEBUG
        readLog.append(components)
        #endif
        work.start()
    }

    private func finishRead(id: ObjectIdentifier, session: Session, components: [String], type: ServedFileType.Entry, result: Result<Reply, ScopedFileReader.Failure>) {
        runningReads -= 1
        while runningReads < limits.concurrentReads, !waitingReads.isEmpty {
            let next = waitingReads.removeFirst()
            if activeTasks[next.id] != nil { next.start() }
        }
        guard let task = activeTasks.removeValue(forKey: id) else { return }
        switch result {
        case .failure(let failure):
            task.didFailWithError(URLError(failure == .notFound ? .fileDoesNotExist : .noPermissionsToReadFile))
            record(components, .failed(failure))
        case .success(let reply):
            guard session.bytesServed + Int64(reply.body.count) <= limits.bytesPerLoad else {
                logExhaustion(session)
                refuse(task, components: components, reason: "byte budget")
                return
            }
            session.bytesServed += Int64(reply.body.count)
            var headers = Self.headers(contentType: type.mimeType, length: reply.body.count, csp: Self.subresourceCSP)
            headers.merge(reply.extraHeaders) { _, new in new }
            respond(task, status: reply.status, headers: headers, body: reply.body)
            record(components, .served(status: reply.status, bytes: reply.body.count))
        }
    }

    struct Reply: Sendable {
        let status: Int
        let extraHeaders: [String: String]
        let body: Data
    }

    /// Reads a subresource off the main thread.
    private nonisolated static func read(
        components: [String], type: ServedFileType.Entry, rangeHeader: String?,
        reader: ScopedFileReader, limits: Limits
    ) -> Result<Reply, ScopedFileReader.Failure> {
        do {
            let reply = try ScopedFileReader.withDatalessFilesNotMaterialized { () throws(ScopedFileReader.Failure) -> Reply in
                guard type.kind == .media else {
                    let file = try reader.open(components: components, maxSize: limits.fileBytes)
                    return Reply(status: 200, extraHeaders: [:], body: try file.readAll())
                }
                let file = try reader.open(components: components, maxSize: limits.mediaFileBytes)
                guard let rangeHeader else {
                    // Whole media files only up to one chunk.
                    guard file.size <= limits.mediaChunkBytes else { throw .tooLarge }
                    return Reply(status: 200, extraHeaders: ["Accept-Ranges": "bytes"], body: try file.readAll())
                }
                guard let request = parseRange(rangeHeader),
                      let range = resolve(request, size: file.size, chunk: limits.mediaChunkBytes)
                else {
                    return Reply(status: 416, extraHeaders: ["Content-Range": "bytes */\(file.size)", "Accept-Ranges": "bytes"], body: Data())
                }
                let body = try file.read(offset: range.lowerBound, length: Int(range.upperBound - range.lowerBound + 1))
                return Reply(status: 206, extraHeaders: [
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/\(file.size)",
                    "Accept-Ranges": "bytes",
                ], body: body)
            }
            return .success(reply)
        } catch {
            return .failure(error)
        }
    }

    // MARK: Responding

    nonisolated static func headers(contentType: String, length: Int, csp: String) -> [String: String] {
        [
            "Content-Type": contentType,
            "Content-Length": "\(length)",
            "Content-Security-Policy": csp,
            "X-Content-Type-Options": "nosniff",
            "Referrer-Policy": "no-referrer",
            "Cache-Control": "no-store",
            "X-DNS-Prefetch-Control": "off",
        ]
    }

    private func respond(_ task: any WKURLSchemeTask, status: Int, headers: [String: String], body: Data) {
        guard let url = task.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)
        else {
            task.didFailWithError(URLError(.cannotParseResponse))
            return
        }
        task.didReceive(response)
        if !body.isEmpty { task.didReceive(body) }
        task.didFinish()
    }

    private func refuse(_ task: any WKURLSchemeTask, components: [String]?, reason: String) {
        Self.log.debug("Refused an HTML subresource request: \(reason, privacy: .public)")
        task.didFailWithError(URLError(.noPermissionsToReadFile))
        record(components, .refused(reason))
    }

    private func logExhaustion(_ session: Session) {
        guard !session.loggedExhaustion else { return }
        session.loggedExhaustion = true
        Self.log.error("An HTML document used up its request or byte budget; further requests fail")
    }

    private func record(_ components: [String]?, _ outcome: LogOutcome) {
        #if DEBUG
        requestLog.append(LogEntry(components: components, outcome: outcome))
        #endif
    }
}
#endif
