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
}
#endif
