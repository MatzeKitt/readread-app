import ReadReadModel
import ReadReadSync
import SwiftData
import SwiftUI

/// Following the replies to a Mastodon post, or changing what is followed.
///
/// One sheet for three ways in — a link typed into a new subscription, a post in the reading pane,
/// and a subscription being edited from the sidebar — because they ask the same two questions:
/// which post, and what to call it.
struct ReplySubscriptionSheet: View {

    let draft: StatusComposer.SubscriptionDraft

    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Queried here rather than passed in: this sheet exists once, when a reader asks for it.
    @Query(sort: \AccountRecord.displayName) private var accounts: [AccountRecord]

    @State private var accountID: UUID?
    @State private var urlString = ""
    @State private var title = ""
    @State private var isSaving = false
    @State private var failure: String?

    /// Set once, when the sheet opens, so a redraw does not put back what has been typed over.
    @State private var hasPrepared = false

    var body: some View {
        NavigationStack {
            Form {
                if candidates.count > 1, draft.target == nil || draft.editing != nil {
                    Section {
                        Picker("Account", selection: $accountID) {
                            ForEach(candidates, id: \.id) { account in
                                Text(account.displayName).tag(Optional(account.id))
                            }
                        }
                    } footer: {
                        // Worth saying, because it decides which replies arrive at all: an instance
                        // only knows the replies that have reached it.
                        Text("The replies are fetched from this account's server.")
                    }
                }

                Section {
                    TextField("Link to the post", text: $urlString)
                        .textContentType(.URL)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()

                    TextField("Title", text: $title)
                } footer: {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Replies to the post appear in the timeline and under this title in the sidebar.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.editing == nil ? Text("Subscribe to Replies") : Text("Edit Subscription"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else if draft.editing == nil {
                        Button("Subscribe") { save() }
                            .disabled(!canSave)
                    } else {
                        Button("Save") { save() }
                            .disabled(!canSave)
                    }
                }
            }
        }
        // Wide enough for a link to be read on the Mac, where a sheet has no size of its own; on
        // iPhone the frame is ignored and the sheet is the screen.
        .frame(minWidth: 420, minHeight: 260)
        .task {
            guard !hasPrepared else { return }
            hasPrepared = true
            accountID = draft.accountID ?? candidates.first?.id
            urlString = draft.urlString
            title = draft.title
        }
        .onChange(of: urlString) { failure = nil }
        .onChange(of: accountID) { failure = nil }
    }

    // MARK: - State

    /// The Mastodon accounts that could follow the post.
    private var candidates: [AccountRecord] {
        accounts.filter { $0.kind == .mastodon && $0.isEnabled }
    }

    private var chosenAccount: AccountRecord? {
        candidates.first { $0.id == accountID } ?? candidates.first
    }

    private var canSave: Bool {
        !isSaving
            && chosenAccount != nil
            && !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The post already known for what is in the fields, so it need not be looked up again.
    ///
    /// Only while the link and the account are what the draft started with: either one changing
    /// means the post has to be found again, as the account that is to follow it knows it.
    private var knownTarget: ReplySubscriptionEditing.Target? {
        guard
            let target = draft.target,
            target.accountID == chosenAccount?.id,
            urlString.trimmingCharacters(in: .whitespacesAndNewlines) == draft.urlString
        else { return nil }
        return target
    }

    // MARK: - Saving

    private func save() {
        guard let account = chosenAccount else { return }
        isSaving = true
        failure = nil

        Task {
            let target: ReplySubscriptionEditing.Target
            if let knownTarget {
                target = knownTarget
            } else {
                switch await services.resolveReplyTarget(urlString, accountID: account.id) {
                case .resolved(let resolved):
                    target = resolved
                case .failed(let message):
                    failure = message
                    isSaving = false
                    return
                }
            }

            do {
                try write(target: target)
                try modelContext.save()
            } catch {
                modelContext.rollback()
                failure = String(localized: "The subscription could not be saved.")
                isSaving = false
                return
            }

            services.replySubscriptionsChanged()
            isSaving = false
            dismiss()
        }
    }

    private func write(target: ReplySubscriptionEditing.Target) throws {
        // A subscription with no name is shown by its link, which is unreadable in a sidebar.
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? target.statusURLString
            : title

        if let editing = draft.editing {
            try ReplySubscriptionEditing.update(editing, title: name, target: target, in: modelContext)
        } else {
            try ReplySubscriptionEditing.subscribe(to: target, title: name, in: modelContext)
        }
    }
}
