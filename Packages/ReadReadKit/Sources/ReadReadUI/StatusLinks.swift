import Foundation
import ReadReadModel
import ReadReadSupport
import SwiftUI

/// One link a post points at, as the row's context menu offers it.
struct StatusLink: Hashable {
    let url: URL
    let title: String
}

/// The links in a post, for opening from the timeline without opening the post first.
///
/// A row's links open with a tap on the text, but the text is clipped at
/// `StatusTextCache.characterLimit`, so a link further down a long post is not in the row at all.
/// The context menu names every one, and is also where a link is followed without aiming at a few
/// underlined words.
enum StatusLinks {

    /// The links the row's menu offers for an item: a post's, and none behind a content warning.
    ///
    /// None behind a warning for the reason the row hides its link preview there: the links' text
    /// is part of what the warning hides. The post itself is one tap away. And none for an
    /// article, whose excerpt is a sample of the page rather than something it says to the reader.
    static func links(offeredFor item: CachedItem) -> [StatusLink] {
        guard item.kind == .status, !item.isBehindContentWarning else { return [] }
        return links(inStatusHTML: item.contentHTML, excluding: item.url)
    }

    /// Every web link in the post, in the order it mentions them, once each.
    ///
    /// Read from the status HTML rather than from the row's cached text, because the row's copy is
    /// clipped at `StatusTextCache.characterLimit` and has had its links removed — and a link
    /// beyond the clip is exactly the one the row cannot show.
    ///
    /// Mentions and hashtags are left out. Mastodon marks both up as anchors, but they point at a
    /// profile or a tag page on somebody's instance rather than at anything the post is linking
    /// to, and a post addressed to five people would otherwise bury its one real link under five
    /// profiles.
    ///
    /// - Parameter excluded: The post's own address, which Open in Browser already covers. A post
    ///   quoting itself is rare, but a menu listing the same destination twice under two names is
    ///   not something to leave to chance.
    static func links(inStatusHTML html: String?, excluding excluded: URL? = nil) -> [StatusLink] {
        guard let html, !html.isEmpty else { return [] }

        var seen: Set<URL> = excluded.map { [$0] } ?? []
        var links: [StatusLink] = []

        for anchor in HTMLParser.parse(html).descendants where anchor.name == "a" {
            guard let href = anchor.attribute("href"),
                  let url = URL(string: href),
                  // Web links only, the same line `LinkPolicy` and the article reader draw. Mastodon
                  // sanitises a post down to these, but a remote instance's markup is still somebody
                  // else's markup.
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  !isMentionOrHashtag(anchor),
                  seen.insert(url).inserted
            else { continue }

            links.append(StatusLink(url: url, title: title(for: anchor.text, url: url)))
        }
        return links
    }

    /// Whether Mastodon's markup marks the anchor as a mention or a hashtag.
    ///
    /// Matched as whole class tokens: the classes come as `u-url mention` and `mention hashtag`,
    /// and a substring match would also catch any class that merely contains the word.
    private static func isMentionOrHashtag(_ anchor: HTMLElement) -> Bool {
        let classes = (anchor.attribute("class") ?? "").lowercased().split(whereSeparator: \.isWhitespace)
        return classes.contains("mention") || classes.contains("hashtag")
    }

    /// What to call the link in the menu.
    ///
    /// The anchor text where the author wrote some, followed by where it actually goes — a link's
    /// text can claim anything, which is the same reason the link preview prints its host. A bare
    /// address is shown as itself without the scheme, which is what Mastodon's own markup does by
    /// hiding it, and repeating the host after it would say the same thing twice.
    private static func title(for text: String, url: URL) -> String {
        let host = url.host(percentEncoded: false).map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }

        guard !text.isEmpty else { return host ?? url.absoluteString }

        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            return String(text.dropFirst(scheme.count))
        }

        guard let host, !text.localizedCaseInsensitiveContains(host) else { return text }
        return "\(text) — \(host)"
    }
}

/// The post's links, as a submenu of the row's context menu.
///
/// Always a submenu, even for a single link. Beside Open in Browser — which for a post opens the
/// *post* — a plain Open Link item would be two lookalike entries whose difference the reader has
/// to remember; the submenu names each link by its text, which is what tells them apart.
///
/// A view of its own so the post's markup is parsed in this body and no other: whatever SwiftUI
/// evaluates while realising a row, the row's own body is not where this work lands.
struct StatusLinksMenu: View {

    let item: CachedItem

    /// Named so a test can resolve it — an SF Symbol that does not exist fails silently. See
    /// `StatusActionSymbol`.
    nonisolated static let symbol = "arrow.up.right.square"

    var body: some View {
        let links = StatusLinks.links(offeredFor: item)

        if !links.isEmpty {
            Menu {
                ForEach(links, id: \.self) { link in
                    // `Link`, like Open in Browser, so it goes through the app's `openURL` and
                    // honours the in-app browser setting exactly as a link tapped in the post does.
                    Link(destination: link.url) {
                        Text(verbatim: link.title)
                    }
                }
            } label: {
                // Not `link`, which Copy Link directly above already draws: two identical glyphs
                // in a row read as one entry repeated.
                Label("Open Link", systemImage: Self.symbol)
            }
        }
    }
}
