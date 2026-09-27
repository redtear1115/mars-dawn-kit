#if os(macOS)
import AppKit
import MarsDawnKit
import MarsDawnThemes
import WebKit

/// Renders the kit's fixed sample document with one theme to a PNG, for the website's theme
/// gallery (`marsdawn theme preview`, kit #139).
///
/// The page is the exporter's own offscreen page (`DocumentExporter`): the same bundled preview
/// template, content-rule list and CSP, with **remote images always off**, so it loads nothing
/// from the network. What it is styled with comes from a registry that serves exactly the one
/// theme (`ThemeRegistry(serving:)`), so its `themes.css` and spliced `preview.css` are that
/// theme's generated CSS and nothing else -- and the only input is a `ValidatedTheme`, which only
/// `ThemeValidator` can make. Nothing from the theme's file reaches the page except through the
/// generator: the sample text is fixed, and the theme's name and summary are not shown.
package enum ThemePreviewRenderer {
    package enum Appearance: String, CaseIterable, Sendable {
        case light, dark
    }

    /// The widths a preview may be rendered at, in pixels (and CSS pixels: the page is laid out at
    /// this width and drawn at one pixel per CSS pixel).
    package static let widthRange = 600...2000
    package static let defaultWidth = 1200
    /// The tallest image made, whatever the theme's sizes do to the sample's height.
    package static let maxHeight = 8000

    package enum RenderError: LocalizedError {
        case widthOutOfRange(Int)
        case snapshotFailed
        case encodingFailed

        package var errorDescription: String? {
            switch self {
            case .widthOutOfRange(let width): "width \(width) is outside \(widthRange.lowerBound)–\(widthRange.upperBound)"
            case .snapshotFailed: "the page couldn't be captured"
            case .encodingFailed: "the capture couldn't be encoded as PNG"
            }
        }
    }

    package struct Result: Sendable {
        package let png: Data
        package let width: Int
        package let height: Int
    }

    /// The fixed sample every preview shows: headings, lists, a quote, a table, code, a Mermaid
    /// diagram, math and a rule -- one of each element a theme styles.
    package static let sampleMarkdown = #"""
    # Field notes

    A theme sets the page's colours and type. This sample shows **bold**, *italic*, `inline code`
    and [a link](#field-notes), then each block a theme styles.

    ## Lists

    - Survey the ridge at first light
    - Log wind speed and dust
      - Twice an hour
    - Return before dusk

    1. Calibrate the spectrometer
    2. Sample three sites
    3. Compare with yesterday

    > The dust settles by noon; the best readings come after that.

    ## Table

    | Site | Depth (cm) | Iron (%) |
    | --- | ---: | ---: |
    | Ridge | 12 | 18.4 |
    | Basin | 30 | 21.1 |
    | Crater rim | 7 | 16.9 |

    ## Code

    ```swift
    struct Reading {
        let site: String
        var iron: Double // percent by mass
    }

    func average(_ readings: [Reading]) -> Double {
        readings.map(\.iron).reduce(0, +) / Double(readings.count)
    }
    ```

    ## Diagram

    ```mermaid
    flowchart LR
      A[Sample] --> B{Clean?}
      B -- yes --> C[Measure]
      B -- no --> D[Discard]
      C --> E[(Log)]
    ```

    ## Math

    The mean of $n$ readings is $\bar{x} = \frac{1}{n}\sum_{i=1}^{n} x_i$, and

    $$
    \sigma = \sqrt{\frac{1}{n}\sum_{i=1}^{n} (x_i - \bar{x})^2}
    $$

    ---

    Rendered by MarsDawn.
    """#

    /// Renders `markdown` (the sample unless a test passes its own) with `theme` in `appearance` at
    /// `width`, and returns it as a PNG exactly `width` pixels wide.
    ///
    /// `inspect` is for tests: it runs against the prepared page before it is captured.
    @MainActor
    package static func render(
        theme: ValidatedTheme,
        appearance: Appearance,
        width: Int = defaultWidth,
        markdown: String = sampleMarkdown,
        inspect: ((PreviewWKWebView) async throws -> Void)? = nil
    ) async throws -> Result {
        guard widthRange.contains(width) else { throw RenderError.widthOutOfRange(width) }
        let registry = ThemeRegistry(serving: [theme])
        // The exporter's scheme handler takes the registry that is current when it is made, so
        // the page is served from `registry` and from nothing else.
        let exporter = ThemeRegistry.$override.withValue(registry) {
            DocumentExporter(baseDirectory: nil, allowRemoteImages: false, width: CGFloat(width))
        }
        let webView = exporter.webView
        webView.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        try await exporter.prepare(markdown: markdown, theme: PreviewTheme(validated: theme))
        if let inspect { try await inspect(webView) }

        let measured = try await webView.evaluateJavaScript(
            "Math.ceil(Math.max(document.documentElement.scrollHeight, document.body.scrollHeight))"
        ) as? Int ?? 0
        let height = min(max(measured, 1), maxHeight)
        webView.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        webView.layoutSubtreeIfNeeded()
        // Layout after the resize (reading a layout property forces it); no requestAnimationFrame:
        // an offscreen view gets no frames.
        _ = try? await webView.evaluateJavaScript("document.documentElement.getBoundingClientRect().height")

        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        configuration.snapshotWidth = NSNumber(value: width)
        configuration.afterScreenUpdates = true
        let image = try await webView.takeSnapshot(configuration: configuration)
        return try encode(image, width: width, height: height)
    }

    /// Draws `image` into an sRGB bitmap of exactly `width` × `height` pixels, whatever the
    /// capture's own scale, and encodes it as PNG.
    @MainActor
    static func encode(_ image: NSImage, width: Int, height: Int) throws -> Result {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let srgb = bitmap.retagging(with: .sRGB) else { throw RenderError.snapshotFailed }
        srgb.size = NSSize(width: width, height: height)
        guard let context = NSGraphicsContext(bitmapImageRep: srgb) else { throw RenderError.snapshotFailed }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = srgb.representation(using: .png, properties: [:]) else { throw RenderError.encodingFailed }
        return Result(png: png, width: width, height: height)
    }
}
#endif
