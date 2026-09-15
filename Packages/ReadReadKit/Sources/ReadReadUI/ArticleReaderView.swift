import ReadReadModel
import SwiftData
import SwiftUI
import WebKit

#if os(macOS)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif

/// Renders an article's HTML with reader styling.
///
/// Uses SwiftUI's own `WebView`/`WebPage` rather than wrapping `WKWebView` in a
/// `UIViewRepresentable`: it is the supported path from macOS/iOS 26 onwards and removes the
/// coordinator plumbing that bridging otherwise needs.
struct ArticleReaderView: View {

    let item: CachedItem

    @State private var page: WebPage
    @State private var router: ArticleLinkRouter
    @State private var loader = FullPageLoader()
    @State private var comments = CommentsLoader()
    @Environment(\.modelContext) private var modelContext
    @Environment(SettingsModel.self) private var settings
    @Environment(\.openURL) private var openURL

    @MainActor
    init(item: CachedItem) {
        self.item = item
        // Built together, because the page takes its decider at construction and keeps it. The
        // router is a class precisely so the closure it calls can be filled in later, once the
        // view can see the environment.
        let router = ArticleLinkRouter()
        _router = State(initialValue: router)
        _page = State(initialValue: WebPage(navigationDecider: router))
    }

    /// Whether the document currently in the web view has finished loading and laying out.
    ///
    /// The web view is kept at zero opacity until this turns true, so a document is composed
    /// invisibly and appears in one step rather than being watched as it assembles.
    @State private var isRendered = false

    var body: some View {
        // Fetched once per body evaluation rather than three times.
        //
        // `source` is a `FetchDescriptor`, and it was reached from `fullPageIsAvailable` and from
        // both ends of `fullPageBinding` — all of them computed properties read from the toolbar.
        // This view's body re-evaluates on every navigation the web view reports, so the fetches
        // ran in the middle of loading each article rather than once when it opened.
        let feedSource = source

        return ZStack {
            // Painted by SwiftUI, in the app's own colours, and *always* underneath the web view.
            //
            // Half of the flash was here: `WKWebView` draws its own opaque white backing before
            // the first paint of a document, so every article began with a white rectangle no
            // matter what the document's CSS said. `webViewContentBackground(.hidden)` stops it
            // drawing that backing at all, which leaves this showing through — the right colour in
            // both appearances, and identical between articles so there is nothing to flash.
            Color(ReaderPalette.background)
                .ignoresSafeArea()

            WebView(page)
                .webViewContentBackground(.hidden)
                // The other half: a document is *loaded* well before it is drawn, so revealing on
                // load left a frame or two of blank, correctly-coloured pane before the text
                // arrived. Held back until the page reports it has finished.
                .opacity(isRendered && !isLoading ? 1 : 0)

            if isLoading {
                LoadingArticlePlaceholder()
            }
        }
        .navigationTitle(item.title)
        .task(id: item.id) {
            // Re-set on every article rather than once, so the router always holds the current
            // environment's `openURL` — which is the one the link setting is wired into.
            router.open = { openURL($0) }
            loader.load(item, in: modelContext)
            // Reset first: the loader outlives the item, so without this the previous article's
            // discussion would sit under the new one until its own fetch replaced it.
            //
            // `prepare` decides, and deliberately fetches nothing — the request waits for the
            // article to be on screen. See `startComments()`.
            comments.reset()
            comments.prepare(item, in: modelContext)
            // Rendered here as well as on change, because the common case — a feed that does not
            // load full pages — leaves the state exactly where it was, and a view that only
            // rendered on change would show the previous article for good.
            //
            // After `comments.prepare`, and that ordering is load-bearing: it answers
            // synchronously whether there are comments coming, which is what tells `render`
            // whether to leave a section for them.
            render()
        }
        .onChange(of: loader.state) { _, _ in
            render()
        }
        // Not a re-render. The comments land while the article is already on screen and very
        // possibly already being read, so they are written into the document that is up rather
        // than occasioning a new one — see `showComments()`.
        .onChange(of: comments.state) { _, _ in
            showComments()
        }
        // Otherwise the pane keeps the size it was built with until the next article is opened,
        // which makes the setting look like it did nothing.
        .onChange(of: settings.reading.contentScale) { _, _ in
            render()
        }
        .onChange(of: settings.reading.contentLineHeight) { _, _ in
            render()
        }
        // `WebPage.isLoading` is observable, so this fires as the navigation completes rather than
        // on a timer. Only ever raises the flag: `render()` lowers it, so a page that finishes and
        // then starts another navigation of its own does not blank the article that is already up.
        .onChange(of: page.isLoading) { _, isLoading in
            guard !isLoading else { return }
            isRendered = true
            // Again here, because a document that has just loaded is empty of whatever was
            // injected into the last one — and because comments that arrived while it was still
            // loading had nothing to be written into.
            showComments()
            startComments()
        }
        .toolbar {
            ToolbarItemGroup {
                if let feedSource, item.url != nil {
                    Toggle(isOn: fullPageBinding(feedSource)) {
                        Label("Full Page", systemImage: "doc.richtext")
                    }
                    // Its own tooltip already, and a longer one than a bare title: what "Full
                    // Page" means is the part worth explaining on hover.
                    .help("Load this feed's articles from their own pages instead of the feed summary.")

                    Toggle(isOn: commentsBinding(feedSource)) {
                        Label("Comments", systemImage: "text.bubble")
                    }
                    // Longer than its title, like the toggle above, because what it costs is the
                    // part worth knowing before switching it on.
                    .help("Load the discussion from each of this feed's articles and show it underneath.")
                }
                // Read Later, Open in Browser and Share all live in `DetailView`, which owns the
                // item rather than the way it happens to be rendered. Only this toggle is a
                // property of *article* rendering, so only it belongs here.
            }
        }
    }

