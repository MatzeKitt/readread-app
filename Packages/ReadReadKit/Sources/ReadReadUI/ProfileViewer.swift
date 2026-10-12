import Foundation
import MastodonAPI
import Observation
import ReadReadModel
import ReadReadSupport
import ReadReadSync
import SwiftData
import SwiftUI

/// A Mastodon account, as much as is known before its profile has loaded.
///
/// Enough to draw the top of the profile at once — the name, the handle, the picture — while the
/// rest is fetched, so opening one does not start on a blank sheet.
///
/// The `id` is the account's id **on one instance**: ids are minted per server, so the same person
/// has a different one on every instance that knows them. Which instance is never part of this
/// value; whoever opens a profile says which of the reader's accounts to ask through, and it is
/// always the account the id was read from.
struct ProfileReference: Hashable, Sendable {

    var id: String
    var name: String

    /// `user@host`, without the leading `@`.
    var handle: String

    var avatarURLString: String?

    /// Custom emoji in the display name, keyed by shortcode.
    var emojis: [String: URL] = [:]
}

extension ProfileReference {

    init(_ account: MastodonAccount) {
        self.init(
            id: account.id,
            name: account.bestDisplayName,
            handle: account.acct,
            avatarURLString: account.avatarURLString,
            emojis: ProfileReference.emojiURLs(account.emojis ?? [])
        )
    }

    /// Someone a post mentions. The mention carries no name or picture; the profile fills them in
    /// once it loads.
    init(_ mention: MastodonMention) {
        self.init(id: mention.id, name: "@\(mention.acct)", handle: mention.acct, avatarURLString: nil)
    }

    static func emojiURLs(_ emojis: [MastodonCustomEmoji]) -> [String: URL] {
        var result: [String: URL] = [:]
        for emoji in emojis {
            guard let url = URL(string: emoji.url) else { continue }
            result[emoji.shortcode] = url
        }
        return result
    }
}

/// What tapping an author does.
///
/// An environment value rather than a model the card reaches for, because what it means depends on
/// where the card is. In the reading pane it presents the profile over the window; inside a profile
/// it pushes the next one onto the profile's own stack, so the reader can walk from a follower to
/// their followers and back again without the sheet closing under them.
///
/// Nil where nothing has said what to do, which is how a card knows to draw the author as plain
/// text rather than as a button that does nothing.
struct OpenProfileAction {

    let handler: @MainActor (ProfileReference) -> Void

    @MainActor
    func callAsFunction(_ profile: ProfileReference) {
        handler(profile)
    }
}

extension EnvironmentValues {
    @Entry var openProfile: OpenProfileAction? = nil
}

/// The profile on screen, if one is open.
///
/// Held at the window, like ``MediaViewerModel`` and ``StatusComposer``, because a profile is
/// opened from places that do not outlive it: a timeline row's context menu, and a reading pane
/// that changes under it whenever the selection moves.
@MainActor
@Observable
final class ProfileViewerModel {

    /// Identified by a fresh id per opening, so opening the same profile twice presents it twice.
    struct Session: Identifiable {
        let id = UUID()

        /// The reader's account to ask through — the one ``ProfileReference/id`` belongs to.
        let accountID: UUID

        let profile: ProfileReference
    }

    var session: Session?

    func open(_ profile: ProfileReference, as accountID: UUID) {
        session = Session(accountID: accountID, profile: profile)
    }

    /// Opens the profile of whoever wrote a stored post, or answers false when the row cannot say.
    ///
    /// The author of the **displayed** status: on a boost, the person being read is the one who
    /// wrote the post, not the one who passed it on. Read from the stored payload, because the
    /// account's id has no column.
    @discardableResult
    func open(authorOf item: CachedItem) -> Bool {
        guard
            item.kind == .status,
            let payload = item.mastodonPayload,
            let status = try? JSONDecoder.mastodon.decode(MastodonStatus.self, from: payload)
        else { return false }

        open(ProfileReference(status.displayStatus.account), as: item.accountID)
        return true
    }

    func dismiss() { session = nil }
}

extension View {

    /// Presents the profile the model is holding.
    func profileViewer(_ model: ProfileViewerModel) -> some View {
        sheet(item: Binding(get: { model.session }, set: { model.session = $0 })) { session in
            ProfileSheet(session: session)
        }
    }
}

// MARK: - Loading

/// Fetches a profile and pages through its posts and its two account lists.
///
/// Kept out of the view for the same reason as ``StatusThreadLoader``: the requests need a lifetime
/// of their own, and a profile popped off the stack must not keep writing into one that has gone.
@MainActor
@Observable
final class ProfileLoader {

