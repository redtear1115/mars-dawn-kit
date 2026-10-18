#if os(macOS)
import AppKit
import Darwin
import Foundation
import PDFKit
import Testing
import WebKit
@testable import MarsDawnExport
@testable import MarsDawnKit

/// The manual layout's own rules (mars-dawn#432 S2) beyond what the PDF corpus checks on every
/// manual fixture: the cover's front-matter rule, the logo's trust boundary, injection, marker
/// spoofing, the private folder, what may leak into the file, and which jobs may run it.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(5)))
struct ManualLayoutTests {
    // MARK: FM: the cover's front-matter rule

    @Test func coverFieldsFollowTheFrontMatterRule() {
        func cover(_ frontMatter: String) -> ManualLayout.Cover? {
            ManualLayout.cover(markdown: "---\n\(frontMatter)\n---\n\n# Body\n")
        }
        // Quoted: one matching pair of " or ' comes off, and only one.
        #expect(cover("title: \"Quoted title\"")?.title == "Quoted title")
        #expect(cover("title: 'Single'")?.title == "Single")
        #expect(cover("title: \"\"Twice\"\"")?.title == "\"Twice\"")
        #expect(cover("title: \"Mixed'")?.title == "\"Mixed'")
        // A block that is not a simple table (a list, a comment) still yields its simple lines.
        let listed = cover("title: With tags\ntags:\n  - one\n  - two\n# a comment\nauthor: Ann")
        #expect(listed?.title == "With tags" && listed?.author == "Ann")
        // The first occurrence of a duplicated key wins.
        #expect(cover("title: First\ntitle: Second")?.title == "First")
        #expect(cover("author: A1\ntitle: T\nauthor: A2")?.author == "A1")
        // Empty counts as absent: no title, no cover; an empty subtitle is no subtitle.
        #expect(cover("title:") == nil)
        #expect(cover("title: \"\"") == nil)
        #expect(cover("title: T\nsubtitle: ''")?.subtitle == nil)
        // No title key, no front matter: no cover.
        #expect(cover("subtitle: S\nauthor: A") == nil)
        #expect(ManualLayout.cover(markdown: "# Body\n\ntext\n") == nil)
        // Every whitelisted key, and nothing else, reaches the cover.
        let full = cover("title: T\nsubtitle: S\nversion: V\ndate: D\nauthor: A\nlogo: L\nsecret: X\ndescription: Y")
        #expect(full == ManualLayout.Cover(title: "T", subtitle: "S", version: "V", date: "D", author: "A", logo: "L"))
    }

    /// C and FM on real exports: the cover shows exactly the whitelisted fields (other keys,
    /// even with values that look like cover text, don't appear anywhere in the PDF); a
    /// duplicated title shows its first value; an empty title means no cover.
    @Test func theCoverShowsExactlyTheWhitelistedFields() async throws {
        let markdown = """
        ---
        title: CTITLE1
        title: CTITLE2
        subtitle: CSUB
        version: CVER
        date: CDATE
        author: CAUTH
        secret: CSECRET
        description: CDESC
        summary: CSUMM
        tags:
          - CTAG
        ---

        # Chapter CHAP

        CBODY text.
        """
        let run = try await ManualProbe.export(markdown)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        #expect(run.report.cover != nil)
        let cover = ManualProbe.lines(run.pageTexts[0])
        #expect(cover == ["CTITLE1", "CSUB", "CVER", "CDATE", "CAUTH"], "the cover reads \(cover)")
        let all = run.pageTexts.joined(separator: "\n")
        for absent in ["CTITLE2", "CSECRET", "CDESC", "CSUMM", "CTAG"] {
            #expect(!all.contains(absent), "\(absent) reached the PDF")
        }
        // The body is still there, so the absence above is not an empty export.
        #expect(all.contains("CBODY"))

        let untitled = try await ManualProbe.export("---\ntitle:\nauthor: UAUTH\n---\n\n# Chapter UCHAP\n\nUBODY\n")
        defer { try? FileManager.default.removeItem(at: untitled.directory) }
        #expect(untitled.report.cover == nil)
        #expect(!untitled.pageTexts.joined().contains("UAUTH"))
        #expect(ManualProbe.lines(untitled.pageTexts[0]).first == "Contents", "page 1 is the contents: \(untitled.pageTexts[0])")
    }

