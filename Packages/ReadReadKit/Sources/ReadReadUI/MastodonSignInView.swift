import AuthenticationServices
import MastodonAPI
import ReadReadModel
import ReadReadSupport
import ReadReadSync
import SwiftData
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Signing in to a Mastodon instance.
///
/// One field, because everything else happens in the instance's own browser sheet — which is the
/// point of OAuth here: ReadRead never sees the password, and the token it does get is narrowed to
/// the scopes in `MastodonOAuth.scopes` — everything the app reads, plus favouriting and boosting.
/// It cannot follow, block or delete, and while `write:statuses` is the only scope Mastodon offers
/// for boosting and therefore also permits posting, nothing in the app posts.
struct MastodonSignInView: View {

    /// The account this sheet is signing in to again, or `nil` when adding a new one.
    ///
    /// An account that arrived by sync has no token here — credentials never leave the device that
    /// holds them — so a second Mac shows it signed out with no obvious way in. Passing the record
    /// makes the way in explicit, and makes it land on *that* record: its id is embedded in every
    /// item, source and reading position already stored under it, so signing in must renew it
    /// rather than mint a second account beside it.
    var reconnecting: AccountRecord?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    /// The accounts already added, which this flow has to consult twice.
    ///
    /// Once before opening the browser, to decide whether the instance must be told to ask who is
    /// signing in, and once after, to refuse an account that is already here. Both are questions
    /// only the store can answer, which is why they are asked in the view rather than inside
    /// `MastodonSignIn`.
    @Query private var accounts: [AccountRecord]

    @State private var instanceInput = ""
    @State private var isAuthorizing = false
    @State private var errorMessage: String?

    /// Held so the sheet can be cancelled if the view goes away mid-flow, rather than leaving an
    /// orphaned browser window with nothing listening for its callback.
    @State private var session: MastodonAuthorizationSession?

