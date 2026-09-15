import Foundation
import Observation
import ReadReadSupport
import ReadReadModel
import SwiftData

/// Loads the full-page article for the item on screen.
///
/// Kept out of the view for the same reason as ``StatusThreadLoader``: opening an article,
/// changing your mind and arrowing to the next one must cancel the first fetch, not leave two
/// racing to write into the same pane.
@MainActor
@Observable
final class FullPageLoader {

    enum State: Equatable {
        /// This feed does not load full pages, or the item is not an article. The pane shows the
        /// feed's own content.
        case notRequested

        case loading

        /// The extracted article, ready to render.
        case loaded(html: String)

        /// Fetched, but the page had no article in it. Distinct from ``failed`` because it is a
        /// permanent property of the page rather than something a retry could fix.
        case unusable

        case failed(String)
    }

    private(set) var state: State = .notRequested

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let fetcher: FullPageFetcher

    init(fetcher: FullPageFetcher = FullPageFetcher()) {
        self.fetcher = fetcher
    }

    /// Loads the article for an item, if its feed asks for full pages.
    ///
    /// Called on selection, so it must be cheap and idempotent for the overwhelmingly common case
    /// where the feed has the feature off.
    func load(_ item: CachedItem, in context: ModelContext) {
        task?.cancel()
        task = nil

        guard item.kind == .article,
              let url = item.url,
              Self.loadsFullPages(sourceID: item.sourceID, in: context)
        else {
            state = .notRequested
            return
        }

        // Already extracted. Set synchronously rather than through the task, so re-selecting a
        // read article never flashes a spinner over content that is already in hand.
        if let cached = item.fullPageHTML {
            state = .loaded(html: cached)
            return
        }
        if item.fullPageFetchedAt != nil {
            // Fetched before and found nothing. Retrying on every selection would mean a request
            // per keypress while arrowing through a feed that does not extract.
            state = .unusable
            return
        }

        state = .loading
        let itemID = item.id

        task = Task { [weak self, fetcher] in
            do {
                let outcome = try await fetcher.fetch(url)
                guard !Task.isCancelled else { return }
                self?.apply(outcome, toItemWithID: itemID, in: context)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // Not cached: unlike an unusable page, a failed fetch is a transient condition and
                // the next attempt may well succeed.
                self?.state = .failed(Self.describe(error))
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        state = .notRequested
    }

    // MARK: - Private

    private func apply(_ outcome: FullPageFetcher.Outcome, toItemWithID id: String, in context: ModelContext) {
        // Re-fetched rather than captured: the task outlives the view that started it, and holding
        // a model object across an await is how a deleted row becomes a crash.
        var descriptor = FetchDescriptor<CachedItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let item = try? context.fetch(descriptor).first

        switch outcome {
        case .extracted(let html, _):
            item?.fullPageHTML = html
            state = .loaded(html: html)
        case .unusable:
            // Recorded so the next selection does not re-fetch a page already known to hold
            // nothing.
            state = .unusable
        }
        item?.fullPageFetchedAt = .now
        try? context.save()
    }

    private static func loadsFullPages(sourceID: String, in context: ModelContext) -> Bool {
        var descriptor = FetchDescriptor<CachedSource>(predicate: #Predicate { $0.id == sourceID })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor).first)?.loadsFullPageContent ?? false
    }

    /// A message for the reading pane.
    ///
    /// Deliberately does not include the error's own description: an `HTTPError` carries a prefix
    /// of the response body, which for a page behind a login is whatever that site chose to put in
    /// it.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case FullPageFetcher.Failure.notAWebPage:
            String(localized: "That link is not a web page.")
        case FullPageFetcher.Failure.tooLarge:
            String(localized: "That page is too large to read here.")
        case FullPageFetcher.Failure.undecodableText:
            String(localized: "That page's text could not be read.")
        case let http as HTTPError where http.isUnauthorized:
            String(localized: "That page needs a subscription or a login.")
        case HTTPError.status(let code, _):
            String(localized: "The site answered with an error (\(code)).")
        default:
            String(localized: "The page could not be loaded.")
        }
    }
}
