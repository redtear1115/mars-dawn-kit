import Foundation
import WebKit

/// Content rule lists for the HTML document web view, kept apart from `PreviewContentRules`.
///
/// The page's CSP header is the first layer; these lists are the second, and also cover
/// requests the CSP doesn't govern, such as `<link rel=preconnect>`. Attach the list for the
/// page's remote-content state before loading the page.
///
/// - Blocked: every web and WebSocket request.
/// - Remote allowed: the same blocks, then lifted for https images, style sheets, fonts and
///   media only. Documents, SVG documents, scripts, fetches, WebSockets, pings, popups,
///   preconnects and everything else stay blocked, and so does plaintext http of any type.
@MainActor
public enum HTMLContentRules {
    /// Bump when the rules change, so a list compiled from older rules is never reused.
    nonisolated static let version = 2
    nonisolated static let identifierPrefix = "dev.southern-light.marsdawn.html-rules"
    /// Resource types that load when the user allows remote content.
    nonisolated static let remoteResourceTypes = ["image", "style-sheet", "font", "media"]

    /// The store identifier of the list for a remote-content state.
    public nonisolated static func identifier(allowsRemoteContent: Bool) -> String {
        "\(identifierPrefix).v\(version).\(allowsRemoteContent ? "remote-allowed" : "blocked")"
    }

    /// Rule list JSON for a remote-content state.
    public nonisolated static func encodedRules(allowsRemoteContent: Bool) -> String {
        let filters = PreviewContentRules.networkURLFilters
        var rules: [[String: Any]] = filters.map { filter in
            ["trigger": ["url-filter": filter], "action": ["type": "block"]]
        }
        if allowsRemoteContent {
            // Rules apply in order: lift the block for these types over https only. The page CSP
            // allows no http either, and this list is the layer below it.
            rules += PreviewContentRules.secureURLFilters.map { filter in
                ["trigger": ["url-filter": filter, "resource-type": remoteResourceTypes], "action": ["type": "ignore-previous-rules"]]
            }
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static var compiled: [Bool: Task<WKContentRuleList, any Error>] = [:]

    /// The compiled list for a remote-content state, compiled once per process.
    /// A failed compile isn't cached, so a later call tries again.
    public static func ruleList(allowsRemoteContent: Bool) async throws -> WKContentRuleList {
        if let task = compiled[allowsRemoteContent] {
            return try await task.value
        }
        let identifier = identifier(allowsRemoteContent: allowsRemoteContent)
        let rules = encodedRules(allowsRemoteContent: allowsRemoteContent)
        let task = Task { @MainActor () throws -> WKContentRuleList in
            guard let list = try await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules)
            else { throw PreviewContentRules.CompileError.noList }
            return list
        }
        compiled[allowsRemoteContent] = task
        do {
            return try await task.value
        } catch {
            if compiled[allowsRemoteContent] == task { compiled[allowsRemoteContent] = nil }
            throw error
        }
    }
}
