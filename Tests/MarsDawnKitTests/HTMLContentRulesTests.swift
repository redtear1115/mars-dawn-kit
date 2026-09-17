#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HTMLContentRulesTests {
    private func rules(_ remote: Bool) throws -> [[String: Any]] {
        let data = Data(HTMLContentRules.encodedRules(allowsRemoteContent: remote).utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    @Test func identifiersAreVersionedAndSeparateFromThePreviewLists() {
        // v2: the allowed state lifts the block for https only, so a v1 list must not be reused.
        #expect(HTMLContentRules.identifier(allowsRemoteContent: false) == "dev.southern-light.marsdawn.html-rules.v2.blocked")
        #expect(HTMLContentRules.identifier(allowsRemoteContent: true) == "dev.southern-light.marsdawn.html-rules.v2.remote-allowed")
        #expect(PreviewContentRules.identifier(allowRemoteImages: false) == "dev.southern-light.marsdawn.preview-rules.v2.blocked")
        #expect(PreviewContentRules.identifier(allowRemoteImages: true) == "dev.southern-light.marsdawn.preview-rules.v2.remote-images-allowed")
    }

    @Test func blockedStateBlocksEveryWebRequest() throws {
        #expect(HTMLContentRules.encodedRules(allowsRemoteContent: false) == PreviewContentRules.encodedRules(allowRemoteImages: false))
        let list = try rules(false)
        #expect(list.count == 2)
    }

    /// Exact rules, in order. The blocks cover http and https; only https is lifted, so the
    /// list blocks plaintext http even for the four allowed types.
    @Test func remoteStateLiftsTheBlockForFourTypesOverHTTPSOnly() throws {
        let list = try rules(true).map { $0 as NSDictionary }
        func block(_ filter: String) -> NSDictionary {
            ["trigger": ["url-filter": filter], "action": ["type": "block"]]
        }
        func lift(_ filter: String) -> NSDictionary {
            ["trigger": ["url-filter": filter, "resource-type": ["image", "style-sheet", "font", "media"]],
             "action": ["type": "ignore-previous-rules"]]
        }
        #expect(list == [block("^https?:"), block("^wss?:"), lift("^https:"), lift("^wss:")])
    }

    @Test func noRuleExemptsLoopbackOrLocalhost() {
        for remote in [false, true] {
            let json = HTMLContentRules.encodedRules(allowsRemoteContent: remote)
                + PreviewContentRules.encodedRules(allowRemoteImages: remote)
            for exemption in ["127.0.0.1", "localhost", "if-domain", "unless-domain", "::1"] {
                #expect(!json.contains(exemption), "\(exemption) in the \(remote ? "allowed" : "blocked") rules")
            }
        }
    }

    @Test(arguments: [false, true])
    func listsCompile(remote: Bool) async throws {
        let list = try await HTMLContentRules.ruleList(allowsRemoteContent: remote)
        #expect(list.identifier == HTMLContentRules.identifier(allowsRemoteContent: remote))
        let again = try await HTMLContentRules.ruleList(allowsRemoteContent: remote)
        #expect(again === list)
    }
}
#endif
