import MastodonAPI
import ReadReadModel
import ReadReadSync
import SwiftData
import SwiftUI

/// Renders a Mastodon status natively, optionally with the conversation around it.
///
/// Native rather than in a web view because a status is small and structured — author, text,
/// attachments — so SwiftUI keeps text selection, Dynamic Type, the platform's link handling and
/// the app's own styling, all of which a web view would discard.
struct StatusReaderView: View {

    let item: CachedItem

    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsModel.self) private var settings

    /// The accounts that could like or boost this post.
    ///
    /// A `@Query` is affordable here in a way it is not in a timeline row: this view is realised
    /// once per post being read, not once per cell while scrolling.
    @Query private var accounts: [AccountRecord]

    /// Every reply subscription, for the toolbar's Subscribe button and for finding the conversation
    /// a followed reply belongs to. Affordable here for the reason `accounts` is.
    @Query private var replySubscriptions: [ReplySubscription]

    @Environment(AppServices.self) private var services

    /// Where the subscription sheet is presented. Optional, like everywhere else it is read.
    @Environment(StatusComposer.self) private var composer: StatusComposer?

    /// Where a tapped author's profile is presented. Optional for the same reason.
    @Environment(ProfileViewerModel.self) private var profiles: ProfileViewerModel?

    @State private var thread = StatusThreadLoader()

    /// This post as its account's instance knows it, for subscribing to its replies.
    ///
    /// Worked out once per post rather than per redraw: it decodes the stored payload. Nil for a
    /// row without one, which has nothing to subscribe to.
    @State private var subscriptionTarget: ReplySubscriptionEditing.Target?

    private var status: RenderableStatus { RenderableStatusCache.status(for: item) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let conversation {
                        wholeConversation(conversation)
                    } else {
                        ancestors

                        StatusCard(status: status, emphasis: .focused, row: item)
                            .environment(\.openProfile, openProfile(as: item.accountID))
                            .id(Self.focusedAnchor)

                        threadFooter
                    }
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
                // The posts around the one being read came through whichever account the thread was
                // loaded with; the stored ones override this with the item's own below.
                .environment(\.openProfile, openProfile(as: thread.accountID ?? item.accountID))
            }
            .onChange(of: thread.state) { _, state in
                guard case .loaded(let ancestors, _) = state else { return }

                if conversation != nil {
                    // The reply being read is somewhere down a whole conversation, which in a lazy
                    // stack has not been laid out yet. Asked twice, as the timeline's restore does:
                    // the first scroll lands on an estimate of where the rows above end, and the
                    // second, once they have been measured, on the reply itself.
                    proxy.scrollTo(Self.focusedAnchor, anchor: .top)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        proxy.scrollTo(Self.focusedAnchor, anchor: .top)
                    }
                    return
                }

                guard !ancestors.isEmpty else { return }
                // The post you chose must stay the post you are looking at. Ancestors are inserted
                // *above* it, so without pinning it back the pane would silently scroll up into
                // somebody else's reply.
                proxy.scrollTo(Self.focusedAnchor, anchor: .top)
            }
        }
        .navigationTitle(status.authorName)
        .toolbar {
            ToolbarItemGroup {
                // Ahead of Show Conversation, because these are what a reader reaches for most
                // often — and after the pane's shared buttons, which belong to the item rather
                // than to the kind of item.
                StatusActionMenu(
                    item: item,
                    accounts: StatusInteractions.Actor.menuOrder(
                        for: accounts,
                        owner: item.accountID
                    ),
                    placement: .toolbar
                )

                if subscriptionTarget != nil {
                    subscriptionButton
                }

                if status.hasConversation, !settings.reading.loadsMastodonThreads, conversationRoot == nil {
                    Button("Show Conversation", systemImage: "bubble.left.and.bubble.right") {
                        thread.load(for: item, in: modelContext)
                    }
                    .disabled(isLoadingThread)
                    .toolbarButtonHelp("Show Conversation")
                }
            }
        }
        .task(id: item.id) {
            // Reset first: the loader outlives the item, so without this the previous post's
            // thread would sit under the new one until its own fetch replaced it.
            thread.reset()
            subscriptionTarget = StatusComposer.subscriptionTarget(for: item)

            // A followed reply is read inside its conversation whatever the thread setting says:
            // seeing the other answers is what subscribing to them was for.
            if let root = conversationRoot {
                thread.loadConversation(
                    rootStatusID: root.statusID,
                    accountID: root.accountID,
                    focusing: item,
                    in: modelContext
                )
                return
            }

            guard settings.reading.loadsMastodonThreads, status.hasConversation else { return }
            thread.load(for: item, in: modelContext)
        }
    }

    // MARK: - Subscribing

    /// The subscription this post came in through, when it is a followed reply.
    private var conversationRoot: ReplySubscription? {
        guard let id = item.replySubscriptionID else { return nil }
        return replySubscriptions.first { $0.id == id }
    }

    /// The subscription following this post's own replies, if there is one.
    private var ownSubscription: ReplySubscription? {
        guard let subscriptionTarget else { return nil }
        return replySubscriptions.first {
            $0.accountID == subscriptionTarget.accountID && $0.statusID == subscriptionTarget.statusID
        }
    }

    /// Subscribe, or unsubscribe once subscribed.
    ///
    /// One button whose title and glyph change, rather than two buttons swapped by an `if`: a
    /// toolbar item that changes identity animates itself out and back in. Filled when subscribed,
    /// which is the convention Like follows — the outline is the offer, the fill is the state.
    ///
    /// Unsubscribing asks nothing. It is undone by subscribing again, which walks the conversation
    /// from the start, and the replies it brought in stay in the home timeline either way.
    private var subscriptionButton: some View {
        let subscription = ownSubscription
        let title: LocalizedStringKey = subscription == nil ? "Subscribe to Replies…" : "Unsubscribe from Replies"

        return Button(title, systemImage: subscription == nil ? "bell" : "bell.fill") {
            if let subscription {
                unsubscribe(subscription)
            } else if composer?.subscribe(to: item) != true {
                services.reportUnusableStatus()
            }
        }
        .toolbarButtonHelp(title)
    }

    private func unsubscribe(_ subscription: ReplySubscription) {
        do {
            try ReplySubscriptionEditing.unsubscribe(subscription, in: modelContext)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            return
        }
        services.replySubscriptionsChanged()
    }

    // MARK: - A whole conversation

    /// A followed reply's conversation, loaded from the subscribed post, with the reply in it.
    private struct Conversation {
        var above: [RenderableStatus]
        var replies: [RenderableStatus]
        var focusID: String
    }

    /// The loaded conversation, when the reply being read is in it.
    ///
    /// Nil while it loads, and when the reply is not among the descendants — deleted since, or
    /// withheld by the instance — in which case the ordinary layout shows the post with the
    /// conversation's replies below it, rather than the reader's reply disappearing from its own
    /// pane.
    private var conversation: Conversation? {
        guard
            case .loaded(let above, let replies) = thread.state,
            let focusID = thread.focusStatusID,
            replies.contains(where: { $0.id == focusID })
        else { return nil }
        return Conversation(above: above, replies: replies, focusID: focusID)
    }

    @ViewBuilder
    private func wholeConversation(_ conversation: Conversation) -> some View {
        ForEach(conversation.above) { post in
            StatusCard(status: post, emphasis: .context)
        }

        Divider().padding(.vertical, 12)

        ForEach(conversation.replies) { reply in
            Group {
                if reply.id == conversation.focusID {
                    // The store's copy rather than the network's, so the counts under the toolbar's
                    // Like are the ones the action writes to — see `StatusCard.row`.
                    StatusCard(status: status, emphasis: .focused, row: item)
                        .environment(\.openProfile, openProfile(as: item.accountID))
                        .id(Self.focusedAnchor)
                } else {
                    StatusCard(status: reply, emphasis: .context)
                }
            }
            .padding(.leading, Self.indent(forDepth: thread.depths[reply.id] ?? 1))
        }
    }

    /// How far a reply is set in for its depth. Capped, because a long back-and-forth between two
    /// people would otherwise walk off the side of an iPhone.
    private static func indent(forDepth depth: Int) -> CGFloat {
        CGFloat(min(max(depth - 1, 0), 4)) * 16
    }

    private static let focusedAnchor = "focused-status"

    private var isLoadingThread: Bool {
        if case .loading = thread.state { return true }
        return false
    }

    /// What sits above the post: the whole way up the conversation once it has loaded, and the post
    /// it replies to or quotes, which ingest already stored.
    ///
    /// A stored *parent* gives way to the loaded thread entirely rather than being merged with it:
    /// the thread's last ancestor *is* that parent, fresher, and when the thread comes back with no
    /// ancestors the parent has been deleted since — the server's answer wins. A stored *quote*
    /// stays, directly above the post: a conversation says nothing about what a post quotes.
    @ViewBuilder
    private var ancestors: some View {
        let isThreadLoaded: Bool = {
            if case .loaded = thread.state { return true }
            return false
        }()

        if case .loaded(let ancestors, _) = thread.state {
            ForEach(ancestors) { ancestor in
                StatusCard(status: ancestor, emphasis: .context)
            }
        }

        if let stored = RenderableStatusCache.parent(for: item), item.replyParentIsQuote || !isThreadLoaded {
            StatusCard(status: stored, emphasis: .context)
                .environment(\.openProfile, openProfile(as: item.accountID))
        }
    }

    // MARK: - Profiles

    /// Opens a profile through `accountID` — the account whose instance the author's id came from.
    private func openProfile(as accountID: UUID) -> OpenProfileAction? {
        guard let profiles else { return nil }
        return OpenProfileAction { profiles.open($0, as: accountID) }
    }

    @ViewBuilder
    private var threadFooter: some View {
        switch thread.state {
        case .idle:
            EmptyView()

        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading conversation…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 16)

        case .loaded(_, let descendants):
            if descendants.isEmpty {
                Text("No replies.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
            } else {
                Divider().padding(.vertical, 12)
                ForEach(descendants) { reply in
                    StatusCard(status: reply, emphasis: .context)
                }
            }
        }
    }
}