    private var isLoading: Bool {
        loader.state == .loading
    }

    /// The feed this item belongs to, when it is one whose full pages could be loaded.
    ///
    /// Mastodon timelines are excluded: a post *is* its content, so there is no page to go and
    /// fetch a better version from.
    private var source: CachedSource? {
        guard item.kind == .article else { return nil }
        let sourceID = item.sourceID
        var descriptor = FetchDescriptor<CachedSource>(predicate: #Predicate { $0.id == sourceID })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    /// Offered here, in the pane, as well as in the sidebar: noticing that a feed is truncated
    /// happens while reading one of its articles, not while looking at the feed list.
    ///
    /// Takes the feed it acts on rather than re-fetching it from both ends of the binding.
    private func fullPageBinding(_ source: CachedSource) -> Binding<Bool> {
        Binding(
            get: { source.loadsFullPageContent },
            set: { newValue in
                source.loadsFullPageContent = newValue
                try? modelContext.save()
                loader.load(item, in: modelContext)
            }
        )
    }

    /// Offered beside the full-page toggle, for the same reason: whether a feed's comments are
    /// worth reading is something you find out while reading one of its articles.
    private func commentsBinding(_ source: CachedSource) -> Binding<Bool> {
        Binding(
            get: { source.loadsComments },
            set: { newValue in
                source.loadsComments = newValue
                try? modelContext.save()
                comments.prepare(item, in: modelContext)
                // The one comments change that *does* re-render: whether the section exists at all
                // is the document's shape rather than its contents, and there is nothing to lose
                // your place in — the reader is at the toolbar, not mid-article. Reloading also
                // means the fetch starts the same way it does on selection, once the document is
                // back up, rather than needing a second path here.
                render()
            }
        )
    }

    /// Starts fetching the comments, once the article no longer needs the network.
    ///
    /// Deferred rather than started on selection, because the discussion is the least important
    /// thing on the page and sits at the bottom of it. Two fetches against the same host at once
    /// share a connection pool, and the request that loses is the article the reader is waiting
    /// for — so this waits until the article is settled and drawn.
    ///
    /// Both guards are load-bearing. `isLoading` is the *full-page* fetch: while that is running
    /// the pane is showing `ReaderDocument.blank`, whose navigation completing would otherwise
    /// start the comments in the middle of the fetch this is meant to stay out of the way of.
    /// `isRendered` means the document now on screen is the article's own.
    private func startComments() {
        guard isRendered, !isLoading else { return }
        comments.start()
    }

    /// Writes the current comment state into the document that is already on screen.
    ///
    /// Through `callJavaScript` rather than by rebuilding the document, because rebuilding scrolls
    /// the reader back to the top. The markup crosses as an *argument* rather than being spliced
    /// into the script text, so no amount of quoting inside a comment can end the statement it is
    /// travelling in.
    ///
    /// Errors are dropped on purpose. The one that happens is calling this before the document has
    /// finished loading, where `window.rrComments` does not exist yet — and the load completing is
    /// itself one of the two things that calls this.
    private func showComments() {
        guard let markup = ReaderComments.markup(for: comments.state) else { return }
        Task {
            _ = try? await page.callJavaScript(
                "window.rrComments(markup);",
                arguments: ["markup": markup]
            )
        }
    }

    private var scale: TextScale { settings.reading.contentScale }
    private var lineHeight: Double { settings.reading.contentLineHeight }

    /// Puts the current state into the web view.
    private func render() {
        // Lowered first, so the outgoing article is hidden for exactly as long as the incoming one
        // takes to compose — which is what makes the swap look like a swap rather than a rebuild.
        isRendered = false
        let baseURL = item.url ?? URL(string: "about:blank")!
        // So an anchor within the article is left to scroll instead of being sent to a browser.
        router.baseURL = item.url

        // Whether to leave a section for the comments to be written into. Read from the loader
        // rather than from the feed, because the loader has already answered the same question —
        // it reports `.notRequested` for a feed with comments off, an item that is not an article,
        // and an item with no page to fetch.
        let hasComments = comments.state != .notRequested

        switch loader.state {
        case .loading:
            // The web view is shared across selections, so the outgoing article has to be cleared
            // as the spinner goes up — otherwise the spinner sits on top of the *previous*
            // article, which reads as the app having lost track of the selection.
            page.load(html: ReaderDocument.blank, baseURL: URL(string: "about:blank")!)
        case .loaded(let html):
            page.load(
                html: ReaderDocument.html(
                    for: item,
                    body: html,
                    hasComments: hasComments,
                    scale: scale,
                    lineHeight: lineHeight
                ),
                baseURL: baseURL
            )
        case .notRequested:
            page.load(
                html: ReaderDocument.html(
                    for: item,
                    hasComments: hasComments,
                    scale: scale,
                    lineHeight: lineHeight
                ),
                baseURL: baseURL
            )
        case .unusable:
            page.load(
                html: ReaderDocument.html(
                    for: item,
                    notice: String(localized: "This page has no article to extract, so the feed's own content is shown."),
                    hasComments: hasComments,
                    scale: scale,
                    lineHeight: lineHeight
                ),
                baseURL: baseURL
            )
        case .failed(let message):
            page.load(
                html: ReaderDocument.html(
                    for: item,
                    notice: message,
                    hasComments: hasComments,
                    scale: scale,
                    lineHeight: lineHeight
                ),
                baseURL: baseURL
            )
        }
    }
}

/// The colour behind a reading pane's web view, matching the reader stylesheet's own background.
///
/// Taken from the platform's text-background colour rather than hard-coded, so it follows the
/// system appearance — including a mid-session switch to dark mode — the same way the CSS does.
///
/// At file scope because two views paint it: this one, and the archived-snapshot reader. A second
/// copy would be free to drift, and drift here shows up as a flash of the wrong colour between
/// articles, which is precisely what painting it was for.
enum ReaderPalette {

    static var background: PlatformColor {
        #if os(macOS)
        .textBackgroundColor
        #else
        .systemBackground
        #endif
    }
}

/// Sends a link tapped inside an article out of the reading pane.
///
/// Without this a tap *navigates the pane*: the article is replaced by whatever was linked, with
/// no back button, no address bar and nothing to say what happened — the reading position is still
/// there in the timeline, but the article you were reading is gone. Handing the URL to `openURL`
/// instead sends it wherever the app's link setting says, which is the in-app browser on iOS and
/// the default browser on the Mac.
@MainActor
final class ArticleLinkRouter: WebPage.NavigationDeciding {

    /// Filled in by the view, which is the only thing that can see the environment.
    var open: ((URL) -> Void)?

    /// The article's own URL.
    var baseURL: URL?

    func decidePolicy(
        for action: WebPage.NavigationAction,
        preferences: inout WebPage.NavigationPreferences
    ) async -> WKNavigationActionPolicy {
        // Only what the reader clicked. Everything else — loading the document itself, a redirect,
        // a form — is the pane doing its job and must be allowed, or the article never appears.
        guard action.navigationType == .linkActivated,
              let url = action.request.url,
              Self.shouldHandOff(url, baseURL: baseURL)
        else {
            return .allow
        }

        open?(url)
        return .cancel
    }

    /// Whether a link should leave the pane.
    ///
    /// Pure and separate because the interesting case is the one that looks like a link and is
    /// not: an anchor into the article itself. A footnote marker is a scroll, and opening a
    /// browser on the page you are already reading would be absurd.
    static func shouldHandOff(_ url: URL, baseURL: URL?) -> Bool {
        guard url.fragment != nil, let baseURL else { return true }
        return withoutFragment(url) != withoutFragment(baseURL)
    }

    private static func withoutFragment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }
}

/// What the reading pane shows while a full page is being fetched.
///
/// A spinner over an empty pane rather than over the feed's summary: showing the summary first and
/// replacing it a second later reads as the article changing under you.
struct LoadingArticlePlaceholder: View {

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading the full article…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading the full article")
    }
}

