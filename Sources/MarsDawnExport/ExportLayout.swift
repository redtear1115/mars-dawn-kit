#if os(macOS)
import AppKit

/// How an exported PDF is laid out on the page (mars-dawn#432).
public enum ExportLayout: String, CaseIterable, Sendable {
    /// What export has always produced: the default.
    case document
    /// A manual: wider margins with a 25 mm binding side, and every top-level heading starts a
    /// new page.
    case manual

    /// Page margins in points. The exporter lays the page out at the paper width minus the left
    /// and right margins, and prints with the same margins: setting only one of the two moves
    /// the page breaks (mars-dawn#432 spike, M4).
    public var pageMargins: NSEdgeInsets {
        switch self {
        case .document:
            NSEdgeInsets(top: 52, left: 46, bottom: 52, right: 46)
        case .manual:
            // The binding side is the left on every page: there is no duplex.
            NSEdgeInsets(top: Self.millimetres(20), left: Self.millimetres(25), bottom: Self.millimetres(20), right: Self.millimetres(20))
        }
    }

    /// Width of the text column on a page `paperWidth` points wide.
    public func printableWidth(paperWidth: CGFloat) -> CGFloat {
        paperWidth - pageMargins.left - pageMargins.right
    }

    private static func millimetres(_ value: Double) -> CGFloat { CGFloat(value * 72 / 25.4) }
}
#endif
