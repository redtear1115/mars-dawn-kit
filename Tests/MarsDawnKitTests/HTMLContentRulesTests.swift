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
        #expect(HTMLContentRules.identifier(allowsRemoteContent: false) == "dev.southern-light.marsdawn.html-rules.v1.blocked")
        #expect(HTMLContentRules.identifier(allowsRemoteContent: true) == "dev.southern-light.marsdawn.html-rules.v1.remote-allowed")
        #expect(PreviewContentRules.identifier(allowRemoteImages: false) == "dev.southern-light.marsdawn.preview-rules.v1.blocked")
        #expect(PreviewContentRules.identifier(allowRemoteImages: true) == "dev.southern-light.marsdawn.preview-rules.v1.remote-images-allowed")
    }

    @Test func blockedStateBlocksEveryWebRequest() throws {
        #expect(HTMLContentRules.encodedRules(allowsRemoteContent: false) == PreviewContentRules.encodedRules(allowRemoteImages: false))
        let list = try rules(false)
        #expect(list.count == 2)
    }

    @Test func remoteStateLiftsTheBlockForFourTypesOnly() throws {
        let list = try rules(true)
        #expect(list.count == 4)
        for (index, filter) in ["^https?:", "^wss?:"].enumerated() {
            let block = list[index]
            #expect((block["trigger"] as? [String: Any])?["url-filter"] as? String == filter)
            #expect((block["trigger"] as? [String: Any])?["resource-type"] == nil)
            #expect((block["action"] as? [String: Any])?["type"] as? String == "block")
            let lift = list[index + 2]
            let trigger = try #require(lift["trigger"] as? [String: Any])
            #expect(trigger["url-filter"] as? String == filter)
            #expect(trigger["resource-type"] as? [String] == ["image", "style-sheet", "font", "media"])
            #expect((lift["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules")
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
