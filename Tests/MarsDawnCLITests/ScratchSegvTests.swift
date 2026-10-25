#if os(macOS)
import Foundation
import Testing
@testable import marsdawn

private enum Scratch {
    @TaskLocal static var optSendable: (@Sendable () throws -> URL?)?
    @TaskLocal static var optPlain: URL??
    @TaskLocal static var nonOpt: @Sendable () throws -> URL? = { URL(fileURLWithPath: "/x") }
    struct Box: Sendable { var f: @Sendable () throws -> URL? }
    @TaskLocal static var boxed: Box? = nil
    @TaskLocal static var nonThrowing: (@Sendable () -> URL?)?
    @TaskLocal static var intClosure: (@Sendable () -> Int)?
    @TaskLocal static var voidClosure: (@Sendable () -> Void)?
    static let fallback: @Sendable () throws -> URL? = { URL(fileURLWithPath: "/y") }
    static func requireOpt() throws -> URL {
        guard let u = try (optSendable ?? fallback)() else { throw CLIFailure.appNotInstalled() }
        return u
    }
}

struct ScratchSegvTests {
    // 1: the original shape, real type
    @Test func s1_original() {
        MarsDawnApp.$locateOverride.withValue({ nil }) {
            #expect { _ = try MarsDawnApp.require() } throws: { ($0 as? CLIFailure)?.code == .appNotInstalled }
        }
    }
    // 2: real type, plain do/catch, no #expect closure
    @Test func s2_realDoCatch() {
        var code: Int32 = -1
        MarsDawnApp.$locateOverride.withValue({ nil }) {
            do { _ = try MarsDawnApp.require() } catch { code = 1 }
        }
        #expect(code == 1)
    }
    // 3: real type, never call require, only enter and leave withValue
    @Test func s3_realEnterLeave() {
        let r = MarsDawnApp.$locateOverride.withValue({ nil }) { 7 }
        #expect(r == 7)
    }
    // 4: real type, read the task local inside without calling it
    @Test func s4_realReadInside() {
        let r = MarsDawnApp.$locateOverride.withValue({ nil }) { MarsDawnApp.locateOverride != nil }
        #expect(r)
    }
    // 5: real type, async withValue
    @Test func s5_realAsync() async {
        await MarsDawnApp.$locateOverride.withValue({ nil }) {
            #expect { _ = try MarsDawnApp.require() } throws: { ($0 as? CLIFailure)?.code == .appNotInstalled }
        }
    }
    // 6: local optional @Sendable closure, sync, called through ??
    @Test func s6_localOptSendable() {
        Scratch.$optSendable.withValue({ nil }) {
            #expect { _ = try Scratch.requireOpt() } throws: { ($0 as? CLIFailure)?.code == .appNotInstalled }
        }
    }
    // 7: local optional non-closure (control: not a closure), enter and leave
    @Test func s7_localOptPlain() {
        let r = Scratch.$optPlain.withValue(.some(nil)) { 7 }
        #expect(r == 7)
    }
    // 8: local non-optional closure, sync
    @Test func s8_localNonOpt() throws {
        let u = try Scratch.$nonOpt.withValue({ nil }) { try Scratch.nonOpt() }
        #expect(u == nil)
    }
    // 9: local boxed in a struct, sync
    @Test func s9_localBoxed() throws {
        let u = try Scratch.$boxed.withValue(Scratch.Box(f: { nil })) { try Scratch.boxed!.f() }
        #expect(u == nil)
    }
    // 10: real type, require() outside any withValue (the default locate, MARSDAWN_APP_PATH pinned)
    @Test func s10_realNoOverride() {
        #expect { _ = try MarsDawnApp.require() } throws: { ($0 as? CLIFailure)?.code == .appNotInstalled }
    }
    // 11: local optional @Sendable closure, sync, enter and leave only
    @Test func s11_localOptSendableEnterLeave() {
        let r = Scratch.$optSendable.withValue({ nil }) { 7 }
        #expect(r == 7)
    }

    // 12: real type, sync, CAPTURING closure
    @Test func s12_realCapturing() {
        let u = URL(fileURLWithPath: "/x")
        let r = MarsDawnApp.$locateOverride.withValue({ u }) { 7 }
        #expect(r == 7)
    }
    // 13: real type, async, capturing closure
    @Test func s13_realAsyncCapturing() async {
        let u = URL(fileURLWithPath: "/x")
        let r = await MarsDawnApp.$locateOverride.withValue({ u }) { 7 }
        #expect(r == 7)
    }
    // 14: real type, sync, non-capturing closure held in a let first
    @Test func s14_realLetClosure() {
        let f: @Sendable () throws -> URL? = { nil }
        let r = MarsDawnApp.$locateOverride.withValue(f) { 7 }
        #expect(r == 7)
    }
    // 15: local non-throwing optional closure, non-capturing
    @Test func s15_nonThrowing() {
        let r = Scratch.$nonThrowing.withValue({ nil }) { 7 }
        #expect(r == 7)
    }
    // 16: local Int closure, non-capturing
    @Test func s16_intClosure() {
        let r = Scratch.$intClosure.withValue({ 1 }) { 7 }
        #expect(r == 7)
    }
    // 17: local Void closure, non-capturing
    @Test func s17_voidClosure() {
        let r = Scratch.$voidClosure.withValue({ }) { 7 }
        #expect(r == 7)
    }
    // 18: local Int closure, capturing
    @Test func s18_intClosureCapturing() {
        let k = Int.random(in: 1...2)
        let r = Scratch.$intClosure.withValue({ k }) { 7 }
        #expect(r == 7)
    }
    // 19: the existing capturing-closure shape used by SkillHintTests/CLIContractTests (async, real)
    @Test func s19_realAsyncCapturingThenRequire() async throws {
        let u = URL(fileURLWithPath: "/x")
        let got = try await MarsDawnApp.$locateOverride.withValue({ u }) { try MarsDawnApp.require() }
        #expect(got == u)
    }
}
#endif
