#if os(macOS)
import AppKit
import Darwin
import Foundation
import Testing
import WebKit
@testable import MarsDawnKit
import MarsDawnThemes

// kit #126 (plan S3): the theme registry -- built-ins plus validated installed themes -- and the
// security-review dispositions it carries: M3 (registry part), L2 (registry), L4, L5 and the
// line-119 fixtures. Every test builds its own `ThemeRegistry`; none touches `.shared`, so tests
// running at the same time keep seeing the built-ins.

/// A scratch folder of installed themes, `<root>/<folder>/theme.json`, removed afterwards.
final class InstalledThemes {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("theme-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func folder(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    @discardableResult
    func add(_ folder: String, _ data: Data) throws -> URL {
        let dir = self.folder(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("theme.json")
        try data.write(to: file)
        return file
    }

    /// A built-in's `theme.json` with `id` in place of its own, edited by `edit`.
    static func theme(_ id: String, from base: String = "dawn", _ edit: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let url = try #require(ThemeDocumentLoader.builtInURL(id: base))
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["id"] = id
        edit(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Sets `object[path[0]][path[1]]… = value` (`nil` removes it).
    static func set(_ object: inout [String: Any], _ path: [String], _ value: Any?) {
        guard let first = path.first else { return }
        if path.count == 1 {
            object[first] = value
            return
        }
        var inner = object[first] as? [String: Any] ?? [:]
        set(&inner, Array(path.dropFirst()), value)
        object[first] = inner
    }

    @discardableResult
    func load(into registry: ThemeRegistry, revokedIDs: Set<String> = [], revokedAuthors: Set<String> = []) -> [PreviewTheme] {
        registry.loadInstalled(from: root, revokedIDs: revokedIDs, revokedAuthors: revokedAuthors)
    }

    func scan(revokedIDs: Set<String> = [], revokedAuthors: Set<String> = []) -> ThemeRegistry.ScanResult {
        ThemeRegistry.scan(directory: root, revokedIDs: revokedIDs, revokedAuthors: revokedAuthors)
    }
}

private let builtInIDs = ["dawn", "classic", "modern", "vivid"]
private let builtInThemes: [PreviewTheme] = [.dawn, .classic, .modern, .vivid]

// MARK: - Order, valid/invalid, fallback, partial fill; no directory

@Suite(.timeLimit(.minutes(1)))
struct ThemeRegistryTests {
    @Test func withNoDirectoryTheRegistryIsTheBuiltInsByteForByte() throws {
        let registry = ThemeRegistry()
        let snapshot = registry.snapshot
        #expect(snapshot.themes.map(\.id) == builtInIDs)
        #expect(snapshot.themes == builtInThemes)
        // What the served stylesheets were before the registry: generated from the four built-ins.
        #expect(snapshot.variablesCSS == PreviewTheme.stylesheet(for: builtInThemes))
        #expect(snapshot.rulesCSS == PreviewTheme.generatedStyleCSS(for: builtInThemes))
        #expect(!snapshot.variablesCSS.isEmpty && !snapshot.rulesCSS.isEmpty, "positive fixture: the built-ins generate CSS")
        #expect(snapshot.partialIDs.isEmpty)
        #expect(ThemeRegistry.reservedIDs == Set(builtInIDs), "every built-in's id is reserved")
        // The process registry, which no test loads into, is the same.
        #expect(PreviewTheme.all.map(\.id) == builtInIDs)
        #expect(PreviewTheme.stylesheet == snapshot.variablesCSS)
        #expect(PreviewTheme.generatedStyleCSS == snapshot.rulesCSS)

        // A folder that doesn't exist leaves the built-ins, unchanged.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        #expect(registry.loadInstalled(from: missing).isEmpty)
        #expect(registry.snapshot.themes == builtInThemes)
        #expect(registry.snapshot.variablesCSS == snapshot.variablesCSS)
        #expect(registry.snapshot.rulesCSS == snapshot.rulesCSS)
    }

    @Test func builtInsComeFirstInTheirOrderThenInstalledThemesByID() throws {
        let dir = try InstalledThemes()
        for id in ["zeta", "alpha-one", "mid", "alpha"] { try dir.add(id, InstalledThemes.theme(id)) }
        let registry = ThemeRegistry()
        let installed = dir.load(into: registry)
        #expect(installed.map(\.id) == ["alpha", "alpha-one", "mid", "zeta"])
        #expect(registry.snapshot.themes.map(\.id) == builtInIDs + ["alpha", "alpha-one", "mid", "zeta"])
        #expect(registry.snapshot.themes.prefix(4) == builtInThemes[...])
        for id in ["alpha", "alpha-one", "mid", "zeta"] {
            #expect(registry.snapshot.variablesCSS.contains(#":root[data-theme="\#(id)"]"#))
            #expect(registry.snapshot.rulesCSS.contains(#"[data-theme="\#(id)"] hr"#))
        }
        // The built-ins' own CSS is still there, first and unchanged.
        #expect(registry.snapshot.variablesCSS.hasPrefix(ThemeRegistry.builtIns.variablesCSS))
        #expect(registry.snapshot.rulesCSS.hasPrefix(ThemeRegistry.builtIns.rulesCSS))
    }

    @Test func anInstalledThemeIsNamedByItsOwnFileNotTheStringTable() throws {
        let dir = try InstalledThemes()
        try dir.add("dusk", InstalledThemes.theme("dusk") { object in
            object["name"] = ["en": "Olympus Dusk"]
            object["summary"] = ["en": "Cool violet dusk"]
        })
        let registry = ThemeRegistry()
        let theme = try #require(dir.load(into: registry).first)
        #expect(theme.id == "dusk")
        #expect(theme.name == "Olympus Dusk")
        #expect(theme.summary == "Cool violet dusk")
    }

    @Test func anInvalidThemeIsDroppedAndItsNeighboursKept() throws {
        let dir = try InstalledThemes()
        try dir.add("good", InstalledThemes.theme("good"))
        try dir.add("bad-colour", InstalledThemes.theme("bad-colour") { InstalledThemes.set(&$0, ["light", "background"], "red") })
        try dir.add("bad-json", Data("{ not json".utf8))
        try dir.add("unknown-key", InstalledThemes.theme("unknown-key") { $0["css"] = "body { color: red }" })
        try dir.add("future", InstalledThemes.theme("future") { $0["schemaVersion"] = 2 })
        try FileManager.default.createDirectory(at: dir.folder("empty"), withIntermediateDirectories: true)
        let registry = ThemeRegistry()
        #expect(dir.load(into: registry).map(\.id) == ["good"])
        let scan = dir.scan()
        #expect(scan.dropped["bad-colour"] == .invalid(rule: "color.hex"))
        #expect(scan.dropped["bad-json"] == .invalid(rule: "json.malformed"))
        #expect(scan.dropped["unknown-key"] == .invalid(rule: "schema.unknownKey"))
        #expect(scan.dropped["future"] == .invalid(rule: "schema.version"))
        #expect(scan.dropped["empty"] == .unreadable)
        for id in ["bad-colour", "bad-json", "unknown-key", "future"] {
            #expect(!registry.snapshot.variablesCSS.contains(#""\#(id)""#))
            #expect(!registry.snapshot.rulesCSS.contains(#""\#(id)""#))
        }
    }

    @Test func anUnknownIDFallsBackToDawn() throws {
        let dir = try InstalledThemes()
        try dir.add("mine", InstalledThemes.theme("mine"))
        let registry = ThemeRegistry()
        dir.load(into: registry)
        #expect(registry.snapshot.named("mine").id == "mine", "positive fixture: an installed id resolves")
        #expect(registry.snapshot.named("classic") == .classic)
        #expect(registry.snapshot.named("nope") == .dawn)
        #expect(registry.snapshot.named(nil) == .dawn)
        // Revoked since: the same id now falls back.
        dir.load(into: registry, revokedIDs: ["mine"])
        #expect(registry.snapshot.named("mine") == .dawn)
        // And the process-wide lookup still falls back the same way.
        #expect(PreviewTheme.named("mine") == .dawn)
    }

    /// Design §7.3 / #126: a file without `syntax`/`diagram` gets Dawn's colours for the same
    /// appearance -- which `ThemeValidator` fills inside `ValidatedTheme` (kit #125) -- and is
    /// marked partial. Built on Classic, whose own syntax and diagram colours differ from Dawn's,
    /// so a fill is visible.
    @Test func aPartialThemeIsFilledFromDawnOfTheSameAppearance() throws {
        let dir = try InstalledThemes()
        try dir.add("whole", InstalledThemes.theme("whole", from: "classic"))
        try dir.add("bare", InstalledThemes.theme("bare", from: "classic") { object in
            for mode in ["light", "dark"] {
                InstalledThemes.set(&object, [mode, "syntax"], nil)
                InstalledThemes.set(&object, [mode, "diagram"], nil)
            }
        })
        try dir.add("half", InstalledThemes.theme("half", from: "classic") { object in
            InstalledThemes.set(&object, ["dark", "diagram"], nil)
        })
        let registry = ThemeRegistry()
        let installed = Dictionary(uniqueKeysWithValues: dir.load(into: registry).map { ($0.id, $0) })
        let whole = try #require(installed["whole"])
        let bare = try #require(installed["bare"])
        let half = try #require(installed["half"])

        // Positive fixture: Classic's own colours differ from Dawn's in every group checked.
        #expect(whole.light.syntax != PreviewTheme.dawn.light.syntax)
        #expect(whole.dark.diagram != PreviewTheme.dawn.dark.diagram)

        #expect(bare.light.syntax == PreviewTheme.dawn.light.syntax)
        #expect(bare.light.diagram == PreviewTheme.dawn.light.diagram)
        #expect(bare.dark.syntax == PreviewTheme.dawn.dark.syntax)
        #expect(bare.dark.diagram == PreviewTheme.dawn.dark.diagram)
        #expect(bare.light.background == whole.light.background, "the base colours stay the file's own")

        #expect(half.light.diagram == whole.light.diagram)
        #expect(half.dark.syntax == whole.dark.syntax)
        #expect(half.dark.diagram == PreviewTheme.dawn.dark.diagram)

        #expect(registry.snapshot.partialIDs == ["bare", "half"])
        // The filled colours are what the page gets.
        #expect(registry.snapshot.variablesCSS.contains(#":root[data-theme="bare"]"#))
    }

    @Test func aMissingBaseColourMakesTheThemeInvalid() throws {
        let dir = try InstalledThemes()
        try dir.add("no-accent", InstalledThemes.theme("no-accent") { InstalledThemes.set(&$0, ["light", "accent"], nil) })
        #expect(dir.scan().dropped["no-accent"] == .invalid(rule: "schema.missing"))
        #expect(dir.scan().installed.isEmpty)
    }
}

// MARK: - Line-119 fixtures, M3, L5

@Suite(.timeLimit(.minutes(1)))
struct ThemeRegistrySecurityTests {
    /// Plan line 119: an id carrying CSS syntax and an out-of-range number never reach the CSS.
    @Test func anIDWithCSSSyntaxAndAnOutOfRangeNumberAreDropped() throws {
        let dir = try InstalledThemes()
        let hostileID = #"evil"]{}"#
        try dir.add(hostileID, InstalledThemes.theme(hostileID))
        try dir.add("evil", InstalledThemes.theme(hostileID))
        try dir.add("wide", InstalledThemes.theme("wide") { InstalledThemes.set(&$0, ["style", "radius"], 999) })
        // Positive fixture: the same file with an in-range radius is accepted and emits it.
        try dir.add("narrow", InstalledThemes.theme("narrow") { InstalledThemes.set(&$0, ["style", "radius"], 7) })

        let registry = ThemeRegistry()
        #expect(dir.load(into: registry).map(\.id) == ["narrow"])
        let css = registry.snapshot.variablesCSS + registry.snapshot.rulesCSS
        #expect(css.contains("--radius: 7px;"))
        #expect(!css.contains(#""]{}"#))
        #expect(!css.contains("999px"))
        #expect(!css.contains(#""evil"#) && !css.contains(#""wide""#))
        let scan = dir.scan()
        #expect(scan.dropped["evil"] == .invalid(rule: "id.pattern"))
        #expect(scan.dropped["wide"] == .invalid(rule: "number.range"))
    }

    /// M3: a built-in's id can't be taken over -- not by a folder named after it, not by any
    /// other folder declaring it -- and an id two folders declare is dropped from both.
    static func hostileInstalls() throws -> InstalledThemes {
        let dir = try InstalledThemes()
        try dir.add("classic", InstalledThemes.theme("classic") { InstalledThemes.set(&$0, ["light", "background"], "#FFFFFF") })
        try dir.add("x", InstalledThemes.theme("classic") { InstalledThemes.set(&$0, ["style", "radius"], 16) })
        try dir.add("twin-a", InstalledThemes.theme("twin-a"))
        try dir.add("twin-b", InstalledThemes.theme("twin-a"))
        try dir.add("folder-y", InstalledThemes.theme("other-id"))
        return dir
    }

    @Test func aTakeoverOfABuiltInOrADuplicatedIDIsDropped() throws {
        let dir = try Self.hostileInstalls()
        let registry = ThemeRegistry()
        #expect(dir.load(into: registry).isEmpty)
        let scan = dir.scan()
        #expect(scan.dropped["classic"] == .reservedID)
        #expect(scan.dropped["x"] == .reservedID)
        #expect(scan.dropped["twin-a"] == .duplicateID)
        #expect(scan.dropped["twin-b"] == .duplicateID)
        #expect(scan.dropped["folder-y"] == .folderMismatch)
        // Exactly the built-ins, byte for byte, in both served stylesheets.
        #expect(registry.snapshot.themes == builtInThemes)
        #expect(registry.snapshot.variablesCSS == ThemeRegistry.builtIns.variablesCSS)
        #expect(registry.snapshot.rulesCSS == ThemeRegistry.builtIns.rulesCSS)
        #expect(registry.snapshot.rulesCSS.components(separatedBy: #"[data-theme="classic"]"#).count
            == ThemeRegistry.builtIns.rulesCSS.components(separatedBy: #"[data-theme="classic"]"#).count)
        #expect(registry.snapshot.named("classic") == .classic)

        // Positive fixture: each file is itself a valid theme -- only the registry's rules drop it.
        for folder in ["classic", "x", "twin-a", "twin-b", "folder-y"] {
            let data = try Data(contentsOf: dir.folder(folder).appendingPathComponent("theme.json"))
            #expect(ThemeValidator.validate(data: data).theme != nil, "\(folder)")
        }
    }

    /// L5: revocation takes installed themes out by id or by author, and never a built-in.
    @Test func revocationDropsInstalledThemesByIDOrAuthorButNeverABuiltIn() throws {
        let dir = try InstalledThemes()
        try dir.add("kept", InstalledThemes.theme("kept") { $0["author"] = ["name": "Someone", "github": "someone"] })
        try dir.add("by-id", InstalledThemes.theme("by-id"))
        try dir.add("by-author", InstalledThemes.theme("by-author") { $0["author"] = ["name": "Jane", "github": "janedoe"] })
        let registry = ThemeRegistry()
        let installed = dir.load(into: registry, revokedIDs: ["dawn", "classic", "modern", "vivid", "by-id"], revokedAuthors: ["JaneDoe"])
        #expect(installed.map(\.id) == ["kept"])
        #expect(registry.snapshot.themes.map(\.id) == builtInIDs + ["kept"])
        #expect(registry.snapshot.named("dawn") == .dawn)
        #expect(registry.snapshot.variablesCSS.hasPrefix(ThemeRegistry.builtIns.variablesCSS))
        #expect(registry.snapshot.rulesCSS.hasPrefix(ThemeRegistry.builtIns.rulesCSS))
        let scan = dir.scan(revokedIDs: ["by-id"], revokedAuthors: ["JaneDoe"])
        #expect(scan.dropped["by-id"] == .revokedID)
        #expect(scan.dropped["by-author"] == .revokedAuthor)
        // Positive fixture: with nothing revoked, all three load.
        #expect(dir.scan().installed.map(\.id) == ["by-author", "by-id", "kept"])
    }
}

// MARK: - L2: file rules and the cap

@Suite(.timeLimit(.minutes(2)))
struct ThemeRegistryFileTests {
    @Test func symlinksAreDroppedUnread() throws {
        let dir = try InstalledThemes()
        let elsewhere = try InstalledThemes()
        let target = try elsewhere.add("linked", InstalledThemes.theme("linked"))
        try elsewhere.add("linkdir", InstalledThemes.theme("linkdir"))
        // A real folder whose theme.json is a symlink to a valid file.
        try FileManager.default.createDirectory(at: dir.folder("linked"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: dir.folder("linked").appendingPathComponent("theme.json"), withDestinationURL: target)
        // A symlink to a real folder holding a valid theme.json.
        try FileManager.default.createSymbolicLink(at: dir.folder("linkdir"), withDestinationURL: elsewhere.folder("linkdir"))
        // Positive fixture: the same bytes as a real file in a real folder load.
        try dir.add("real", InstalledThemes.theme("real"))

        let scan = dir.scan()
        #expect(scan.installed.map(\.id) == ["real"])
        #expect(scan.dropped["linked"] == .unreadable)
        #expect(scan.dropped["linkdir"] == .notAFolder)
        #expect(elsewhere.scan().installed.map(\.id) == ["linkdir", "linked"], "positive fixture: the link targets are valid themes")
    }

    @Test func aFIFOOrAnOversizedFileIsDroppedWithoutBlocking() throws {
        let dir = try InstalledThemes()
        try FileManager.default.createDirectory(at: dir.folder("pipe"), withIntermediateDirectories: true)
        #expect(mkfifo(dir.folder("pipe").appendingPathComponent("theme.json").path, 0o600) == 0)
        var big = try InstalledThemes.theme("big")
        big.append(Data(repeating: UInt8(ascii: " "), count: ThemeValidator.maxFileBytes + 1 - big.count))
        #expect(big.count == ThemeValidator.maxFileBytes + 1)
        try dir.add("big", big)
        var fits = try InstalledThemes.theme("fits")
        fits.append(Data(repeating: UInt8(ascii: " "), count: ThemeValidator.maxFileBytes - fits.count))
        try dir.add("fits", fits)

        let start = ContinuousClock.now
        let scan = dir.scan()
        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(scan.dropped["pipe"] == .unreadable)
        #expect(scan.dropped["big"] == .invalid(rule: "file.tooLarge"))
        #expect(scan.installed.map(\.id) == ["fits"], "positive fixture: exactly the cap loads")
    }

    @Test func the201stThemeIsIgnored() throws {
        let dir = try InstalledThemes()
        let ids = (0...ThemeRegistry.maxInstalled).map { String(format: "t%03d", $0) }
        #expect(ids.count == 201)
        for id in ids { try dir.add(id, InstalledThemes.theme(id)) }
        let registry = ThemeRegistry()
        let installed = dir.load(into: registry)
        #expect(installed.count == 200)
        #expect(installed.map(\.id) == Array(ids.prefix(200)))
        #expect(registry.snapshot.themes.count == 204)
        let scan = dir.scan()
        #expect(scan.dropped == ["t200": .overLimit], "the one over the limit is ignored and recorded for the log line")
        #expect(!registry.snapshot.variablesCSS.contains(#""t200""#))
    }
}

// MARK: - L4: one read, one snapshot per page load

@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct ThemeRegistrySnapshotTests {
    private static func serve(_ handler: PreviewSchemeHandler, _ path: String) -> String {
        let task = FakeSchemeTask(url: URL(string: "marsdawn-app://preview/\(path)")!)
        handler.webView(WKWebView(), start: task)
        return String(decoding: task.body, as: UTF8.self)
    }

    private static func href(_ name: String, in page: String) throws -> String {
        let start = try #require(page.range(of: "href=\"\(name)"))
        return String(page[start.lowerBound...].dropFirst(6).prefix { $0 != "\"" })
    }

    /// A theme whose light background is `background`.
    private static func tinted(_ id: String, _ background: String) throws -> Data {
        try InstalledThemes.theme(id) { InstalledThemes.set(&$0, ["light", "background"], background) }
    }

    @Test func aFileChangedOnDiskAfterLoadingChangesNothingServed() throws {
        let dir = try InstalledThemes()
        let file = try dir.add("mine", Self.tinted("mine", "#FFFDFA"))
        let registry = ThemeRegistry()
        dir.load(into: registry)
        let handler = ThemeRegistry.$override.withValue(registry) { PreviewSchemeHandler() }
        let page = Self.serve(handler, "index.html?theme=mine")
        let themesBefore = Self.serve(handler, try Self.href("themes.css", in: page))
        let rulesBefore = Self.serve(handler, try Self.href("preview.css", in: page))
        #expect(themesBefore.contains("--bg: #FFFDFA;"))

        try Self.tinted("mine", "#FFFEF0").write(to: file)

        let again = Self.serve(handler, "index.html?theme=mine")
        #expect(Self.serve(handler, try Self.href("themes.css", in: again)) == themesBefore)
        #expect(Self.serve(handler, try Self.href("preview.css", in: again)) == rulesBefore)
        #expect(registry.snapshot.named("mine").light.background == "#FFFDFA")
        // Positive fixture: the change was real -- the next load picks it up.
        dir.load(into: registry)
        #expect(registry.snapshot.named("mine").light.background == "#FFFEF0")
        let reloaded = Self.serve(handler, "index.html?theme=mine")
        #expect(Self.serve(handler, try Self.href("themes.css", in: reloaded)).contains("--bg: #FFFEF0;"))
    }

    /// No directory passed: `index.html` is served exactly as before the registry (plain
    /// stylesheet links), and its stylesheets come from the built-ins even if the registry loads
    /// installed themes between the page and its stylesheet requests.
    @Test func aBuiltInsOnlyPageIsServedAsBeforeAndKeepsTheBuiltIns() throws {
        let dir = try InstalledThemes()
        try dir.add("late", Self.tinted("late", "#FFFDFA"))
        let registry = ThemeRegistry()
        let handler = ThemeRegistry.$override.withValue(registry) { PreviewSchemeHandler() }

        let url = URL(string: "marsdawn-app://preview/index.html?theme=dawn")!
        let page = Self.serve(handler, "index.html?theme=dawn")
        let raw = try Data(contentsOf: Self.previewFolderURL.appendingPathComponent("index.html"))
        #expect(page == String(decoding: PreviewSchemeHandler.page(raw, for: url), as: UTF8.self))
        #expect(try Self.href("themes.css", in: page) == "themes.css")
        #expect(try Self.href("preview.css", in: page) == "preview.css")

        // The registry changes between the page and its stylesheets.
        #expect(dir.load(into: registry).map(\.id) == ["late"])
        let themes = Self.serve(handler, "themes.css")
        let rules = Self.serve(handler, "preview.css")
        #expect(themes == ThemeRegistry.builtIns.variablesCSS)
        let rawCSS = try String(contentsOf: Self.previewFolderURL.appendingPathComponent("preview.css"), encoding: .utf8)
        #expect(rules == rawCSS.replacingOccurrences(of: PreviewSchemeHandler.themeRulesMarker, with: ThemeRegistry.builtIns.rulesCSS))
        #expect(!themes.contains(#""late""#) && !rules.contains(#""late""#))

        // Positive fixture: a page served now names the new snapshot, which has the new theme.
        let next = Self.serve(handler, "index.html?theme=late")
        #expect(try Self.href("themes.css", in: next) == "themes.css?snapshot=\(registry.snapshot.token)")
        #expect(Self.serve(handler, try Self.href("themes.css", in: next)).contains(#":root[data-theme="late"]"#))
        #expect(Self.serve(handler, try Self.href("preview.css", in: next)).contains(#"[data-theme="late"] hr"#))
    }

    /// A page served from a loaded snapshot names it; when the registry is swapped between that
    /// page and its two stylesheet requests, both still come from the page's snapshot.
    @Test func bothStylesheetsOfOnePageComeFromTheSnapshotItsPageWasServedFrom() throws {
        let first = try InstalledThemes()
        try first.add("before", Self.tinted("before", "#FFFDFA"))
        let second = try InstalledThemes()
        try second.add("after", Self.tinted("after", "#FFFEF0"))
        let registry = ThemeRegistry()
        let handler = ThemeRegistry.$override.withValue(registry) { PreviewSchemeHandler() }
        first.load(into: registry)
        let pinned = registry.snapshot

        let page = Self.serve(handler, "index.html?theme=before")
        let themesLink = try Self.href("themes.css", in: page)
        let rulesLink = try Self.href("preview.css", in: page)
        #expect(themesLink == "themes.css?snapshot=\(pinned.token)")
        #expect(rulesLink == "preview.css?snapshot=\(pinned.token)")

        // The registry is swapped between the page and its stylesheets.
        second.load(into: registry)
        #expect(registry.snapshot.token != pinned.token)
        let themes = Self.serve(handler, themesLink)
        let rules = Self.serve(handler, rulesLink)
        #expect(themes == pinned.variablesCSS)
        #expect(themes.contains(#":root[data-theme="before"]"#) && !themes.contains(#""after""#))
        #expect(rules.contains(#"[data-theme="before"] hr"#) && !rules.contains(#""after""#))

        // Positive fixture: the swapped-in snapshot really differs, and a new page gets it.
        let next = Self.serve(handler, "index.html?theme=after")
        let nextThemes = Self.serve(handler, try Self.href("themes.css", in: next))
        #expect(nextThemes.contains(#":root[data-theme="after"]"#) && !nextThemes.contains(#""before""#))
    }

    static let previewFolderURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview")

    /// The real page in WebKit: it asks for both stylesheets with the token its `index.html`
    /// carried, and an installed theme is actually drawn with its own colours.
    @Test func thePageRequestsBothStylesheetsWithItsTokenAndDrawsAnInstalledTheme() async throws {
        let dir = try InstalledThemes()
        try dir.add("drawn", Self.tinted("drawn", "#FFFEF0"))
        let registry = ThemeRegistry()
        #expect(dir.load(into: registry).map(\.id) == ["drawn"])
        let recorder = ThemeRegistry.$override.withValue(registry) { RegistryRecordingSchemeHandler() }
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(recorder, forURLScheme: PreviewSchemeHandler.scheme)
        configuration.websiteDataStore = .nonPersistent()
        let webView = PreviewWKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        webView.appearance = NSAppearance(named: .aqua)
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        _ = webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(theme: registry.snapshot.named("drawn"))))
        let deadline = ContinuousClock.now + .seconds(20)
        while webView.isLoading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }

        let token = registry.snapshot.token
        let requested = recorder.urls.map { "\($0.path)?\($0.query ?? "")" }
        #expect(requested.contains("/themes.css?snapshot=\(token)"), "\(requested)")
        #expect(requested.contains("/preview.css?snapshot=\(token)"), "\(requested)")
        let background = try await webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
        #expect(background == "rgb(255, 254, 240)")
        let theme = try await webView.evaluateJavaScript("document.documentElement.dataset.theme") as? String
        #expect(theme == "drawn")
    }
}

/// `PreviewSchemeHandler`, recording every URL it's asked for.
@MainActor
final class RegistryRecordingSchemeHandler: NSObject, WKURLSchemeHandler {
    private let inner = PreviewSchemeHandler()
    private(set) var urls: [URL] = []

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        if let url = urlSchemeTask.request.url { urls.append(url) }
        inner.webView(webView, start: urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

// MARK: - M3: the S1 golden with hostile installs present

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ThemeRegistryGoldenTests {
    /// The four built-ins render exactly as the S1 golden says while the hostile installs of
    /// `ThemeRegistrySecurityTests.hostileInstalls()` -- and one valid installed theme, which
    /// shows the installs were really in effect -- are loaded into the registry the pages use.
    @Test func theGoldenIsUnchangedWithHostileInstallsPresent() async throws {
        let dir = try ThemeRegistrySecurityTests.hostileInstalls()
        try dir.add("valid-one", InstalledThemes.theme("valid-one"))
        let registry = ThemeRegistry()
        #expect(dir.load(into: registry).map(\.id) == ["valid-one"])

        let captured = try await ThemeRegistry.$override.withValue(registry) {
            try await ThemeGoldenHarness.capture()
        }
        #expect(Set(captured.entries.map(\.theme)) == Set(builtInIDs + ["valid-one"]), "positive fixture: the installed theme was rendered too")

        let golden = try JSONDecoder().decode(GoldenSnapshot.self, from: Data(contentsOf: ThemeGoldenTests.goldenURL))
        let builtIn = captured.entries.filter { builtInIDs.contains($0.theme) }
        #expect(builtIn.count == golden.entries.count)
        var mismatches: [String] = []
        for entry in golden.entries {
            let key = GoldenKey(theme: entry.theme, mode: entry.mode, selector: entry.selector)
            guard let actual = captured[key] else {
                mismatches.append("\(entry.theme)/\(entry.mode)/\(entry.selector): missing")
                continue
            }
            for (property, expected) in entry.properties where actual[property] != expected {
                mismatches.append("\(entry.theme)/\(entry.mode)/\(entry.selector) \(property): got \(actual[property] ?? "<nil>"), want \(expected)")
            }
        }
        #expect(mismatches.isEmpty, Comment(rawValue: mismatches.joined(separator: "\n")))
    }
}
#endif
