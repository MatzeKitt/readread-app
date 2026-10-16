import Foundation

/// A URL with a second, complete URL glued onto its host.
///
/// Weebly's feeds prefix every image with their CDN host even when the path is already absolute,
/// so `content:encoded` carries
/// `https://49114053-….preview.editmysite.comhttps://heyeased.weebly.com/uploads/….png`. That
/// parses as a URL on the host `…editmysite.comhttps`, which does not exist, and the image never
/// loads. The page itself has the right URL; only the feed is broken.
///
/// The inner URL is the one that works, so the repair drops everything before it. A host running
/// straight into `http://` or `https://` is never a real address, which is what makes this safe to
/// apply to any markup rather than to one publisher's.
public enum DoubledURL {

    /// The outer scheme and host, up to the point where the second scheme starts. The host stops
    /// at the first `/`, so a URL that merely *contains* another one — a share link with
    /// `?url=https://…` — is left alone.
    private static let outerPrefix = try? NSRegularExpression(
        pattern: #"\bhttps?://[^\s"'<>/]+?(?=https?://)"#,
        options: [.caseInsensitive]
    )

    /// The markup, or a single URL, with every doubled URL cut down to its inner half.
    public static func repairing(_ text: String) -> String {
        guard let outerPrefix, text.contains("://") else { return text }
        return outerPrefix.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )
    }
}
