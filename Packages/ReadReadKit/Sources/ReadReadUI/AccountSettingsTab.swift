import FreshRSSAPI
import MastodonAPI
import ReadReadModel
import ReadReadSupport
import ReadReadSync
import SwiftData
import SwiftUI

/// The accounts pane: the servers ReadRead reads from, and the endpoint it syncs positions through.
///
/// The two are in one place because from the user's side they are the same question — "what is this
/// app talking to" — even though internally one is a feed source and the other is the sync
/// transport.
struct AccountSettingsTab: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    @Query(sort: \AccountRecord.createdAt) private var accounts: [AccountRecord]

    @State private var signIn: SignInRequest?
    @State private var pendingRemoval: AccountRecord?

    /// The accounts this device holds a credential for.
    ///
    /// Read from the Keychain rather than inferred from the record, because the record cannot know:
    /// the account list syncs and credentials deliberately do not, so a record that arrived from
    /// another device looks exactly like one signed in here. See ``AccountConnections/hasCredential(forAccountID:kind:)``.
    @State private var signedInAccountIDs: Set<UUID> = []

    /// Whether the Keychain has been asked yet.
    ///
    /// Without it every row claims to be signed out for the instant before the first answer
    /// arrives, which is a warning about nothing on every visit to this pane.
    @State private var hasCheckedCredentials = false

    /// What a sign-in sheet was opened for.
    ///
    /// Adding an account and signing in to one already listed are the same flow with a different
    /// destination: the first creates a record, the second must land on the record the reader
    /// pressed the button on — keeping its id, and with it every reading position, cached item and
    /// sync record already attached to it.
    private struct SignInRequest: Identifiable {

        let kind: AccountKind

        /// The account being signed in to again, or `nil` when adding a new one.
        let existing: AccountRecord?

        var id: String { existing.map(\.id.uuidString) ?? kind.rawValue }
    }

    var body: some View {
        // A `Form`, not a `List`: the sync endpoint's fields need the leading-label layout a form
        // gives them. In a list they rendered as bare, unlabelled text fields.
        Form {
            Section {
                if accounts.isEmpty {
                    ContentUnavailableView(
                        "No Accounts",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text("Add a FreshRSS server or a Mastodon account to start reading.")
                    )
                }

                ForEach(accounts) { account in
                    AccountRow(
                        account: account,
                        // Unknown until the Keychain has answered, and unknown is not the same as
                        // signed out — see `hasCheckedCredentials`.
                        isSignedIn: !hasCheckedCredentials || signedInAccountIDs.contains(account.id),
                        onSignIn: { signIn = SignInRequest(kind: account.kind, existing: account) }
                    ) { isEnabled in
                        account.isEnabled = isEnabled
                        // Its items leave the timeline and every count with it. Switching an
                        // account off and still seeing its posts in All Items reads as the switch
                        // not working.
                        _ = try? ThresholdService.setAccountEnabled(
                            isEnabled,
                            forAccountID: account.id,
                            in: modelContext
                        )
                        persist(account)
                    }
                    .contextMenu {
                        Button("Remove…", systemImage: "trash", role: .destructive) {
                            pendingRemoval = account
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Accounts")
                    Spacer()
                    Menu {
                        Button("FreshRSS…", systemImage: "server.rack") {
                            signIn = SignInRequest(kind: .freshRSS, existing: nil)
                        }
                        Button("Mastodon…", systemImage: "bubble.left.and.bubble.right") {
                            signIn = SignInRequest(kind: .mastodon, existing: nil)
                        }
                    } label: {
                        Label("Add Account", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } footer: {
                Text("ReadRead never writes to FreshRSS. Read state on the server is left exactly as it is.")
            }

            SyncEndpointSection()

            if !services.failures.isEmpty {
                Section("Last Refresh") {
                    ForEach(services.failures, id: \.self) { failure in
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
            }
        }
        // Re-asked on dismissal, because a sign-in changes the answer without changing the account
        // list: signing in to a record that is already listed leaves its id exactly where it was,
        // so nothing the `.task` below watches would have moved.
        .sheet(item: $signIn, onDismiss: { Task { await checkCredentials() } }) { request in
            switch request.kind {
            case .freshRSS: FreshRSSSignInView(reconnecting: request.existing)
            case .mastodon: MastodonSignInView(reconnecting: request.existing)
            }
        }
        // Keyed on the ids, so an account added or removed re-asks and an unrelated edit — a
        // display name, an enabled toggle — does not.
        .task(id: accounts.map(\.id)) {
            await checkCredentials()
        }
        .confirmationDialog(
            "Remove “\(pendingRemoval?.displayName ?? "")”?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { account in
            Button("Remove", role: .destructive) { remove(account) }
        } message: { _ in
            // Says that it travels. The account list syncs, so removing an account here removes it
            // from the other devices too — and the old wording ("Nothing on the server changes",
            // meaning the FreshRSS or Mastodon server) read as a promise that nothing left this
            // device at all.
            Text("Its cached items and saved credentials are deleted, here and on your other devices. Nothing on the FreshRSS or Mastodon server changes.")
        }
        .formStyle(.grouped)
        .navigationTitle("Accounts")
    }

    /// Asks the Keychain which accounts this device can actually sign in as.
    private func checkCredentials() async {
        signedInAccountIDs = await AccountConnections()
            .signedInAccountIDs(among: accounts.map { (id: $0.id, kind: $0.kind) })
        hasCheckedCredentials = true
    }

    private func persist(_ account: AccountRecord) {
        try? SyncOutbox.record(account, in: modelContext)
        try? modelContext.save()
        Task { await services.accountsChanged() }
    }

    /// Deletes the account, its credentials, and everything ingested under it.
    ///
    /// The cached items go too. Leaving them would strand rows in the timeline belonging to a
    /// server the app can no longer reach, which can never be refreshed and cannot be opened.
    private func remove(_ account: AccountRecord) {
        let id = account.id

        // Detached: this reaches the Keychain, which can block behind a SecurityAgent prompt, and
        // the confirmation dialog dismissing is not worth freezing the window over.
        Task.detached(priority: .userInitiated) {
            try? AccountConnections().forgetCredentials(forAccountID: id)
        }
        try? modelContext.delete(model: CachedItem.self, where: #Predicate { $0.accountID == id })
        try? modelContext.delete(model: CachedSource.self, where: #Predicate { $0.accountID == id })
        try? modelContext.delete(model: SyncCursor.self, where: #Predicate { $0.accountID == id })

        // Queued while the record is still here to describe, and committed by the same save as the
        // deletion. It names the account rather than only its id, because the other devices hold it
        // under ids of their own — see `SyncOutbox.recordAccountDeletion(_:in:)`.
        try? SyncOutbox.recordAccountDeletion(account, in: modelContext)
        modelContext.delete(account)
        try? modelContext.save()

        pendingRemoval = nil
        Task { await services.accountsChanged() }
    }
}

// MARK: - Rows

private struct AccountRow: View {

    @Bindable var account: AccountRecord

    /// Whether this device holds the account's credential.
    ///
    /// The row says so, and offers the way out. An account arriving from another device carries no
    /// password or token — that split is what makes the account list safe to sync at all — so on a
    /// second Mac every synced account is signed out, and until this row said so the only sign of
    /// it was an empty timeline and a line in the last-refresh report that pointed at a button
    /// ("Add Account") which does not sound like the answer to "sign in again".
    ///
    /// It answers whether a credential *exists*, not whether it still works — which is exactly why
    /// the button below is offered either way. See ``signInTitle``.
    let isSignedIn: Bool

    let onSignIn: () -> Void
    let onEnabledChanged: (Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: account.kind == .mastodon ? "bubble.left.and.bubble.right" : "server.rack")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !isSignedIn {
                    Label("Not signed in on this device", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button(signInTitle, action: onSignIn)
                .controlSize(.small)
                .help(signInHelp)

            Toggle("Enabled", isOn: $account.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: account.isEnabled) { onEnabledChanged(account.isEnabled) }
        }
        .padding(.vertical, 2)
    }

    /// What the button says, which is the whole of this change.
    ///
    /// It used to appear only when the account had no credential, on the reasoning that an account
    /// already signed in has nothing to sign in *for*. That is wrong in the two cases where it
    /// matters, and both of them leave a working-looking row that cannot do its job:
    ///
    /// - **A Mastodon token cannot widen.** Its scopes are fixed at the moment it was granted, so an
    ///   account authorised before the app asked to be allowed to like, boost, reply or mute keeps
    ///   a token that cannot, and every such write comes back 403. Signing in again is the only
    ///   thing that replaces it — see `MastodonSignInView.signIn()`, which renews in place.
    /// - **A FreshRSS API password can change on the server.** The Keychain item is still there and
    ///   is still wrong.
    ///
    /// Neither shows as "not signed in", because a credential does exist. Without this button the
    /// only route was to remove the account and add it again — which deletes its cached items, its
    /// cursors and, because the account list syncs, the account on every other device with it.
    ///
    /// Typed as `LocalizedStringKey` explicitly. A branch over string literals in a `Text` position
    /// yields a `String`, takes the verbatim overload, and ships English with no warning — the same
    /// trap `MastodonSignInView.title` records.
    private var signInTitle: LocalizedStringKey {
        guard isSignedIn else { return "Sign In" }
        // Different words because they are different acts: one grants permissions, the other
        // replaces a password.
        return account.kind == .mastodon ? "Reauthorise…" : "Sign In Again…"
    }

    /// Says what pressing it costs, which is the question anyone hesitating over it is asking.
    ///
    /// macOS only in practice — `help` is a tooltip there and nothing on iOS — which is acceptable
    /// because the answer is "nothing is lost" and the button is safe to try.
    private var signInHelp: LocalizedStringKey {
        account.kind == .mastodon
            ? "Sign in to this account again to grant permissions added since it was last authorised. Its reading position, saved items and cached posts are kept."
            : "Sign in to this server again to replace the stored API password. Its reading position, saved items and cached articles are kept."
    }

    private var subtitle: String {
        let host = account.serverURL?.host() ?? account.serverURLString
        return account.username.isEmpty ? host : "\(account.username) · \(host)"
    }
}

// MARK: - Sync endpoint

/// The position-sync service: an address and a bearer token.
private struct SyncEndpointSection: View {

    @Environment(AppServices.self) private var services

    @State private var settings = SyncEndpointSettings()
    @State private var token = ""
    @State private var hasStoredToken = false
    @State private var status: EndpointStatus = .idle

    /// The single sync-state row, for the clock it recorded. A `@Query` rather than a fetch so the
    /// line appears when a run measures one, without this screen having to be reopened.
    @Query private var syncStates: [SyncState]

    /// What to say about this device's clock, if anything.
    private var clockWarning: String? {
        guard let skew = syncStates.first?.clockSkewSeconds else { return nil }
        return ClockSkew.warning(for: skew)
    }

    private enum EndpointStatus: Equatable {
        case idle
        case checking
        case reachable(String)
        case failed(String)
    }

    var body: some View {
        Section {
            Toggle("Sync reading position", isOn: $settings.isEnabled)
                .onChange(of: settings.isEnabled) { save() }

            TextField("Server", text: $settings.urlString, prompt: Text("https://rss.example.com/readread"))
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif
                .onSubmit { save() }

            // A `SecureField` rather than a plain one: this is a bearer token that grants full
            // access to the endpoint, and it should no more be shoulder-surfable than a password.
            SecureField("Token", text: $token, prompt: hasStoredToken ? Text(verbatim: "••••••••") : Text("Paste the token"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }

            HStack {
                Button("Save and Test") { save(thenTest: true) }
                    .disabled(settings.url == nil)

                if hasStoredToken {
                    Button("Forget Token", role: .destructive) { forgetToken() }
                }

                Spacer()
                statusView
            }

            // Only when there is something wrong to say. A clock that agrees with the server is
            // the ordinary case and needs no line of its own — this is here so that the one fault
            // the app cannot correct has somewhere to show up. See `ClockSkew`.
            if let warning = clockWarning {
                Label {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Position Sync")
        } footer: {
            // Says exactly what crosses the wire. This endpoint is self-hosted, and the reason it
            // can be is that it never needs a feed credential.
            Text("Carries reading positions, Read Later, filters and the account list. Feed passwords and access tokens never leave this device.")
        }
        .task {
            settings = services.endpoint.loadSettings()
            // Awaited, so the Keychain read happens off the main actor. A `.task` closure on a
            // `View` is `@MainActor`, and the synchronous read here froze the whole app behind a
            // SecurityAgent prompt the user could not even see.
            hasStoredToken = await services.endpoint.hasToken()
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().controlSize(.small)
        case .reachable(let detail):
            Label(detail, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let detail):
            Label(detail, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func save(thenTest: Bool = false) {
        services.endpoint.saveSettings(settings)

        // Everything that touches the Keychain runs inside this task, so a write that stops behind
        // a SecurityAgent prompt leaves the window responsive instead of freezing it.
        Task {
            if !token.isEmpty {
                do {
                    try await services.endpoint.setToken(token)
                } catch {
                    // Reported, not swallowed. A token that silently failed to store leaves the
                    // pane saying "no token saved yet" with no hint as to why — exactly the state
                    // this was found in when the Keychain backend changed underneath it.
                    status = .failed(String(localized: "The token could not be saved: \(String(describing: error))."))
                    return
                }
                // Cleared from view state the moment it is in the Keychain, so it is not sitting
                // in a SwiftUI value for the lifetime of the window.
                token = ""
                hasStoredToken = await services.endpoint.hasToken()
            }

            await services.syncEndpointChanged()
            if thenTest { await test() }
        }
    }

    private func test() async {
        guard let configuration = await services.endpoint.configuration() else {
            status = .failed(hasStoredToken ? String(localized: "Check the address.") : String(localized: "No token saved yet."))
            return
        }

        status = .checking
        let client = SyncClient(configuration: configuration)
        do {
            let health = try await client.health()
            guard health.ok else {
                status = .failed(String(localized: "The server answered, but reports it is not healthy."))
                return
            }
            status = .reachable(String(localized: "Reachable · \(health.service ?? "sync") \(health.version ?? "")"))
        } catch SyncError.unauthorized {
            // Worth separating: a rejected token and an unreachable host look identical from the
            // outside, and they have completely different fixes.
            status = .failed(String(localized: "The server rejected that token."))
        } catch {
            // The error's own text is not shown: a client error can carry the request URL, and this
            // one's headers carry the bearer token.
            status = .failed(String(localized: "Could not reach the server."))
        }
    }

    private func forgetToken() {
        hasStoredToken = false
        status = .idle
        Task {
            try? await services.endpoint.removeToken()
            await services.syncEndpointChanged()
        }
    }
}
