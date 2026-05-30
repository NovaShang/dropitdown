import SwiftUI
import MarkdownUI

/// Render a markdown note (front-matter stripped) using MarkdownUI — a
/// mature CommonMark/GFM renderer. Replaces the old AttributedString path,
/// which only handled inline styling (no headings/lists/code/tables) and
/// bogged down on longer notes.
struct MarkdownText: View {
    let content: String
    /// Hard cap on characters fed to MarkdownUI. MarkdownUI renders a
    /// paragraph as a deep `Text + Text + …` concatenation, and SwiftUI's
    /// resolver recurses per node — a few thousand inline runs overflow the
    /// main-thread stack. Callers that can't guarantee a small note (e.g.
    /// the History preview card) pass a cap; oversized input is truncated
    /// with an ellipsis. `nil` means the caller already bounded the size.
    var maxCharacters: Int? = nil

    var body: some View {
        var body = MarkdownText.stripFrontmatter(content)
        var truncated = false
        if let cap = maxCharacters, body.count > cap {
            body = String(body.prefix(cap))
            truncated = true
        }
        return Markdown(truncated ? body + "\n\n…" : body)
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
