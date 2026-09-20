import MastodonAPI
import ReadReadModel
import ReadReadSync
import SwiftData
import SwiftUI

/// Writing a reply to a Mastodon post.
///
/// Presented from the shell rather than from the row the reader clicked — see ``StatusComposer`` —
/// so a refresh arriving mid-sentence cannot take the half-written reply away with the row it was
/// started from.
struct ReplyComposerSheet: View {

    let draft: StatusComposer.ReplyDraft

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    /// Every account that could post. Queried here rather than passed in: this view exists once,
    /// when a reader chooses to answer something, so a fetch costs nothing — unlike the same query
    /// inside a row, which is why `StatusActionMenu` takes its accounts as a parameter.
    @Query(sort: \AccountRecord.displayName) private var accounts: [AccountRecord]

    @State private var actingAccountID: UUID?
    @State private var text = ""
    @State private var spoilerText = ""
    @State private var showsContentWarning = false
    @State private var visibility: MastodonVisibility = .private
    @State private var isSending = false

    /// Set once, when the composer opens, so switching accounts does not wipe what has been typed.
    @State private var hasPrepared = false

    var body: some View {
        NavigationStack {
            Form {
                inReplyTo

                if candidates.count > 1 {
                    Section {
                        Picker("Reply as", selection: $actingAccountID) {
                            ForEach(candidates, id: \.id) { account in
                                Text(account.displayName).tag(Optional(account.id))
                            }
                        }
                    } footer: {
                        // Worth saying, because the consequence is invisible until afterwards: a
                        // reply from another account is posted by that account, in its own name, on
                        // its own instance.
                        Text("The reply is posted by this account, on its own server.")
                    }
                }

                Section {
                    if showsContentWarning {
                        TextField("Content warning", text: $spoilerText)
                    }

                    // `axis: .vertical` rather than a `TextEditor`: inside a `Form` a `TextEditor`
                    // brings its own scroll view and its own inset, which reads as a box dropped
                    // into the sheet. A vertical field grows with the text and is still a field.
                    TextField("Write a reply…", text: $text, axis: .vertical)
                        .lineLimit(6...16)
                } footer: {
                    footer
                }

                Section {
                    Picker("Visibility", selection: $visibility) {
                        ForEach(allowedVisibilities, id: \.self) { option in
                            Text(Self.name(of: option)).tag(option)
                        }
                    }
                } footer: {
                    // Only when there is something to explain. A reply to a public post can be
                    // anything, and saying so would be noise on the common case.
                    if allowedVisibilities.count < MastodonVisibility.allCases.count {
                        Text("A reply cannot be seen by more people than the post it answers.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Reply")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reply") { send() }
                        .disabled(!canSend)
                }
            }
        }
        // Wide enough for a paragraph to look like one on the Mac, where a sheet has no size of its
        // own; on iPhone the frame is ignored and the sheet is the screen.
        .frame(minWidth: 420, minHeight: 360)
        .task {
            guard !hasPrepared else { return }
            hasPrepared = true
            actingAccountID = candidates.first?.id
            visibility = MastodonVisibility.defaultForReply(to: draft.parentVisibility)
            text = prefix(excluding: candidates.first)
            showsContentWarning = false
        }
        // Not on the account itself, because re-addressing the reply would have to rewrite text the
        // reader may have edited. Only the mentions at the very front are replaced, and only while
        // they are still exactly what was put there.
        .onChange(of: actingAccountID) { previous, _ in
            retarget(from: previous)
        }
    }

    // MARK: - Pieces

    /// The post being answered, so the reply is written with it in view.
    private var inReplyTo: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.authorName)
                    .font(.subheadline.weight(.semibold))
                Text(draft.excerpt)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        } header: {
            Text("In reply to")
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button(showsContentWarning ? "Remove Content Warning" : "Add Content Warning") {
                withAnimation {
                    showsContentWarning.toggle()
                    if !showsContentWarning { spoilerText = "" }
                }
            }
            .font(.footnote)

            Spacer()

            Text("\(remaining)")
                .monospacedDigit()
                // Only coloured once it is a problem. A counter that is always tinted is a counter
                // nobody reads by the time it matters.
                .foregroundStyle(remaining < 0 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .accessibilityLabel(
                    remaining < 0
                        ? Text("^[\(-remaining) character](inflect: true) over the limit")
                        : Text("^[\(remaining) character](inflect: true) left")
                )
        }
    }

    // MARK: - State

    /// The Mastodon accounts that could post this, the post's own first.
    private var candidates: [AccountRecord] {
        accounts
            .filter { $0.kind == .mastodon && $0.isEnabled }
            .sorted { left, right in
                let owner = draft.item.accountID
                if (left.id == owner) != (right.id == owner) { return left.id == owner }
                return left.displayName.localizedStandardCompare(right.displayName) == .orderedAscending
            }
    }

    private var actingAccount: AccountRecord? {
        candidates.first { $0.id == actingAccountID } ?? candidates.first
    }

    private var allowedVisibilities: [MastodonVisibility] {
        MastodonVisibility.allowedForReply(to: draft.parentVisibility)
    }

    /// How much room is left, by the instance's counting rules — see ``MastodonPostLength``.
    private var remaining: Int {
        MastodonPostLength.defaultLimit - MastodonPostLength.count(
            text: text,
            spoilerText: showsContentWarning ? spoilerText : ""
        )
    }

    /// Whether there is a reply to send.
    ///
    /// The length is deliberately **not** part of this. The counter is this app's arithmetic and
    /// the limit is the instance's, and they can legitimately disagree — an instance that allows
    /// more than 500 is common. Refusing to send would be this app enforcing a rule it only guessed
    /// at; the instance's own answer comes back as a plain sentence instead.
    private var canSend: Bool {
        !isSending
            && actingAccount != nil
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The mentions a reply opens with, minus the account doing the replying.
    ///
    /// Excluding yourself is not cosmetic: a reply that mentions its own author notifies them of
    /// their own post, and on some instances counts toward the conversation's participants.
    private func prefix(excluding account: AccountRecord?) -> String {
        let own = account.map { Self.handle(of: $0) }
        let handles = draft.mentions.filter { handle in
            guard let own else { return true }
            return handle.caseInsensitiveCompare(own) != .orderedSame
        }
        guard !handles.isEmpty else { return "" }
        return handles.map { "@\($0)" }.joined(separator: " ") + " "
    }

    /// Re-addresses the reply when the acting account changes, but only while it is untouched.
    ///
    /// The test is whether the text still *is* the prefix the previous account was given. Once a
    /// word has been typed the reader owns it, and silently rewriting the front of a sentence
    /// somebody is in the middle of writing is worse than leaving a stale mention in it.
    private func retarget(from previous: UUID?) {
        let old = prefix(excluding: candidates.first { $0.id == previous })
        guard text == old else { return }
        text = prefix(excluding: actingAccount)
    }

    /// `user@host`, as Mastodon writes it in `acct` for a remote account.
    ///
    /// Built from the record because that is all this app stores about its own accounts: the
    /// username it signed in with, and the instance it signed in to.
    static func handle(of account: AccountRecord) -> String {
        let host = account.serverURL?.host() ?? ""
        let username = AuthorMute.normalised(account.username)
        // A local account's own `acct` has no domain, but the mentions being matched against came
        // from a status on that same instance, where the author is written bare. Matching both
        // shapes is why this is compared case-insensitively rather than parsed.
        return host.isEmpty ? username : "\(username)@\(host)"
    }

    private static func name(of visibility: MastodonVisibility) -> LocalizedStringKey {
        switch visibility {
        case .public: "Public"
        case .unlisted: "Quiet public"
        case .private: "Followers only"
        case .direct: "Mentioned people only"
        }
    }

    private func send() {
        guard let account = actingAccount else { return }
        isSending = true

        let reply = StatusInteractions.Reply(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            spoilerText: showsContentWarning ? spoilerText : "",
            visibility: visibility,
            // The draft's, not a fresh one — see `StatusComposer.ReplyDraft.idempotencyKey`. A
            // reader who presses Reply, sees a timeout, and presses it again is sending the same
            // draft, and the instance is what makes sure that is one post rather than two.
            idempotencyKey: draft.idempotencyKey
        )

        Task {
            let failure = await services.reply(reply, to: draft.item, as: StatusInteractions.Actor(
                id: account.id,
                displayName: account.displayName,
                serverURLString: account.serverURLString
            ))
            isSending = false
            // Only on success. A failure is raised as an alert at the window, and dismissing the
            // sheet under it would throw away the text the reader would have to type again.
            if failure == nil { dismiss() }
        }
    }
}
