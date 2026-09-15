import Foundation
import MastodonAPI
import Observation
import ReadReadModel
import ReadReadSync
import SwiftData

/// Fetches the conversation around a status.
///
/// Kept out of the view so the request has a lifetime the view does not: opening a post, changing
/// your mind and selecting the next one must cancel the first fetch rather than leave two racing
/// to write into the same pane.
@MainActor
@Observable
final class StatusThreadLoader {

    enum State: Equatable {
        /// Nothing asked for yet.
        case idle
        case loading
        case loaded(ancestors: [RenderableStatus], descendants: [RenderableStatus])
        case failed(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading):
                true
            case (.loaded(let la, let ld), .loaded(let ra, let rd)):
                la.map(\.id) == ra.map(\.id) && ld.map(\.id) == rd.map(\.id)
            case (.failed(let l), .failed(let r)):
                l == r
            default:
                false
            }
        }
    }

    private(set) var state: State = .idle

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let connections: AccountConnections

    init(connections: AccountConnections = AccountConnections()) {
        self.connections = connections
    }

    /// Clears whatever was loaded and cancels any request in flight.
    func reset() {
        task?.cancel()
        task = nil
        state = .idle
    }

    /// Loads the conversation for a stored status.
    ///
    /// Takes the `CachedItem` rather than an id because the account it belongs to decides which
    /// instance to ask — a status id is only meaningful on its own server.
    func load(for item: CachedItem, in context: ModelContext) {
        task?.cancel()

        guard let statusID = Self.statusID(of: item) else {
            state = .failed(String(localized: "This post has no conversation to load."))
            return
        }

        let accountID = item.accountID
        state = .loading

        task = Task { [weak self, connections] in
            guard let account = Self.account(accountID, in: context) else {
                self?.state = .failed(String(localized: "The account this post came from is no longer set up."))
                return
            }

            do {
                guard case .mastodon(_, let client) = try connections.connect(account) else {
                    self?.state = .failed(String(localized: "This post did not come from a Mastodon account."))
                    return
                }

                let context = try await client.context(of: statusID)
                // Checked after the await as well as relying on cancellation: a task cancelled
                // mid-request still resumes here, and writing then would drop a stale thread into
                // a pane that has already moved on to another post.
                guard !Task.isCancelled else { return }

                self?.state = .loaded(
                    ancestors: context.ancestors.map { RenderableStatus($0) },
                    descendants: context.descendants.map { RenderableStatus($0) }
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // The error text is not shown: a client error can carry the request, and this
                // one's headers carry the access token.
                self?.state = .failed(String(localized: "The conversation could not be loaded."))
            }
        }
    }

    /// The status's id on its own instance.
    ///
    /// Recovered from the stored payload rather than by unpicking `CachedItem.id`, whose namespaced
    /// form is the store's business. Uses the **displayed** status: a boost has no conversation of
    /// its own, so asking for the wrapper's context returns an empty one.
    private static func statusID(of item: CachedItem) -> MastodonStatusID? {
        guard item.kind == .status,
              let data = item.mastodonPayload,
              let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: data)
        else { return nil }

        return status.displayStatus.id
    }

    private static func account(_ id: UUID, in context: ModelContext) -> AccountRecord? {
        var descriptor = FetchDescriptor<AccountRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
