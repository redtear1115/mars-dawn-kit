import Foundation
import os
import MarsDawnThemes

/// The themes a preview can use: the four built-ins, in their fixed order, then the installed
/// themes the host has loaded from a directory (kit #126, design §4.4).
///
/// A host that never calls `loadInstalled` sees exactly the built-ins, and the served stylesheets
/// are byte-identical to what they were before the registry existed. The CLI resolves `--theme`
/// against the built-ins only (design §7.4), whatever the process registry holds.
///
/// **Every load validates every file** (security review M3, L2, L4, L5; design §7.2 -- the
/// container is writable by the app, so the Quick Look extension re-checks what it reads, and the
/// app re-checks on every launch, not only when a theme is installed). `loadInstalled` only reads:
/// it never writes, moves or deletes anything, so the Quick Look extension can call it on the
/// shared container.
///
/// What is read and how:
///
/// - The layout is `<directory>/<id>/theme.json`. Only direct subfolders whose **name** passes
///   `ThemeGrammar.isThemeID` are opened; anything else in `<directory>` is ignored unread.
/// - A subfolder and its `theme.json` are checked with `lstat` semantics and opened with
///   `O_NOFOLLOW`, relative to the already-open parent (`openat`), then re-checked with `fstat`
///   against what `lstat` saw: a symlinked folder or file, a FIFO, a device or anything else that
///   is not a plain folder holding a plain file is dropped without being read.
/// - A file is read **once** into memory, at most `ThemeValidator.maxFileBytes` + 1 bytes (one
///   more is refused as too large), validated from those bytes by `ThemeValidator`, and the
///   theme's colours and CSS come from that one `ValidatedTheme` (L4). Nothing re-reads the file.
/// - A theme's id comes from the validated file, never from its folder. The folder's name must
///   equal the id (M3), the id must not be a built-in's (reserved), must not be revoked, and must
///   not be claimed by any other folder -- if two folders' files declare the same id, **every**
///   folder claiming it is dropped, so the outcome doesn't depend on the order folders are listed.
/// - A theme by a revoked author (`author.github`, compared ignoring ASCII case) is dropped.
///   Revocation never touches a built-in (L5).
/// - At most `maxInstalled` themes are accepted, in ascending order of id; the rest are ignored
///   with a log line (L2).
///
/// A theme whose file leaves `syntax` or `diagram` out gets Dawn's colours for the same
/// appearance -- `ThemeValidator` fills them inside `ValidatedTheme` -- and is listed in the
/// snapshot's `partialIDs`.
///
/// Each load produces one immutable `Snapshot`, with its CSS generated once. The preview scheme
/// handler pins the snapshot current when it serves `index.html` and serves that same snapshot's
/// `themes.css` and spliced `preview.css` to the page, so one page never mixes two registries.
/// While the registry holds just the built-ins, pages are served exactly as before it existed.
public final class ThemeRegistry: Sendable {
    /// The process's registry: `PreviewTheme.all`, `PreviewTheme.named(_:)`, the served
    /// stylesheets and PDF export read it. The app loads its installed themes into this one.
    public static let shared = ThemeRegistry()

    /// L2: the most installed themes one load accepts.
    package static let maxInstalled = 200

    /// The built-ins' ids: reserved, never loaded from a directory, never revoked.
    package static let reservedIDs: Set<String> = ["dawn", "classic", "modern", "vivid"]

    private let state: OSAllocatedUnfairLock<Snapshot>

    package init() {
        state = OSAllocatedUnfairLock(initialState: Self.builtIns)
    }

    /// The current snapshot. Immutable: a later `loadInstalled` replaces it, never changes it.
    package var snapshot: Snapshot { state.withLock { $0 } }

    /// Replaces the installed themes with those found in `directory` (design §4.4, §5.3), and
    /// returns them in the order they are listed after the built-ins. A missing or unreadable
    /// `directory` leaves just the built-ins. Safe to call from any thread; only reads the disk.
    ///
    /// - Parameters:
    ///   - directory: The folder holding one `<id>/theme.json` per installed theme.
    ///   - revokedIDs: Theme ids to drop (the index's `revoked` list). A built-in's id is ignored.
    ///   - revokedAuthors: GitHub usernames whose themes are dropped, compared ignoring ASCII case.
    @discardableResult
    public func loadInstalled(from directory: URL, revokedIDs: Set<String> = [], revokedAuthors: Set<String> = []) -> [PreviewTheme] {
        let scan = Self.scan(directory: directory, revokedIDs: revokedIDs, revokedAuthors: revokedAuthors)
        let next = Snapshot(themes: Self.builtIns.themes + scan.installed, partialIDs: scan.partialIDs)
        state.withLock { $0 = next }
        return scan.installed
    }