/// One status in a thread.
struct StatusCard: View {

    enum Emphasis {
        /// The post being read.
        case focused
        /// A post above or below it in the conversation.
        case context
        /// One of a list of posts that are each read for themselves, like a profile's. Sized like
        /// a context card, but at full strength and with its timestamp linking to the post.
        case listed
    }

    let status: RenderableStatus
    var emphasis: Emphasis = .focused

    /// The store's row for this post, when there is one — which is only ever the focused card.
    ///
    /// The card is otherwise built from the stored payload, and a payload is as stale as the last
    /// refresh. That is the right answer for the posts around it and the wrong one for the post the
    /// reader has just liked from the toolbar two inches above: the button would say Unlike while
    /// the count underneath it still read the old figure. The row is what the action writes to, so
    /// the row is what the focused card counts from.
    var row: CachedItem?

    /// Whether the reader has chosen to see the post's sensitive media.
    ///
    /// Per-card and reset whenever the status changes, so revealing one post's media never
    /// reveals another's.
    @State private var isRevealed = false

    @Environment(\.openURL) private var openURL
    @Environment(\.openProfile) private var openProfile
    @Environment(SettingsModel.self) private var settings

    private var contentScale: TextScale { settings.reading.contentScale }
    private var contentLineHeight: Double { settings.reading.contentLineHeight }

