import ReadReadModel
import SwiftUI

/// One timeline row: source favicon and title, item title, and a three-line excerpt.
struct ItemRow: View {

    let item: CachedItem

    /// Source name for the header line. Passed in rather than looked up per row, so scrolling does
    /// not issue a fetch per cell.
    var sourceTitle: String?

    /// The feed's favicon, from `CachedSource`. Passed in for the same reason as the title.
    ///
    /// It has to come from the feed, because an *item* has no icon of its own: FreshRSS carries
    /// `iconUrl` on a subscription, not on an entry, so `CachedItem.iconURLString` is nil for
    /// every article ever ingested — which is why the timeline drew a radio-waves glyph on every
    /// row while the sidebar, built from the same feeds, showed their favicons.
    var sourceIconURLString: String?

    /// Whether to explain that the item arrived below the reading position.
    ///
    /// Off in the "older items arrived" list, where every row shares that state and the badge
    /// would be noise rather than an explanation.
    var showsLateArrival: Bool

    /// The reader's size preferences, passed in rather than read from the environment here.
    ///
    /// A row is realised as fast as the list can scroll, and reading an `@Observable` from inside
    /// one takes an observation dependency per row. The list already holds the settings, so it
    /// hands down the two values that matter.
    var headingScale: TextScale
    var bodyScale: TextScale

    /// Leading for the row's text, as a CSS-style multiple of the font size.
    ///
    /// One value for both kinds of row, and that is the whole point of it. A post's text and an
    /// article's excerpt are the same thing in the same style — the row's text, under the row's
    /// heading — so leading them differently made a timeline of mixed posts and articles read as
    /// two lists interleaved.
    ///
    /// It applied to statuses only at first, on the reasoning that an excerpt is a three-line
    /// sample nobody reads closely and stretching it apart costs row density for nothing. True of
    /// the excerpt in isolation, and beside the point next to the post directly above it: the
    /// mismatch is visible in a way the density is not.
    var lineHeight: Double

    /// Whether this post is behind a content warning.
    ///
    /// Derived rather than stored, from what ingest already does: a warned status has its
    /// *spoiler* text as `title` and an empty `excerpt`, precisely so the list can show the
    /// warning without showing the post. An empty post with no warning also lands here, and has
    /// nothing to reveal either way.
    private var hasContentWarning: Bool {
        item.kind == .status && item.excerpt.isEmpty
    }

    /// The post's text, with its formatting, from the shared parse cache.
    ///
    /// Behind a content warning this is the warning itself, plain, and the post's markup is never
    /// touched. Rendering `contentHTML` unconditionally — as the first version of this did —
    /// printed the hidden post straight into the timeline, which is the one thing a content
    /// warning exists to prevent.
    private var statusText: AttributedString {
        // The warning text itself, and capped like any other: a content warning is written by
        // hand and is usually a line, but nothing stops it being an essay.
        guard !hasContentWarning else {
            return StatusTextCache.clipped(AttributedString(item.title))
        }
        return StatusTextCache.shared.text(id: item.id, html: item.contentHTML, plain: item.title)
    }

    /// The link preview to draw under the post, if there is one to draw.
    ///
    /// Suppressed behind a content warning, for the same reason the media is: the card carries the
    /// linked page's own headline and picture, and printing those beside the warning would answer
    /// the question the author asked not to be answered — a post warning for a news story and
    /// linking to it would have the story's headline sitting directly underneath.
    private var linkCard: LinkCard? {
        hasContentWarning ? nil : item.linkCard
    }

    #if DEBUG
    /// Exposed because nil has to read as "nothing to show" here and not as `true`, and a filled
    /// star on a post nobody liked is a claim about the reader.
    var engagementForTesting: EngagementCounts { engagement }
    /// Exposed so the content-warning rule covers the link preview too, which carries the linked
    /// page's headline and is therefore part of what a warning hides.
    var linkCardForTesting: LinkCard? { linkCard }
    /// Exposed so the content-warning rule can be tested. It decides whether a hidden post is
    /// printed into the timeline, which is not something to leave to inspection.
    var hasContentWarningForTesting: Bool { hasContentWarning }
    /// Exposed because the three-state column behind it is easy to read wrongly, and reading it
    /// wrongly attributes a post to somebody who had nothing to do with it.
    var boostedByForTesting: String? { boostedBy }
    @MainActor var statusTextForTesting: AttributedString { statusText }
    #endif

