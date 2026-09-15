import Foundation
import ReadReadModel
import SwiftUI

/// Formatted post text for timeline rows, parsed once per post.
///
/// The timeline shows a Mastodon post as the post rather than as a headline, so it has to keep the
/// author's formatting — the links, the emphasis, the line breaks between paragraphs. That means
/// an `AttributedString` built from the status HTML, and building one is exactly the kind of work
/// a list row must never do: rows are realised as fast as the list can scroll, and every re-render
/// would re-parse the same markup.
///
/// So it is parsed on first sight and kept. A row that scrolls off and back is free, which is the
/// case that actually happens while reading.
///
/// Bounded, and by insertion order rather than by use: an exact LRU would have to touch the order
/// array on every *read*, which is a write on the hot path this type exists to keep clean. A
/// timeline scrolls in one direction at a time, so insertion order is close enough to use order
/// for the eviction to fall on rows nobody is looking at.
@MainActor
final class StatusTextCache {

    static let shared = StatusTextCache()

    private var texts: [String: AttributedString] = [:]
    private var order: [String] = []

    /// Comfortably more than a screen holds, so scrolling back never re-parses, and small enough
    /// that a long timeline does not accumulate every post it has ever drawn.
    private let limit = 600

    /// The most of a post a timeline row shows.
    ///
    /// Five hundred is Mastodon's own posting limit, but that is a *local* limit on the instance
    /// doing the posting — a federated timeline routinely carries posts from instances that allow
    /// far more, and one of those turns a row into several screens of text with the next post
    /// somewhere below the horizon. A row is a decision about whether to read the thing; the post
    /// itself is one tap away and shows in full.
    static let characterLimit = 500

