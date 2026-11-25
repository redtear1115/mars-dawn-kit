#if os(macOS)
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit

/// #234: two processes compiling the same list race for one file on disk, and the loser's export
/// fails. Losing is worth another try; nothing else is.
@MainActor
struct ContentRuleCompileTests {
    private struct Other: Error {}

    private let lost = NSError(
        domain: WKError.errorDomain, code: WKError.Code.contentRuleListStoreCompileFailed.rawValue
    )
    private let delays: [Duration] = [.milliseconds(1), .milliseconds(2), .milliseconds(3)]

    private func run(failures: [any Error]) async -> (result: Result<Int, any Error>, calls: Int, slept: [Duration]) {
        var calls = 0
        var slept: [Duration] = []
        do {
            let value = try await ContentRuleCompile.retrying(delays: delays, sleep: { slept.append($0) }) {
                calls += 1
                if calls <= failures.count { throw failures[calls - 1] }
                return 42
            }
            return (.success(value), calls, slept)
        } catch {
            return (.failure(error), calls, slept)
        }
    }

    @Test func aCompileThatWorksIsTriedOnceWithNoWait() async {
        let outcome = await run(failures: [])
        #expect(outcome.calls == 1)
        #expect(outcome.slept.isEmpty)
    }

    @Test func losingTheRaceIsTriedAgain() async throws {
        let outcome = await run(failures: [lost, lost])
        #expect(try outcome.result.get() == 42)
        #expect(outcome.calls == 3)
        #expect(outcome.slept == Array(delays.prefix(2)))
    }

    @Test func thereIsAnEndToIt() async {
        let outcome = await run(failures: [lost, lost, lost, lost, lost])
        #expect(outcome.calls == delays.count + 1)
        #expect((try? outcome.result.get()) == nil, "the last failure is what the caller gets")
    }

    @Test func nothingElseIsTriedAgain() async {
        let others: [any Error] = [
            Other(),
            PreviewContentRules.CompileError.noList,
            NSError(domain: WKError.errorDomain, code: WKError.Code.contentRuleListStoreLookUpFailed.rawValue),
            NSError(domain: "another", code: lost.code),
        ]
        for error in others {
            let outcome = await run(failures: [error])
            #expect(outcome.calls == 1, "\(error)")
            #expect(outcome.slept.isEmpty)
        }
    }

    /// The real store, with the code it really reports.
    @Test func theErrorIsTheOneWebKitGives() {
        #expect(WKError.Code.contentRuleListStoreCompileFailed.rawValue == 6)
        #expect(ContentRuleCompile.isLostRace(lost))
    }

    /// The default delays add up to little: an export waits a third of a second at most.
    @Test func theWaitIsShort() {
        let total = ContentRuleCompile.retryDelays.reduce(Duration.zero, +)
        #expect(total <= .milliseconds(500))
    }
}
#endif
