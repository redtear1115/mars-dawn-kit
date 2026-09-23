#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import ObjectiveC
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
    private static let log = Logger(subsystem: "dev.southern-light.marsdawn-kit", category: "PreviewWebView")

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
        Self.installRuntimeGates
        super.init(frame: frame, configuration: configuration)
        allowsLinkPreview = false
    }

    public required init?(coder: NSCoder) {
        Self.installRuntimeGates
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

    override open func loadHTMLString(_ string: String, baseURL: URL?) -> WKNavigation? {
        guard rulesAttached("loadHTMLString") else { return nil }
        return super.loadHTMLString(string, baseURL: baseURL)
    }

    override open func loadFileURL(_ url: URL, allowingReadAccessTo readAccessURL: URL) -> WKNavigation? {
        guard rulesAttached("loadFileURL") else { return nil }
        return super.loadFileURL(url, allowingReadAccessTo: readAccessURL)
    }

    /// `baseURL` is optional although WebKit's header marks it nonnull: `loadHTMLString(_:baseURL:)`
    /// forwards a nil base here, and a non-optional parameter trapped bridging it (#41).
    override open func load(_ data: Data, mimeType: String, characterEncodingName: String, baseURL: URL?) -> WKNavigation? {
        guard rulesAttached("load(data)") else { return nil }
        if let baseURL {
            return super.load(data, mimeType: mimeType, characterEncodingName: characterEncodingName, baseURL: baseURL)
        }
        // Swift can't hand nil to super's nonnull parameter, so this calls WKWebView's own
        // implementation with it, as `loadHTMLString(_:baseURL: nil)` itself does.
        typealias Implementation = @convention(c) (AnyObject, Selector, NSData, NSString, NSString, NSURL?) -> WKNavigation?
        let selector = #selector(WKWebView.load(_:mimeType:characterEncodingName:baseURL:))
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else { return nil }
        let original = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
        return original(self, selector, data as NSData, mimeType as NSString, characterEncodingName as NSString, nil)
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

    /// Restoring a saved state loads its page, so it waits for the rules like a load.
    override open var interactionState: Any? {
        get { super.interactionState }
        set {
            guard rulesAttached("interactionState") else { return }
            super.interactionState = newValue
        }
    }

    // MARK: Runtime gates

    /// Selectors of loading methods that only some WebKit versions have, gated at run time.
    ///
    /// `loadURL:` (Swift `load(_: URL)`) arrived with macOS 27. A Swift override would need the
    /// macOS 27 SDK to compile, and a kit built with an older SDK would leave it ungated on
    /// macOS 27. Instead, the gate is added to this class when WebKit has the method, whatever
    /// SDK the kit was built with. It is only added to `PreviewWKWebView`; WebKit is untouched.
    nonisolated static let runtimeGatedSelectors = ["loadURL:"]

    private static let installRuntimeGates: Void = {
        for name in runtimeGatedSelectors {
            installRefusingOverride(for: NSSelectorFromString(name))
        }
    }()

    /// Adds `selector` to this class: refused (returning nil) while no rule list is attached,
    /// otherwise WKWebView's own implementation. The selector must take one object argument
    /// and return an optional object, like `loadURL:`. Does nothing if WKWebView lacks it or
    /// this class already implements it. Returns whether the gate was added.
    @discardableResult
    static func installRefusingOverride(for selector: Selector) -> Bool {
        guard let method = class_getInstanceMethod(WKWebView.self, selector),
              let typeEncoding = method_getTypeEncoding(method),
              method_getNumberOfArguments(method) == 3, // self, _cmd and one argument.
              String(cString: typeEncoding).hasPrefix("@"), // Returns an object…
              let argumentType = method_copyArgumentType(method, 2)
        else { return false }
        defer { free(argumentType) }
        guard String(cString: argumentType) == "@" else { return false } // …and takes one.
        typealias Implementation = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Implementation.self)
        let name = NSStringFromSelector(selector)
        let gate: @convention(block) (AnyObject, AnyObject?) -> AnyObject? = { object, argument in
            let allowed = MainActor.assumeIsolated {
                (object as? PreviewWKWebView)?.rulesAttached(name) ?? false
            }
            guard allowed else { return nil }
            return original(object, selector, argument)
        }
        return class_addMethod(PreviewWKWebView.self, selector, imp_implementationWithBlock(gate), typeEncoding)
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