    /// How the post was received, from the store where there is a row and from the payload where
    /// there is not. See ``row``.
    private var engagement: EngagementCounts {
        guard let row else {
            return EngagementCounts(
                reblogCount: status.reblogCount,
                favouriteCount: status.favouriteCount,
                replyCount: status.replyCount,
                isFavourited: status.isFavourited,
                isReblogged: status.isReblogged
            )
        }
        return EngagementCounts(
            reblogCount: row.reblogCount,
            favouriteCount: row.favouriteCount,
            replyCount: row.replyCount,
            isFavourited: row.isFavourited ?? false,
            isReblogged: row.isReblogged ?? false
        )
    }

    #if DEBUG
    /// Exposed because the choice between the row and the payload is invisible until it is wrong,
    /// and the way it goes wrong is a Like the reader just made not appearing in the count under
    /// the button they pressed.
    var engagementForTesting: EngagementCounts { engagement }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let boostedBy = status.boostedBy {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.2.squarepath")
                    // A display name, so it can carry emoji like any other.
                    EmojiText(boostedBy, emojis: status.emojis)
                    Text("boosted")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(boostedBy) boosted")
            }

            header

            body(of: status)

            // Under the post rather than in front of it, as in the timeline row: the post is read
            // straight away, and the warning still says what it is about.
            if status.hasContentWarning {
                ContentWarningNotice(text: status.spoilerText, scale: contentScale)
            }