    init(
        item: CachedItem,
        sourceTitle: String? = nil,
        sourceIconURLString: String? = nil,
        showsLateArrival: Bool = true,
        headingScale: TextScale = .standard,
        bodyScale: TextScale = .standard,
        lineHeight: Double = ReadingSettings.defaultLineHeight
    ) {
        self.item = item
        self.sourceTitle = sourceTitle
        self.sourceIconURLString = sourceIconURLString
        self.showsLateArrival = showsLateArrival
        self.headingScale = headingScale
        self.bodyScale = bodyScale
        self.lineHeight = lineHeight
    }

    /// What the row's own text is set in — a post's words, and an article's excerpt.
    ///
    /// Halfway between `.primary` and `.secondary`, because SwiftUI has nothing there. Its
    /// hierarchy only descends — secondary, tertiary, quaternary, quinary — so the single step
    /// below full contrast is a large one, and this row needs both sides of it: the text has to
    /// carry a post, which is the whole item and not a caption, while staying under the headline
    /// beside it and clear of ``StatusTextCache/linkColor``, which is `.primary`.
    ///
    /// Mixed rather than dimmed, and the difference matters. `.opacity` moves a colour toward the
    /// *background*, so it means "lighter" in one appearance and "darker" in the other — the row's
    /// links were written that way once and came out dimmer than their own sentence in dark mode.
    /// Mixing two semantic colours stays semantic: both ends move with the appearance and with the
    /// accessibility contrast settings, so the midpoint does too.
    private static let bodyColor = Color.primary.mix(with: .secondary, by: 0.5)

