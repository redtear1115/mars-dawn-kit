#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import OSLog
import WebKit

/// The web view for every Markdown preview page (app preview, export, Quick Look).
///
/// - No link previews (they would load the linked page).
/// - The context menu has no item that reloads the page or opens or downloads content.
/// - Every loading entry point (`load`, `loadHTMLString`, `loadFileURL`, data and simulated
///   loads, reloads and history moves) refuses to start until a content rule list has been
///   applied with `applyContentRuleList(_:)`, so no page loads without the network rules.
open class PreviewWKWebView: WKWebView {
    private static let log = Logger(subsystem: "dev.southern-light.marsdawn", category: "PreviewWebView")

    /// Context menu items that load content or reload the page.
    ///
    /// WebKit's `_WKMenuItemIdentifier*` constants aren't in the public headers; their values
    /// are these names (the app's tests check them against WebKit at run time).
    public nonisolated static let removedMenuItemIdentifiers: Set<String> = [
        "WKMenuItemIdentifierReload",
        "WKMenuItemIdentifierOpenLinkInNewWindow",
        "WKMenuItemIdentifierDownloadLinkedFile",
        "WKMenuItemIdentifierDownloadImage",
        "WKMenuItemIdentifierOpenImageInNewWindow",
        "WKMenuItemIdentifierDownloadMedia",
        "WKMenuItemIdentifierOpenMediaInNewWindow",
        "WKMenuItemIdentifierOpenFrameInNewWindow",
    ]

    /// A `load(_:)` call and the rule list that was attached when it was made.
    public struct LoadRecord: Sendable, Equatable {
        public let url: URL?
        public let contentRuleListIdentifier: String?
    }

    /// Identifier of the content rule list currently attached by `applyContentRuleList(_:)`.
    public private(set) var contentRuleListIdentifier: String?
    /// The first and the most recent `load(_:)` calls that started a navigation.
    public private(set) var firstLoad: LoadRecord?
    public private(set) var lastLoad: LoadRecord?

