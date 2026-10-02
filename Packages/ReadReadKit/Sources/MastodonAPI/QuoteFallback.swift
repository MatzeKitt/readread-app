import Foundation

/// The "RE: <link>" paragraph Mastodon writes into every quote post.
///
/// It is there for apps that cannot show quotes, marked `class="quote-inline"` so that apps which
/// can will drop it. Dropped only where the quoted post is actually shown: a quote whose post may
/// not be shown — pending, revoked, deleted — keeps the link, which is then all there is.
public enum QuoteFallback {

    /// Matches the paragraph whatever else its tag carries. Non-greedy, so it stops at its own
    /// `</p>` rather than the post's last one.
    private static let paragraph = try? NSRegularExpression(
        pattern: #"<p\b[^>]*\bclass="[^"]*\bquote-inline\b[^"]*"[^>]*>.*?</p>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// The status HTML without the fallback paragraph.
    public static func removing(from html: String) -> String {
        guard let paragraph, html.contains("quote-inline") else { return html }
        return paragraph.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..., in: html),
            withTemplate: ""
        )
    }
}