    enum Tab: Hashable, CaseIterable {
        case posts
        case following
        case followers
    }

    enum Phase: Equatable {
        case idle
        case loading
        case failed(String)
    }

    /// One pageable list.
    struct Listing<Element: Identifiable> {
        var elements: [Element] = []
        var phase: Phase = .idle

        /// Where the next page starts. Nil before the first page, and after the last.
        var nextMaxID: String?

        /// Whether the first page has come back. Separate from ``nextMaxID``, whose nil means both
        /// "not started" and "finished".
        var hasLoaded = false

        var canLoadMore: Bool { !hasLoaded || nextMaxID != nil }

        /// Adds a page, skipping anything already listed.
        ///
        /// Not hypothetical: a post and a boost of it both display the post, under the post's id,
        /// and a list that repeats an id breaks `ForEach`'s identity — rows swap content or vanish.
        mutating func append(_ page: [Element], next: String?) where Element.ID == String {
            var seen = Set(elements.map(\.id))
            elements += page.filter { seen.insert($0.id).inserted }
            // An empty page with a next link would page forever over nothing.
            nextMaxID = page.isEmpty ? nil : next
            hasLoaded = true
            phase = .idle
        }
    }

    let reference: ProfileReference
    let accountID: UUID

    private(set) var profile: MastodonProfile?
    private(set) var profilePhase: Phase = .idle

    /// Whether there is an instance to ask. False before ``start(in:)`` and when the account could
    /// not be connected, in which case there are no lists to offer either.
    private(set) var isConnected = false

    private(set) var posts = Listing<RenderableStatus>()
    private(set) var following = Listing<AccountRow>()
    private(set) var followers = Listing<AccountRow>()

    /// The posts the account has pinned, shown above the rest. Empty until they arrive, and if they
    /// never do: they are a heading over the posts, not something worth an error of their own.
    private(set) var pinned: [RenderableStatus] = []

    /// The posts below the pinned ones, without the pinned ones again.
    ///
    /// The instance lists a pinned post in its place in time as well. Shown twice in one stack, the
    /// two copies would share an id, which `ForEach` cannot tell apart.
    var unpinnedPosts: [RenderableStatus] {
        guard !pinned.isEmpty else { return posts.elements }
        let pinnedIDs = Set(pinned.map(\.id))
        return posts.elements.filter { !pinnedIDs.contains($0.id) }
    }

    // MARK: Following

    /// One of the reader's Mastodon accounts, and how it stands towards this profile.
    struct FollowActor: Identifiable {

        enum Problem: Equatable {
            /// The token was granted before following was asked for.
            case notAllowed
            /// The account's server could not find this profile.
            case notFound
            /// Signed out, or its server did not answer.
            case unavailable
        }

        /// The reader's account.
        let id: UUID
        let name: String

        /// The profile's id **on this account's instance**, once known. For the account the profile
        /// was opened through it is known from the start; for the rest it has to be resolved.
        var targetID: String?

        var relationship: MastodonRelationship?
        var problem: Problem?

        /// This account is the profile being shown, which has nothing to follow.
        var isSelf = false

        /// A follow or unfollow is on its way.
        var isChanging = false

        var isLoading: Bool { relationship == nil && problem == nil && !isSelf }

        /// Following, or asked to and not answered yet. Either way, the action on offer is to undo it.
        var follows: Bool { relationship?.following == true || relationship?.requested == true }
    }

    /// Every Mastodon account the reader could follow with, the one the profile was opened through
    /// first — the order the Like and Boost menus use, for the same reason.
    private(set) var actors: [FollowActor] = []

    /// Why the last follow or unfollow did not work, for the line under the handle.
    private(set) var followProblem: String?

    /// The actors that are not this profile itself.
    var followActors: [FollowActor] { actors.filter { !$0.isSelf } }

    /// Whether to offer a menu of accounts rather than a single button.
    ///
    /// Counted with the reader's own account included: on the profile of one of two accounts, the
    /// other is the only one that can follow — and a bare Follow button would not say which.
    var offersAccountMenu: Bool { actors.count > 1 }

    /// Whether this profile follows any of the reader's other accounts.
    var followsReader: Bool {
        actors.contains { !$0.isSelf && $0.relationship?.followedBy == true }
    }