    override public init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        allowsLinkPreview = false
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        allowsLinkPreview = false
    }

    /// Replaces any attached content rule lists with `list`.
    public func applyContentRuleList(_ list: WKContentRuleList) {
        let controller = configuration.userContentController
        controller.removeAllContentRuleLists()
        controller.add(list)
        contentRuleListIdentifier = list.identifier
    }

    /// Detaches every content rule list; loads are refused again until one is applied.
    func removeContentRuleLists() {
        configuration.userContentController.removeAllContentRuleLists()
        contentRuleListIdentifier = nil
    }

    /// Whether a load may start; logs the refusal otherwise.
    private func rulesAttached(_ entryPoint: String) -> Bool {
        guard contentRuleListIdentifier == nil else { return true }
        Self.log.error("Refusing \(entryPoint, privacy: .public) before the preview's content rules are attached")
        return false
    }

    /// Returned by refused loads whose Swift signature can't return nil. It tracks no navigation.
    /// A `WKNavigation` made outside WebKit crashes when deallocated, so this one lives for the
    /// whole process.
    private static let refusedNavigation = WKNavigation()

    override open func load(_ request: URLRequest) -> WKNavigation? {
        guard rulesAttached("load(_:)"), let identifier = contentRuleListIdentifier else { return nil }
        let navigation = super.load(request)
        if navigation != nil {
            let record = LoadRecord(url: request.url, contentRuleListIdentifier: identifier)
            if firstLoad == nil { firstLoad = record }
            lastLoad = record
        }
        return navigation
    }

    #if compiler(>=6.4) // The macOS 27 SDK, which declares `load(_: URL)`.
    @available(macOS 27.0, *)
    override open func load(_ url: URL) -> WKNavigation? {
        guard rulesAttached("load(URL)") else { return nil }
        return super.load(url)
    }
    #endif

    override open func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        guard rulesAttached("loadHTMLString") else { return nil }
        return super.loadHTMLString(string, baseURL: baseURL)
    }

    override open func loadFileURL(_ url: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? {
        guard rulesAttached("loadFileURL") else { return nil }
        return super.loadFileURL(url, allowingReadAccessTo: readAccessURL)
    }

    override open func load(_ data: Data, mimeType: String, characterEncodingName: String, baseURL: URL) -> WKNavigation? {
        guard rulesAttached("load(data)") else { return nil }
        return super.load(data, mimeType: mimeType, characterEncodingName: characterEncodingName, baseURL: baseURL)
    }

    override open func loadFileRequest(_ request: URLRequest, allowingReadAccessTo readAccessURL: URL) -> WKNavigation {
        guard rulesAttached("loadFileRequest") else { return Self.refusedNavigation }
        return super.loadFileRequest(request, allowingReadAccessTo: readAccessURL)
    }

    override open func loadSimulatedRequest(_ request: URLRequest, response: URLResponse, responseData data: Data) -> WKNavigation {
        guard rulesAttached("loadSimulatedRequest") else { return Self.refusedNavigation }
        return super.loadSimulatedRequest(request, response: response, responseData: data)
    }

    override open func loadSimulatedRequest(_ request: URLRequest, responseHTML string: String) -> WKNavigation {
        guard rulesAttached("loadSimulatedRequest") else { return Self.refusedNavigation }
        return super.loadSimulatedRequest(request, responseHTML: string)
    }

    @available(macOS, deprecated: 12.0, message: "Use loadSimulatedRequest(_:response:responseData:)")
    override open func loadSimulatedRequest(_ request: URLRequest, with response: URLResponse, responseData data: Data) -> WKNavigation {
        guard rulesAttached("loadSimulatedRequest") else { return Self.refusedNavigation }
        return super.loadSimulatedRequest(request, with: response, responseData: data)
    }

    @available(macOS, deprecated: 12.0, message: "Use loadSimulatedRequest(_:responseHTML:)")
    override open func loadSimulatedRequest(_ request: URLRequest, withResponseHTML string: String) -> WKNavigation {
        guard rulesAttached("loadSimulatedRequest") else { return Self.refusedNavigation }
        return super.loadSimulatedRequest(request, withResponseHTML: string)
    }

    override open func reload() -> WKNavigation? {
        guard rulesAttached("reload") else { return nil }
        return super.reload()
    }

    override open func reloadFromOrigin() -> WKNavigation? {
        guard rulesAttached("reloadFromOrigin") else { return nil }
        return super.reloadFromOrigin()
    }

    override open func go(to item: WKBackForwardListItem) -> WKNavigation? {
        guard rulesAttached("go(to:)") else { return nil }
        return super.go(to: item)
    }

    override open func goBack() -> WKNavigation? {
        guard rulesAttached("goBack") else { return nil }
        return super.goBack()
    }

    override open func goForward() -> WKNavigation? {
        guard rulesAttached("goForward") else { return nil }
        return super.goForward()
    }

    override open func reload(_ sender: Any?) {
        guard rulesAttached("reload(_:)") else { return }
        super.reload(sender)
    }

    override open func reloadFromOrigin(_ sender: Any?) {
        guard rulesAttached("reloadFromOrigin(_:)") else { return }
        super.reloadFromOrigin(sender)
    }

    override open func goBack(_ sender: Any?) {
        guard rulesAttached("goBack(_:)") else { return }
        super.goBack(sender)
    }

    override open func goForward(_ sender: Any?) {
        guard rulesAttached("goForward(_:)") else { return }
        super.goForward(sender)
    }

    override open func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        Self.removeLoadingItems(from: menu)
    }

    /// Removes the items in `removedMenuItemIdentifiers` (in submenus too), then the
    /// separators left leading, trailing or doubled.
    public static func removeLoadingItems(from menu: NSMenu) {
        for item in menu.items {
            if let identifier = item.identifier?.rawValue, removedMenuItemIdentifiers.contains(identifier) {
                menu.removeItem(item)
            } else if let submenu = item.submenu {
                removeLoadingItems(from: submenu)
            }
        }
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator {
                menu.removeItem(item)
            } else {
                previousWasSeparator = item.isSeparatorItem
            }
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}
#endif
