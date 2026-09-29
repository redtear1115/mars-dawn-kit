#if os(macOS)
import Foundation
import Testing
@testable import MarsDawnKit
import MarsDawnThemes

// The public validation entry (app #293) against what a load does: every file the kit has as a
// fixture, run through `ThemeValidation.validate(data:)` and through `ThemeRegistry` installed
// alone at `<id>/theme.json`, must be accepted by both or refused by both, for the same reason.

/// `Tests/MarsDawnThemesTests/ThemeFixtures`, read from the source tree: that target's bundle
/// isn't available to this one.
private let fixtureRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("MarsDawnThemesTests/ThemeFixtures", isDirectory: true)

private func fixtures(_ folder: String) -> [URL] {
    let url = fixtureRoot.appendingPathComponent(folder)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.sorted().map { url.appendingPathComponent($0) }
}

/// One file and a name for it in failure messages.
struct ValidationCase: CustomTestStringConvertible, Sendable {
    let name: String
    let data: Data
    var testDescription: String { name }

    static let all: [ValidationCase] = {
        var cases: [ValidationCase] = []
        for folder in ["valid", "invalid", "publish", "hostile"] {
            for url in fixtures(folder) {
                cases.append(ValidationCase(name: "\(folder)/\(url.lastPathComponent)", data: (try? Data(contentsOf: url)) ?? Data()))
            }
        }
        // The built-ins' own files: valid themes whose ids are reserved.
        for id in ThemeRegistry.reservedIDs.sorted() {
            if let url = ThemeDocumentLoader.builtInURL(id: id), let data = try? Data(contentsOf: url) {
                cases.append(ValidationCase(name: "built-in/\(id)", data: data))
            }
        }
        // The same theme under an id of its own, then padded with trailing spaces to exactly the
        // size cap (accepted) and one byte past it (refused unread).
        if let data = try? InstalledThemes.theme("equivalence-check") {
            cases.append(ValidationCase(name: "renamed built-in", data: data))
            let atCap = data + Data(repeating: 0x20, count: ThemeValidation.maxFileBytes - data.count)
            cases.append(ValidationCase(name: "padded to the cap", data: atCap))
            cases.append(ValidationCase(name: "one byte over the cap", data: atCap + Data([0x20])))
        }
        return cases
    }()
}

/// The folder a host would install the file under: its `id` when that is a theme id, so the
/// folder-name rule (which the bytes alone can't decide) never refuses it; otherwise any theme id,
/// since a file with an unusable id is refused before the folder is compared.
private func folderName(for data: Data) -> String {
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    if let id = object?["id"] as? String, ThemeGrammar.isThemeID(id) { return id }
    return "fixture"
}

@Suite(.timeLimit(.minutes(1)))
struct PublicThemeValidationTests {
    @Test func theCasesAreThere() {
        let names = ValidationCase.all.map(\.name)
        #expect(names.filter { $0.hasPrefix("valid/") }.count >= 8, "positive fixture: valid themes found")
        #expect(names.filter { $0.hasPrefix("invalid/") }.count >= 50, "positive fixture: invalid themes found")
        #expect(names.filter { $0.hasPrefix("publish/") }.count == 2)
        #expect(names.filter { $0.hasPrefix("built-in/") }.count == 4)
        #expect(names.contains("one byte over the cap"))
    }

    /// Accept/refuse per file equals a load's, and a refusal names the same rule the load dropped
    /// the folder for (`id.reserved` for a load's `reservedID`).
    @Test(arguments: ValidationCase.all)
    func theEntryAgreesWithALoad(_ item: ValidationCase) throws {
        let result = ThemeValidation.validate(data: item.data)
        #expect(result.isValid == result.issues.isEmpty, "\(item.name): \(result)")

        let installed = try InstalledThemes()
        let folder = folderName(for: item.data)
        try installed.add(folder, item.data)
        let scan = installed.scan()
        let loaded = scan.installed.map(\.id)

        if let id = result.themeID {
            #expect(loaded == [id], "\(item.name): the entry accepts \(id), the load gave \(loaded) (dropped \(scan.dropped))")
        } else {
            #expect(loaded.isEmpty, "\(item.name): the entry refuses (\(result.issues)), the load accepted \(loaded)")
            let expected: ThemeRegistry.Drop = result.issues.first?.rule == "id.reserved"
                ? .reservedID : .invalid(rule: result.issues.first?.rule ?? "none")
            #expect(scan.dropped[folder] == expected, "\(item.name): the entry says \(result.issues), the load dropped \(scan.dropped)")
        }
    }

    @Test func aValidThemeReportsItsID() throws {
        let result = ThemeValidation.validate(data: try InstalledThemes.theme("my-theme"))
        #expect(result == ThemeValidation.Result(themeID: "my-theme", issues: []))
    }

    @Test func aBuiltInsIDIsRefusedAsReserved() throws {
        let result = ThemeValidation.validate(data: try InstalledThemes.theme("classic", from: "dawn"))
        #expect(result.themeID == nil)
        #expect(result.issues.map(\.rule) == ["id.reserved"])
        #expect(result.issues.first?.path == "id")
    }

    @Test func aNewerSchemaIsRefusedWithItsOwnRule() throws {
        let data = try InstalledThemes.theme("future") { $0["schemaVersion"] = 2 }
        let result = ThemeValidation.validate(data: data)
        #expect(result.issues.map(\.rule) == ["schema.version"], "\(result.issues)")
    }

    @Test func aMissingSyntaxGroupIsFilledAsALoadDoes() throws {
        let data = try InstalledThemes.theme("partial") { InstalledThemes.set(&$0, ["light", "syntax"], nil) }
        #expect(ThemeValidation.validate(data: data).themeID == "partial")
    }
}
#endif