    /// The sentence for the single account whose token predates following, where a menu would have
    /// said it beside the account's name.
    var followNotice: String? {
        if let followProblem { return followProblem }
        guard !offersAccountMenu, let only = actors.first, only.problem == .notAllowed else { return nil }
        return Self.notAllowedYet(only.name)
    }

    /// The same sentence a Like gets from a token granted before it was allowed.
    static func notAllowedYet(_ accountName: String) -> String {
        String(localized: "\(accountName) has not allowed this yet. Use Reauthorise on its row in Settings to grant it.")
    }

    /// How another instance can be asked to find this profile.
    ///
    /// The ActivityPub URI where the instance gives one, because it names the account on every
    /// server alike. Otherwise the handle, completed with the viewing instance's host for a local
    /// account — whose `acct` is the bare username there. That host is the instance's web address,
    /// which for the rare instance serving handles under a different domain is not the handle's
    /// domain; WebFinger usually still answers there, and the URI covers every instance from 4.2.
    nonisolated static func resolutionQuery(for profile: MastodonProfile, viewingHost: String?) -> String? {
        if let uri = profile.uri, !uri.isEmpty { return uri }
        if profile.isRemote { return profile.acct }
        guard let viewingHost, !viewingHost.isEmpty else { return nil }
        return "\(profile.acct)@\(viewingHost)"
    }

    /// Whether an account as an instance lists it is that instance's own `username`.
    ///
    /// Only a local account can be: the acting account lives on the instance being asked, so its
    /// `acct` there is the bare username.
    nonisolated static func isSelf(acct: String, username: String) -> Bool {
        guard !acct.contains("@") else { return false }
        return AuthorMute.normalised(acct).lowercased() == AuthorMute.normalised(username).lowercased()
    }

    /// One account in a follower list. A wrapper only so it can be `Identifiable` by the id the
    /// list deduplicates on.
    struct AccountRow: Identifiable, Sendable {
        var profile: ProfileReference
        var id: String { profile.id }
    }

    @ObservationIgnored private var client: MastodonClient?

    /// A client per account that could follow, by the reader's account id.
    @ObservationIgnored private var followClients: [UUID: MastodonClient] = [:]
    @ObservationIgnored private var usernames: [UUID: String] = [:]
    @ObservationIgnored private var viewingHost: String?
    @ObservationIgnored private var hasResolvedActors = false
    @ObservationIgnored private var tasks: [Tab: Task<Void, Never>] = [:]
    @ObservationIgnored private var profileTask: Task<Void, Never>?
    @ObservationIgnored private let connections: AccountConnections

    init(reference: ProfileReference, accountID: UUID, connections: AccountConnections = AccountConnections()) {
        self.reference = reference
        self.accountID = accountID
        self.connections = connections
    }

    func cancel() {
        profileTask?.cancel()
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
    }

    /// Fetches the profile and the first page of posts.
    func start(in context: ModelContext) {
        guard profilePhase != .loading else { return }

        do {
            client = try connectedClient(in: context)
            isConnected = true
        } catch {
            profilePhase = .failed(Self.describe(error))
            return
        }

        loadProfile()
        loadMore(.posts)
        loadPinned()
        // The account the profile was opened through already knows the profile's id. The others
        // wait for the profile itself, whose address is how their instances are asked to find it.
        if let viewing = actors.first, viewing.id == accountID {
            loadRelationship(of: viewing.id, with: reference.id)
        }
    }

    private func loadPinned() {
        guard let client else { return }
        let id = reference.id
        Task { [weak self] in
            guard let statuses = try? await client.pinnedStatuses(id) else { return }
            self?.pinned = statuses.map { RenderableStatus($0) }
        }
    }

    /// Finds the profile on every other account's instance, then how each stands towards it.
    private func resolveOtherActors(for profile: MastodonProfile) {
        guard !hasResolvedActors else { return }
        hasResolvedActors = true

        if let index = actors.firstIndex(where: { $0.id == accountID }) {
            actors[index].isSelf = Self.isSelf(acct: profile.acct, username: usernames[accountID] ?? "")
        }

        let query = Self.resolutionQuery(for: profile, viewingHost: viewingHost)
        for actor in actors where actor.id != accountID && actor.problem == nil {
            guard let client = followClients[actor.id], let query else {
                update(actor.id) { $0.problem = .unavailable }
                continue
            }
            let username = usernames[actor.id] ?? ""
            Task { [weak self] in
                do {
                    guard let account = try await client.resolveAccount(query) else {
                        self?.update(actor.id) { $0.problem = .notFound }
                        return
                    }
                    self?.update(actor.id) {
                        $0.targetID = account.id
                        $0.isSelf = Self.isSelf(acct: account.acct, username: username)
                    }
                    if !Self.isSelf(acct: account.acct, username: username) {
                        self?.loadRelationship(of: actor.id, with: account.id)
                    }
                } catch {
                    self?.update(actor.id) { $0.problem = .unavailable }
                }
            }
        }
    }

