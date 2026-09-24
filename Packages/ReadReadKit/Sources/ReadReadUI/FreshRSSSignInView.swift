import FreshRSSAPI
import ReadReadModel
import ReadReadSupport
import ReadReadSync
import SwiftData
import SwiftUI

/// Signing in to a FreshRSS server.
///
/// Verifies before saving anything. A stored account that has never successfully authenticated is
/// worse than no account: it looks configured, refreshes silently fail, and the timeline just
/// stays empty with nothing to point at.
struct FreshRSSSignInView: View {

    /// The account this sheet is signing in to again, or `nil` when adding a new one.
    ///
    /// An account that arrived by sync has no password here — credentials never leave the device
    /// that holds them — so it is listed and signed out. Signing in has to renew *that* record:
    /// its id is embedded in every source, item and reading position stored under it, and a second
    /// record for the same server would re-download the lot under new ids and leave the positions
    /// pointing at rows nothing references.
    var reconnecting: AccountRecord?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    /// Consulted so a server already in the list is renewed rather than duplicated — the same check
    /// the Mastodon flow makes. See `signIn()`.
    @Query private var accounts: [AccountRecord]

    @State private var serverURLString = ""
    @State private var username = ""
    @State private var apiPassword = ""
    @State private var displayName = ""

    @State private var isVerifying = false
    @State private var errorMessage: String?

    private var isComplete: Bool {
        normalisedURL != nil && !username.isEmpty && !apiPassword.isEmpty
    }

    /// The server URL, with a scheme filled in if the user typed a bare host.
    ///
    /// Defaults to `https`. A LAN-hosted FreshRSS over plain http still works — the app's ATS
    /// exception allows it for local hosts — but it has to be typed explicitly, so an API password
    /// is never put on the wire in clear text by a guess.
    private var normalisedURL: URL? {
        let trimmed = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.host() != nil else { return nil }
        return url
    }

