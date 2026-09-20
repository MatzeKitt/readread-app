import Foundation

/// How long a post counts as, by Mastodon's rules rather than by Swift's.
///
/// A counter that simply counted characters would be wrong in the two cases that matter most, and
/// wrong in the direction that stops a reader posting something the instance would have accepted:
/// a link is a link however long it is, and a fediverse handle is mostly domain.
///
/// - **Every link counts as 23**, whatever its length. Mastodon replaces a URL with a fixed-width
///   shortened form when it counts, so a 200-character tracking URL costs 23.
/// - **A mention costs only its username.** `@someone@a.very.long.instance.example` counts as
///   `@someone`; the domain is free, because the instance is implied for everyone reading it.
/// - **A content warning counts too**, against the same limit as the body. That is why
///   ``count(text:spoilerText:)`` takes both rather than being called twice.
///
/// This is an honest approximation and not a guarantee, and the composer treats it as one. The
/// limit itself is per-instance — 500 is the default and most instances keep it, but some raise it
/// — and the app never asks an instance for its own figure. So the counter guides, and the
/// instance decides: a post over the real limit comes back as a 422 and is reported as such. See
/// ``MastodonError/rejected``.
public enum MastodonPostLength {

    /// What one link costs, whatever its length.
    public static let urlWeight = 23

    /// The default an instance ships with. Not authoritative — see the note above.
    public static let defaultLimit = 500

    /// What the instance will count this draft as.
    public static func count(text: String, spoilerText: String = "") -> Int {
        count(text) + count(spoilerText)
    }

    /// One field's contribution.
    static func count(_ text: String) -> Int {
        // URLs first, and that order is load-bearing: a URL may contain an `@` — a `mailto:` in a
        // link, a query parameter — and collapsing mentions first would eat a piece of it.
        var counted = replacing(text, pattern: Self.urlPattern) { _ in
            String(repeating: "x", count: urlWeight)
        }
        counted = replacing(counted, pattern: Self.mentionPattern) { match in
            // Group 1 is the `@user` half and group 2, when it is there at all, is the domain that
            // costs nothing. So group 1 is the answer either way.
            match.count >= 2 ? match[1] : match[0]
        }
        return counted.count
    }

    /// `https://…` up to the first whitespace, which is how a post is written.
    private static let urlPattern = "https?://[^\\s]+"

    /// `@user` with an optional `@host` after it. The host is what the count leaves out.
    private static let mentionPattern = "(@[A-Za-z0-9_]+)(@[A-Za-z0-9.\\-]+)?"

    /// Rewrites every match, handing the replacement the match's capture groups.
    ///
    /// Written by hand rather than with `stringByReplacingMatches(in:options:range:withTemplate:)`
    /// because a template cannot produce "23 of the letter x" — and building the replacement from
    /// the groups is also what keeps the mention rule readable.
    private static func replacing(
        _ text: String,
        pattern: String,
        with replacement: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        let nsText = text as NSString
        var result = ""
        var consumed = 0

        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            result += nsText.substring(with: NSRange(location: consumed, length: match.range.location - consumed))

            var groups: [String] = []
            for index in 0..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                groups.append(nsText.substring(with: match.range(at: index)))
            }
            result += replacement(groups)
            consumed = match.range.location + match.range.length
        }

        result += nsText.substring(from: consumed)
        return result
    }
}