    private func loadRelationship(of actorID: UUID, with targetID: String) {
        guard let client = followClients[actorID] else { return }
        update(actorID) { $0.targetID = targetID }
        Task { [weak self] in
            do {
                guard let relationship = try await client.relationship(with: targetID) else {
                    self?.update(actorID) { $0.problem = .unavailable }
                    return
                }
                self?.update(actorID) { $0.relationship = relationship }
            } catch MastodonError.writeNotAuthorized {
                self?.update(actorID) { $0.problem = .notAllowed }
            } catch {
                self?.update(actorID) { $0.problem = .unavailable }
            }
        }
    }

    /// Follows the profile as one of the reader's accounts, or unfollows it, or withdraws a
    /// request not yet answered.
    func toggleFollow(as actorID: UUID) {
        guard
            let actor = actors.first(where: { $0.id == actorID }),
            let client = followClients[actorID],
            let targetID = actor.targetID,
            actor.relationship != nil,
            !actor.isChanging
        else { return }
        let follows = actor.follows

        update(actorID) { $0.isChanging = true }
        followProblem = nil
        Task { [weak self] in
            defer { self?.update(actorID) { $0.isChanging = false } }
            do {
                let relationship = try await client.follow(targetID, isOn: !follows)
                self?.update(actorID) { $0.relationship = relationship }
                // Fetched again for the follower count, which the reader may just have changed.
                // Quietly: a stale count is not worth replacing the profile with an error.
                if let refresh = self?.client, let id = self?.reference.id,
                   let profile = try? await refresh.profile(id) {
                    self?.profile = profile
                }
            } catch MastodonError.writeNotAuthorized {
                self?.update(actorID) {
                    $0.relationship = nil
                    $0.problem = .notAllowed
                }
                self?.followProblem = Self.notAllowedYet(actor.name)
            } catch {
                self?.followProblem = follows
                    ? String(localized: "Could not unfollow. The server may be unreachable.")
                    : String(localized: "Could not follow. The server may be unreachable.")
            }
        }
    }

    private func update(_ actorID: UUID, _ change: (inout FollowActor) -> Void) {
        guard let index = actors.firstIndex(where: { $0.id == actorID }) else { return }
        change(&actors[index])
    }

    func loadProfile() {
        guard let client else { return }
        profilePhase = .loading
        let id = reference.id

        profileTask?.cancel()
        profileTask = Task { [weak self] in
            do {
                let profile = try await client.profile(id)
                guard !Task.isCancelled else { return }
                self?.profile = profile
                self?.profilePhase = .idle
                self?.resolveOtherActors(for: profile)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                self?.profilePhase = .failed(Self.describe(error))
            }
        }
    }

    /// Fetches the next page of a tab, unless one is already on its way or there is none.
    func loadMore(_ tab: Tab) {
        guard let client, tasks[tab] == nil else { return }

        let id = reference.id
        switch tab {
        case .posts:
            guard posts.canLoadMore else { return }
            posts.phase = .loading
            let maxID = posts.nextMaxID
            run(tab) { [weak self] in
                let page = try await client.accountStatuses(id, maxID: maxID)
                self?.posts.append(page.statuses.map { RenderableStatus($0) }, next: page.nextMaxID)
            } failed: { [weak self] message in
                self?.posts.phase = .failed(message)
            }

        case .following:
            guard following.canLoadMore else { return }
            following.phase = .loading
            let maxID = following.nextMaxID
            run(tab) { [weak self] in
                let page = try await client.following(of: id, maxID: maxID)
                self?.following.append(Self.rows(page.accounts), next: page.nextMaxID)
            } failed: { [weak self] message in
                self?.following.phase = .failed(message)
            }

        case .followers:
            guard followers.canLoadMore else { return }
            followers.phase = .loading
            let maxID = followers.nextMaxID
            run(tab) { [weak self] in
                let page = try await client.followers(of: id, maxID: maxID)
                self?.followers.append(Self.rows(page.accounts), next: page.nextMaxID)
            } failed: { [weak self] message in
                self?.followers.phase = .failed(message)
            }
        }
    }