    /// How much of the headline line to show.
    ///
    /// A status has no title of its own — its text *is* the headline — so on iPhone it is shown in
    /// full. That is where the timeline is the reading surface: tapping into a detail view to read
    /// two more lines of a short post is not a trade worth making. On the Mac the reading pane is
    /// always beside the list, so rows stay a uniform two lines and the post is read there.
    private var titleLineLimit: Int? {
        #if os(macOS)
        return 2
        #else
        return item.kind == .status ? nil : 2
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch item.kind {
            case .status: statusHeader
            case .article: articleHeader
            }

            // A status has no title of its own — its text *is* the post — so it is set in body
            // weight and shown whole. An article's headline is a headline and stays bold and
            // clipped, with its excerpt underneath.
            if item.kind == .status {
                if !item.title.isEmpty {
                    // `.subheadline`, the same style as an article's excerpt, because that is what
                    // this is: the row's *text*, under the row's heading. Set at `.body` it came
                    // out the size of an article headline and answered to the heading preference
                    // in everything but name — so a timeline of mixed articles and posts had two
                    // competing text sizes in it, and "list text" did not control the one thing
                    // most obviously made of text.
                    // Formatted rather than flattened. A post's structure and its link *text* are
                    // part of what it says, and the row was showing `plainText`, which threw them
                    // away — so a post that was mostly a link read as a bare sentence with the
                    // link missing. Parsed once per post and cached; see `StatusTextCache`.
                    //
                    // The links themselves are not live here: the attribute is dropped so the
                    // row keeps its own tap, and the anchor text is underlined so it still reads
                    // as a link. See `StatusTextCache.defusedLinks(_:)`.
                    Text(statusText)
                        .scaledFont(.subheadline, scale: bodyScale, lineHeight: lineHeight)
                        // Matching an article's excerpt, and see ``bodyColor`` for why it is a
                        // mixed colour rather than one of the four SwiftUI offers. The short of
                        // it: the post's text *is* the item — there is no headline above it doing
                        // the scanning — so `.secondary` dimmed the only thing on the row worth
                        // reading, and `.primary` collided with the links.
                        .foregroundStyle(Self.bodyColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !item.attachments.isEmpty {
                    StatusMediaStrip(
                        attachments: item.attachments,
                        // Defaulting to sensitive when nothing was recorded. A store written
                        // before the flag existed has `nil` here, and treating that as "safe"
                        // would show media the author asked to have hidden. `StatusBackfill` fills
                        // it in, after which the real answer applies.
                        // A content warning hides the media too. The author put the post behind
                        // a warning; showing its pictures beside the warning text would answer
                        // the question they asked not to be answered.
                        isSensitive: hasContentWarning || (item.isSensitive ?? true)
                    )
                    .padding(.top, 2)
                }

                if let card = linkCard {
                    LinkPreviewCard(card: card, scale: bodyScale)
                        .padding(.top, 4)
                }
            } else {
                Text(item.title)
                    .scaledFont(.headline, weight: .semibold, scale: headingScale)
                    .lineLimit(2)

                if !item.excerpt.isEmpty {
                    Text(item.excerpt)
                        // The same leading as a post's text above it. See ``lineHeight``.
                        .scaledFont(.subheadline, scale: bodyScale, lineHeight: lineHeight)
                        // And the same colour, so a timeline of mixed articles and posts does not
                        // read as two lists interleaved — see the post's text above.
                        .foregroundStyle(Self.bodyColor)
                        .lineLimit(3)
                }
            }

            if item.kind == .status, boostedBy != nil || hasEngagement {
                // One line for everything about how the post travelled: who put it in front of
                // you, and how far it has gone. Both are footnotes to the post rather than part
                // of it, and giving them a line each would cost row density on every boosted post
                // in the timeline.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let boostedBy {
                        boostAttribution(boostedBy)
                    }

                    if hasEngagement {
                        engagement
                            // The counts are short and fixed-width; the name is the part that can
                            // run long, so the name is the part that gives way.
                            .layoutPriority(1)
                    }
                }
            }

            if item.arrivedLate, showsLateArrival {
                // Explains why an item is sitting far down the list despite having just arrived.
                Label("Arrived late", systemImage: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        // Deliberately the same figure as the stack's own spacing above, which makes the gap
        // between two rows — two paddings meeting — exactly twice the gap between the lines
        // within one. That ratio is what reads as a list of separate items rather than as one
        // column of text with headings in it.
        .padding(.vertical, 6)
    }

    /// Avatar, display name, handle, time — the shape a timeline of people reads best in.
    private var statusHeader: some View {
        // Two alignments, because the header holds two unrelated things.
        //
        // The avatar and the name/handle pair are one unit and are centred against each other:
        // hanging a two-line block from a 36-point avatar's top edge leaves a gap under it that
        // grows with the text-size setting, so the pair looks dropped rather than placed.
        //
        // The timestamp is not part of that unit. It belongs to the row, and it reads as the
        // corner marker of the row — so it stays pinned to the top edge. Letting it inherit the
        // centring, as it did when it was a sibling of the avatar, floated it into the middle of
        // the header for no reason: nothing about a date wants to line up with a face.
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                SourceIcon(
                    urlString: item.iconURLString,
                    fallbackSystemImage: "person.crop.circle",
                    size: 36
                )
                // Rounded rather than square: it is a person's avatar, and Mastodon serves them
                // square.
                .clipShape(.rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 0) {
                    Text(bylineText)
                        .scaledFont(.subheadline, weight: .semibold, scale: headingScale)
                        .lineLimit(1)

                    if let handle = handleText {
                        Text(handle)
                            .scaledFont(.caption, scale: headingScale)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            // A view of its own so it can age on screen without rebuilding the row around it —
            // see `RelativeClock`. It carries its own spoken label; the styling below is the
            // row's.
            RelativeTimestamp(date: item.publishedAt)
                .font(.caption)
                // Set with the source name rather than under it. `.tertiary` is a long way down in
                // dark mode, where the hierarchy's steps are the difference between white and the
                // background rather than between black and it, and a timestamp that has faded into
                // the row cannot do the orienting job the note below describes.
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // The timestamp must never be the thing squeezed out by a long display name — it
                // is how you orient yourself in the timeline.
                .layoutPriority(1)
        }
    }

    /// Favicon, feed name, time — one line, because an article's headline carries the weight.
    private var articleHeader: some View {
        HStack(spacing: 6) {
            SourceIcon(
                // The feed's icon first, since for an article that is the only one there is; the
                // item's own is kept as a fallback rather than dropped, because a store written
                // before this carried one on some rows and there is no reason to stop showing it.
                urlString: sourceIconURLString ?? item.iconURLString,
                fallbackSystemImage: "dot.radiowaves.up.forward",
                size: 14
            )

            Text(bylineText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            // Ageing on screen and spelled out for VoiceOver, like the status header's. See there.
            RelativeTimestamp(date: item.publishedAt)
                .font(.caption)
                // With the source name, as in the status header above. See there.
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    /// Who to name on the header line.
    ///
    /// For a status that is the **author**, not the source. Every post in a Mastodon timeline
    /// shares one source — "Home" — so naming it repeated the same word down the whole column and
    /// left the one thing that varies, and that you actually scan for, only inside the post's text.
    /// An article is the other way round: the feed's name is what identifies it, and its byline is
    /// often missing or a bare email address.
    private var bylineText: String {
        switch item.kind {
        case .status: item.authorName ?? sourceTitle ?? ""
        case .article: sourceTitle ?? item.authorName ?? ""
        }
    }

    /// The `@user@host` line under the display name, or `nil` when there is nothing to add.
    ///
    /// Suppressed when it would only repeat the line above it. An account that has left its
    /// display name empty is shown as `@handle` by `bestDisplayName`, so printing the handle again
    /// underneath gives the same string twice in two sizes.
    private var handleText: String? {
        guard let handle = item.authorHandle, !handle.isEmpty else { return nil }
        let line = "@\(handle)"
        return line == bylineText ? nil : line
    }

    /// Who boosted this post into the timeline, or nil when it arrived directly.
    ///
    /// Read from the column rather than from `mastodonPayload`, which is the whole reason the
    /// column exists: a row is realised as fast as the list can scroll, and running a `JSONDecoder`
    /// over a full status per cell is exactly what the denormalised columns are here to avoid.
    ///
    /// An empty string is not nil — it means the row has been examined and is not a boost. See
    /// ``CachedItem/boostedByName``.
    private var boostedBy: String? {
        guard let name = item.boostedByName, !name.isEmpty else { return nil }
        return name
    }

    /// "Someone boosted", ahead of the counts.
    ///
    /// One interpolated string rather than a name and a separate word, so translators get a
    /// sentence to work with — German puts an auxiliary in the middle of it ("%@ hat geboostet"),
    /// which two adjacent `Text`s could not express.
    ///
    /// Truncated in the middle, unusually and deliberately: both ends carry meaning here. Clipping
    /// the tail would eat the verb and leave a bare name sitting next to a boost count, which
    /// reads as though the name *is* the count's label.
    private func boostAttribution(_ name: String) -> some View {
        Label {
            Text("\(name) boosted")
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: "arrow.2.squarepath")
        }
        .font(.caption2)
        // A step brighter than the counts beside it. This is the reason the post is in the
        // timeline at all, where the counts are trivia about it.
        .foregroundStyle(.secondary)
    }

    /// How the post was received, and which of it the reader did.
    ///
    /// Built once and asked whether it has anything to say, rather than the row keeping its own
    /// copy of that test: the reading pane had the identical three-way `> 0` check written out
    /// beside its own copy of this strip, and only one of the two would have learned about the
    /// Like and Boost flags.
    private var engagement: EngagementCounts {
        EngagementCounts(
            reblogCount: item.reblogCount,
            favouriteCount: item.favouriteCount,
            replyCount: item.replyCount,
            // Nil reads as false. A row written before these columns existed has nothing to show
            // either way, and `StatusBackfill` is what turns that into an answer.
            isFavourited: item.isFavourited ?? false,
            isReblogged: item.isReblogged ?? false
        )
    }

    /// Whether the post has been engaged with at all.
    ///
    /// A row of three zeroes says nothing and costs a line of height on every post in the
    /// timeline, so the whole strip is dropped rather than shown empty.
    private var hasEngagement: Bool { engagement.hasAny }
}

/// Boosts, favourites and replies, as of the last refresh — and which of them the reader has done.
///
/// Zeroes are omitted individually as well as collectively: "12 boosts · 0 favourites" reads as a
/// judgement, where showing just the boosts reads as a fact.
struct EngagementCounts: View {

    let reblogCount: Int
    let favouriteCount: Int
    let replyCount: Int

    /// Whether the reader's own account has favourited or boosted this.
    ///
    /// Drawn rather than only offered in a menu, because the menu is not visible: without this the
    /// only way to find out whether a post had already been liked was to open the context menu and
    /// read whether it said Like or Unlike.
    var isFavourited = false
    var isReblogged = false

    /// Whether there is anything to draw.
    ///
    /// On the type rather than at each call site, because both call sites had their own copy of the
    /// same three-way `> 0` test and the reading pane's would not have learned about the flags.
    var hasAny: Bool {
        reblogCount > 0 || favouriteCount > 0 || replyCount > 0
    }

    var body: some View {
        HStack(spacing: 10) {
            if reblogCount > 0 {
                count(
                    reblogCount,
                    // Named centrally, and the same glyph in both states — see
                    // ``StatusActionSymbol``. Contrast is the whole visual signal for a boost —
                    // there is no filled glyph to switch to — which is why the label below says it
                    // out loud as well.
                    systemImage: StatusActionSymbol.boost,
                    isMine: isReblogged,
                    label: isReblogged
                        ? Text("^[\(reblogCount) boost](inflect: true), including yours")
                        : Text("^[\(reblogCount) boost](inflect: true)")
                )
            }
            if favouriteCount > 0 {
                count(
                    favouriteCount,
                    systemImage: isFavourited ? StatusActionSymbol.favourited : StatusActionSymbol.favourite,
                    isMine: isFavourited,
                    label: isFavourited
                        ? Text("^[\(favouriteCount) favourite](inflect: true), including yours")
                        : Text("^[\(favouriteCount) favourite](inflect: true)")
                )
            }
            if replyCount > 0 {
                count(
                    replyCount,
                    systemImage: StatusActionSymbol.reply,
                    isMine: false,
                    label: Text("^[\(replyCount) reply](inflect: true)")
                )
            }
        }
        .font(.caption2)
        // One step up from `.tertiary`, which in dark mode had these counts most of the way to the
        // background. They are footnotes to the post, but they are the only numbers on the row and
        // a number you have to look twice at is not carrying its meaning.
        .foregroundStyle(.secondary)
    }

    /// One count, with the icon carrying the meaning visually.
    ///
    /// The label is built by the caller as a `Text` with the noun written out as a **literal**, and
    /// both halves of that matter. `accessibilityLabel` prefers its `StringProtocol` overload for an
    /// interpolated `String`, which passes inflection markup through verbatim — and the markup can
    /// only agree with a noun it can actually see, so passing the noun in as a variable would
    /// defeat it even through the `Text` overload. Measured in the running app, where the first
    /// version announced "1 replies".
    ///
    /// The ternaries above are over `Text` rather than over `String`, which is what keeps that
    /// working: each branch is still a literal, so the inflection markup is applied to it. Written
    /// as one interpolated `String` the markup would be printed on screen verbatim instead.
    ///
    /// - Parameter isMine: Whether the reader did this one. Drawn at full contrast — `.primary`
    ///   against the `.secondary` the rest of the strip is set in — rather than in the accent
    ///   colour.
    ///
    ///   The accent colour is the obvious choice and it has a failure mode this does not: a
    ///   selected row in a `List` is filled with the accent colour, and SwiftUI recolours a row's
    ///   text for that but cannot recolour a style the row asked for explicitly. An accent-tinted
    ///   star on the selected post would be blue on blue. `.primary` is semantic, so it means the
    ///   same thing in both appearances, follows the accessibility contrast settings, and inverts
    ///   with the row when it is selected. `StatusTextCache/linkColor` chose it over an accent for
    ///   the neighbouring case and records the same reasoning.
    ///
    ///   Not an opacity either: lowering opacity moves a colour *toward the background*, which
    ///   reads as "lighter" in light mode and "dimmer" in dark, so the emphasis would swap between
    ///   the two appearances.
    private func count(_ value: Int, systemImage: String, isMine: Bool, label: Text) -> some View {
        Label {
            Text(value, format: .number.notation(.compactName))
                .monospacedDigit()
        } icon: {
            Image(systemName: systemImage)
        }
        .labelStyle(CountLabelStyle())
        .foregroundStyle(isMine ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .accessibilityLabel(label)
    }
}

/// An icon and its number, set close enough together to read as one figure.
///
/// The default label style spaces an icon from its title for a *button* — a word wide enough that
/// the gap has to separate two things. Here the title is one or two digits and the icon is what
/// says which number it is, so at that spacing the strip read as six loose glyphs rather than three
/// counts, and the eye had to pair them up itself.
///
/// Baseline-aligned rather than centred, because the digits and the symbol are being read as one
/// run of text; centring sits a tall glyph like the reply bubble slightly low against its number.
private struct CountLabelStyle: LabelStyle {

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

#if DEBUG
#Preview {
    List {
        ItemRow(
            item: CachedItem(
                id: "1",
                sourceID: "s",
                accountID: UUID(),
                kind: .article,
                title: "A headline that runs on long enough to need wrapping across two lines",
                publishedAt: .now.addingTimeInterval(-3_600),
                sortKey: SortKey(millis: 1, id: "1"),
                ingestKey: SortKey(millis: 1, id: "1")
            ),
            sourceTitle: "Daring Fireball"
        )
    }
}
#endif
