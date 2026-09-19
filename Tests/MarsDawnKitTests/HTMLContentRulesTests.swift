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
    /// code it arrived with (D-1c).
    @Test func noPolicyEverLiftsScriptOrWebSockets() {
        for policy in HTMLContentPolicy.allCases {
            let json = HTMLContentRules.encodedRules(for: policy)
            guard let lifted = json.range(of: "ignore-previous-rules") else { continue }
            let lift = String(json[..<lifted.lowerBound])
            #expect(!lift.contains("\"script\""), "script lifted in \(policy)")
            #expect(!lift.contains("websocket"), "websocket lifted in \(policy)")
            #expect(!json.contains("\"^wss:\""), "wss lifted in \(policy)")
        }
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