    private func run(
        _ tab: Tab,
        _ work: @escaping @MainActor () async throws -> Void,
        failed: @escaping @MainActor (String) -> Void
    ) {
        tasks[tab] = Task { [weak self] in
            defer { self?.tasks[tab] = nil }
            do {
                try await work()
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                failed(Self.describe(error))
            }
        }
    }

    private static func rows(_ accounts: [MastodonAccount]) -> [AccountRow] {
        accounts.map { AccountRow(profile: ProfileReference($0)) }
    }

    /// Connects the account the profile was opened through, and every other account that could
    /// follow it.
    ///
    /// Only the first can fail the profile: the others are offered in the Follow menu, and one of
    /// them being signed out is a fact about that menu item rather than about the profile.
    private func connectedClient(in context: ModelContext) throws -> MastodonClient {
        let all = (try? context.fetch(FetchDescriptor<AccountRecord>())) ?? []
        guard let account = all.first(where: { $0.id == accountID }) else {
            throw ProfileLoaderError.accountGone
        }
        guard case .mastodon(_, let client) = try connections.connect(account) else {
            throw ProfileLoaderError.notMastodon
        }

        viewingHost = account.serverURL?.host()
        followClients = [account.id: client]
        usernames = [account.id: account.username]
        actors = [FollowActor(id: account.id, name: account.displayName)]
        // Rebuilt from scratch, as on a retry after the profile failed, so the others are found
        // again once it loads.
        hasResolvedActors = false

        let others = StatusInteractions.Actor.menuOrder(for: all, owner: accountID).filter { $0.id != accountID }
        for other in others {
            guard let record = all.first(where: { $0.id == other.id }) else { continue }
            var actor = FollowActor(id: record.id, name: record.displayName)
            if case .mastodon(_, let otherClient)? = try? connections.connect(record) {
                followClients[record.id] = otherClient
                usernames[record.id] = record.username
            } else {
                actor.problem = .unavailable
            }
            actors.append(actor)
        }
        return client
    }

    private enum ProfileLoaderError: Error {
        case accountGone
        case notMastodon
    }

    /// Built case by case rather than from the error's own text, which can carry the request — and
    /// the request carries the access token.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case ProfileLoaderError.accountGone:
            String(localized: "The account this profile was opened from is no longer set up.")
        case ProfileLoaderError.notMastodon:
            String(localized: "This post did not come from a Mastodon account.")
        case MastodonError.tokenRevoked:
            String(localized: "The Mastodon account needs to be signed in again.")
        default:
            String(localized: "This could not be loaded.")
        }
    }
}

// MARK: - Presentation

/// The overlay a profile opens in, with a stack of its own for the profiles reached from it.
struct ProfileSheet: View {

    let session: ProfileViewerModel.Session

    @Environment(\.dismiss) private var dismiss

    @State private var path: [ProfileReference] = []

    /// The sheet's own media viewer. The window's cannot present while this sheet is up — a
    /// presentation from underneath a sheet is silently dropped — so a picture tapped in a
    /// profile's posts would otherwise do nothing at all.
    @State private var mediaViewer = MediaViewerModel()

    var body: some View {
        content
            .environment(\.openProfile, OpenProfileAction { path.append($0) })
            .environment(mediaViewer)
            .mediaViewer(mediaViewer)
    }

    #if os(macOS)
    /// A stack drawn by hand on the Mac. A sheet there has no window toolbar for a navigation
    /// stack's back button to live in, so the bar is part of the content instead.
    private var content: some View {
        let current = path.last ?? session.profile

        return VStack(spacing: 0) {
            HStack {
                if !path.isEmpty {
                    Button("Back", systemImage: "chevron.backward") { path.removeLast() }
                        .keyboardShortcut("[", modifiers: .command)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            ProfileView(reference: current, accountID: session.accountID)
                // A new identity per profile, so each one starts its own loader rather than
                // inheriting the state of the one it was reached from.
                .id(path.count)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 560, idealHeight: 720)
    }
    #else
    private var content: some View {
        NavigationStack(path: $path) {
            ProfileView(reference: session.profile, accountID: session.accountID)
                .navigationDestination(for: ProfileReference.self) { profile in
                    ProfileView(reference: profile, accountID: session.accountID)
                }
        }
    }
    #endif
}

/// One profile: who it is, then their posts, or whom they follow, or who follows them.
struct ProfileView: View {

    let reference: ProfileReference
    let accountID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openProfile) private var openProfile
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsModel.self) private var settings

    @State private var loader: ProfileLoader?
    @State private var tab: ProfileLoader.Tab = .posts