    /// The post's text with its formatting, or a plain fallback.
    ///
    /// - Parameter id: The item id, which is what keys the cache. Safe because the content of a
    ///   status never changes under a fixed id — an edited post arrives as a new revision that
    ///   re-ingests the row, and `contentHTML` is written then, so keying on the id alone cannot
    ///   serve stale text for long enough to matter.
    func text(id: String, html: String?, plain: String) -> AttributedString {
        if let cached = texts[id] { return cached }

        let rendered = Self.render(html: html, plain: plain, stripsLinks: true)
        texts[id] = rendered
        order.append(id)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            texts.removeValue(forKey: oldest)
        }
        return rendered
    }

    /// The post's text in full, for the reading pane.
    ///
    /// The same parse as ``text(id:html:plain:)`` without the row's clip. The pane is where a post
    /// is actually read, so cutting it at ``characterLimit`` there would truncate long posts in the
    /// one place they must be whole — which is exactly what routing the reader through the row's
    /// cache would do.
    ///
    /// Its own map rather than a flag on the same one, because the two versions differ only in
    /// length: sharing a key would let whichever view asked first decide how much of the post the
    /// other one got.
    ///
    /// Bounded far more tightly than the row cache. Rows are realised by the screenful while
    /// scrolling; full posts are read one thread at a time, and each one held here is the whole
    /// post rather than five hundred characters of it.
    func fullText(id: String, html: String?, plain: String) -> AttributedString {
        if let cached = fullTexts[id] { return cached }

        let rendered = Self.render(html: html, plain: plain, limit: nil)
        fullTexts[id] = rendered
        fullOrder.append(id)
        while fullOrder.count > fullLimit, let oldest = fullOrder.first {
            fullOrder.removeFirst()
            fullTexts.removeValue(forKey: oldest)
        }
        return rendered
    }

    private var fullTexts: [String: AttributedString] = [:]
    private var fullOrder: [String] = []

    /// A thread and the few posts read before it.
    private let fullLimit = 60

    /// - Parameter stripsLinks: Whether to defuse the link attributes, leaving the anchor text
    ///   readable as a link but not acting as one. Set for a timeline row; never for the reading
    ///   pane.
    ///
    ///   Both paths mark their links the same way — see ``recoloured(_:)``. This is only about the
    ///   tap: a link inside a row is a second target sitting on top of the row's own, so tapping a
    ///   post that happens to be mostly a link opened the browser instead of the post. The row is
    ///   the affordance in a list; the links are live in the pane the row opens.
    private static func render(
        html: String?,
        plain: String,
        limit: Int? = characterLimit,
        stripsLinks: Bool = false
    ) -> AttributedString {
        guard let html, !html.isEmpty else { return clippedIfNeeded(AttributedString(plain), to: limit) }

        // The same conversion the detail view uses, so a post does not change shape between the
        // list and the reader. Markdown is the intermediate because `AttributedString` can parse
        // it off the main thread, unlike its HTML importer.
        guard let attributed = try? AttributedString(
            markdown: MastodonMarkdown.markdown(fromStatusHTML: html),
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            // A post whose markup will not parse still has to show its words.
            return clippedIfNeeded(AttributedString(plain), to: limit)
        }
        return clippedIfNeeded(stripsLinks ? defusedLinks(attributed) : liveLinks(attributed), to: limit)
    }

    /// What a link is drawn in, in the row and in the reading pane alike.
    ///
    /// Not a hue of its own, which is the whole point: a run carrying a `.link` is otherwise drawn
    /// in the accent colour, so every post containing one had a stripe of saturated blue through
    /// text that is the app's own greys — and the identical post read in the pane changed hue from
    /// the identical post in the row.
    ///
    /// How far it sits above the text differs by column, which is why the underline exists. In the
    /// row it is half a step, over ``ItemRow/bodyColor``; in the pane the post is at full contrast
    /// and it is no step at all.
    ///
    /// It was an opacity on `.secondary` once, which was wrong in a way worth recording: lowering
    /// opacity moves a colour toward the *background*, so "lighter" only holds in light mode and
    /// dark mode got the opposite. A semantic colour is the only kind that means the same thing in
    /// both appearances, and it follows the accessibility contrast settings for free.
    ///
    /// Being the same colour as the text is what makes the underline load-bearing rather than
    /// decorative — see ``recoloured(_:)``.
    ///
    /// Not private, because the pane has to spend it twice: once as this attribute and once as a
    /// `tint`. See ``liveLinks(_:)``.
    static let linkColor = Color.primary

    /// The same text with its links marked but defused: no longer tappable.
    ///
    /// The tap is the whole reason. A link inside a row is a second target sitting on top of the
    /// row's own, so tapping a post that happens to be mostly a link opened the browser instead of
    /// the post. The row is the affordance in a list; the links are live in the pane it opens.
    ///
    /// Marking first and clearing `link` afterwards matters: with the link still in place the run
    /// is unambiguously a link, which is what makes it findable.
    static func defusedLinks(_ text: AttributedString) -> AttributedString {
        var stripped = recoloured(text)
        // Assigned across the whole range rather than run by run, for the reason in
        // ``recoloured(_:)``.
        stripped.link = nil
        return stripped
    }

    /// The same text with its links marked and still live, for the reading pane.
    static func liveLinks(_ text: AttributedString) -> AttributedString {
        recoloured(text)
    }

    /// Paints every link run in ``linkColor`` and underlines it.
    ///
    /// The underline is not decoration. Contrast used to carry the whole job — the anchor text was
    /// `.primary` against a body a full step down — and it cannot any more: the pane sets its
    /// posts at full contrast, so there is no step there at all, and the row's body has come up to
    /// ``ItemRow/bodyColor``, half a step below. Half a step is a hint, not a mark. Losing the mark
    /// matters most in exactly the post where it is least tolerable: one that is mostly a link
    /// reads as a bare sentence with the link missing.
    ///
    /// The ranges are collected *before* anything is written, because `AttributedString` merges
    /// adjacent runs that end up with identical attributes — so mutating attributes while walking
    /// the runs those attributes produced is a mutation during iteration.
    private static func recoloured(_ text: AttributedString) -> AttributedString {
        var painted = text

        let linkRanges = painted.runs.compactMap { run in
            run.link == nil ? nil : run.range
        }
        for range in linkRanges {
            painted[range].foregroundColor = linkColor
            painted[range].underlineStyle = .single
        }
        return painted
    }

    /// Clips to `limit`, or returns the text untouched when there is none.
    ///
    /// Named apart from ``clipped(_:to:)`` rather than overloading it: an `Int?` argument against
    /// an `Int` parameter with a default is exactly the shape that resolves to the wrong one.
    private static func clippedIfNeeded(_ text: AttributedString, to limit: Int?) -> AttributedString {
        guard let limit else { return text }
        return clipped(text, to: limit)
    }

    /// Cuts a post down to ``characterLimit``, at a word boundary where there is one nearby.
    ///
    /// Clipped here rather than with `lineLimit` in the row, because the two answer different
    /// questions. `lineLimit` is about how tall the row is *allowed* to be and depends on the
    /// width it happens to be laid out at; this is about how much of the post is worth laying out
    /// at all. Doing it here also means the cost is paid once per post and the cache holds the
    /// short version, rather than keeping a four-thousand-character string alive to draw a
    /// fraction of it.
    static func clipped(_ text: AttributedString, to limit: Int = characterLimit) -> AttributedString {
        let characters = text.characters
        guard characters.count > limit else { return text }

        var end = characters.index(characters.startIndex, offsetBy: limit)

        // Back up to the last space, so the cut does not land mid-word. Bounded, because a post
        // can legitimately have no spaces in its last stretch — a URL, or a language that does not
        // write them — and searching back to the start would throw away most of the post.
        let earliest = characters.index(characters.startIndex, offsetBy: limit - wordBoundaryWindow)
        var probe = end
        while probe > earliest {
            let previous = characters.index(before: probe)
            if characters[previous].isWhitespace {
                end = previous
                break
            }
            probe = previous
        }

        var clipped = AttributedString(text[..<end])

        // Trailing whitespace before an ellipsis reads as a gap rather than a cut.
        while let last = clipped.characters.last, last.isWhitespace {
            clipped.removeSubrange(clipped.index(beforeCharacter: clipped.endIndex)..<clipped.endIndex)
        }

        // Plain, and deliberately so: appending it to a run that happened to be a link would
        // otherwise make the ellipsis part of the link.
        clipped.append(AttributedString("…"))
        return clipped
    }

    /// How far back to look for a space. Roughly a long word.
    private static let wordBoundaryWindow = 24
}
