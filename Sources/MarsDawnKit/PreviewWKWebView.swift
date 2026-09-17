#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import OSLog
import WebKit

/// The web view for every Markdown preview page (app preview, export, Quick Look).
///
/// - No link previews (they would load the linked page).
/// - The context menu has no item that reloads the page or opens or downloads content.
/// - `load(_:)` refuses to start until a content rule list has been applied with
///   `applyContentRuleList(_:)`, so no page loads without the network rules in place.
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

    override open func load(_ request: URLRequest) -> WKNavigation? {
        guard let identifier = contentRuleListIdentifier else {
            Self.log.error("Refusing to load a preview page before its content rules are attached")
            return nil
        }
        let navigation = super.load(request)
        if navigation != nil {
            let record = LoadRecord(url: request.url, contentRuleListIdentifier: identifier)
            if firstLoad == nil { firstLoad = record }
            lastLoad = record
        }
        return navigation
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