    /// The account waiting on the unfollow confirmation. See `unfollow(as:in:)`.
    @State private var pendingUnfollow: UUID?

    private var contentScale: TextScale { settings.reading.contentScale }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header

                if let loader {
                    switch loader.profilePhase {
                    case .failed(let message):
                        failure(message) { loader.start(in: modelContext) }
                            .padding(.horizontal, 20)
                    default:
                        if let profile = loader.profile {
                            details(of: profile)
                        }
                    }

                    if loader.isConnected {
                        tabs
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)

                        Divider()

                        list(of: loader)
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(Text(verbatim: loader?.profile?.bestDisplayName ?? reference.name))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        #endif
        .task(id: reference) {
            // Kept across a disappearance: on iPhone this view disappears whenever the next profile
            // is pushed over it, and coming back should find it as it was left rather than loading
            // it again from the top.
            guard loader?.reference != reference else { return }
            loader?.cancel()
            let loader = ProfileLoader(reference: reference, accountID: accountID)
            self.loader = loader
            tab = .posts
            loader.start(in: modelContext)
        }
    }

    // MARK: Header

    private var emojis: [String: URL] {
        guard let profile = loader?.profile else { return reference.emojis }
        return ProfileReference.emojiURLs(profile.emojis ?? [])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            banner

            HStack(alignment: .bottom, spacing: 12) {
                SourceIcon(
                    urlString: loader?.profile?.avatarURLString ?? reference.avatarURLString,
                    fallbackSystemImage: "person.crop.circle",
                    size: 72
                )
                .clipShape(.rect(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.background, lineWidth: 3)
                }
                // Pulled up over the banner, the way every Mastodon client draws a profile.
                .padding(.top, bannerURL == nil ? 0 : -40)

                Spacer(minLength: 0)

                if let loader {
                    followControl(loader)
                }
            }
            .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 2) {
                EmojiText(loader?.profile?.bestDisplayName ?? reference.name, emojis: emojis, scale: contentScale)
                    .scaledFont(.title3, weight: .bold, scale: contentScale)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    Text(verbatim: "@\(loader?.profile?.acct ?? reference.handle)")
                        .textSelection(.enabled)
                    if loader?.profile?.locked == true {
                        Image(systemName: "lock.fill")
                            .accessibilityLabel("Approves followers")
                    }
                    if loader?.profile?.bot == true {
                        Text("Bot")
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                    if loader?.followsReader == true {
                        Text("Follows you")
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: .capsule)
                    }
                }
                .scaledFont(.subheadline, scale: contentScale)
                .foregroundStyle(.secondary)

                if let notice = loader?.followNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: Following