    /// Neither a cover nor a heading: no contents, no bookmarks, and every page is a body page
    /// with its "n / N" footer, the first one "1 / N".
    @Test func aDocumentWithoutTitleOrHeadingsIsAllBody() async throws {
        let paragraph = String(repeating: "Plain text without any heading. ", count: 40)
        let markdown = (1...12).map { "P\($0) " + paragraph }.joined(separator: "\n\n") + "\n\n### Level three NOH3\n\nPLAINEND99\n"
        let run = try await ManualProbe.export(markdown)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        #expect(run.report.cover == nil && run.report.headings.isEmpty && run.report.bodyStart == 0)
        #expect(run.pageTexts.count >= 2, "\(run.pageTexts.count) pages")
        #expect(run.pageTexts.first.map { ManualProbe.withoutFooter($0).hasPrefix("P1 ") } == true)
        for (index, text) in run.pageTexts.enumerated() {
            let footer = ManualProbe.footer(text)
            #expect(footer?.n == index + 1 && footer?.total == run.pageTexts.count, "page \(index + 1): \(String(describing: footer))")
        }
        #expect(ManualProbe.outline(run.document).isEmpty && run.document.outlineRoot == nil)
        #expect(!run.pageTexts.joined().contains("Contents"))
        #expect(ManualProbe.pageTexts(run.report.passA).count == run.pageTexts.count)
    }

    // MARK: SEC-1: the logo is an image like any other

    /// <root>/granted/project/ (the document's folder) with the logo variants, <root>/granted/shared
    /// (above the document, inside a granted parent) and <root>/outside.
    @MainActor struct LogoTree {
        var root: URL
        var project: URL
        var granted: URL
        static let colour = (red: 13, green: 201, blue: 87)

        init() throws {
            let files = FileManager.default
            root = files.temporaryDirectory.appendingPathComponent("manual-logo-\(UUID().uuidString)").resolvingSymlinksInPath()
            granted = root.appendingPathComponent("granted")
            project = granted.appendingPathComponent("project")
            for folder in ["granted/project/img", "granted/shared", "outside"] {
                try files.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            let png = ManualProbe.png(red: Self.colour.red, green: Self.colour.green, blue: Self.colour.blue)
            for path in ["granted/project/img/logo.png", "granted/project/img/my logo.png", "granted/shared/logo.png", "outside/logo.png"] {
                try png.write(to: root.appendingPathComponent(path))
            }
            try png.write(to: project.appendingPathComponent("logo.txt"))
            try files.createSymbolicLink(at: project.appendingPathComponent("link-in.png"), withDestinationURL: project.appendingPathComponent("img/logo.png"))
            try files.createSymbolicLink(at: project.appendingPathComponent("link-out.png"), withDestinationURL: root.appendingPathComponent("outside/logo.png"))
            #expect(mkfifo(project.appendingPathComponent("fifo.png").path, 0o600) == 0)
            // 33 MB: a real PNG followed by padding, over the asset handler's 32 MB cap.
            var big = png
            big.append(Data(count: 33 * 1024 * 1024))
            try big.write(to: project.appendingPathComponent("big.png"))
        }
    }

    struct LogoRow: CustomStringConvertible {
        var name: String
        var logo: String
        var grantedScope = false
        var present: Bool
        var placeholder: String?
        var description: String { name }
    }