            if engagement.hasAny {
                engagement
                    .font(.caption)
            }
        }
        .padding(emphasis == .focused ? 16 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The same grey the selected row in the timeline is filled with — one constant, because
        // the two are a column apart and the reader sees them together. See ``SurfaceFill``.
        .background(
            emphasis == .focused ? SurfaceFill.current : SurfaceFill.clear,
            in: .rect(cornerRadius: 12)
        )
        .opacity(emphasis == .context ? 0.85 : 1)
        .task(id: status.id) {
            // A recycled card must not carry the previous post's revealed state onto a new one —
            // that would show sensitive media without anyone asking.
            isRevealed = false
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            author

            Spacer(minLength: 8)

            timestamp
                .font(.caption)
                .foregroundStyle(.tertiary)
                .layoutPriority(1)
        }
    }

    /// The avatar and the name, which open the author's profile where there is one to open.
    ///
    /// The whole pair rather than the name alone, because the picture is the bigger target and is
    /// where a reader's thumb goes looking for "who is this".
    @ViewBuilder
    private var author: some View {
        if let openProfile, let profile = status.authorProfile {
            Button {
                openProfile(profile)
            } label: {
                authorLabel.contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the profile")
        } else {
            authorLabel
        }
    }

    private var authorLabel: some View {
        HStack(spacing: 10) {
            SourceIcon(
                urlString: status.avatarURLString,
                fallbackSystemImage: "person.crop.circle",
                size: emphasis == .focused ? 40 : 28
            )

            VStack(alignment: .leading, spacing: 1) {
                EmojiText(status.authorName, emojis: status.emojis, scale: contentScale)
                    .scaledFont(
                        emphasis == .focused ? .headline : .subheadline,
                        weight: .semibold,
                        scale: contentScale
                    )
                    .lineLimit(1)

                if let handle = status.authorHandle {
                    Text("@\(handle)")
                        .scaledFont(.caption, scale: contentScale)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    /// When the post was published, linking to the post itself where there is a link.
    ///
    /// This is a status's answer to a linked headline, and it replaced the reading pane's "Open in
    /// Browser" button — see `DetailView.itemActions`. A post has no headline to link, and the two
    /// candidates in the header are not interchangeable: the *author* linking to their profile is a
    /// convention strong enough that pointing it at the post instead would be a small betrayal,
    /// while the *timestamp* linking to the post is Mastodon's own convention, in its own web
    /// interface and in every client that follows it.
    ///
    /// Only on the focused card. A context card is a neighbour in the conversation, and turning
    /// each one into a way out of the app is not what the thread is for.
    @ViewBuilder
    private var timestamp: some View {
        // Narrow on screen and wrong out loud: VoiceOver reads the abbreviation itself, so a post
        // two hours old was announced as "2h". The wide style is the same fact spelled out, and
        // costs nothing visually because it is never drawn.
        let label = Text(status.createdAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
        let spoken = Text(status.createdAt, format: .relative(presentation: .numeric, unitsStyle: .wide))

        if emphasis != .context, let url = status.url {
            Link(destination: url) { label }
                // The pane's own colours, not the link colour: this is a timestamp that happens to
                // be tappable, and painting it as a link would make the loudest thing in the
                // header the least important one.
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Open post from \(spoken) in browser"))
        } else {
            label.accessibilityLabel(spoken)
        }
    }

    @ViewBuilder
    private func body(of status: RenderableStatus) -> some View {
        EmojiText(attributedContent(of: status), emojis: status.emojis, scale: contentScale)
            // The post's own text, so it follows the reading-pane size preference. Its chrome —
            // handles, timestamps, boost attribution — deliberately does not: those are labels
            // that orient you around the post rather than part of what you are reading.
            .scaledFont(
                emphasis == .focused ? .body : .callout,
                scale: contentScale,
                lineHeight: contentLineHeight
            )
            .textSelection(.enabled)
            // The links are already painted ``StatusTextCache/linkColor`` by `liveLinks`, and this
            // is the same colour said a second way. Belt and braces on purpose: SwiftUI draws a
            // link run in the tint colour, and which of the two wins when both are set is not
            // something to leave to inference in the one place a wrong answer is a stripe of
            // accent blue through every post.
            .tint(StatusTextCache.linkColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A mention opens the person's profile here. Everything else goes on to the window's
            // own handler, which decides between the in-app browser and the system — returning
            // `.systemAction` instead would skip that decision.
            .environment(\.openURL, OpenURLAction { url in
                if let openProfile, let profile = status.mentionedProfiles[url.absoluteString] {
                    openProfile(profile)
                } else {
                    openURL(url)
                }
                return .handled
            })

        if let poll = status.poll {
            PollView(poll: poll, contentScale: contentScale)
        }

        if !status.attachments.isEmpty {
            AttachmentGrid(
                attachments: status.attachments,
                // Sensitive media stays blurred until asked for. A thread is full of other
                // people's posts, so this is not a hypothetical.
                isSensitive: status.isSensitive && !isRevealed,
                onReveal: { isRevealed = true }
            )
        }

        // The same card the timeline row draws, in the same place in the post — under the text and
        // the media.
        if let card = status.linkCard, card.isShowable {
            // Opening the link is the card's own job now, in the row as much as here — see
            // ``LinkPreviewCard``.
            LinkPreviewCard(card: card, scale: contentScale)
        }
    }

    /// Renders the status HTML as an `AttributedString` so links stay tappable.
    ///
    /// Through the same cache the timeline rows use — its *unclipped* side, because a row shows a
    /// sample of a post and the pane shows the post. This used to parse in place, which means it
    /// parsed on every body evaluation of every card — and a thread is a stack of cards that all
    /// re-evaluate together whenever the thread loads, a size preference moves, or the pane is
    /// re-laid out. The parse is a regex pass plus an `AttributedString` markdown import, which is
    /// exactly the work `StatusTextCache` exists to do once.
    ///
    /// Sharing the cache with the list is safe because the keys cannot collide: a stored item's id
    /// is always prefixed (`mastodon:…`, `freshrss:…`) by `SourceIdentifier`, while a thread post
    /// arriving from the network carries the instance's bare status id.
    ///
    /// Falls back to the pre-computed plain text when parsing fails, so a malformed status still
    /// shows its words rather than an empty pane.
    private func attributedContent(of status: RenderableStatus) -> AttributedString {
        StatusTextCache.shared.fullText(id: status.id, html: status.contentHTML, plain: status.plainText)
    }
}

/// Converts the narrow subset of HTML that Mastodon emits into Markdown.
///
/// Mastodon sanitises status HTML down to a small, documented set of tags — `<p>`, `<br>`, `<a>`
/// and `<span>` — so a full HTML parser is unnecessary here. Markdown is the intermediate because
/// `AttributedString` can parse it on any thread, unlike its HTML importer.
enum MastodonMarkdown {

    static func markdown(fromStatusHTML html: String) -> String {
        var text = html
            .replacingOccurrences(of: "</p>", with: "\n\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")

        text = rewritingLinks(in: text)
        text = strippingRemainingTags(from: text)
        text = decodingBasicEntities(in: text)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Turns `<a href="…">label</a>` into `[label](…)`.
    private static func rewritingLinks(in html: String) -> String {
        // Non-greedy so consecutive links do not collapse into one match.
        guard let regex = try? NSRegularExpression(
            pattern: "<a[^>]*href=\"([^\"]*)\"[^>]*>(.*?)</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return html
        }

        var result = ""
        var lastEnd = html.startIndex

        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let full = Range(match.range, in: html),
                  let hrefRange = Range(match.range(at: 1), in: html),
                  let labelRange = Range(match.range(at: 2), in: html) else { continue }

            result += html[lastEnd..<full.lowerBound]
            let label = strippingRemainingTags(from: String(html[labelRange]))
            // Escape the label's brackets so a link whose text contains `]` cannot terminate the
            // Markdown link early and swallow the rest of the line.
            let safeLabel = label
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            result += "[\(safeLabel)](\(html[hrefRange]))"
            lastEnd = full.upperBound
        }

        result += html[lastEnd...]
        return result
    }

    private static func strippingRemainingTags(from html: String) -> String {
        var output = ""
        var insideTag = false
        for character in html {
            switch character {
            case "<": insideTag = true
            case ">": insideTag = false
            default: if !insideTag { output.append(character) }
            }
        }
        return output
    }

    private static func decodingBasicEntities(in text: String) -> String {
        // `&amp;` must be decoded last, or `&amp;lt;` would wrongly become `<`.
        text
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Media attachments in a simple adaptive grid.
struct AttachmentGrid: View {

    let attachments: [Attachment]

    /// Blur the media until the reader asks to see it.
    var isSensitive = false

    var onReveal: (() -> Void)?

    /// Optional so a preview or a test can render the grid with no shell around it.
    @Environment(MediaViewerModel.self) private var viewer: MediaViewerModel?

    var body: some View {
        ZStack {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { offset, attachment in
                    Button {
                        viewer?.present(attachments, startingAt: offset)
                    } label: {
                        cell(for: attachment)
                    }
                    .buttonStyle(.plain)
                    // Nothing behind a blur is clickable: opening a picture the reader has not
                    // agreed to see, because they tapped where it happened to be, is exactly what
                    // the blur is there to prevent.
                    .disabled(isSensitive)
                    .accessibilityLabel(attachment.describedAs.map { Text($0) } ?? Text("Attachment"))
                    .accessibilityHint(attachment.kind == .image ? Text("Shows the image full size") : Text("Plays this media"))
                }
            }
            // Blurred rather than not loaded: the image is already on its way, and hiding it behind
            // a placeholder that then pops in is worse than a blur that lifts.
            .blur(radius: isSensitive ? 28 : 0)
            // Clipped so the blur cannot bleed the image past its own bounds and defeat itself.
            .clipShape(.rect(cornerRadius: 12))
            .accessibilityHidden(isSensitive)

            if isSensitive {
                Button("Show Media", systemImage: "eye") {
                    onReveal?()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    /// One tile.
    ///
    /// The cell decides its own size and the image is laid *into* it as an overlay.
    ///
    /// Sizing the `AsyncImage` directly does not work: `scaledToFill` keeps the image's aspect
    /// ratio, so constraining only the height lets a wide photo claim whatever width it likes. On
    /// a Mac's reading pane there was room to absorb that; on an iPhone it blew the grid out past
    /// the screen and the media appeared broken. An overlay cannot expand its parent, which is the
    /// property being relied on here.
    private func cell(for attachment: Attachment) -> some View {
        Color.clear
            .frame(height: attachments.count == 1 ? 320 : 160)
            .frame(maxWidth: .infinity)
            .overlay {
                // Always the preview, never the original. Two reasons, and the first was a bug: a
                // Mastodon video or `gifv` *is* an MP4, no image decoder will touch one, and every
                // video in a post therefore rendered as a broken-image triangle. `previewURL` is
                // the server's own still of the same media. The second is weight — these tiles are
                // 160 to 320 points tall, and pulling a full-size original to draw one costs
                // megabytes per attachment. Clicking opens the original in the viewer, which is
                // where the pixels are actually wanted.
                //
                // Through the shared store rather than `AsyncImage` for the same reason the viewer
                // does not use it: a lazy grid takes a cell's view down when it scrolls out of a
                // long thread, cancelling the load, and SwiftUI then restores the cell's state
                // with that cancellation latched as a permanent failure. See ``MediaImageLoader``.
                if let image = RemoteImageStore.timelineMedia.image(for: attachment.previewURL) {
                    image.resizable().scaledToFill()
                } else {
                    placeholder(systemImage: attachment.kind == .image ? "photo" : "film")
                }
            }
            .overlay {
                // Marked, because a still frame of a video is indistinguishable from a photo and
                // the difference decides what clicking it is going to do.
                if attachment.kind != .image {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: attachments.count == 1 ? 52 : 34))
                        .foregroundStyle(.white)
                        .shadow(radius: 4)
                }
            }
            .clipped()
            .clipShape(.rect(cornerRadius: 12))
            .contentShape(.rect(cornerRadius: 12))
    }

    /// A single attachment gets the full width; two or more share a two-column grid.
    private var columns: [GridItem] {
        attachments.count == 1 ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
    }

    private func placeholder(systemImage: String) -> some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
    }
}