/// Builds the HTML document an article is rendered inside.
///
/// The feed's own markup is wrapped rather than rendered bare: feed HTML carries no viewport, no
/// colour scheme and often absolute widths, so unwrapped it renders as a desktop page shrunk into
/// the pane, in permanent light mode, with images overflowing horizontally.
enum ReaderDocument {

    /// What a reader document is built from.
    ///
    /// A value type rather than the `CachedItem` itself, because the pane has to render two things
    /// that are not the same kind of object: a cached item, and a Read Later snapshot of an item
    /// the cache no longer has. They carry the same four fields, and having the document take those
    /// four is what stops the archive view growing a second, drifting copy of this stylesheet.
    struct Subject {

        /// `nil` for a Mastodon post, which has no title of its own — ingest puts the post's own
        /// text in `title`, and setting *that* as an `<h1>` would print the post twice, once as a
        /// headline.
        var title: String?

        var authorName: String?
        var publishedAt: Date
        var contentHTML: String

        /// Where the item came from, so the headline can link to it.
        ///
        /// This replaced a toolbar button. "Open in Browser" used to be one of three buttons over
        /// the reading pane, which on an iPhone is a scarce slot spent on something the content can
        /// carry itself — a headline that links to the article is where a reader already expects
        /// to be able to click through. See `DetailView.itemActions`.
        ///
        /// `nil` leaves the heading as plain text rather than as a dead link, which is the right
        /// answer for the handful of feeds that publish no link at all.
        var urlString: String?

