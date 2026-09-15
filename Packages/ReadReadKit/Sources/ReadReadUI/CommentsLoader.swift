import Foundation
import Observation
import ReadReadModel
import ReadReadSupport
import SwiftData

/// Loads the discussion under the article on screen.
///
/// Kept out of the view for the same reason as ``FullPageLoader`` and ``StatusThreadLoader``:
/// opening an article, changing your mind and arrowing to the next one must cancel the first
/// fetch, not leave two racing to write into the same pane.
@MainActor
@Observable
final class CommentsLoader {

    enum State: Equatable {
        /// This feed does not load comments, or the item is not an article. The pane shows no
        /// comment section at all.
        case notRequested

        /// This article has comments to fetch, and the fetch has deliberately not started.
        ///
        /// The state that keeps the discussion out of the article's way. Comments sit at the
        /// bottom of the page and matter less than the thing they are about, so requesting them
        /// while the article is still arriving means two fetches against the same host racing for
        /// the same connections — and the one that loses is the one the reader is waiting for.
        /// The pane leaves an empty section for them and starts the fetch once the article is up.
        case pending

        case loading

        /// Whatever the site had — threads, the page's own markup, or nothing.
        case loaded(CommentsFetcher.Outcome)

        case failed(String)
    }

    private(set) var state: State = .notRequested

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let fetcher: CommentsFetcher

    /// Where each article's comments were found, by item id.
    ///
    /// The point is the request it removes. Finding the comments means fetching the article's page;
    /// reading them means fetching the API. The first answer does not change while the app is open
    /// — a post's id and its site's API do not move — so re-opening an article costs one request
    /// instead of two, and arrowing back and forth through a feed stops re-downloading pages.
    ///
    /// Kept here rather than in the store, deliberately. It is derived, it is cheap to rebuild, and
    /// persisting it would mean a schema change plus an invalidation rule for a site that moves its
    /// API — for a saving of one request per article per launch.
    ///
    /// Not bounded: one entry is a URL and an integer, and the ceiling is however many articles get
    /// opened in one session.
    @ObservationIgnored private var discoveries: [String: CommentsFetcher.Discovery] = [:]

    /// What ``prepare(_:in:)`` decided, held until ``start()`` acts on it.
    @ObservationIgnored private var queued: (itemID: String, url: URL)?

    init(fetcher: CommentsFetcher = CommentsFetcher()) {
        self.fetcher = fetcher
    }

    /// Decides whether this item has comments to fetch, without fetching anything.
    ///
    /// Split from ``start()`` for two reasons, and only the second is about the network. The pane
    /// has to know *before* it builds its document whether to leave a section for the comments,
    /// because filling one in later is an injection and adding one later is a reload — so the
    /// answer has to be available synchronously, on selection. And the fetch itself must wait
    /// until the article is on screen, which is a moment only the view knows about.
    ///
    /// Called on selection, so it must be cheap and idempotent for the overwhelmingly common case
    /// where the feed has the feature off.
    func prepare(_ item: CachedItem, in context: ModelContext) {
        task?.cancel()
        task = nil
        queued = nil

        guard item.kind == .article,
              let url = item.url,
              Self.loadsComments(sourceID: item.sourceID, in: context)
        else {
            state = .notRequested
            return
        }

        // A page already known to have no comments anywhere in it. Answered synchronously so
        // arrowing through such a feed does not put a spinner up per keypress.
        if let known = discoveries[item.id], known.isEmpty {
            state = .loaded(.unsupported)
            return
        }

        queued = (item.id, url)
        state = .pending
    }

    /// Begins the fetch ``prepare(_:in:)`` queued, if there is one.
    ///
    /// Idempotent, and it has to be: the view calls this every time the web view finishes a
    /// navigation, which happens again on a re-render for a reading-size change. Only a `.pending`
    /// loader has anything to start.
    func start() {
        guard case .pending = state, let queued else { return }
        self.queued = nil

        state = .loading
        let itemID = queued.itemID
        let url = queued.url
        let known = discoveries[itemID]

        task = Task { [weak self, fetcher] in
            do {
                // Discovery is reused; the comments themselves never are. A discussion gains
                // replies while you are reading the article above it, so the one thing that must
                // not be cached is the part that changes.
                let discovery = if let known { known } else { try await fetcher.discover(url) }
                let outcome = try await fetcher.comments(using: discovery, at: url)

                // Checked after the awaits as well as relying on cancellation: a cancelled task
                // still resumes here, and writing then would drop one article's discussion under
                // another article.
                guard !Task.isCancelled else { return }
                self?.discoveries[itemID] = discovery
                self?.state = .loaded(outcome)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.state = .failed(Self.describe(error))
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        queued = nil
        state = .notRequested
    }

    // MARK: - Private

    private static func loadsComments(sourceID: String, in context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<CachedSource>(predicate: #Predicate { $0.id == sourceID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.loadsComments ?? false
    }

    /// A message for the comment section.
    ///
    /// Matched case by case, and deliberately never interpolating the error itself: an `HTTPError`
    /// carries a prefix of the response body, which for a site behind a login or a bot wall is
    /// whatever that site chose to put in it.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case CommentsFetcher.Failure.notAWebPage:
            String(localized: "That link is not a web page, so it has no comments.")
        case CommentsFetcher.Failure.tooLarge:
            String(localized: "That page is too large to read here.")
        case CommentsFetcher.Failure.undecodableText:
            String(localized: "That page's text could not be read.")
        case let http as HTTPError where http.isUnauthorized:
            String(localized: "This site does not share its comments.")
        case HTTPError.status(let code, _):
            String(localized: "The site answered with an error (\(code)).")
        default:
            String(localized: "The comments could not be loaded.")
        }
    }
}
