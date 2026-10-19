#if os(macOS)
import Foundation
import Testing
@testable import MarsDawnExport

/// The handbook layout's two error messages (kit #192): the English the app's string table
/// carries (mars-dawn#432), word for word. The kit has no translations of them.
struct ExportLayoutErrorTextTests {
    @Test func theHandbookMessagesAreTheApprovedEnglish() {
        #expect(DocumentExporter.ExportError.manualLayoutNeedsSave.errorDescription
            == "The Handbook layout can only be exported as a PDF file, not printed directly.")
        #expect(DocumentExporter.ExportError.manualLayoutPaginationChanged.errorDescription
            == "The Handbook layout’s page numbers couldn’t be worked out for this document, so nothing was saved. Try again with the Document layout.")
    }
}
#endif