    // MARK: - Snapshot

    /// One immutable view of the registry, with the CSS generated from it once (L4, L2).
    package final class Snapshot: Sendable {
        /// Distinct for every snapshot in the process; how a served page names the snapshot its
        /// `index.html` was served from.
        package let token: UInt64
        /// Built-ins first, in their fixed order, then the installed themes by id.
        package let themes: [PreviewTheme]
        /// Installed themes whose file left out `syntax` or `diagram` (filled from Dawn).
        package let partialIDs: Set<String>
        /// `themes.css`: every theme's palette block.
        package let variablesCSS: String
        /// The per-theme rules spliced into `preview.css`.
        package let rulesCSS: String

        init(themes: [PreviewTheme], partialIDs: Set<String>) {
            token = Self.nextToken.withLock { value in
                value += 1
                return value
            }
            self.themes = themes
            self.partialIDs = partialIDs
            variablesCSS = PreviewTheme.stylesheet(for: themes)
            rulesCSS = PreviewTheme.generatedStyleCSS(for: themes)
        }

        /// The theme with `id`, or Dawn.
        package func named(_ id: String?) -> PreviewTheme {
            themes.first { $0.id == id } ?? .dawn
        }

        private static let nextToken = OSAllocatedUnfairLock(initialState: UInt64(0))
    }

    /// The built-ins alone: what every registry starts with, and all the CLI ever resolves.
    package static let builtIns = Snapshot(themes: [.dawn, .classic, .modern, .vivid], partialIDs: [])

    /// A registry a test can put in place of `shared` for the code it runs, without changing what
    /// any other test running at the same time sees. Nothing outside the package can set it.
    @TaskLocal package static var override: ThemeRegistry?

    /// `override` if set, otherwise `shared`.
    package static var current: ThemeRegistry { override ?? shared }

    // MARK: - Loading

    private static let log = Logger(subsystem: "dev.southern-light.marsdawn-kit", category: "ThemeRegistry")

    /// Why an installed theme was left out. Carries only validator rule ids and ids that passed
    /// `ThemeGrammar.isThemeID`, never raw text from a file or a folder name.
    package enum Drop: Error, Equatable, Sendable {
        case notAFolder
        case unreadable
        case invalid(rule: String)
        case reservedID
        case folderMismatch
        case duplicateID
        case revokedID
        case revokedAuthor
        case overLimit
    }

    package struct ScanResult: Sendable {
        package var installed: [PreviewTheme] = []
        package var partialIDs: Set<String> = []
        /// Keyed by folder name. Folders whose name isn't a theme id aren't recorded.
        package var dropped: [String: Drop] = [:]
    }

    /// Reads and validates every `<directory>/<id>/theme.json`. Internal to the package so tests
    /// can check why each folder was dropped; `loadInstalled` is the public entry point.
    package static func scan(directory: URL, revokedIDs: Set<String>, revokedAuthors: Set<String>) -> ScanResult {
        var result = ScanResult()
        let root = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else {
            if errno != ENOENT { log.error("THEME-DIR-UNREADABLE: the installed-themes folder can't be opened (errno \(errno, privacy: .public))") }
            return result
        }
        defer { close(root) }

        // Folders in byte order of name, so everything below is deterministic.
        let names = folderNames(in: root).filter(ThemeGrammar.isThemeID).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }

        struct Candidate { let folder: String; let theme: ValidatedTheme }
        var candidates: [Candidate] = []
        for folder in names {
            switch readThemeFile(folder: folder, in: root) {
            case .failure(let drop):
                result.dropped[folder] = drop
            case .success(let data):
                let report = ThemeValidator.validate(data: data)
                guard let theme = report.theme else {
                    result.dropped[folder] = .invalid(rule: report.issues.first?.rule ?? "unknown")
                    continue
                }
                candidates.append(Candidate(folder: folder, theme: theme))
            }
        }

        // M3: an id claimed by more than one folder is dropped from all of them.
        var claims: [String: Int] = [:]
        for candidate in candidates { claims[candidate.theme.id, default: 0] += 1 }

