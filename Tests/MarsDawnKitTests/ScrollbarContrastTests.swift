#if os(macOS)
import AppKit
import Testing
import WebKit
@testable import MarsDawnKit

/// The preview's scrollbar has to be visible in every theme (mars-dawn#23). The page sets
/// `color-scheme: light dark`, so without `scrollbar-color` WebKit draws its own scrollbar for the
/// scheme rather than for the theme, and on a dark theme both the track and the thumb came out
/// near-black. A reader with "Always show scroll bars" then saw a black strip with no thumb in it.
@Suite(.timeLimit(.minutes(1)))
struct ScrollbarContrastTests {
    nonisolated(unsafe) private static let cases: [(PreviewTheme, Bool)] = PreviewTheme.all.flatMap { [($0, false), ($0, true)] }

    /// The thumb as the CSS mixes it: the muted colour, a quarter of the way to the page.
    private func thumb(_ palette: PreviewTheme.Palette) -> (Double, Double, Double) {
        let muted = channels(palette.muted), background = channels(palette.background)
        return (
            muted.0 * 0.75 + background.0 * 0.25,
            muted.1 * 0.75 + background.1 * 0.25,
            muted.2 * 0.75 + background.2 * 0.25
        )
    }

    @Test(arguments: cases)
    func theThumbStandsOutAgainstTheTrack(theme: PreviewTheme, dark: Bool) {
        let palette = theme.palette(dark: dark)
        let label = "\(theme.id) \(dark ? "dark" : "light")"
        // WCAG 1.4.11 asks 3:1 for a control's own colour against what it sits on. The track is
        // the page, so this is the thumb against the page.
        #expect(contrast(thumb(palette), channels(palette.background)) >= 3, "\(label) thumb on track")
    }

    /// WebKit, not the stylesheet, has the last word: `scrollbar-color` has to survive the
    /// `color-mix` and the theme's own variables.
    @MainActor
    @Test func theRealPageResolvesBothColours() async throws {
        let webView = PreviewWKWebView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 400),
            configuration: PreviewWebView.makeConfiguration()
        )
        webView.appearance = NSAppearance(named: .darkAqua)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.applyContentRuleList(try await PreviewContentRules.ruleList(allowRemoteImages: false))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter.continuation = continuation
            if webView.load(URLRequest(url: PreviewSchemeHandler.pageURL(lightTheme: .dawn, darkTheme: .dawn))) == nil {
                continuation.resume(throwing: URLError(.cancelled))
            }
        }

        let resolved = (try await webView.evaluateJavaScript(
            "getComputedStyle(document.documentElement).scrollbarColor"
        )) as? String ?? ""
        // Two colours, neither of them the default. `auto` is what the bug looked like.
        #expect(resolved != "auto", "the page is back to WebKit's own scrollbar colours")
        let colours = resolved.components(separatedBy: ") ").filter { !$0.isEmpty }
        #expect(colours.count == 2, "expected a thumb and a track, got \(resolved)")
        #expect(resolved.contains("srgb") || resolved.contains("rgb"), "\(resolved)")
    }

    final class NavigationWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Error>?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    // MARK: Colour arithmetic

    private func channels(_ hex: String) -> (Double, Double, Double) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        func channel(_ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) / 255 }
        return (channel(16), channel(8), channel(0))
    }

    private func luminance(_ colour: (Double, Double, Double)) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(colour.0) + 0.7152 * linear(colour.1) + 0.0722 * linear(colour.2)
    }

    private func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let (l1, l2) = (luminance(a), luminance(b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}
#endif