    var body: some View {
        SignInSheet(
            title: title,
            isBusy: isVerifying,
            canSubmit: isComplete,
            submitTitle: "Sign In",
            error: errorMessage,
            onCancel: { dismiss() },
            onSubmit: { Task { await signIn() } }
        ) {
            Section {
                TextField("Server", text: $serverURLString, prompt: Text("https://rss.example.com"))
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif

                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif

                SecureField("API password", text: $apiPassword)
                    .textFieldStyle(.roundedBorder)
            } header: {
                Text("Server")
            } footer: {
                // The single most common FreshRSS setup mistake, and it produces a bare 401 that
                // says nothing about the real cause.
                Text("This is the separate **API password** from FreshRSS's Profile settings, not your login password.")
            }

            Section("Name") {
                TextField("Name", text: $displayName, prompt: normalisedURL?.host().map { Text($0) } ?? Text("Optional"))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .task {
            // Everything but the password, which is the only thing this device is missing. The
            // fields stay editable: a server that has moved is signed in to again from exactly
            // here, and the record follows the address rather than being stranded at the old one.
            guard let reconnecting, serverURLString.isEmpty else { return }
            serverURLString = reconnecting.serverURLString
            username = reconnecting.username
            displayName = reconnecting.displayName
        }
    }

    /// Typed explicitly, so both branches are `LocalizedStringKey` literals rather than a `String`
    /// that would take `SignInSheet`'s verbatim path and escape translation.
    private var title: LocalizedStringKey {
        reconnecting == nil ? "Add FreshRSS" : "Sign In"
    }

    private func signIn() async {
        guard let url = normalisedURL else { return }

        isVerifying = true
        errorMessage = nil
        defer { isVerifying = false }

        let client = GReaderClient(
            baseURL: url,
            credentials: .init(username: username, apiPassword: apiPassword)
        )

        do {
            // `authenticate` is the ClientLogin call. Doing it here means a wrong password is
            // reported against the field that caused it rather than as a silent refresh failure
            // an hour later.
            _ = try await client.authenticate()
            _ = try await client.userInfo()
        } catch {
            errorMessage = Self.describe(error)
            return
        }

        let name = displayName.isEmpty ? (url.host() ?? "FreshRSS") : displayName

        // Which record this password belongs to, and the answer is not always "a new one".
        //
        // The row it was started from, if it was started from one. Otherwise any account already
        // listed for the same server and user — which is the normal case on a second device, where
        // the account list has synced and only the credential is missing. Minting a second record
        // there would have been a quiet disaster of exactly the kind this app keeps finding:
        // account ids are embedded in every source, item and `source:` scope, so the duplicate
        // re-downloads the whole server under new ids and every reading position stays attached to
        // the copy that is about to be deduplicated away. The Mastodon flow has always renewed in
        // place; this one did not, and that asymmetry was the bug.
        let identity = AccountIdentity(
            kindRaw: AccountKind.freshRSS.rawValue,
            serverURLString: url.absoluteString,
            username: username
        )
        let existing = reconnecting ?? AccountIdentity.account(matching: identity, in: accounts)

        let account = existing ?? AccountRecord(
            // Derived from the identity rather than minted, so this device and every other one
            // name the account — and therefore its feeds, its items and its scopes — identically.
            // See `AccountIdentity.accountID`.
            id: identity.accountID,
            kind: .freshRSS,
            displayName: name,
            serverURLString: url.absoluteString,
            username: username
        )

        do {
            // Keychain first: an account row whose password failed to store would be a permanently
            // broken account, whereas an orphaned Keychain item is harmless and overwritten on the
            // next attempt.
            // Detached, so the write happens off the main actor: against the legacy login
            // keychain this can stop dead behind a SecurityAgent prompt, and on the main actor
            // that freezes the sheet the prompt is sitting on top of.
            let password = apiPassword
            let key = account.id.uuidString
            try await Task.detached(priority: .userInitiated) {
                try KeychainStore().setString(password, for: .freshRSSAPIPassword, key: key)
            }.value
        } catch {
            errorMessage = String(localized: "The password could not be saved to the Keychain.")
            return
        }

        if let existing {
            // Refreshed from what was just verified, since the address or the display name may be
            // why the reader came back here. The id is untouched, which is the whole point.
            existing.displayName = name
            existing.serverURLString = url.absoluteString
            existing.username = username
        } else {
            modelContext.insert(account)
        }

        try? SyncOutbox.record(account, in: modelContext)
        try? modelContext.save()

        dismiss()
        Task { await services.accountsChanged() }
    }

    /// Turns a client error into something worth reading.
    ///
    /// Deliberately does not include the error's own description: a `GReaderError` can carry the
    /// request, and a Google Reader request carries the auth token.
    static func describe(_ error: any Error) -> String {
        // A reachable server that answered 404 is the commonest setup mistake — an address pointing
        // at the FreshRSS *page* rather than its root, or at something else entirely. Saying "check
        // your connection" there sends people to look at their network, which is fine.
        if let httpError = error as? HTTPError {
            if case .status(let code, _) = httpError {
                switch code {
                case 401, 403:
                    return String(localized: "The server rejected that username or API password. The API password is set separately, in FreshRSS's own profile settings.")
                case 404:
                    return String(localized: "That address answered, but has no FreshRSS API at it. Give the address of the FreshRSS site itself, without any path.")
                default:
                    return String(localized: "The server answered with an error (\(code)). Check the address points at FreshRSS.")
                }
            }
        }

        guard let readerError = error as? GReaderError else {
            return String(localized: "Could not reach the server. Check the address and your connection.")
        }

        switch readerError {
        case .invalidCredentials:
            // Names the API password specifically: it is the setting people miss, and the server's
            // own answer is a bare 401 that says nothing about which password it wanted.
            return String(localized: "The server rejected that username or API password. The API password is set separately, in FreshRSS's own profile settings.")
        case .malformedLoginResponse:
            return String(localized: "That address answered, but not like FreshRSS. Check it points at the site root.")
        case .invalidServerURL:
            return String(localized: "That address could not be used. Check it for typos.")
        case .unexpectedResponse:
            return String(localized: "The server responded with something unexpected. Check the address points at FreshRSS.")
        }
    }
}

/// Shared chrome for the two sign-in sheets.
///
/// Both are a short form, a busy state and one error line; giving them a common container keeps the
/// two flows visually identical, which matters because the difference between them is already
/// confusing enough (one is a password, the other opens a browser).
struct SignInSheet<Content: View>: View {

    let title: LocalizedStringKey
    let isBusy: Bool
    let canSubmit: Bool
    let submitTitle: LocalizedStringKey
    let error: String?
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            Form {
                content

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isBusy)

            HStack {
                if isBusy {
                    ProgressView().controlSize(.small)
                    Text("Checking…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Button(submitTitle, action: onSubmit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit || isBusy)
            }
            .padding(20)
        }
        #if os(macOS)
        .frame(width: 460, height: 460)
        #endif
    }
}
