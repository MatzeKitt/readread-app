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

    /// The post the loaded conversation is to be read around, when it was loaded as a whole.
    ///
    /// Set by ``loadConversation(rootStatusID:accountID:focusing:in:)``, where the posts above
    /// the focus are the subscribed post and its ancestors, and the reply being read sits somewhere
    /// among ``State/loaded(ancestors:descendants:)``'s descendants rather than between the two.
    /// Nil for the ordinary thread, which is loaded around the post itself.
    private(set) var focusStatusID: String?

    /// How deep each descendant sits below the post the conversation was loaded for, from one.
    ///
    /// Only filled for a whole conversation, where the replies to a dozen different replies are
    /// otherwise one flat column with nothing to say which answers which.
    private(set) var depths: [String: Int] = [:]

    /// The reader's account the loaded posts were fetched through.
    ///
    /// Worth keeping because the posts carry ids — their authors' above all — that mean something
    /// only on that account's instance, and a whole conversation is loaded through the
    /// subscription's account rather than necessarily the one the post arrived in.
    private(set) var accountID: UUID?

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
        focusStatusID = nil
        depths = [:]
        accountID = nil
    }

    /// Loads the conversation for a stored status.
    ///
    /// Takes the `CachedItem` rather than an id because the account it belongs to decides which
    /// instance to ask — a status id is only meaningful on its own server.
    func load(for item: CachedItem, in context: ModelContext) {
        task?.cancel()
        focusStatusID = nil
        depths = [:]

        guard let statusID = Self.statusID(of: item) else {
            state = .failed(String(localized: "This post has no conversation to load."))
            return
        }

        let accountID = item.accountID
        self.accountID = accountID
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

    /// Loads the whole conversation under a subscribed post, to read one of its replies inside it.
    ///
    /// The ordinary thread is the wrong shape for a followed reply. It is loaded around the reply,
    /// so it shows the chain straight up to the subscribed post and the replies *to this reply* —
    /// and none of the other answers, which are what following a conversation is for. Loaded from
    /// the subscribed post instead, the reply is one of its descendants, and the reader sees it in
    /// its place among them.
    ///
    /// Two requests, side by side: the post itself, which a context does not include, and its
    /// context. The post is drawn above its replies, under its own ancestors.
    ///
    /// - Parameters:
    ///   - rootStatusID: The subscribed post's id on the account's instance.
    ///   - item: The reply being read. Its displayed status's id becomes ``focusStatusID``.
    func loadConversation(
        rootStatusID: String,
        accountID: UUID,
        focusing item: CachedItem,
        in context: ModelContext
    ) {
        task?.cancel()

        guard let focus = Self.statusID(of: item) else {
            // No payload to find the reply's id in, so there is no place in the conversation to
            // put it. The ordinary thread says so in its own words.
            load(for: item, in: context)
            return
        }

        focusStatusID = focus.rawValue
        depths = [:]
        self.accountID = accountID
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

                let rootID = MastodonStatusID(rootStatusID)
                async let root = client.status(rootID)
                async let conversation = client.context(of: rootID)
                let (post, thread) = try await (root, conversation)
                guard !Task.isCancelled else { return }

                // A subscribed post that has gone still has its replies to read, so its absence
                // only takes it out of the column rather than failing the whole conversation.
                let above = thread.ancestors + (post.map { [$0] } ?? [])
                self?.depths = Self.depths(of: thread.descendants, under: rootID.rawValue)
                self?.state = .loaded(
                    ancestors: above.map { RenderableStatus($0) },
                    descendants: thread.descendants.map { RenderableStatus($0) }
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                // Not shown, as in `load(for:in:)`: the error can carry the request's headers.
                self?.state = .failed(String(localized: "The conversation could not be loaded."))
            }
        }
    }

    /// How deep each reply sits below `rootID`: one for a direct answer, two for an answer to that.
    ///
    /// Worked out from each reply's parent rather than from its position, because Mastodon returns
    /// the descendants as one flat array. A reply whose parent is not in the array — one the
    /// instance withheld — is put one level under the post, which is the least wrong place for it.
    nonisolated static func depths(of descendants: [MastodonStatus], under rootID: String) -> [String: Int] {
        let parents = Dictionary(
            descendants.map { ($0.id.rawValue, $0.inReplyToId) },
            uniquingKeysWith: { first, _ in first }
        )
        var depths: [String: Int] = [rootID: 0]

        func depth(of id: String, seen: Set<String>) -> Int {
            if let known = depths[id] { return known }
            // Climbs only through parents that are the post or among its replies. A cycle cannot
            // come from a real instance, but a malformed answer must not hang the pane, so a
            // repeat ends the climb as well.
            guard
                let parent = parents[id] ?? nil,
                parent == rootID || parents[parent] != nil,
                !seen.contains(parent)
            else {
                depths[id] = 1
                return 1
            }
            let value = depth(of: parent, seen: seen.union([id])) + 1
            depths[id] = value
            return value
        }

        for status in descendants {
            _ = depth(of: status.id.rawValue, seen: [])
        }
        depths[rootID] = nil
        return depths
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