    static func logoRows(_ tree: LogoTree) -> [LogoRow] {
        let png = ManualProbe.png(red: LogoTree.colour.red, green: LogoTree.colour.green, blue: LogoTree.colour.blue)
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='40' height='40'><rect width='40' height='40' fill='rgb(13,201,87)'/></svg>"
        return [
            LogoRow(name: "relative", logo: "img/logo.png", present: true),
            LogoRow(name: "dot-relative", logo: "./img/logo.png", present: true),
            LogoRow(name: "percent-encoded", logo: "img/my%20logo.png", present: true),
            LogoRow(name: "absolute inside", logo: tree.project.appendingPathComponent("img/logo.png").path, present: true),
            LogoRow(name: "../ above the scope", logo: "../shared/logo.png", present: false),
            LogoRow(name: "../ inside a granted parent", logo: "../shared/logo.png", grantedScope: true, present: true),
            LogoRow(name: "absolute outside", logo: tree.root.appendingPathComponent("outside/logo.png").path, present: false),
            LogoRow(name: "symlink to inside", logo: "link-in.png", present: false),
            LogoRow(name: "symlink to outside", logo: "link-out.png", present: false),
            LogoRow(name: "file URL", logo: "file://" + tree.project.appendingPathComponent("img/logo.png").path, present: false),
            LogoRow(name: "http", logo: "http://127.0.0.1:9/logo.png", present: false, placeholder: PreviewWebView.insecureImagePlaceholderLabel),
            LogoRow(name: "https, remote off", logo: "https://logo.example.invalid/logo.png", present: false, placeholder: PreviewWebView.webImagePlaceholderLabel),
            LogoRow(name: "data PNG", logo: "data:image/png;base64," + png.base64EncodedString(), present: true),
            LogoRow(name: "data SVG", logo: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString(), present: false),
            LogoRow(name: "PNG named .txt", logo: "logo.txt", present: false),
            LogoRow(name: "FIFO", logo: "fifo.png", present: false),
            LogoRow(name: "33 MB", logo: "big.png", present: false),
            LogoRow(name: "quoted", logo: "\"img/logo.png\"", present: true),
        ]
    }

