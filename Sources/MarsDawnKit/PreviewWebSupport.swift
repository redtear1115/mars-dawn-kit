import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the bundled preview page (HTML, CSS, mermaid.js, highlight.js) from a private
/// URL scheme so the page can run under a strict Content-Security-Policy.
public final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    public nonisolated static let scheme = "marsdawn-app"
    public nonisolated static let pageURL = URL(string: "\(scheme)://preview/index.html")!
    /// Generated from `PreviewTheme.all` rather than read from the bundle.
    nonisolated static let themesStylesheetName = "themes.css"

    /// Placeholder in index.html's CSP `img-src`, filled per load.
    nonisolated static let remoteImagesToken = "__REMOTE_IMAGE_SOURCES__"
    nonisolated static let remoteImagesQueryItem = "remote-images"

    /// The page URL with the initial theme applied before first paint. Remote (https) images
    /// are blocked by the page's CSP unless `allowRemoteImages` is set.
    public nonisolated static func pageURL(theme: PreviewTheme, allowRemoteImages: Bool = false) -> URL {
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "theme", value: theme.id)]
        if allowRemoteImages {
            components.queryItems?.append(URLQueryItem(name: remoteImagesQueryItem, value: "1"))
        }
        return components.url!
    }

    /// The page URL with separate light and dark themes applied before first paint (S2).
    /// `theme-boot.js` picks between them by `prefers-color-scheme`. Remote (https) images
    /// are blocked by the page's CSP unless `allowRemoteImages` is set.
    public nonisolated static func pageURL(lightTheme: PreviewTheme, darkTheme: PreviewTheme, allowRemoteImages: Bool = false) -> URL {
        var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "theme", value: lightTheme.id),
            URLQueryItem(name: "darkTheme", value: darkTheme.id),
        ]
        if allowRemoteImages {
            components.queryItems?.append(URLQueryItem(name: remoteImagesQueryItem, value: "1"))
        }
        return components.url!
    }

    /// index.html with its CSP completed for the requested remote-image policy.
    nonisolated static func page(_ html: Data, for requestURL: URL) -> Data {
        let items = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let allowRemote = items.contains { $0.name == remoteImagesQueryItem && $0.value == "1" }
        let text = String(decoding: html, as: UTF8.self)
            .replacingOccurrences(of: remoteImagesToken, with: allowRemote ? "https:" : "")
        return Data(text.utf8)
    }

    private let rootURL: URL

    override public init() {
        rootURL = Bundle.module.url(forResource: "Preview", withExtension: nil)!.standardizedFileURL
    }

    public func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let requestURL = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let data: Data
        let pathExtension: String
        if requestURL.path == "/\(Self.themesStylesheetName)" {
            data = Data(PreviewTheme.stylesheet.utf8)
            pathExtension = "css"
        } else if let fileURL = resolve(requestURL), let contents = try? Data(contentsOf: fileURL) {
            data = fileURL.lastPathComponent == "index.html" ? Self.page(contents, for: requestURL) : contents
            pathExtension = fileURL.pathExtension
        } else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType = UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mimeType, "Content-Length": "\(data.count)"]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    public func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    /// Maps a request path to a file inside the bundled Preview folder, rejecting traversal.
    private func resolve(_ url: URL) -> URL? {
        let relative = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return nil }
        let candidate = rootURL.appendingPathComponent(relative).standardizedFileURL
        guard candidate.path.hasPrefix(rootURL.path + "/") else { return nil }
        return candidate
    }
}

@MainActor
public enum PreviewWebView {
    /// Name of the script message handler the page uses to forward console errors.
    public nonisolated static let logHandlerName = "log"
    /// Message handler receiving `{line, atEnd}` when the user scrolls the preview.
    public nonisolated static let scrollHandlerName = "scrollSync"

    /// Message handler the page calls when the user asks to grant folder access for images.
    public nonisolated static let assetAccessHandlerName = "assetAccess"

