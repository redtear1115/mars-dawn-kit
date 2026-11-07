import Foundation
import WebKit

/// Compiles a content rule list into the shared store. Every `marsdawn` of one name uses the same
/// store on disk, and a compile writes the same file whatever is in it, so of two processes at once
/// one can lose and get `contentRuleListStoreCompileFailed` (#234: 146 of 3,600 compiles with 24
/// processes, and an export that fails with exit 5). The list is there for the taking by then, or
/// is about to be, so another try gets it. Nothing else is tried again: a compile that really failed
/// fails the same way each time.
enum ContentRuleCompile {
    /// How long to wait before each further try. Short: a compile takes milliseconds.
    static let retryDelays: [Duration] = [.milliseconds(50), .milliseconds(100), .milliseconds(200)]

    @MainActor
    static func list(identifier: String, rules: String) async throws -> WKContentRuleList {
        try await retrying {
            guard let list = try await WKContentRuleListStore.default()
                .compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules)
            else { throw PreviewContentRules.CompileError.noList }
            return list
        }
    }

    static func isLostRace(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == WKError.errorDomain
            && error.code == WKError.Code.contentRuleListStoreCompileFailed.rawValue
    }

    /// `operation`, tried again after each of `delays` while it loses the race.
    @MainActor
    static func retrying<Value>(
        delays: [Duration] = retryDelays,
        sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        var remaining = delays[...]
        while true {
            do {
                return try await operation()
            } catch {
                guard isLostRace(error), let delay = remaining.popFirst() else { throw error }
                try await sleep(delay)
            }
        }
    }
}
