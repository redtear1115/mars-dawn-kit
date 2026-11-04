#if os(macOS)
import Foundation

/// What an export does with collapsible blocks: every `<details>`, which also covers `:::spoiler`
/// and Obsidian's foldable callouts (`> [!note]-`), since those render as `<details>` too
/// (redtear1115/mars-dawn#300).
///
/// In both modes a printed `<summary>` is a bold line with no disclosure triangle, open or
/// closed, and front matter stays out of the PDF.
public enum DetailsMode: String, CaseIterable, Sendable {
    /// Every `<details>` prints open: what export has always done, and the default.
    case expand
    /// Only a `<details>` that is open in the rendered page prints its content (`<details open>`,
    /// `:::spoiler {state="open"}`, `> [!tip]+`); the others print their summary alone.
    ///
    /// "Open in the rendered page" is what the preview first shows. In an exclusive group
    /// (`<details name="…">`) WebKit keeps only one member open, the first open one in the
    /// document, so a group written with several `open` members prints only that first one open.
    case asWritten = "as-written"
}
#endif