    public static func makeConfiguration(assets: DocumentAssetSchemeHandler? = nil) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(PreviewSchemeHandler(), forURLScheme: PreviewSchemeHandler.scheme)
        if let assets {
            configuration.setURLSchemeHandler(assets, forURLScheme: DocumentAssetSchemeHandler.scheme)
        }
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }

    /// JavaScript that replaces the preview content with a freshly rendered fragment.
    /// `lineCount` lets scroll sync map the document's end.
    public nonisolated static func updateScript(html: String, lineCount: Int = 0) -> String {
        "window.MarsDawn && MarsDawn.update(\(jsonStringLiteral(html)), \(lineCount));"
    }

    /// JavaScript that scrolls the preview to a (fractional, 1-based) source line.
    public nonisolated static func scrollScript(line: Double, atEnd: Bool) -> String {
        let safeLine = line.isFinite ? max(1, line) : 1
        return "window.MarsDawn && MarsDawn.scrollToLine(\(safeLine), \(atEnd));"
    }

    /// JavaScript that switches the page to another theme, re-rendering diagrams.
    public nonisolated static func themeScript(_ theme: PreviewTheme) -> String {
        "window.MarsDawn && MarsDawn.setTheme(\(jsonStringLiteral(theme.id)));"
    }

    /// JavaScript that switches the page to separate light and dark themes (S2), re-rendering
    /// diagrams. The page keeps whichever one matches the current color scheme.
    public nonisolated static func themeScript(light: PreviewTheme, dark: PreviewTheme) -> String {
        "window.MarsDawn && MarsDawn.setThemes(\(jsonStringLiteral(light.id)), \(jsonStringLiteral(dark.id)));"
    }

    /// Message handler the page calls when the user asks to load remote images.
    public nonisolated static let loadRemoteImagesHandlerName = "loadRemoteImages"

    /// Tells the page whether remote images are blocked, so it can offer to load them.
    public nonisolated static func remoteImagesScript(blocked: Bool, message: String, buttonLabel: String, placeholderLabel: String) -> String {
        let state: [String: Any] = [
            "blocked": blocked,
            "message": message,
            "buttonLabel": buttonLabel,
            "placeholderLabel": placeholderLabel,
        ]
        let data = try! JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        return "window.MarsDawn && MarsDawn.setRemoteImageState(\(String(decoding: data, as: UTF8.self)));"
    }

    /// Tells the page whether local images are blocked by missing folder access, with UI labels,
    /// and retries images that failed to load.
    public nonisolated static func assetStateScript(needsAccess: Bool, grantLabel: String, missingLabel: String, blockedLabel: String) -> String {
        let state: [String: Any] = [
            "needsAccess": needsAccess,
            "grantLabel": grantLabel,
            "missingLabel": missingLabel,
            "blockedLabel": blockedLabel,
        ]
        let data = try! JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        return "window.MarsDawn && MarsDawn.setAssetState(\(String(decoding: data, as: UTF8.self)));"
    }

    nonisolated static func jsonStringLiteral(_ string: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed])
        return String(decoding: data, as: UTF8.self)
    }
}

/// Content rule lists that keep the preview web views off the network.
///
/// The page's CSP is the first layer; these lists are the second, and also cover requests the
/// CSP doesn't govern, such as `<link rel=preconnect>`. Attach the list for the page's
/// remote-image state before loading the page.
@MainActor
public enum PreviewContentRules {
    /// Bump when the rules change, so a list compiled from older rules is never reused.
    nonisolated static let version = 1
    nonisolated static let identifierPrefix = "dev.southern-light.marsdawn.preview-rules"
    /// Every web and WebSocket URL, whatever the case of the scheme. WebKit's rule regexes
    /// have no alternation (`|`), so the schemes take one filter each.
    nonisolated static let networkURLFilters = ["^https?:", "^wss?:"]

    /// The store identifier of the list for a remote-image state.
    public nonisolated static func identifier(allowRemoteImages: Bool) -> String {
        "\(identifierPrefix).v\(version).\(allowRemoteImages ? "remote-images-allowed" : "blocked")"
    }

    /// Rule list JSON. Blocked: every web request. Allowed: every web request except images.
    public nonisolated static func encodedRules(allowRemoteImages: Bool) -> String {
        var rules: [[String: Any]] = networkURLFilters.map { filter in
            ["trigger": ["url-filter": filter], "action": ["type": "block"]]
        }
        if allowRemoteImages {
            // Rules apply in order: lift the block for images only, so every other type stays blocked.
            rules += networkURLFilters.map { filter in
                ["trigger": ["url-filter": filter, "resource-type": ["image"]], "action": ["type": "ignore-previous-rules"]]
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static var compiled: [Bool: Task<WKContentRuleList, any Error>] = [:]

    public enum CompileError: Error {
        case noList
    }

    /// The compiled list for a remote-image state, compiled once per process.
    /// A failed compile isn't cached, so a later call tries again.
    public static func ruleList(allowRemoteImages: Bool) async throws -> WKContentRuleList {
        if let task = compiled[allowRemoteImages] {
            return try await task.value
        }
        let identifier = identifier(allowRemoteImages: allowRemoteImages)
        let rules = encodedRules(allowRemoteImages: allowRemoteImages)
        let task = Task { @MainActor () throws -> WKContentRuleList in
            guard let list = try await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules)
            else { throw CompileError.noList }
            return list
        }
        compiled[allowRemoteImages] = task
        do {
            return try await task.value
        } catch {
            if compiled[allowRemoteImages] == task { compiled[allowRemoteImages] = nil }
            throw error
        }
    }
}
