import Foundation
import WebKit

/// What an HTML document is allowed to do (A4-3).
///
/// Two states, not three. There is no independently consentable "remote content but no scripts":
/// the reader's one choice is to run the document, which turns on its scripts and its https
/// subresources together. A third case nothing could reach would be a dead state that reads as a
/// live one, which is how a later caller ends up with a policy nobody reviewed.
public enum HTMLContentPolicy: String, Sendable, CaseIterable {
    /// Nothing runs and nothing is fetched. Every HTML document starts here.
    case blocked
    /// The reader chose to run this document, in this window, until it is reloaded or closed.
    case running
}

/// Content rule lists for the HTML document web view, kept apart from `PreviewContentRules`.
///
/// The page's CSP header is the first layer; these lists are the second, and also cover
/// requests the CSP doesn't govern, such as `<link rel=preconnect>`. Attach the list for the
/// page's policy before loading the page.
///
/// - Blocked: every web and WebSocket request.
/// - Running: the same blocks, then lifted for https scripts, images, style sheets, fonts, media
///   and fetches. Script joined the lift in v4 (mars-dawn#658, rewriting D-1c): a document the
///   reader runs may load code over https, so the program is no longer only the bytes in the file,
///   and the bar says so. Documents, SVG documents, WebSockets, pings, popups, preconnects and
///   everything else stay blocked, and so does plaintext http of any type, script included.
@MainActor
public enum HTMLContentRules {
    /// Bump when the rules change, so a list compiled from older rules is never reused.
    nonisolated static let version = 4
    nonisolated static let identifierPrefix = "dev.southern-light.marsdawn.html-rules"
    /// Resource types that load while a document is running. `raw` and `fetch` are both accepted
    /// by WebKit's dialect and both are listed, because which one a `fetch()` is classified under
    /// isn't documented, and a document the copy says may send data over the network has to be
    /// able to. `script` is here since v4 (mars-dawn#658); `raw`, `websocket`, `ping`, `popup` and
    /// `document` never are.
    nonisolated static let runningResourceTypes = ["script", "image", "style-sheet", "font", "media", "fetch"]

    /// The store identifier of the list for a policy.
    public nonisolated static func identifier(for policy: HTMLContentPolicy) -> String {
        "\(identifierPrefix).v\(version).\(policy.rawValue)"
    }

    /// Rule list JSON for a policy.
    public nonisolated static func encodedRules(for policy: HTMLContentPolicy) -> String {
        let filters = PreviewContentRules.networkURLFilters
        var rules: [[String: Any]] = filters.map { filter in
            ["trigger": ["url-filter": filter], "action": ["type": "block"]]
        }
        if policy == .running {
            // Rules apply in order: lift the block for these types over https only, never for
            // plaintext http and never for ws or wss. The page CSP allows no http either, and this list
            // is the layer below it.
            rules += [["trigger": ["url-filter": "^https:", "resource-type": runningResourceTypes],
                       "action": ["type": "ignore-previous-rules"]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static var compiled: [HTMLContentPolicy: Task<WKContentRuleList, any Error>] = [:]

    /// The compiled list for a policy, compiled once per process.
    /// A failed compile isn't cached, so a later call tries again.
    public static func ruleList(for policy: HTMLContentPolicy) async throws -> WKContentRuleList {
        if let task = compiled[policy] {
            return try await task.value
        }
        let identifier = identifier(for: policy)
        let rules = encodedRules(for: policy)
        let task = Task { @MainActor () throws -> WKContentRuleList in
            guard let list = try await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules)
            else { throw PreviewContentRules.CompileError.noList }
            return list
        }
        compiled[policy] = task
        do {
            return try await task.value
        } catch {
            if compiled[policy] == task { compiled[policy] = nil }
            throw error
        }
    }
}
