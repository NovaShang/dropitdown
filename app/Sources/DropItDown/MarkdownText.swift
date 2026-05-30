import SwiftUI

/// Render a markdown body with the YAML front-matter stripped. Falls back
/// to plain text for content the system parser can't handle.
struct MarkdownText: View {
    let content: String

    var body: some View {
        let body = MarkdownText.stripFrontmatter(content)
        if let attr = try? AttributedString(
            markdown: body,
            options: .init(
                allowsExtendedAttributes: false,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) {
            Text(attr)
                .font(.body)
                .textSelection(.enabled)
        } else {
            Text(body)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
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
