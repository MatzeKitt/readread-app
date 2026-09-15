import Foundation

/// The preview of a link a post points at: picture, headline, blurb.
///
/// This is Mastodon's own `PreviewCard`, which the instance builds from the target page's oEmbed
/// endpoint or, failing that, its OpenGraph tags. Read from the timeline response rather than
/// fetched here, and that is the entire design decision worth recording: a reader that went and
/// scraped `og:` tags itself would issue a request per link to a site it has no relationship with,
/// from the reader's own address, while scrolling — which announces to every linked publisher that
/// this person scrolled past a post mentioning them. The instance has already done the fetch once,
/// for everybody, and hands over the result.
///
/// A plain value: it is denormalised onto ``CachedItem`` as scalar columns and rebuilt on read,
/// because a timeline row must not run a `JSONDecoder` to draw itself.
public struct LinkCard: Hashable, Sendable, Codable {

    /// Where the link goes. Kept as a string because that is what the column holds and what
    /// decides whether there is a card at all — see ``CachedItem/linkCard``.
    public var urlString: String

    /// `og:title`, as the instance resolved it.
    public var title: String

    /// `og:description`. Frequently empty, and a card is still worth showing without one.
    ///
    /// Not `description`, which would collide with `CustomStringConvertible` on a type this is
    /// interpolated into.
    public var summary: String

    /// `og:image`, already hosted or proxied by the instance in the usual case.
    public var imageURLString: String?

    public init(
        urlString: String,
        title: String,
        summary: String = "",
        imageURLString: String? = nil
    ) {
        self.urlString = urlString
        self.title = title
        self.summary = summary
        self.imageURLString = imageURLString
    }

    public var url: URL? {
        URL(string: urlString)
    }

    /// The picture to draw, over `https` only.
    ///
    /// A card's image URL comes from a third party by way of the instance, and it is the one part
    /// of a card that causes a request from the reader's device. Refusing plain `http` keeps that
    /// request off the wire in the clear; a card without a picture still shows its headline. The
    /// same rule the comment avatars follow.
    public var imageURL: URL? {
        guard let string = imageURLString, let url = URL(string: string) else { return nil }
        return url.scheme?.lowercased() == "https" ? url : nil
    }

    /// The site the link points at, for the line under the blurb.
    ///
    /// Derived from the URL rather than taken from the card's own `provider_name`, which Mastodon
    /// leaves empty for most sites and fills with whatever the page claimed for the rest. The host
    /// is a fact about where a tap would actually go, which is the useful thing to print next to
    /// somebody else's headline.
    public var hostLabel: String? {
        guard let host = url?.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Whether there is enough here to be worth a box.
    ///
    /// A card with no headline is the case this rules out: instances do produce them, for a link
    /// whose target answered with nothing useful, and an empty box under a post reads as a bug.
    public var isShowable: Bool {
        !title.isEmpty && url != nil
    }
}
