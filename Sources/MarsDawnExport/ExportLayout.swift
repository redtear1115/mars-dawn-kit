#if os(macOS)
import AppKit

/// How an exported PDF is laid out on the page (mars-dawn#432).
public enum ExportLayout: String, CaseIterable, Sendable {
    /// What export has always produced: the default.
    case document
    /// A manual: wider margins with a 25 mm binding side, and every top-level heading starts a
    /// new page.
    case manual
    /// A handout: the document's margins plus a blank notes column of about a third of the
    /// column on the right of every page, a title header on page 1 and a "name · date · n / N"
    /// footer (mars-dawn#432 S3).
    case handout

    /// Page margins in points. The exporter lays the page out at the paper width minus the left
    /// and right margins, and prints with the same margins: setting only one of the two moves
    /// the page breaks (mars-dawn#432 spike, M4).
    public var pageMargins: NSEdgeInsets {
        switch self {
        case .document:
            NSEdgeInsets(top: 51, left: 45, bottom: 51, right: 45)
        case .manual:
            // The binding side is the left on every page: there is no duplex.
            NSEdgeInsets(top: Self.millimetres(20), left: Self.millimetres(25), bottom: Self.millimetres(20), right: Self.millimetres(20))
        case .handout:
            // The notes column is inside the printable area, so a table wider than the body can
            // run into it (mars-dawn#432 S3, amendment A1-R2); the body's own edge is `bodyMargins`.
            NSEdgeInsets(top: 51, left: 45, bottom: 51, right: 45)
        }
    }

    /// Where the body's text column ends: `pageMargins`, except in the handout, where the notes
    /// column (`notesColumnWidth`) sits between the body and the right margin. On A4 the
    /// handout's body is two thirds of the 505 pt between the outer margins.
    public var bodyMargins: NSEdgeInsets {
        var margins = pageMargins
        if self == .handout { margins.right += Self.notesColumnWidth }
        return margins
    }

    /// Width of the text column on a page `paperWidth` points wide.
    public func printableWidth(paperWidth: CGFloat) -> CGFloat {
        paperWidth - pageMargins.left - pageMargins.right
    }

    /// The handout's notes column, from the body's right edge to the outer margin.
    public static let notesColumnWidth: CGFloat = 168

    private static func millimetres(_ value: Double) -> CGFloat { CGFloat(value * 72 / 25.4) }
}
#endif
