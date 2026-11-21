#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HTMLContentRulesTests {
    private func rules(_ policy: HTMLContentPolicy) throws -> [[String: Any]] {
        let data = Data(HTMLContentRules.encodedRules(for: policy).utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    @Test func identifiersAreVersionedAndSeparateFromThePreviewLists() {
        // v4: the running list lifts https script too (mars-dawn#658), so a v3 list, which
        // didn't, must never be reused for a document the reader runs.
        #expect(HTMLContentRules.identifier(for: .blocked) == "dev.southern-light.marsdawn.html-rules.v4.blocked")
        #expect(HTMLContentRules.identifier(for: .running) == "dev.southern-light.marsdawn.html-rules.v4.running")
        #expect(PreviewContentRules.identifier(allowRemoteImages: false) == "dev.southern-light.marsdawn.preview-rules.v2.blocked")
        #expect(PreviewContentRules.identifier(allowRemoteImages: true) == "dev.southern-light.marsdawn.preview-rules.v2.remote-images-allowed")
    }

    @Test func thereAreExactlyTwoPolicies() {
        // Not three. A "remote content but not running" state would be one nothing can reach,
        // and a dead state that reads as a live one is how a later caller gets a policy nobody
        // reviewed (A4-3, D-1).
        #expect(HTMLContentPolicy.allCases == [.blocked, .running])
    }

    @Test func blockedStateBlocksEveryWebRequest() throws {
        #expect(HTMLContentRules.encodedRules(for: .blocked) == PreviewContentRules.encodedRules(allowRemoteImages: false))
        let list = try rules(.blocked)
        #expect(list.count == 2)
    }

    /// Exact rules, in order. The blocks cover http and https; only https is lifted, so the list
    /// blocks plaintext http of every type, script included (mars-dawn#658).
    @Test func runningStateLiftsTheBlockOverHTTPSOnly() throws {
        let list = try rules(.running).map { $0 as NSDictionary }
        func block(_ filter: String) -> NSDictionary {
            ["trigger": ["url-filter": filter], "action": ["type": "block"]]
        }
        let lift: NSDictionary = [
            "trigger": ["url-filter": "^https:",
                        "resource-type": ["script", "image", "style-sheet", "font", "media", "fetch"]],
            "action": ["type": "ignore-previous-rules"],
        ]
        #expect(list == [block("^https?:"), block("^wss?:"), lift])
    }

    /// What must never appear in a lift, at any scheme: WebSockets, pings, popups, nested
    /// documents and `raw` (which also lifted preconnect and preload). Script may, since
    /// mars-dawn#658, but only through the one https lift. The rules are decoded, so each lift's
    /// own `resource-type` list is read (the JSON is written with sorted keys, which puts `action`
    /// before `trigger`, so a text search before the action cannot see it).
    @Test func noPolicyEverLiftsPlaintextHTTPWebSocketsOrPopups() throws {
        let forbidden: Set<String> = ["raw", "websocket", "ping", "popup", "document", "svg-document"]
        var lifts = 0
        for policy in HTMLContentPolicy.allCases {
            let list = try rules(policy)
            let lifting = list.filter { ($0["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules" }
            // The blocked policy has no lift at all; the running one has exactly one.
            #expect(lifting.count == (policy == .blocked ? 0 : 1), "\(policy) has \(lifting.count) lifts")
            for rule in lifting {
                lifts += 1
                let trigger = try #require(rule["trigger"] as? [String: Any], "\(policy)")
                let types = try #require(trigger["resource-type"] as? [String], "a lift without a resource-type list lifts every type in \(policy)")
                #expect(!types.isEmpty)
                #expect(Set(types).isDisjoint(with: forbidden), "lifted \(Set(types).intersection(forbidden)) in \(policy)")
                let filter = try #require(trigger["url-filter"] as? String)
                // Exactly https: not `^https?:`, which would lift plaintext http, script included.
                #expect(filter == "^https:", "a lift reaches past https in \(policy): \(filter)")
            }
        }
        #expect(lifts == 1, "the instrument must see the running policy's lift")
    }

    @Test func noRuleExemptsLoopbackOrLocalhost() {
        for policy in HTMLContentPolicy.allCases {
            let json = HTMLContentRules.encodedRules(for: policy)
                + PreviewContentRules.encodedRules(allowRemoteImages: policy == .running)
            for exemption in ["127.0.0.1", "localhost", "if-domain", "unless-domain", "::1"] {
                #expect(!json.contains(exemption), "\(exemption) in the \(policy) rules")
            }
        }
    }

    @Test(arguments: HTMLContentPolicy.allCases)
    func listsCompile(policy: HTMLContentPolicy) async throws {
        let list = try await HTMLContentRules.ruleList(for: policy)
        #expect(list.identifier == HTMLContentRules.identifier(for: policy))
        let again = try await HTMLContentRules.ruleList(for: policy)
        #expect(again === list)
    }
}
#endif