        let authors = Set(revokedAuthors.map(asciiLowercased))
        var accepted: [ValidatedTheme] = []
        for candidate in candidates {
            let id = candidate.theme.id
            let drop: Drop? =
                if reservedIDs.contains(id) { .reservedID }
                else if claims[id, default: 0] > 1 { .duplicateID }
                else if candidate.folder != id { .folderMismatch }
                else if revokedIDs.contains(id) { .revokedID }
                else if let github = candidate.theme.document.author?.github, authors.contains(asciiLowercased(github)) { .revokedAuthor }
                else if accepted.count >= maxInstalled { .overLimit }
                else { nil }
            if let drop {
                result.dropped[candidate.folder] = drop
            } else {
                accepted.append(candidate.theme)
            }
        }

        for theme in accepted {
            result.installed.append(PreviewTheme(validated: theme))
            let document = theme.document
            if document.light.syntax == nil || document.light.diagram == nil || document.dark.syntax == nil || document.dark.diagram == nil {
                result.partialIDs.insert(theme.id)
            }
        }

        let counts = Dictionary(grouping: result.dropped.values, by: { "\($0)" }).mapValues(\.count)
        for (reason, count) in counts.sorted(by: { $0.key < $1.key }) {
            log.error("THEME-DROPPED: \(count, privacy: .public) installed theme(s) left out: \(reason, privacy: .public)")
        }
        if let over = counts["\(Drop.overLimit)"] {
            log.error("THEME-LIMIT: \(over, privacy: .public) installed theme(s) beyond the limit of \(maxInstalled, privacy: .public) were ignored")
        }
        for (folder, drop) in result.dropped.sorted(by: { $0.key < $1.key }) where drop == .duplicateID {
            log.error("THEME-DUPLICATE: folder \(folder, privacy: .public) declares an id another folder also declares; every claimant is dropped")
        }
        for id in result.partialIDs.sorted() {
            log.info("THEME-PARTIAL: \(id, privacy: .public) has no syntax or diagram colours of its own; using Dawn's")
        }
        return result
    }

    private static func asciiLowercased(_ text: String) -> String {
        String(decoding: text.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
    }

    /// The entries of the open folder `root`, read through that descriptor, so the listing and the
    /// opens below are of the same folder even if its path is replaced meanwhile.
    private static func folderNames(in root: Int32) -> [String] {
        let copy = dup(root)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            return []
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// `<root>/<folder>/theme.json`, read once: the folder must be a real folder and the file a
    /// real file (no symlink at either step), opened without following links and checked again
    /// once open, read up to one byte past the size cap.
    private static func readThemeFile(folder: String, in root: Int32) -> Result<Data, Drop> {
        var folderStat = stat()
        guard fstatat(root, folder, &folderStat, AT_SYMLINK_NOFOLLOW) == 0 else { return .failure(.unreadable) }
        guard folderStat.st_mode & S_IFMT == S_IFDIR else { return .failure(.notAFolder) }
        let dir = openat(root, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dir >= 0 else { return .failure(.notAFolder) }
        defer { close(dir) }
        var openedFolder = stat()
        guard fstat(dir, &openedFolder) == 0, openedFolder.st_mode & S_IFMT == S_IFDIR,
              openedFolder.st_dev == folderStat.st_dev, openedFolder.st_ino == folderStat.st_ino
        else { return .failure(.notAFolder) }

        var fileStat = stat()
        guard fstatat(dir, "theme.json", &fileStat, AT_SYMLINK_NOFOLLOW) == 0 else { return .failure(.unreadable) }
        guard fileStat.st_mode & S_IFMT == S_IFREG else { return .failure(.unreadable) }
        let fd = openat(dir, "theme.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .failure(.unreadable) }
        defer { close(fd) }
        var openedFile = stat()
        guard fstat(fd, &openedFile) == 0, openedFile.st_mode & S_IFMT == S_IFREG,
              openedFile.st_dev == fileStat.st_dev, openedFile.st_ino == fileStat.st_ino
        else { return .failure(.unreadable) }

        let limit = ThemeValidator.maxFileBytes + 1
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < limit {
            let wanted = min(buffer.count, limit - data.count)
            let got = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, wanted) }
            if got < 0 {
                if errno == EINTR { continue }
                return .failure(.unreadable)
            }
            if got == 0 { break }
            data.append(contentsOf: buffer[0..<got])
        }
        if data.count > ThemeValidator.maxFileBytes { return .failure(.invalid(rule: "file.tooLarge")) }
        return .success(data)
    }
}