    var body: some View {
        SignInSheet(
            title: title,
            isBusy: isAuthorizing,
            canSubmit: !instanceInput.trimmingCharacters(in: .whitespaces).isEmpty,
            submitTitle: "Continue",
            error: errorMessage,
            onCancel: {
                session?.cancel()
                dismiss()
            },
            onSubmit: { Task { await signIn() } }
        ) {
            Section {
                TextField("Instance", text: $instanceInput, prompt: Text("mastodon.social"))
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
            } header: {
                Text("Instance")
            } footer: {
                Text("Your server's address. You can type it as `mastodon.social`, `@you@mastodon.social`, or a full URL.")
            }

            Section {
                // Reworded when Like and Boost shipped, because the old sentence — "asks only for
                // read access … cannot post, boost or follow" — became false the moment the app
                // asked for `write:` scopes. The awkward half is stated rather than glossed: there
                // is no scope for boosting alone, so the grant genuinely permits posting, and a
                // consent screen that undersells what it is granting is worse than a wordy one.
                Label("ReadRead reads your home timeline and your account, and can favourite and boost. Mastodon grants boosting and posting together, so the permission is wider than the app: ReadRead never posts, follows or blocks.", systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { session?.cancel() }
        .task {
            // Prefilled rather than asked for again: the instance is already known, and making
            // someone retype the address of an account the app is showing them is busywork.
            guard let reconnecting, instanceInput.isEmpty else { return }
            instanceInput = reconnecting.serverURL?.host() ?? reconnecting.serverURLString
        }
    }

    /// Typed explicitly, so both branches are `LocalizedStringKey` literals. A ternary that
    /// produces a `String` takes the verbatim overload and ships English with no warning.
    private var title: LocalizedStringKey {
        reconnecting == nil ? "Add Mastodon" : "Sign In"
    }

    private func signIn() async {
        isAuthorizing = true
        errorMessage = nil
        defer {
            isAuthorizing = false
            session = nil
        }

        let session = MastodonAuthorizationSession { Self.presentationAnchor() }
        self.session = session

        let result: MastodonSignIn.Result
        do {
            result = try await MastodonSignIn().signIn(
                instanceInput: instanceInput,
                session: session,
                isAddingAnotherAccount: isAddingAnotherAccount
            )
        } catch {
            // Nil means the user cancelled, which is a decision rather than a failure — the sheet
            // simply closes.
            guard let message = Self.describe(error) else {
                dismiss()
                return
            }
            errorMessage = message
            return
        }

        // Checked here rather than trusted to the browser step, and it is not belt and braces:
        // `force_login` only makes the instance *ask*, and one perfectly reasonable answer is to
        // sign in as the account you were already signed in as. Two records for one account then
        // refresh the same timeline twice and count it twice in the sidebar.
        let identity = AccountIdentity(
            kindRaw: AccountKind.mastodon.rawValue,
            serverURLString: result.instanceURL.absoluteString,
            username: result.account.username
        )
        // The instance's own name for the user, not what they typed: `@me@host` and `me` are the
        // same account, and the sidebar should say which one it actually signed in as. Built once
        // so a new record and a renewed one cannot disagree about it.
        let displayName = "@\(result.account.username)@\(result.instanceURL.host() ?? "mastodon")"

        // Signing in *to a row* has a destination, and it is the only case where the app can tell
        // the reader they landed somewhere else. Which account the instance hands back is decided
        // in its browser sheet, not here — a live session, a second account on the same instance,
        // a wrong tab — so a mismatch is entirely possible, and quietly adding the account they
        // did not ask for would leave the one they pressed still signed out and a stranger beside
        // it. Reported and nothing written; adding that account is what the Add Account menu is
        // for.
        if let reconnecting, AccountIdentity(reconnecting) != identity {
            errorMessage = String(
                localized: "Signed in as \(displayName), but this account is \(reconnecting.displayName). Nothing was changed."
            )
            return
        }

        // An account already here is renewed rather than refused, and that is load-bearing rather
        // than generous. Signing in again is the *only* way an account's granted scopes can widen,
        // so refusing here would leave a reader who signed in before this app asked for write
        // scopes with no route at all to a token that can favourite and boost. It also keeps the
        // account's id, and with it every reading position, cached item and sync record already
        // attached to it.
        //
        // It is reached both ways: from the accounts pane's Sign In button, which arrives with
        // `reconnecting` set and has already checked it landed on the right account, and from Add
        // Account, where an account the reader did not realise was already listed ends up here
        // instead of becoming a second copy of itself.
        if let existing = AccountIdentity.account(matching: identity, in: accounts) {
            await renew(existing, with: result, displayName: displayName)
            return
        }

        let account = AccountRecord(
            kind: .mastodon,
            displayName: displayName,
            serverURLString: result.instanceURL.absoluteString,
            username: result.account.username
        )

        do {
            // Stored before the row exists so an account is never left without its token — the
            // same ordering as the FreshRSS flow, and for the same reason.
            try await MastodonSignIn().persistToken(result.accessToken, accountID: account.id)
        } catch {
            errorMessage = String(localized: "The access token could not be saved to the Keychain.")
            return
        }

        modelContext.insert(account)
        try? SyncOutbox.record(account, in: modelContext)
        try? modelContext.save()

        dismiss()
        Task { await services.accountsChanged() }
    }

    /// Replaces an existing account's token with a freshly granted one.
    ///
    /// The record is kept and only its credential changes. The display name is refreshed with it,
    /// since the instance is the authority on what the account is called and it may have changed
    /// since the account was added.
    ///
    /// Not reported as anything on success. The reader asked to sign in to an account and is now
    /// signed in to it, which is what the sheet closing says — and the case where they *meant* to
    /// add a second account is now one they cannot reach by accident, because the instance is made
    /// to show its login form when there is already an account on it.
    private func renew(
        _ account: AccountRecord,
        with result: MastodonSignIn.Result,
        displayName: String
    ) async {
        do {
            try await MastodonSignIn().persistToken(result.accessToken, accountID: account.id)
        } catch {
            errorMessage = String(localized: "The access token could not be saved to the Keychain.")
            return
        }

        account.displayName = displayName
        account.serverURLString = result.instanceURL.absoluteString
        account.username = result.account.username
        try? SyncOutbox.record(account, in: modelContext)
        try? modelContext.save()

        dismiss()
        Task { await services.accountsChanged() }
    }

    /// Whether the app already has an account on the instance being typed.
    ///
    /// Read from what the reader has typed *so far*, which is sound because it is only consulted
    /// at the moment sign-in starts — the same string the flow is about to normalise into a host.
    /// A nonsense address yields no host and answers false, and the flow then fails on the address
    /// itself, which is the better error to show.
    ///
    /// The account being signed in to again does not count itself. Forcing the login form is not
    /// free — `force_login` signs the reader's own web session out on the way past — and when the
    /// only account on the instance is the one being reconnected, whoever the browser is already
    /// logged in as is almost certainly them. It still forces when a *second* account shares the
    /// instance, because then the live session genuinely could be the wrong one; and if it is wrong
    /// anyway, the identity check above catches it rather than writing the token somewhere odd.
    private var isAddingAnotherAccount: Bool {
        guard let instanceURL = MastodonClient.normalisedInstanceURL(from: instanceInput) else {
            return false
        }
        return AccountIdentity.hasAccount(
            kindRaw: AccountKind.mastodon.rawValue,
            onSameServerAs: AccountIdentity(
                kindRaw: AccountKind.mastodon.rawValue,
                serverURLString: instanceURL.absoluteString,
                // Not known yet, and not part of the question. See `hasAccount`.
                username: ""
            ),
            in: accounts.filter { $0.id != reconnecting?.id }
        )
    }

    /// The window the authorisation sheet hangs off, or `nil` if the app has none to offer.
    ///
    /// Optional because on iOS there is no longer a way to invent one: every `UIWindow`
    /// initialiser that does not take a `UIWindowScene` is deprecated as of iOS 26, and a window
    /// with no scene could not have presented the sheet anyway. With no scene there is genuinely
    /// nothing to anchor to, and saying so lets the caller fail with a message rather than hand
    /// AuthenticationServices a window that will never appear.
    @MainActor
    private static func presentationAnchor() -> ASPresentationAnchor? {
        #if os(macOS)
        NSApp.keyWindow ?? NSApp.windows.first
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        // The foreground-active scene first: on iPad and in Stage Manager several are connected at
        // once, and the sheet belongs to the one the user is looking at.
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first else {
            return nil
        }
        return scene.keyWindow ?? scene.windows.first ?? ASPresentationAnchor(windowScene: scene)
        #endif
    }

    /// Turns a sign-in failure into something actionable.
    ///
    /// A cancelled sheet is not an error: the user closing the browser window is a decision, and
    /// showing them a red banner for it is just noise.
    static func describe(_ error: any Error) -> String? {
        if let authError = error as? ASWebAuthenticationSessionError,
           authError.code == .canceledLogin {
            return nil
        }

        guard let mastodonError = error as? MastodonError else {
            return String(localized: "Could not reach that instance. Check the address and your connection.")
        }

        switch mastodonError {
        case .invalidInstanceURL:
            return String(localized: "That does not look like an instance address.")
        case .tokenRevoked:
            return String(localized: "The instance rejected the new token straight away. Try signing in again.")
        case .authorizationFailed:
            // Covers a mismatched `state` as well as a missing code — the former is what a
            // hijacked callback looks like, so it is worth not glossing over.
            return String(localized: "The authorisation did not complete. Start again, and finish in the window that opens.")
        case .unexpectedResponse:
            return String(localized: "That address answered, but not like a Mastodon instance.")
        case .writeNotAuthorized, .statusNotFound:
            // Neither can arise from signing in — they belong to liking and boosting, which
            // happens long after this screen is gone. Answered generically rather than left to a
            // `default`, so that adding a case to `MastodonError` keeps failing the build here
            // until somebody has decided what this screen should say about it.
            return String(localized: "Could not reach that instance. Check the address and your connection.")
        }
    }
}
