import ReadReadModel
import SwiftUI
import WebKit

/// The reading pane for a Read Later entry whose cached item is gone.
///
/// ## Why this exists
///
/// `ReadLaterEntry` is a *snapshot*: title, byline, excerpt, and — when the setting is on — the
/// article body, copied at the moment it was saved. The stated point of copying all that is that
/// the entry outlives the cache, so a saved article stays readable after retention prunes it or the
/// feed drops it.
///
/// Nothing ever read the snapshot back. The pane resolved the entry's `itemID` to a `CachedItem`
/// and rendered that, so an entry with no cached item showed an empty pane — and every entry
/// arriving from another device has no cached item here, because an item id embeds a per-device
/// account UUID (see ``ItemResolution``). Between the two, "Read Later items cannot be opened" was
/// the ordinary case rather than an edge one, and `archivedHTML` was a column that was written,
/// counted in the row's little download badge, and never shown.
///
/// Deliberately not a copy of ``ArticleReaderView``: no full-page loading — there is no feed row
/// here to configure and nothing to re-fetch into — and no kind switch. A saved Mastodon post
/// renders through the same document as an article rather than through `StatusReaderView`, because
/// what a snapshot has is HTML and a byline, not the avatar, poll, media and boost attribution that
/// view is built to show.
struct ArchivedItemView: View {

    let entry: ReadLaterEntry

    @State private var page: WebPage
    @State private var router: ArticleLinkRouter
    @Environment(SettingsModel.self) private var settings
    @Environment(\.openURL) private var openURL

    @MainActor
    init(entry: ReadLaterEntry) {
        self.entry = entry
        // Built together, for the reason given in `ArticleReaderView.init`: the page takes its
        // navigation decider at construction and keeps it.
        let router = ArticleLinkRouter()
        _router = State(initialValue: router)
        _page = State(initialValue: WebPage(navigationDecider: router))
    }

    var body: some View {
        ZStack {
            Color(ReaderPalette.background)
                .ignoresSafeArea()

            WebView(page)
                .webViewContentBackground(.hidden)
        }
        .navigationTitle(entry.title)
        .task(id: entry.itemID) {
            router.open = { openURL($0) }
            router.baseURL = entry.url
            render()
        }
        // The same two as the article reader: without them the pane keeps whatever size it was
        // built with, and the setting looks as though it did nothing.
        .onChange(of: settings.reading.contentScale) { _, _ in
            render()
        }
        .onChange(of: settings.reading.contentLineHeight) { _, _ in
            render()
        }
    }

    /// The document, from whatever the snapshot actually kept.
    private func render() {
        let hasBody = entry.archivedHTML != nil
        page.load(
            html: ReaderDocument.html(
                for: subject,
                // Said only when there is no body, and worth saying: the pane is showing three
                // lines where an article should be, and the reason — this was saved without an
                // offline copy, and the item has since left the cache — is not guessable. The
                // toolbar's Open in Browser is the way out, when the entry has a URL.
                notice: hasBody
                    ? nil
                    : String(localized: "Only the saved summary is left: this item was put aside without an offline copy, and it is no longer in the cache."),
                scale: settings.reading.contentScale,
                lineHeight: settings.reading.contentLineHeight
            ),
            baseURL: entry.url ?? URL(string: "about:blank")!
        )
    }

    private var subject: ReaderDocument.Subject {
        ReaderDocument.Subject(
            // A saved post's `title` is the post's own text — see `ReaderDocument.Subject.title`.
            title: entry.kind == .status ? nil : entry.title,
            // The feed's name stands in for a missing byline. In this pane the article's own
            // heading is right there above it, so the useful second line is where it came from.
            authorName: entry.authorName ?? (entry.sourceTitle.isEmpty ? nil : entry.sourceTitle),
            publishedAt: entry.publishedAt,
            contentHTML: entry.archivedHTML ?? ReaderDocument.paragraphs(from: fallbackText),
            // The snapshot's own link, so the headline clicks through here too. It matters more
            // in this pane than in the reader's: a snapshot is often all that is left of an item
            // the cache has pruned, and the original is then the only place the rest of it is.
            urlString: entry.urlString
        )
    }

    /// What to show when there is no saved body.
    ///
    /// The excerpt, falling back to the title — which for a post behind a content warning is the
    /// warning, and is the only text the snapshot has.
    private var fallbackText: String {
        entry.excerpt.isEmpty ? entry.title : entry.excerpt
    }
}