    /// Follow, Unfollow, or Cancel Request — as any of the reader's Mastodon accounts.
    ///
    /// One button for a reader with one account, which is then the only possible answer to "as
    /// whom". With several, a menu naming each, like Like and Boost: which account follows is the
    /// whole question, and a follow from the wrong one is seen by the person followed.
    ///
    /// Nothing until the profile has loaded, because which of the reader's accounts *is* this
    /// profile is not known before — and a Follow button on one's own profile offers nonsense.
    @ViewBuilder
    private func followControl(_ loader: ProfileLoader) -> some View {
        if loader.profile != nil {
            Group {
                if loader.offersAccountMenu {
                    followMenu(loader)
                } else if let only = loader.actors.first, !only.isSelf, only.relationship != nil {
                    followButton(for: only, in: loader)
                }
            }
            .confirmationDialog(
                unfollowTitle(loader),
                isPresented: Binding(
                    get: { pendingUnfollow != nil },
                    set: { if !$0 { pendingUnfollow = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingUnfollow
            ) { actorID in
                Button("Unfollow", role: .destructive) { loader.toggleFollow(as: actorID) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This account approves its followers, so following it again needs a new request.")
            }
        }
    }

    @ViewBuilder
    private func followButton(for actor: ProfileLoader.FollowActor, in loader: ProfileLoader) -> some View {
        Group {
            if actor.relationship?.following == true {
                Button("Unfollow") { unfollow(as: actor.id, in: loader) }
                    .buttonStyle(.bordered)
            } else if actor.relationship?.requested == true {
                Button("Cancel Request") { loader.toggleFollow(as: actor.id) }
                    .buttonStyle(.bordered)
            } else {
                Button("Follow") { loader.toggleFollow(as: actor.id) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .disabled(actor.isChanging)
        .overlay {
            if actor.isChanging {
                ProgressView().controlSize(.small)
            }
        }
    }

    /// The menu for a reader with several accounts.
    ///
    /// Titled for the state across all of them — Following as soon as any one follows, which is the
    /// answer to the question a profile's button is read for — and prominent only while none does,
    /// the way the single button is.
    @ViewBuilder
    private func followMenu(_ loader: ProfileLoader) -> some View {
        let actors = loader.followActors
        let anyFollows = actors.contains { $0.follows }
        let isChanging = actors.contains { $0.isChanging }

        let menu = Menu {
            ForEach(actors) { actor in
                followMenuItem(for: actor, in: loader)
            }
        } label: {
            if anyFollows {
                // Its own key: the tab below says "Following" of whom *they* follow, and German
                // needs a different word for the reader's own following.
                Label {
                    Text(LocalizedStringResource("Following (menu)", defaultValue: "Following"))
                } icon: {
                    Image(systemName: "checkmark")
                }
            } else {
                Text("Follow")
            }
        }
        .fixedSize()
        .disabled(actors.isEmpty)
        .overlay {
            if isChanging {
                ProgressView().controlSize(.small)
            }
        }

        if anyFollows {
            menu.buttonStyle(.bordered)
        } else {
            menu.buttonStyle(.borderedProminent)
        }
    }

    /// One account in the Follow menu: what it would do, or why it cannot.
    @ViewBuilder
    private func followMenuItem(for actor: ProfileLoader.FollowActor, in loader: ProfileLoader) -> some View {
        if let problem = actor.problem {
            Button {} label: {
                switch problem {
                case .notAllowed:
                    Text("\(actor.name): Reauthorise in Settings to follow")
                case .notFound:
                    Text("\(actor.name): Its server cannot find this account")
                case .unavailable:
                    Text("\(actor.name): Not available")
                }
            }
            .disabled(true)
        } else if actor.isLoading || actor.isChanging {
            Button("\(actor.name): Loading…") {}
                .disabled(true)
        } else if actor.relationship?.following == true {
            Button("Unfollow as \(actor.name)", systemImage: "person.badge.minus") {
                unfollow(as: actor.id, in: loader)
            }
        } else if actor.relationship?.requested == true {
            Button("Cancel Request as \(actor.name)", systemImage: "person.badge.clock") {
                loader.toggleFollow(as: actor.id)
            }
        } else {
            Button("Follow as \(actor.name)", systemImage: "person.badge.plus") {
                loader.toggleFollow(as: actor.id)
            }
        }
    }

    /// Asks first only where unfollowing cannot simply be undone: an account that approves its
    /// followers has to approve the reader again. Everywhere else Follow puts it back.
    private func unfollow(as actorID: UUID, in loader: ProfileLoader) {
        if loader.profile?.locked == true {
            pendingUnfollow = actorID
        } else {
            loader.toggleFollow(as: actorID)
        }
    }

    private func unfollowTitle(_ loader: ProfileLoader) -> String {
        String(localized: "Unfollow @\(loader.profile?.acct ?? reference.handle)?")
    }

    private var bannerURL: URL? {
        loader?.profile?.headerURLString.flatMap(URL.init(string:))
    }

    @ViewBuilder
    private var banner: some View {
        if let bannerURL {
            Color.clear
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let image = RemoteImageStore.timelineMedia.image(for: bannerURL) {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .clipped()
                .accessibilityHidden(true)
        } else {
            Color.clear.frame(height: 12)
        }
    }

    @ViewBuilder
    private func details(of profile: MastodonProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !profile.note.isEmpty {
                EmojiText(
                    StatusTextCache.shared.fullText(
                        id: "profile:\(accountID):\(profile.id)",
                        html: profile.note,
                        plain: HTMLText.plainText(from: profile.note)
                    ),
                    emojis: emojis,
                    scale: contentScale
                )
                .scaledFont(.body, scale: contentScale, lineHeight: settings.reading.contentLineHeight)
                .textSelection(.enabled)
                .tint(StatusTextCache.linkColor)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let fields = profile.fields, !fields.isEmpty {
                fieldTable(fields, of: profile)
            }

            if let joined = profile.createdAt {
                Label {
                    Text("Joined \(joined.formatted(.dateTime.month(.wide).year()))")
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private func fieldTable(_ fields: [MastodonProfile.Field], of profile: MastodonProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(fields.enumerated()), id: \.offset) { offset, field in
                if offset > 0 { Divider() }
                VStack(alignment: .leading, spacing: 2) {
                    EmojiText(field.name, emojis: emojis, scale: contentScale)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        EmojiText(
                            StatusTextCache.shared.fullText(
                                id: "profile-field:\(accountID):\(profile.id):\(offset)",
                                html: field.value,
                                plain: HTMLText.plainText(from: field.value)
                            ),
                            emojis: emojis,
                            scale: contentScale
                        )
                        .scaledFont(.callout, scale: contentScale)
                        .textSelection(.enabled)
                        .tint(StatusTextCache.linkColor)

                        if field.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel("Verified link")
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
    }

    // MARK: Tabs

    /// The three counts, which are also the three lists — the arrangement every Mastodon client
    /// uses, so the number and the way to see what it counts are the same thing.
    private var tabs: some View {
        HStack(spacing: 8) {
            tabButton(.posts, count: loader?.profile?.statusesCount, title: "Posts")
            tabButton(.following, count: loader?.profile?.followingCount, title: "Following")
            tabButton(.followers, count: loader?.profile?.followersCount, title: "Followers")
        }
    }

    private func tabButton(_ tab: ProfileLoader.Tab, count: Int?, title: LocalizedStringKey) -> some View {
        let isSelected = self.tab == tab

        return Button {
            self.tab = tab
            loader?.loadMore(tab)
        } label: {
            VStack(spacing: 2) {
                Text(count.map { $0.formatted(.number.notation(.compactName)) } ?? "–")
                    .font(.headline)
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isSelected ? SurfaceFill.current : SurfaceFill.clear, in: .rect(cornerRadius: 10))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Lists

    @ViewBuilder
    private func list(of loader: ProfileLoader) -> some View {
        switch tab {
        case .posts:
            ForEach(loader.pinned) { post in
                VStack(alignment: .leading, spacing: 0) {
                    Label("Pinned", systemImage: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                    StatusCard(status: post, emphasis: .listed)
                        .padding(.horizontal, 8)
                }
                Divider().padding(.horizontal, 20)
            }
            ForEach(loader.unpinnedPosts) { post in
                StatusCard(status: post, emphasis: .listed)
                    .padding(.horizontal, 8)
                Divider().padding(.horizontal, 20)
            }
            footer(for: loader.posts, empty: "No posts.", tab: .posts)

        case .following:
            followNote(for: loader)
            ForEach(loader.following.elements) { row in
                accountRow(row.profile)
            }
            footer(for: loader.following, empty: emptyNetworkText(for: loader), tab: .following)

        case .followers:
            followNote(for: loader)
            ForEach(loader.followers.elements) { row in
                accountRow(row.profile)
            }
            footer(for: loader.followers, empty: emptyNetworkText(for: loader), tab: .followers)
        }
    }

    private func emptyNetworkText(for loader: ProfileLoader) -> LocalizedStringKey {
        loader.profile?.hideCollections == true ? "This account keeps this list private." : "Nobody here yet."
    }

    /// Why a remote account's lists are shorter than their counts: an instance can only list the
    /// accounts it knows, while the counts come from the account's own server.
    @ViewBuilder
    private func followNote(for loader: ProfileLoader) -> some View {
        if loader.profile?.isRemote == true {
            Text("Only accounts known to your server are listed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
        }
    }

    private func accountRow(_ profile: ProfileReference) -> some View {
        Button {
            openProfile?(profile)
        } label: {
            HStack(spacing: 10) {
                SourceIcon(urlString: profile.avatarURLString, fallbackSystemImage: "person.crop.circle", size: 36)
                    .clipShape(.rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 1) {
                    EmojiText(profile.name, emojis: profile.emojis, scale: contentScale)
                        .scaledFont(.subheadline, weight: .semibold, scale: contentScale)
                        .lineLimit(1)
                    Text(verbatim: "@\(profile.handle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.forward")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the profile")
    }

    /// The end of a list: a spinner that fetches the next page as it scrolls into view, the reason
    /// a page failed, or a word for a list with nothing in it.
    @ViewBuilder
    private func footer<Element: Identifiable>(
        for listing: ProfileLoader.Listing<Element>,
        empty: LocalizedStringKey,
        tab: ProfileLoader.Tab
    ) -> some View {
        Group {
            switch listing.phase {
            case .failed(let message):
                failure(message) { loader?.loadMore(tab) }
            case .loading:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            case .idle:
                if listing.canLoadMore {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .onAppear { loader?.loadMore(tab) }
                } else if listing.elements.isEmpty {
                    Text(empty)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(20)
    }

    private func failure(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Try Again", action: retry)
                .controlSize(.small)
        }
        .padding(.vertical, 12)
    }
}
