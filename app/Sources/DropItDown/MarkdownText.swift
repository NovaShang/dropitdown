import SwiftUI
import MarkdownUI

/// Render a markdown note (front-matter stripped) using MarkdownUI — a
/// mature CommonMark/GFM renderer. Replaces the old AttributedString path,
/// which only handled inline styling (no headings/lists/code/tables) and
/// bogged down on longer notes.
struct MarkdownText: View {
    let content: String

    var body: some View {
        Markdown(MarkdownText.stripFrontmatter(content))
            .markdownTheme(.dropItDown)
            .textSelection(.enabled)
    }

    /// Drop the leading `---\nkey: value\n...\n---\n` block, if present.
    static func stripFrontmatter(_ text: String) -> String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return text }
        var closeIdx: Int?
        for i in 1..<lines.count {
            if lines[i] == "---" { closeIdx = i; break }
        }
        guard let close = closeIdx else { return text }
        return lines.dropFirst(close + 1)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Theme {
    /// GitHub theme tuned to the app: 15pt body, accent-coloured links, and
    /// a softer inline-code background so it reads well in the Notes pane.
    static let dropItDown = Theme.gitHub
        .text {
            FontSize(15)
        }
        .link {
            ForegroundColor(.accentColor)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.88))
            BackgroundColor(Color.secondary.opacity(0.12))
        }
}
