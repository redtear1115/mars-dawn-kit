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
        // v3: two policies, and the running one lifts script's neighbours but never script, so a
        // v2 list (which had a remote-allowed state) must never be reused.
        #expect(HTMLContentRules.identifier(for: .blocked) == "dev.southern-light.marsdawn.html-rules.v3.blocked")
        #expect(HTMLContentRules.identifier(for: .running) == "dev.southern-light.marsdawn.html-rules.v3.running")
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

    /// Exact rules, in order. The blocks cover http and https; only https is lifted, and only for
    /// types that are not code, so the list blocks plaintext http even for those and blocks
    /// script at every scheme.
    @Test func runningStateLiftsTheBlockForNonCodeTypesOverHTTPSOnly() throws {
        let list = try rules(.running).map { $0 as NSDictionary }
        func block(_ filter: String) -> NSDictionary {
            ["trigger": ["url-filter": filter], "action": ["type": "block"]]
        }
        let lift: NSDictionary = [
            "trigger": ["url-filter": "^https:",
                        "resource-type": ["image", "style-sheet", "font", "media", "fetch"]],
            "action": ["type": "ignore-previous-rules"],
        ]
        #expect(list == [block("^https?:"), block("^wss?:"), lift])
    }

    /// The one type that must never appear in a lift, at any scheme: a running document runs the
    /// code it arrived with (D-1c). The rules are decoded, so each lift's own `resource-type`
    /// list is read (the JSON is written with sorted keys, which puts `action` before `trigger`,
    /// so a text search before the action cannot see it).
    @Test func noPolicyEverLiftsScriptOrWebSockets() throws {
        let forbidden: Set<String> = ["script", "raw", "websocket", "ping", "popup"]
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
                #expect(!filter.contains("ws"), "a lift reaches web sockets in \(policy): \(filter)")
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