    /// Every row of the matrix in one run, so each "absent" row has its "present" twins beside it.
    /// Presence is read from the PDF twice: an image XObject on page 1 and the logo's colour in its
    /// pixels. The cover's `src` is byte-identical to the one the renderer writes for the same
    /// source as a body image.
    @Test func theLogoLoadsExactlyAsABodyImageWould() async throws {
        let tree = try LogoTree()
        defer { try? FileManager.default.removeItem(at: tree.root) }
        var failures: [String] = []
        for row in Self.logoRows(tree) {
            let markdown = "---\ntitle: Logo LOGOTITLE\nlogo: \(row.logo)\n---\n\n# Chapter\n\nText.\n"
            let started = ContinuousClock.now
            let run = try await ManualProbe.export(
                markdown, baseDirectory: tree.project, scopeRoot: row.grantedScope ? tree.granted : nil
            )
            defer { try? FileManager.default.removeItem(at: run.directory) }
            let elapsed = ContinuousClock.now - started
            let xobjects = ManualProbe.imageXObjects(run.data, page: 0)
            let colour = ManualProbe.showsColor(run.document, page: 0, red: LogoTree.colour.red, green: LogoTree.colour.green, blue: LogoTree.colour.blue)
            if (xobjects > 0) != row.present || colour != row.present {
                failures.append("\(row.name): image XObjects \(xobjects), colour \(colour), expected present \(row.present)")
            }
            if let placeholder = row.placeholder, !ManualProbe.collapse(run.pageTexts[0]).contains(placeholder) {
                failures.append("\(row.name): no \"\(placeholder)\" placeholder on the cover: \(run.pageTexts[0])")
            }
            #expect(elapsed < DocumentExporter.contentTimeout, "\(row.name): took \(elapsed)")
            // Parity with a body image of the same source (the quoted row's source is its value).
            let source = ManualLayout.unquoted(row.logo)
            let body = await MarkdownRenderer.renderResult("![](\(source.replacingOccurrences(of: " ", with: "%20")))", options: .preview(baseDirectory: tree.project))
            let bodySource = body.flatMap { ManualProbe.firstImageSource($0.html) }
            let coverSource = ManualProbe.firstImageSource(run.report.coverHTML)
            if coverSource == nil || coverSource != bodySource {
                failures.append("\(row.name): cover src \(String(describing: coverSource)), body src \(String(describing: bodySource))")
            }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    // MARK: SEC-2: document text and the contents title are data

    static let payload = "</div><img src=x onerror=\"window.__pwned=1\">\"'`${window.__pwned=1}` \"); window.__pwned=1; (\"\u{2028}"

    /// The payload in every whitelisted field, in a heading and in the contents title: nothing
    /// runs, no element is made from it, the HTML holds only its escaped form, and the PDF shows
    /// the characters themselves.
    @Test func documentTextAndTheContentsTitleNeverRun() async throws {
        let p = Self.payload
        let markdown = """
        ---
        title: FTITLE\(p)
        subtitle: FSUB\(p)
        version: FVER\(p)
        date: FDATE\(p)
        author: FAUTH\(p)
        logo: \(p)
        ---

        # HEAD `` \(p) ``

        Body.
        """
        var page: [String: String] = [:]
        var hooks = ManualHooks()
        hooks.afterPassB = { webView in
            let script = """
            return JSON.stringify({
              pwned: typeof window.__pwned,
              handlers: document.querySelectorAll("[onerror]").length,
              injected: document.querySelectorAll('img[src="x"]').length
            });
            """
            for (name, world) in [("page", WKContentWorld.page), ("manual", ManualLayout.world)] {
                page[name] = try await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: world) as? String
            }
        }
        let run = try await ManualProbe.export(markdown, tocTitle: "TOC" + p, hooks: hooks)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        for world in ["page", "manual"] {
            #expect(page[world] == #"{"pwned":"undefined","handlers":0,"injected":0}"#, "\(world) world: \(page[world] ?? "nil")")
        }
        // The cover's HTML holds the escaped form only.
        let html = run.report.coverHTML
        #expect(!html.contains("<img src=x") && !html.contains("</div><img"), "raw payload in the cover HTML")
        #expect(html.contains("&lt;/div&gt;&lt;img src=x onerror="), "escaped payload missing from the cover HTML")
        // The PDF shows the characters (U+2028 is a line break on the page).
        func flat(_ text: String) -> String {
            String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "\u{2028}" }.map(Character.init))
        }
        let literal = flat(p)
        let cover = flat(run.pageTexts[0])
        for field in ["FTITLE", "FSUB", "FVER", "FDATE", "FAUTH"] {
            #expect(cover.contains(field + literal), "\(field): the cover doesn't show the payload: \(run.pageTexts[0])")
        }
        let contents = flat(run.pageTexts[1])
        #expect(contents.contains("TOC" + literal), "the contents title: \(run.pageTexts[1])")
        #expect(contents.contains("HEAD" + literal), "the contents entry: \(run.pageTexts[1])")
        #expect(run.report.headings.first?.text.contains("</div><img src=x") == true)
    }

    // MARK: SEC-3: markers can't be spoofed

