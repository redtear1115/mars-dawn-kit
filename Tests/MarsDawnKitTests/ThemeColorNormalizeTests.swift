#if os(macOS)
import Testing
@testable import MarsDawnKit

@MainActor
@Suite
struct ThemeColorNormalizeTests {
    @Test(arguments: [
        "rgb(128, 128, 128)",
        "rgba(128, 128, 128, 1)",
        "color(srgb 0.50196 0.50196 0.50196)",
        // Inverse sRGB transfer at 128/255, then cube root: L = 0.5998708056221469.
        "oklab(0.5998708056221469 0 0)",
    ])
    func equivalentGreys(value: String) {
        #expect(ThemeGoldenHarness.normalize(value) == "rgba(128, 128, 128, 1.00)")
    }

    @Test func oklabLightnessIsNotAnSRGBChannel() {
        let light = ThemeGoldenHarness.normalize("oklab(0.34 0 0)")
        let dark = ThemeGoldenHarness.normalize("oklab(0.739911 0 0)")
        #expect(light == "rgba(56, 56, 56, 1.00)")
        #expect(dark == "rgba(171, 171, 171, 1.00)")
        #expect(light != ThemeGoldenHarness.normalize("color(srgb 0.34 0.34 0.34)"))
        #expect(dark != ThemeGoldenHarness.normalize("color(srgb 0.7 0.7 0.7)"))
    }

    @Test func oklabRed() {
        #expect(ThemeGoldenHarness.normalize("oklab(0.62796 0.22486 0.12585)") == "rgba(255, 0, 0, 1.00)")
    }

    @Test(arguments: [
        "color(srgb 1 0 0 / 0.5)",
        "oklab(0.62796 0.22486 0.12585 / 0.5)",
    ])
    func alphaCarriesThrough(value: String) {
        let normalized = ThemeGoldenHarness.normalize(value)
        #expect(normalized == "rgba(255, 0, 0, 0.50)")
        #expect(normalized.hasSuffix("0.50)"))
    }

    @Test(arguments: [
        "none", "oklab(none 0 0)", "color(srgb 50% 0 0)",
        "color(display-p3 1 0 0)", "calc(1px + 2px)", "12px",
    ])
    func unsupportedValuesPassThrough(value: String) {
        #expect(ThemeGoldenHarness.normalize(value) == value)
    }

    @Test(arguments: ["light", "dark"])
    func checkboxExceptionIsScoped(mode: String) {
        let golden = "rgba(128, 128, 128, 1.00)"
        let expected = mode == "light" ? "rgba(56, 56, 56, 1.00)" : "rgba(171, 171, 171, 1.00)"
        for property in ["color", "borderTopColor"] {
            let adjusted = ThemeGoldenHarness.expectedValue(
                golden, selector: ".task-list-item input", property: property,
                mode: mode, osMajorVersion: 27
            )
            #expect(adjusted == expected)
            #expect(ThemeGoldenHarness.expectedValue(
                golden, selector: ".task-list-item input", property: property,
                mode: mode, osMajorVersion: 26
            ) == golden)
            #expect(ThemeGoldenHarness.normalize("rgb(129, 129, 129)") != adjusted)
        }
        #expect(ThemeGoldenHarness.expectedValue(
            golden, selector: "p", property: "color", mode: mode, osMajorVersion: 27
        ) == golden)
        #expect(ThemeGoldenHarness.expectedValue(
            golden, selector: ".task-list-item input", property: "backgroundColor",
            mode: mode, osMajorVersion: 27
        ) == golden)
    }
}
#endif