        init(
            title: String?,
            authorName: String? = nil,
            publishedAt: Date,
            contentHTML: String,
            urlString: String? = nil
        ) {
            self.title = title
            self.authorName = authorName
            self.publishedAt = publishedAt
            self.contentHTML = contentHTML
            self.urlString = urlString
        }

        init(_ item: CachedItem) {
            self.init(
                title: item.title,
                authorName: item.authorName,
                publishedAt: item.publishedAt,
                contentHTML: item.contentHTML,
                urlString: item.urlString
            )
        }
    }

    /// - Parameters:
    ///   - body: Article HTML to render in place of the feed's own content, when a full page was
    ///     extracted. Already sanitised by `HTMLSanitizer`.
    ///   - notice: A line explaining why the feed's content is being shown after all.
    static func html(
        for item: CachedItem,
        body: String? = nil,
        notice: String? = nil,
        hasComments: Bool = false,
        scale: TextScale = .standard,
        lineHeight: Double = ReadingSettings.defaultLineHeight
    ) -> String {
        html(
            for: Subject(item),
            body: body,
            notice: notice,
            hasComments: hasComments,
            scale: scale,
            lineHeight: lineHeight
        )
    }

    /// - Parameter hasComments: Whether to leave an empty comment section for the loader to fill.
    ///   Empty and `hidden`, because the comments arrive a request after the article does: filling
    ///   it means re-rendering the document, and re-rendering means the reader loses their place in
    ///   the article they had already started. See `ArticleReaderView.showComments()`.
    static func html(
        for subject: Subject,
        body: String? = nil,
        notice: String? = nil,
        hasComments: Bool = false,
        scale: TextScale = .standard,
        lineHeight: Double = ReadingSettings.defaultLineHeight
    ) -> String {
        let byline = [subject.authorName, subject.publishedAt.formatted(date: .abbreviated, time: .shortened)]
            .compactMap { $0 }
            .joined(separator: " · ")

        let banner = notice.map { "<p class=\"notice\">\(escaped($0))</p>" } ?? ""
        let heading = subject.title.map { title in
            // Linked when there is somewhere to link to. Clicks go through `ArticleLinkRouter`
            // like every other link in the document, so this honours the reader's in-app/external
            // preference for free — and it is why the URL is not opened from Swift here.
            //
            // `escaped` on both halves. The title is text from a feed and the URL is a string from
            // one; an unescaped quote in either closes the attribute and everything after it is
            // markup this app wrote on a stranger's behalf.
            guard let urlString = headlineHref(subject.urlString) else {
                return "<h1>\(escaped(title))</h1>"
            }
            return "<h1><a class=\"headline\" href=\"\(escaped(urlString))\">\(escaped(title))</a></h1>"
        } ?? ""
        let comments = hasComments
            ? "<section id=\"\(ReaderComments.sectionID)\" hidden></section>"
            : ""

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
        <style>:root { --reader-scale: \(scale.multiplier); --reader-leading: \(lineHeight) }</style>
        </head>
        <body>
        <article>
        \(heading)
        <p class="byline">\(escaped(byline))</p>
        \(banner)
        \(body ?? subject.contentHTML)
        </article>
        \(comments)
        <script>\(script)</script>
        </body>
        </html>
        """
    }

    /// Plain text as document markup, for a snapshot that kept only an excerpt.
    ///
    /// Escaped and split into paragraphs on blank lines: the excerpt is *text*, so rendering it as
    /// HTML would both lose its line breaks and hand the document whatever `<` the article happened
    /// to contain.
    static func paragraphs(from text: String) -> String {
        text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "<p>\(escaped($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            .joined(separator: "\n")
    }

    /// An empty document, used to clear the pane between selections.
    static let blank = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>html, body { background: transparent; margin: 0 }</style>
        </head><body></body></html>
        """

    /// Reader styling.
    ///
    /// `color-scheme: light dark` is what makes the web view honour the system appearance — without
    /// it the pane stays stubbornly white in dark mode. Sizes use `-apple-system-body` so the text
    /// tracks Dynamic Type instead of being pinned to a fixed pixel size.
    private static let css = """
        :root {
            color-scheme: light dark;
            --text: #1c1c1e;
            --muted: #6c6c70;
            --rule: rgba(0, 0, 0, 0.12);
            --link: #0a2f5f;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --text: #f2f2f7;
                --muted: #9c9ca0;
                --rule: rgba(255, 255, 255, 0.16);
                --link: #7fb0ff;
            }
        }
        body {
            margin: 0;
            padding: 2rem 1.5rem 4rem;
            font: -apple-system-body;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            /* Multiplied onto whatever `-apple-system-body` resolved to, rather than replacing it
               with a fixed size — so the reader's Dynamic Type setting still decides the baseline
               and this only shifts it. Everything else in the document sizes in `em`, so one
               declaration carries the whole article. */
            font-size: calc(1em * var(--reader-scale, 1));
            line-height: var(--reader-leading, 1.5);
            color: var(--text);
            /* Transparent on purpose: the pane behind this is painted by SwiftUI, so the document
               must not paint a second background over it. Making this a colour instead is what
               reintroduces a flash, because the document's paint lands after the view is on
               screen. */
            background: transparent;
            -webkit-text-size-adjust: 100%;
        }
        article { max-width: 42rem; margin: 0 auto; }
        h1 { font-size: 1.7em; line-height: 1.25; margin: 0 0 0.35em; }
        /* The headline links to the original, and reads as a headline rather than as a link: in
           the app's link colour it would be the loudest thing on the page, and underlined it
           would look like a mistake. The underline on hover is the affordance; on a touch screen
           there is no hover and no need for one, because tapping a headline to reach the article
           is what a reader tries anyway. */
        h1 a.headline { color: inherit; text-decoration: none; }
        h1 a.headline:hover { text-decoration: underline; }
        h2, h3, h4 { line-height: 1.3; margin: 1.6em 0 0.5em; }
        .byline { color: var(--muted); font-size: 0.9em; margin: 0 0 2em; }
        /* Explains why the feed's own content is being shown; deliberately quiet, since the
           article below it is still perfectly readable. */
        .notice {
            margin: 0 0 2em;
            padding: 0.6em 0.9em;
            border-radius: 0.5em;
            font-size: 0.85em;
            color: var(--muted);
            background: color-mix(in srgb, var(--text) 7%, transparent);
        }
        a { color: var(--link); }
        /* Images and embeds must never force horizontal scrolling in a narrow pane. */
        img, video, iframe, svg { max-width: 100%; height: auto; }
        /* An article's pictures are usually reproduced small enough to be unreadable, so they open
           full-pane. The cursor says so before the click. An image the author wrapped in a link
           keeps the link's cursor, because the link is what it will do. */
        img { cursor: zoom-in; }
        a img { cursor: pointer; }
        /* The script gives every enlargeable image a tab stop, so it needs somewhere to draw the
           focus. Left to the default, a focused `<img>` in a dark reader is nearly invisible. */
        img[role="button"]:focus-visible,
        .rr-lightbox-close:focus-visible {
            outline: 3px solid var(--link);
            outline-offset: 3px;
        }
        /* Escape closes the overlay, and on iPhone there is no Escape. */
        .rr-lightbox-close {
            position: fixed;
            top: 1rem;
            right: 1rem;
            width: 2.5rem;
            height: 2.5rem;
            border: none;
            border-radius: 50%;
            background: rgba(255, 255, 255, 0.18);
            color: #fff;
            font-size: 1.2rem;
            line-height: 1;
            cursor: pointer;
        }
        .rr-lightbox {
            position: fixed;
            inset: 0;
            z-index: 9999;
            display: flex;
            align-items: center;
            justify-content: center;
            overflow: auto;
            background: rgba(0, 0, 0, 0.94);
            cursor: zoom-out;
            -webkit-user-select: none;
        }
        /* Fit to the pane first: the point is to see the whole picture. */
        .rr-lightbox img { max-width: 100%; max-height: 100%; width: auto; cursor: zoom-in; }
        /* Then, on a second click, its own pixels — with the overlay scrolling around it, which is
           what makes a large diagram or screenshot actually readable. */
        .rr-lightbox.rr-actual { align-items: flex-start; justify-content: flex-start; }
        .rr-lightbox.rr-actual img { max-width: none; max-height: none; cursor: zoom-out; }
        figure { margin: 1.5em 0; }
        figcaption { color: var(--muted); font-size: 0.85em; }
        blockquote {
            margin: 1.5em 0;
            padding: 0 0 0 1em;
            border-left: 3px solid var(--rule);
            color: var(--muted);
        }
        pre {
            overflow-x: auto;
            padding: 0.9em;
            border-radius: 0.5em;
            background: color-mix(in srgb, var(--text) 7%, transparent);
        }
        code { font-family: ui-monospace, "SF Mono", Menlo, monospace; font-size: 0.9em; }
        /* Wide tables scroll inside their own box rather than stretching the document. */
        table { display: block; overflow-x: auto; border-collapse: collapse; }
        th, td { padding: 0.4em 0.7em; border: 1px solid var(--rule); }
        hr { border: none; border-top: 1px solid var(--rule); margin: 2em 0; }
        /* The discussion, shaped like the Mastodon thread it is modelled on: the same measure as
           the article, a rule to separate it, and each reply nested under what it replies to. */
        #comments {
            max-width: 42rem;
            margin: 3em auto 0;
            padding-top: 1.5em;
            border-top: 1px solid var(--rule);
        }
        .rr-comments-title { font-size: 1.15em; margin: 0 0 1em; }
        .rr-comments-note { color: var(--muted); font-size: 0.9em; margin: 0; }
        /* No markers and no padding of its own: the indent below is the only thing that should say
           how deep a reply sits, and a list marker beside an avatar reads as a bullet point. */
        .rr-thread { list-style: none; margin: 0; padding: 0; }
        /* Nested threads step right and carry a rule, so the depth survives being read on a phone
           where the indent alone is too small to notice. `em` rather than a fixed size, so a
           larger reading size indents proportionally instead of squeezing the text. */
        .rr-thread .rr-thread {
            margin-left: 1.1em;
            padding-left: 1.1em;
            border-left: 2px solid var(--rule);
        }
        .rr-comment { margin: 0 0 1.5em; }
        .rr-comment-head { display: flex; align-items: center; gap: 0.5em; margin-bottom: 0.35em; }
        /* Fixed and non-shrinking: an avatar that has not loaded yet must not let the name jump
           left and then back as it arrives. */
        .rr-avatar {
            flex: none;
            width: 2em;
            height: 2em;
            border-radius: 50%;
            object-fit: cover;
            background: color-mix(in srgb, var(--text) 10%, transparent);
        }
        .rr-author { font-weight: 600; font-size: 0.95em; }
        .rr-when { color: var(--muted); font-size: 0.85em; margin-left: auto; }
        /* The body's own paragraphs, tightened: a comment is usually one paragraph, and an
           article's paragraph spacing between two of them reads as two comments. */
        .rr-comment-body > :first-child { margin-top: 0; }
        .rr-comment-body > :last-child { margin-bottom: 0; }
        .rr-comment-body p { margin: 0.5em 0; }
        /* The fallback path, where the markup is whatever a theme produced. Its own nesting and
           lists are intact, so all this does is stop them being drawn as article furniture. */
        .rr-comments-page ol, .rr-comments-page ul { list-style: none; padding-left: 1.1em; }
        .rr-comments-page img { max-width: 3em; }
        @media (prefers-reduced-motion: reduce) {
            * { animation: none !important; transition: none !important; }
        }
        """

    /// Click-to-enlarge and playable media, done inside the document.
    ///
    /// In the document rather than bridged out to SwiftUI because the pictures here are *article*
    /// HTML: an `<img>` may be a `srcset`, a `<picture>`, a data URI or a relative path resolved
    /// against the article's own base URL, and only the web view knows which bytes it actually
    /// drew. Handing a URL across to a native viewer would mean re-resolving all of that and
    /// getting it wrong for the interesting cases.
    ///
    /// The video half is a plain omission being corrected: feeds routinely emit `<video>` with no
    /// `controls` attribute, and a video with no controls is a still frame you cannot start.
    private static let script = """
        (function () {
            var box = null;

            // Where focus was before the overlay took it, so closing puts it back on the picture
            // that was opened rather than dumping it at the top of the document.
            var returnFocusTo = null;

            function close() {
                if (!box) { return; }
                box.remove();
                box = null;
                document.documentElement.style.overflow = "";
                if (returnFocusTo && returnFocusTo.focus) { returnFocusTo.focus(); }
                returnFocusTo = null;
            }

            function open(source, alt, origin) {
                close();
                returnFocusTo = origin || null;

                box = document.createElement("div");
                box.className = "rr-lightbox";
                // Announced as a dialog rather than as an anonymous div, so a screen reader says
                // what has just taken over the pane instead of reading the page behind it.
                box.setAttribute("role", "dialog");
                box.setAttribute("aria-modal", "true");
                box.setAttribute("aria-label", alt || "Image");

                var image = document.createElement("img");
                image.src = source;
                if (alt) { image.alt = alt; }
                box.appendChild(image);

                // Escape alone was the only way out, and there is no Escape on a phone — so
                // VoiceOver and a touch keyboard both had to close it by guessing at the margin.
                var closeButton = document.createElement("button");
                closeButton.type = "button";
                closeButton.className = "rr-lightbox-close";
                closeButton.setAttribute("aria-label", "\(String(localized: "Close image"))");
                closeButton.textContent = "✕";
                closeButton.addEventListener("click", function (event) {
                    event.stopPropagation();
                    close();
                });
                box.appendChild(closeButton);

                box.addEventListener("click", function (event) {
                    // Clicking the picture toggles fit against actual size; clicking the space
                    // around it closes. Anything else and there is no way out on a trackpad.
                    if (event.target === image) {
                        box.classList.toggle("rr-actual");
                    } else if (event.target === box) {
                        close();
                    }
                });

                document.body.appendChild(box);
                document.documentElement.style.overflow = "hidden";
                closeButton.focus();
            }

            /// Whether this image is one the reader can enlarge.
            ///
            /// The same two tests the click handler applies, hoisted so the markup can be
            /// prepared up front — an affordance that only exists once you have clicked is no
            /// affordance at all to anyone not using a mouse.
            function isEnlargeable(image) {
                // An image inside a link belongs to the link: the author said where it goes.
                if (image.closest("a")) { return false; }
                // Inside the discussion, only what is *drawn* counts. A comment's avatar is
                // chrome, and it is delivered at 96 pixels to be drawn at 32 — so measuring it
                // the article's way, by the larger of natural and laid-out size, turned every
                // commenter's face into a clickable picture.
                var side = image.closest("#comments")
                    ? (image.offsetWidth || 0)
                    // Spacers, tracking pixels and inline icons. Opening a 16-point bullet
                    // full-pane is not what anyone clicking it meant.
                    : Math.max(image.naturalWidth || 0, image.offsetWidth || 0);
                return side >= 80;
            }

            document.addEventListener("click", function (event) {
                if (box) { return; }
                var target = event.target;
                if (!target || !target.closest) { return; }

                var image = target.closest("img");
                if (!image || !isEnlargeable(image)) { return; }

                event.preventDefault();
                open(image.currentSrc || image.src, image.alt, image);
            });

            document.addEventListener("keydown", function (event) {
                if (event.key === "Escape") { close(); }
            });

            /// Marks the enlargeable images as the buttons they behave like.
            ///
            /// Click-to-enlarge was mouse-only: an `<img>` is not focusable and carries no role,
            /// so nothing about the picture said it could be opened and no key would open it.
            /// A tab stop, a role, and Enter/Space are what turn the existing behaviour into one
            /// a keyboard or VoiceOver can reach.
            ///
            /// Run after load as well as immediately, because `offsetWidth` and `naturalWidth`
            /// are both zero until the image has been laid out — measuring too early would
            /// classify every picture in the article as a spacer.
            function markEnlargeable(image) {
                if (!isEnlargeable(image) || image.getAttribute("role") === "button") { return; }
                image.setAttribute("role", "button");
                image.setAttribute("tabindex", "0");
                // Kept short: the alt text is already the image's own label, and repeating it
                // here would have it read twice.
                image.setAttribute("aria-haspopup", "dialog");
                image.title = image.title || "\(String(localized: "Show this image full size"))";
            }

            function markAllEnlargeable() {
                Array.prototype.forEach.call(document.querySelectorAll("img"), markEnlargeable);
            }

            markAllEnlargeable();
            window.addEventListener("load", markAllEnlargeable);
            Array.prototype.forEach.call(document.querySelectorAll("img"), function (image) {
                image.addEventListener("load", function () { markEnlargeable(image); });
            });

            document.addEventListener("keydown", function (event) {
                if (box) { return; }
                if (event.key !== "Enter" && event.key !== " ") { return; }

                var image = document.activeElement;
                if (!image || image.tagName !== "IMG" || !isEnlargeable(image)) { return; }

                // Space scrolls a document, which is exactly the wrong thing under a picture the
                // reader has just chosen to open.
                event.preventDefault();
                open(image.currentSrc || image.src, image.alt, image);
            });

            /// Fills the comment section, from Swift, without reloading the document.
            ///
            /// The whole reason this is a function rather than part of the document: the comments
            /// arrive a request after the article, and re-rendering to include them would scroll
            /// the reader back to the top of something they had already started reading.
            window.rrComments = function (markup) {
                var host = document.getElementById("comments");
                if (!host) { return; }
                host.innerHTML = markup;
                // `hidden` rather than a class, so a section with nothing in it takes no space and
                // draws no rule above itself.
                host.hidden = !markup;
                // The pictures inside a comment are new to the document, so whatever the reader
                // can enlarge has to be marked again.
                markAllEnlargeable();
            };

            Array.prototype.forEach.call(
                document.querySelectorAll("video, audio"),
                function (media) {
                    media.controls = true;
                    // Inline rather than taking over the screen, matching how the article reads.
                    media.setAttribute("playsinline", "");
                    // Metadata only: a feed page with four videos on it must not pull four videos.
                    if (!media.getAttribute("preload")) { media.preload = "metadata"; }
                }
            );
        })();
        """

    /// Escapes text interpolated into the document's own chrome.
    ///
    /// Only for the title and byline. The article body is intentionally *not* escaped — it is HTML
    /// and rendering it is the point — which is exactly why these two fields must be, since a title
    /// containing `<` would otherwise break the surrounding markup.
    /// The headline's `href`, or `nil` when the item's link is not one to put in a document.
    ///
    /// Restricted to http and https, which is the same line `LinkPolicy` draws and drawn here for a
    /// sharper reason. A feed's canonical link is a string from a stranger, and this is the one
    /// place the app writes such a string into an anchor of its *own* making — a `javascript:` href
    /// there is script the reader ran by clicking a headline, not a page they asked to visit. The
    /// article body's own anchors are the feed's markup and a separate matter; this one is ours.
    private static func headlineHref(_ urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty else { return nil }
        guard let scheme = URL(string: urlString)?.scheme?.lowercased() else { return nil }
        guard scheme == "http" || scheme == "https" else { return nil }
        return urlString
    }

    private static func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
