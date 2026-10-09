#if os(macOS)
import Foundation

/// One `expect.json` file: what a corpus fixture's export must contain
/// (redtear1115/mars-dawn#2; schema documented in the corpus contract, not repeated here).
struct FixtureExpectation: Decodable {
    struct Diagrams: Decodable {
        var rendered: Int
        var failed: Int
    }

    var markers: [String] = []
    var markersOnLastPage: [String] = []
    var absent: [String] = []
    var placeholders: [String] = []
    var diagrams: Diagrams?
    var images: Int?
    var allowRemoteImages: Bool = false
    var notes: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case markers, markersOnLastPage, absent, placeholders, diagrams, images, allowRemoteImages, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        markers = try container.decodeIfPresent([String].self, forKey: .markers) ?? []
        markersOnLastPage = try container.decodeIfPresent([String].self, forKey: .markersOnLastPage) ?? []
        absent = try container.decodeIfPresent([String].self, forKey: .absent) ?? []
        placeholders = try container.decodeIfPresent([String].self, forKey: .placeholders) ?? []
        diagrams = try container.decodeIfPresent(Diagrams.self, forKey: .diagrams)
        images = try container.decodeIfPresent(Int.self, forKey: .images)
        allowRemoteImages = try container.decodeIfPresent(Bool.self, forKey: .allowRemoteImages) ?? false
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// A fixture ready to export: either a committed folder copied into a private temp directory
/// per the corpus contract, or one built in memory by a generator (`long`, `boundary-*`).
struct CorpusFixture {
    var name: String
    var markdown: String
    /// nil for generated fixtures that reference no images.
    var baseDirectory: URL?
    var expectation: FixtureExpectation
    /// Temp directory to remove once the fixture is done with, if any.
    var workDirectory: URL?

    func cleanUp() {
        guard let workDirectory else { return }
        try? FileManager.default.removeItem(at: workDirectory)
    }
}

enum CorpusLoaderError: Error {
    case corpusResourceMissing
    case documentMissing(String)
}

/// Loads committed fixture folders from `Tests/MarsDawnExportTests/Corpus/`, copied into the
/// test bundle's resources by `Package.swift` (`resources: [.copy("Corpus")]`).
enum CorpusLoader {
    /// Every fixture folder's name, sorted. any loose file at the
    /// corpus root is not a fixture and is skipped.
    static func fixtureNames() throws -> [String] {
        guard let corpusURL = Bundle.module.url(forResource: "Corpus", withExtension: nil) else {
            throw CorpusLoaderError.corpusResourceMissing
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: corpusURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// Copies `<name>`'s folder into `<tmp>/<uuid>/corpus/<name>/`, copies `_parent/*` up one
    /// level (so `../outside.png` can exist outside the fixture's own folder), and substitutes
    /// `{{FIXTURE_DIR}}` in `document.md` for the copy's absolute path.
    static func load(_ name: String) throws -> CorpusFixture {
        guard let corpusURL = Bundle.module.url(forResource: "Corpus", withExtension: nil) else {
            throw CorpusLoaderError.corpusResourceMissing
        }
        let source = corpusURL.appendingPathComponent(name, isDirectory: true)
        let fm = FileManager.default

        let workDirectory = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let corpusDirectory = workDirectory.appendingPathComponent("corpus", isDirectory: true)
        let fixtureDirectory = corpusDirectory.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            guard item.lastPathComponent != "_parent" else { continue }
            try fm.copyItem(at: item, to: fixtureDirectory.appendingPathComponent(item.lastPathComponent))
        }

        let parentSource = source.appendingPathComponent("_parent", isDirectory: true)
        if fm.fileExists(atPath: parentSource.path) {
            for item in try fm.contentsOfDirectory(at: parentSource, includingPropertiesForKeys: nil) {
                try fm.copyItem(at: item, to: corpusDirectory.appendingPathComponent(item.lastPathComponent))
            }
        }

        let markdownURL = fixtureDirectory.appendingPathComponent("document.md")
        guard fm.fileExists(atPath: markdownURL.path) else { throw CorpusLoaderError.documentMissing(name) }
        let rawMarkdown = try String(contentsOf: markdownURL, encoding: .utf8)
        let markdown = rawMarkdown.replacingOccurrences(of: "{{FIXTURE_DIR}}", with: fixtureDirectory.path)

        let expectURL = fixtureDirectory.appendingPathComponent("expect.json")
        let expectation: FixtureExpectation
        if fm.fileExists(atPath: expectURL.path) {
            expectation = try JSONDecoder().decode(FixtureExpectation.self, from: Data(contentsOf: expectURL))
        } else {
            expectation = FixtureExpectation()
        }

        return CorpusFixture(
            name: name, markdown: markdown, baseDirectory: fixtureDirectory,
            expectation: expectation, workDirectory: workDirectory
        )
    }
}

/// `normalize(s)` from the corpus contract: NFKC, then every Unicode whitespace/newline scalar
/// removed. A marker matches a text when `normalize(text).contains(normalize(marker))`.
func corpusNormalize(_ text: String) -> String {
    String(text.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
        !CharacterSet.whitespacesAndNewlines.contains($0)
    })
}
#endif
