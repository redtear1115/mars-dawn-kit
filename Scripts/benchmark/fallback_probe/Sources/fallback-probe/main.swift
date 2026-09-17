import Foundation
import MarsDawnKit

// Renders one Markdown file with MarsDawnKit's own renderer (the same call
// MarsDawnExport makes before laying a page out) and prints the HTML to stdout.
// Used only by Scripts/benchmark/run.py to check, behaviorally, whether a build's
// renderer hit a dense-Markdown fallback for a given input, rather than guessing
// from the exported PDF.

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: fallback-probe <markdown-file>\n".utf8))
    exit(64)
}

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)

let markdown: String
do {
    markdown = try String(contentsOf: url, encoding: .utf8)
} catch {
    FileHandle.standardError.write(Data("fallback-probe: couldn't read \(path): \(error)\n".utf8))
    exit(2)
}

let html = MarkdownRenderer.render(markdown)
print(html)