    /// Strings in the spike's marker format (and in this export's own shape), a raw span
    /// imitating a marker, and repeated heading texts: every heading is still numbered with
    /// the page it starts on.
    @Test func markerLookalikesInTheDocumentChangeNoNumber() async throws {
        let filler = String(repeating: "Filler sentence for the page. ", count: 30)
        let markdown = """
        # Alpha @@H000@@

        Body @@H000@@ @@H001@@ @@H002@@ MABCDEFGHJKMNPQH0Z MABCDEFGHJKMNPQEZ.

        <span class="mark" style="position: absolute; color: transparent; font-size: 1px">@@H001@@</span>

        \(filler)

        ## Repeated

        \(filler)

        # Beta @@H002@@

        \(filler)

        ## Repeated

        @@H003@@ \(filler)

        # Alpha @@H000@@

        \(filler)

        ## Repeated @@H001@@

        \(filler)
        """
        let run = try await ManualProbe.export(markdown)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        let truth = ManualProbe.truthPages(headings: run.report.headings, pageTexts: run.pageTexts, bodyStart: run.report.bodyStart)
        #expect(run.report.headings.count == 6)
        for (index, heading) in run.report.headings.enumerated() {
            let page = try #require(truth[index], "\(heading.text) not found")
            #expect(run.report.numbers[index] == page - run.report.bodyStart + 1,
                    "\(index) \(heading.text): numbered \(String(describing: run.report.numbers[index])), on body page \(page - run.report.bodyStart + 1)")
        }
        #expect(ManualProbe.outline(run.document).count == 6)
    }

    // MARK: SEC-4: the private folder

    static let sample = "---\ntitle: Temp TTITLE\n---\n\n# One\n\nText.\n\n## Two\n\nMore.\n"

    struct Planted: Error {}

    /// Success, a failure after pass A and a cancellation after pass A: each removes its private
    /// folder (seen holding pass A), and only success writes the destination. Pass A is printed
    /// under the temporary directory, in a folder only the user can open. (The folder is named by
    /// what the export itself reported: other suites export in parallel into the same directory.)
    @Test func thePrivateFolderIsAlwaysRemoved() async throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path

        var sawPassA: URL?
        var hooks = ManualHooks()
        hooks.afterPassA = { url in
            sawPassA = url
            let attributes = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
            #expect((attributes[.posixPermissions] as? Int) == 0o700)
        }
        let run = try await ManualProbe.export(Self.sample, hooks: hooks)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        let passA = try #require(sawPassA)
        #expect(passA.resolvingSymlinksInPath().path.hasPrefix(temporary + "/"), "pass A at \(passA.path)")
        #expect(passA.deletingLastPathComponent().standardizedFileURL == run.report.workDirectory.standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: run.report.workDirectory.path), "success left \(run.report.workDirectory.path)")

        for mode in ["failure", "cancellation"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manual-fail-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("out.pdf")
            var failing = ManualHooks()
            var work: URL?
            failing.afterPassA = { url in
                work = url.deletingLastPathComponent()
                #expect(FileManager.default.fileExists(atPath: url.path), "\(mode): pass A was printed")
                if mode == "failure" { throw Planted() }
                withUnsafeCurrentTask { $0?.cancel() }
            }
            do {
                _ = try await DocumentExporter.exportPDF(
                    markdown: Self.sample, to: destination, theme: .dawn, baseDirectory: nil, allowRemoteImages: false,
                    layout: .manual, inspect: nil, hooks: failing
                )
                Issue.record("\(mode): the export finished")
            } catch {
                #expect(mode == "failure" ? error is Planted : error is CancellationError, "\(mode): threw \(error)")
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path), "\(mode): wrote the destination")
            let folder = try #require(work, "\(mode): pass A never printed")
            #expect(folder.lastPathComponent.hasPrefix("marsdawn-manual-"))
            #expect(!FileManager.default.fileExists(atPath: folder.path), "\(mode) left \(folder.path)")
        }
    }

    // MARK: SEC-5: nothing about the export's files reaches the PDF

    /// Exported as the CLI does, to a hidden `.tmp.pdf` beside the destination, from a folder
    /// with a sentinel name: the Info dictionary, the XMP and the text hold none of the paths,
    /// the user name, the folder, the marker token or the private folder's name. The sentinel in
    /// a heading is found, so the search can see what it looks for. The cover's title and
    /// author don't become the PDF's /Title and /Author.
    @Test func nothingAboutTheExportsFilesReachesThePDF() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SEC5FOLDERSENTINEL-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent(".out.pdf.\(UUID().uuidString).tmp.pdf")
        var report: ManualReport?
        var hooks = ManualHooks()
        hooks.report = { report = $0 }
        _ = try await DocumentExporter.exportPDF(
            markdown: "---\ntitle: SEC5TITLE\nauthor: SEC5AUTHOR\n---\n\n# Heading SEC5HEADSENTINEL\n\nText.\n",
            to: destination, theme: .dawn, baseDirectory: folder, allowRemoteImages: false, layout: .manual,
            inspect: nil, hooks: hooks
        )
        let report_ = try #require(report)
        let data = try Data(contentsOf: destination)
        let document = try #require(PDFDocument(data: data))
        let text = ManualProbe.pageTexts(document).joined(separator: "\n")
        let raw = String(decoding: data, as: UTF8.self)
        // The Info dictionaries as written (every revision's trailer's /Info object), and as
        // PDFKit reads them back: PDFKit can write a /Title it then doesn't read back.
        let infoObjects = raw.matches(of: /\/Info\s+(\d+)\s+(\d+)\s+R/).compactMap { match -> String? in
            guard let start = raw.range(of: "\n\(match.1) \(match.2) obj") else { return nil }
            return raw[start.upperBound...].range(of: "endobj").map { String(raw[start.upperBound..<$0.lowerBound]) }
        }
        #expect(!infoObjects.isEmpty, "precondition: the file has an Info dictionary")
        let info = infoObjects.joined(separator: "\n") + "\n"
            + (document.documentAttributes ?? [:]).map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        let xmp = raw.range(of: "<x:xmpmeta").map { String(raw[$0.lowerBound...].prefix(20_000)) } ?? ""

        #expect(text.contains("SEC5HEADSENTINEL"), "positive control: the heading's sentinel is in the text")
        var leaks = ["/Users/", ".tmp.pdf", "SEC5FOLDERSENTINEL", report_.token, "marsdawn-manual-", folder.path]
        if NSUserName().count >= 3 { leaks.append(NSUserName()) }
        for leak in leaks {
            #expect(!text.contains(leak), "the text holds \(leak)")
            #expect(!info.contains(leak), "the Info dictionary holds \(leak): \(info)")
            #expect(!xmp.contains(leak), "the XMP holds \(leak)")
            #expect(!raw.contains(leak), "the file's bytes hold \(leak)")
        }
        #expect(!info.contains("SEC5TITLE") && !info.contains("SEC5AUTHOR"), "front matter in the Info dictionary: \(info)")
    }

    // MARK: EP: entry points

    /// What the app's Export as PDF does: the internal `run…` path every public `run…` and
    /// `exportPDF` reaches, configured by the caller to save to a file without panels.
    @Test func aSaveJobThroughRunGetsEveryManualFeature() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manual-ep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("out.pdf")
        let printInfo = NSPrintInfo()
        printInfo.paperSize = DocumentExporter.Paper.a4.size
        var report: ManualReport?
        var hooks = ManualHooks()
        hooks.report = { report = $0 }
        let result = try await DocumentExporter.runReportingDiagramDetails(
            markdown: Self.sample, theme: .dawn, baseDirectory: nil, allowRemoteImages: false, layout: .manual,
            tocTitle: "EPTOC", printInfo: printInfo, window: nil, inspect: nil, hooks: hooks
        ) { info, operation in
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
        }
        #expect(result.completed)
        let report_ = try #require(report)
        let document = try #require(PDFDocument(url: destination))
        let texts = ManualProbe.pageTexts(document)
        #expect(texts.count == 3, "cover, contents, one body page: \(texts.count)")
        #expect(texts[0].contains("Temp TTITLE"))
        #expect(texts[1].contains("EPTOC"))
        #expect(ManualProbe.footer(texts[2])?.n == 1 && ManualProbe.footer(texts[2])?.total == 1)
        #expect(report_.numbers == [1, 1])
        #expect(ManualProbe.outline(document).map(\.label) == ["One", "Two"])
        #expect(!FileManager.default.fileExists(atPath: report_.workDirectory.path), "left \(report_.workDirectory.path)")
    }

    /// A manual job that isn't a panel-free save to a file is refused before anything prints:
    /// the print panel (the app's Print…), and dispositions other than `.save`. A document job
    /// with a panel is not refused: it reaches the point where it would print.
    @Test func manualJobsThatDontSaveToAFileAreRefusedBeforePrinting() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manual-refuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("out.pdf")

        struct ReachedPrint: Error {}
        typealias Configure = (NSPrintInfo, NSPrintOperation) -> Void
        let cases: [(String, ExportLayout, Configure)] = [
            ("panel, nothing configured", .manual, { _, _ in }),
            ("save to a file, with a panel", .manual, { info, operation in
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
                operation.showsPrintPanel = true
            }),
            ("spool, no panel", .manual, { info, operation in
                info.jobDisposition = .spool
                operation.showsPrintPanel = false
            }),
            ("preview, no panel", .manual, { info, operation in
                info.jobDisposition = .preview
                operation.showsPrintPanel = false
            }),
            ("save without a URL, no panel", .manual, { info, operation in
                info.jobDisposition = .save
                operation.showsPrintPanel = false
            }),
        ]
        for (name, layout, configure) in cases {
            var hooks = ManualHooks()
            var reached = false
            hooks.beforePrint = { _ in reached = true; throw ReachedPrint() }
            do {
                _ = try await DocumentExporter.runReportingDiagramDetails(
                    markdown: Self.sample, theme: .dawn, baseDirectory: nil, allowRemoteImages: false, layout: layout,
                    printInfo: NSPrintInfo(), window: nil, inspect: nil, hooks: hooks, configure: configure
                )
                Issue.record("\(name): ran")
            } catch DocumentExporter.ExportError.manualLayoutNeedsSave {
            } catch {
                Issue.record("\(name): threw \(error)")
            }
            #expect(!reached, "\(name): reached printing")
            #expect(!FileManager.default.fileExists(atPath: destination.path), "\(name): wrote a file")
        }

        // The document layout's Print… (a panel, nothing configured) is not refused.
        var hooks = ManualHooks()
        hooks.beforePrint = { operation in
            #expect(operation.showsPrintPanel)
            throw ReachedPrint()
        }
        await #expect(throws: ReachedPrint.self) {
            _ = try await DocumentExporter.runReportingDiagramDetails(
                markdown: Self.sample, theme: .dawn, baseDirectory: nil, allowRemoteImages: false, layout: .document,
                printInfo: NSPrintInfo(), window: nil, inspect: nil, hooks: hooks
            )
        }
    }

    // MARK: L: the instrument sees a lost link

    /// The links probe can see a loss: the final file redrawn through CoreGraphics without its
    /// annotations reads as fewer links than the printed file it came from.
    @Test func theLinksProbeSeesALostLink() async throws {
        let markdown = "# Links\n\nSee [the site](https://example.com/a) and a note.[^1]\n\n## More\n\n[Another](https://example.com/b)\n\n[^1]: The note.\n"
        let run = try await ManualProbe.export(markdown)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        let printed = try #require(PDFDocument(data: run.report.passB))
        #expect(ManualProbe.links(printed) == ManualProbe.links(run.document))
        #expect(ManualProbe.links(run.document).urls.count == 2)

        let redrawn = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: redrawn as CFMutableData))
        let source = try #require(CGPDFDocument(CGDataProvider(data: run.data as CFData)!))
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for index in 1...source.numberOfPages {
            guard let page = source.page(at: index) else { continue }
            var mediaBox = page.getBoxRect(.mediaBox)
            context.beginPage(mediaBox: &mediaBox)
            context.drawPDFPage(page)
            context.endPage()
        }
        context.closePDF()
        let lossy = try #require(PDFDocument(data: redrawn as Data))
        #expect(lossy.pageCount == run.document.pageCount)
        #expect(ManualProbe.links(lossy) != ManualProbe.links(run.document), "a CG redraw kept the links?")
        #expect(ManualProbe.links(lossy).perPage.reduce(0, +) < ManualProbe.links(run.document).perPage.reduce(0, +))
    }
}
#endif
