import AppKit
import Foundation
import notify
import Security

// PLAN #69 slice 0 (feasibility spike, never merged, never released): proves a signed, sandboxed
// MarsDawn copy can deliver a Darwin notification, keyed by a one-time token, that this separate,
// unsandboxed process receives, and that a custom `'mdRq'` keyword survives on a folder open
// event sent through `NSWorkspace.open(... configuration.appleEvent)`.
//
// Usage: spike69notify <app-path> <folder-path>
// Prints only the resulting code on stdout (an unsigned integer), or "none" if the state never
// left 0 within the 10 s wait. The token itself is never printed here, except when
// SPIKE69_DEBUG_TOKEN_FILE is set (the harness's own debug seam), which is the one place this
// spike writes it to disk.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard CommandLine.arguments.count >= 3 else {
    fail("usage: spike69notify <app-path> <folder-path>", code: 64)
}

let appURL = URL(fileURLWithPath: CommandLine.arguments[1])
let folderURL = URL(fileURLWithPath: CommandLine.arguments[2])

/// 16 random bytes as lowercase hex (plan L1: `SecRandomCopyBytes`).
func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else { fail("token generation failed (\(status))") }
    return bytes.map { String(format: "%02x", $0) }.joined()
}

let token = randomToken()
let name = "dev.southern-light.marsdawn.folder.\(token)"

if let debugPath = ProcessInfo.processInfo.environment["SPIKE69_DEBUG_TOKEN_FILE"] {
    try? token.write(toFile: debugPath, atomically: true, encoding: .utf8)
}

// Plan [P7]: register before sending.
var notifyToken: Int32 = 0
let registerStatus = notify_register_check(name, &notifyToken)
guard registerStatus == NOTIFY_STATUS_OK else {
    fail("register_failed status=\(registerStatus)")
}

// 'mdRq': typeUTF8Text, exactly 32 bytes (the hex token itself).
let requestKeyword: AEKeyword = 0x6D64_5271 // 'mdRq'
let event = NSAppleEventDescriptor.appleEvent(
    withEventClass: AEEventClass(kCoreEventClass),
    eventID: AEEventID(kAEOpenDocuments),
    targetDescriptor: nil,
    returnID: AEReturnID(kAutoGenerateReturnID),
    transactionID: AETransactionID(kAnyTransactionID)
)
let list = NSAppleEventDescriptor.list()
list.insert(NSAppleEventDescriptor(fileURL: folderURL), at: 1)
event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
let tokenData = Data(token.utf8)
guard let tokenDescriptor = tokenData.withUnsafeBytes({ buffer in
    NSAppleEventDescriptor(descriptorType: DescType(typeUTF8Text), bytes: buffer.baseAddress, length: buffer.count)
}) else {
    notify_cancel(notifyToken)
    fail("could not build the token descriptor")
}
event.setParam(tokenDescriptor, forKeyword: requestKeyword)

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = true
configuration.appleEvent = event

do {
    _ = try await NSWorkspace.shared.open([folderURL], withApplicationAt: appURL, configuration: configuration)
} catch {
    notify_cancel(notifyToken)
    fail("open_failed: \(error)")
}

// Plan L4: the deadline starts after NSWorkspace.open returns (a cold launch isn't counted).
let deadline = Date().addingTimeInterval(10)
var sawFirstCheck = false
var code: UInt64 = 0
while Date() < deadline {
    var checkResult: Int32 = 0
    let checkStatus = notify_check(notifyToken, &checkResult)
    if checkStatus == NOTIFY_STATUS_OK, checkResult != 0 {
        if !sawFirstCheck {
            // Plan L4: the first notify_check true is ignored (registration itself coalesces to
            // "changed"). Every wake after that reads the state and decides by its value.
            sawFirstCheck = true
        } else {
            var state: UInt64 = 0
            notify_get_state(notifyToken, &state)
            if state != 0 {
                code = state
                break
            }
        }
    }
    usleep(50_000)
}
if code == 0 {
    // Also read state once more directly, in case the only post coalesced with registration's
    // own coalesced "changed" flag (single-post cases can land on the first check).
    var state: UInt64 = 0
    if notify_get_state(notifyToken, &state) == NOTIFY_STATUS_OK, state != 0 {
        code = state
    }
}
notify_cancel(notifyToken)
print(code == 0 ? "none" : String(code))
