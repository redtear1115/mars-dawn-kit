import Foundation
import Testing
@testable import MarsDawnKit

/// Callouts need no new permission (kit #135): the page's Content-Security-Policy strings are the
/// ones release/0.7.1 had before them, character for character. A change to any is a decision of
/// its own (the slice's stop rule), so this test says so by name.
struct CalloutCSPTests {
    static let previewMeta = "default-src 'none'; script-src marsdawn-app:; style-src marsdawn-app: 'unsafe-inline'; img-src marsdawn-app: marsdawn-asset: data: __REMOTE_IMAGE_SOURCES__; font-src marsdawn-app: data:; base-uri 'none'; form-action 'none'"
    static let blocked = "default-src 'none'; img-src marsdawn-html: data:; style-src marsdawn-html: 'unsafe-inline'; font-src marsdawn-html: data:; media-src marsdawn-html:; script-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; connect-src 'none'; manifest-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"
    static let running = "default-src 'none'; img-src marsdawn-html: data: https:; style-src marsdawn-html: 'unsafe-inline' https:; font-src marsdawn-html: data: https:; media-src marsdawn-html: https:; script-src 'unsafe-inline'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; connect-src https:; manifest-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"

    @Test func thePreviewPagesPolicyIsUnchanged() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MarsDawnKit/Resources/Preview/index.html")
        let html = try String(contentsOf: url, encoding: .utf8)
        let policies = html.matches(of: /http-equiv="Content-Security-Policy"\s+content="([^"]*)"/).map { String($0.output.1) }
        #expect(policies == [Self.previewMeta], "the page's CSP changed: \(policies)")
    }

    @Test func theDocumentPagesPoliciesAreUnchanged() {
        #expect(HTMLDocumentSchemeHandler.blockedCSP == Self.blocked)
        #expect(HTMLDocumentSchemeHandler.runningCSP == Self.running)
    }
}
