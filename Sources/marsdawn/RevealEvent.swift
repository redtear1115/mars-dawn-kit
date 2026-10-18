#if os(macOS)
import AppKit
import Foundation

/// The `aevt`/`odoc` Apple Event that `marsdawn open` hands to
/// `NSWorkspace.open(_:withApplicationAt:configuration:)` as `OpenConfiguration.appleEvent`.
///
/// The line rides inside the open-documents event itself rather than in a second message, so it
/// arrives with the files on a cold launch and on an already-running app, and the sandbox
/// extension that lets the app read those files travels with it. The app also handles
/// `marsdawn://open?path=…&line=N` links from version 1.0.0, but only for Markdown files inside
/// folders already open in its sidebar, because a link carries no sandbox extension; `open`
/// never sends one.
///
/// The line applies to *every* file in the event, which is why `marsdawn open` only ever puts
/// files that asked for the same line into one event.
enum RevealEvent {
    /// Our own keyword for the line, `'mdLn'`, sent beside `keyAEPosition` as an Int32.
    ///
    /// `keyAEPosition` is the keyword other editors read, so we send it as well. Other senders
    /// put a 32-byte SelectionRange record there instead of a number, so the app should treat a
    /// non-Int32 `keyAEPosition` as absent and prefer `'mdLn'`, which only this tool sends.
    static let lineKeyword = AEKeyword(fourCharCode: "mdLn")

    /// Files that open together, all landing on `line` when one was asked for.
    struct Group: Equatable {
        var urls: [URL]
        var line: Int?
    }

    /// Splits targets into the events they travel in: neighbours asking for the same line share
    /// one event, so `a.md b.md` is still a single open and `a.md:1 b.md:99` is two.
    static func groups(for targets: [OpenTarget]) -> [Group] {
        var groups: [Group] = []
        for target in targets {
            if let last = groups.last, last.line == target.line {
                groups[groups.count - 1].urls.append(target.url)
            } else {
                groups.append(Group(urls: [target.url], line: target.line))
            }
        }
        return groups
    }

    /// Builds the event: the direct object is the file-URL list, and the line goes in both
    /// `keyAEPosition` and `'mdLn'`. Returns nil when no line was asked for, so that open keeps
    /// using the event AppKit builds for it, exactly as before.
    static func openDocuments(urls: [URL], line: Int?) -> NSAppleEventDescriptor? {
        guard let line, let position = Int32(exactly: line) else { return nil }
        let event = NSAppleEventDescriptor.appleEvent(
            withEventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenDocuments),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        let list = NSAppleEventDescriptor.list()
        for (offset, url) in urls.enumerated() {
            list.insert(NSAppleEventDescriptor(fileURL: url), at: offset + 1)
        }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        event.setParam(NSAppleEventDescriptor(int32: position), forKeyword: AEKeyword(keyAEPosition))
        event.setParam(NSAppleEventDescriptor(int32: position), forKeyword: lineKeyword)
        return event
    }
}

extension AEKeyword {
    /// The four ASCII characters of an Apple Event keyword, as the code they name.
    init(fourCharCode code: StaticString) {
        var value: UInt32 = 0
        code.withUTF8Buffer { bytes in
            precondition(bytes.count == 4, "a four-character code is four ASCII bytes")
            for byte in bytes {
                value = value << 8 | UInt32(byte)
            }
        }
        self = value
    }
}
#endif
