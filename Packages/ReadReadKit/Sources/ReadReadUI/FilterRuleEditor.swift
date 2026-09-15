import ReadReadModel
import SwiftData
import SwiftUI

/// A rule being edited.
///
/// A value type rather than the `FilterRule` model, so that cancelling really cancels. Editing the
/// model directly would apply every keystroke to the store, and a pattern is invalid for most of
/// the time it is being typed — the live preview would then be filtering the timeline against
/// half-finished input.
struct FilterDraft: Identifiable, Equatable {

    let id: UUID
    var name: String
    var pattern: String
    var fields: FilterFields
    var matchKind: FilterMatchKind
    var isCaseSensitive: Bool
    var scope: FilterScope
    var isEnabled: Bool

    /// Whether this draft came from an existing rule, which decides the sheet's title and whether
    /// there is anything to delete.
    let isExisting: Bool

    init() {
        id = UUID()
        name = ""
        pattern = ""
        fields = .titleAndContent
        matchKind = .contains
        isCaseSensitive = false
        scope = .everywhere
        isEnabled = true
        isExisting = false
    }

    init(_ rule: FilterRule) {
        id = rule.id
        name = rule.name
        pattern = rule.pattern
        fields = rule.fields
        matchKind = rule.matchKind
        isCaseSensitive = rule.isCaseSensitive
        scope = rule.scope
        isEnabled = rule.isEnabled
        isExisting = true
    }

    var isValid: Bool {
        !pattern.isEmpty && !fields.isEmpty
    }

    /// A throwaway `FilterRule` for compiling and previewing, never inserted into a context.
    ///
    /// Building the engine from the same type the store holds is what guarantees the preview and
    /// the real pass agree — a separate "preview matcher" is exactly how a preview ends up lying.
    func detachedRule() -> FilterRule {
        FilterRule(
            id: id,
            name: name,
            pattern: pattern,
            fields: fields,
            matchKind: matchKind,
            isCaseSensitive: isCaseSensitive,
            scope: scope,
            isEnabled: true
        )
    }

    static func describe(_ fields: FilterFields) -> String {
        var names: [String] = []
        if fields.contains(.title) { names.append(String(localized: "title")) }
        if fields.contains(.content) { names.append(String(localized: "text")) }
        if fields.contains(.author) { names.append(String(localized: "author")) }
        if fields.contains(.sourceTitle) { names.append(String(localized: "source")) }
        return names.isEmpty ? String(localized: "nothing") : names.formatted(.list(type: .or))
    }
}

/// The add/edit sheet.
struct FilterRuleEditor: View {

    @State var draft: FilterDraft
    let onSave: (FilterDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \AccountRecord.createdAt) private var accounts: [AccountRecord]
    @Query(sort: \CachedSource.title) private var sources: [CachedSource]

    /// How many cached items the draft would hide, or `nil` while it is being counted.
    @State private var matchCount: Int?

    /// Why the pattern will not compile, if it will not.
    @State private var patternError: String?

    /// Held for the sheet's lifetime. See ``previewCounter()``.
    @State private var counter: FilterReevaluator?

    /// The scope picker's rows, resolved from the two queries rather than rebuilt from them.
    ///
    /// Every keystroke re-runs this view's body, and building the picker straight from the queries
    /// meant two `filter` passes and a `Text` per account and per subscribed feed each time —
    /// reading a managed property off every one of them. There are only ever as many of these as
    /// there are feeds, and they change when the subscription list changes, not when someone types.
    @State private var scopeChoices: [ScopeChoice] = []

    /// Stops the preview counting the whole cache on every keystroke.
    private static let previewDebounce = Duration.milliseconds(350)

    /// The preview stops counting past this, because the exact number stops mattering once a rule
    /// is obviously too broad, and a full pass over a large cache is not free.
    private static let previewLimit = 5_000

    var body: some View {
        container {
            Form {
                Section {
                    TextField("Pattern", text: $draft.pattern, prompt: Text("Text to look for"))
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif

                    Picker("Match", selection: $draft.matchKind) {
                        ForEach(FilterMatchKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }

                    Toggle("Case-sensitive", isOn: $draft.isCaseSensitive)
                } header: {
                    Text("Match")
                } footer: {
                    preview
                }

                Section("Look in") {
                    fieldToggle("Title", .title)
                    fieldToggle("Text", .content)
                    fieldToggle("Author", .author)
                    fieldToggle("Source name", .sourceTitle)
                }

                Section("Where") {
                    Picker("Applies to", selection: $draft.scope) {
                        Text("Everywhere").tag(FilterScope.everywhere)

                        ForEach(scopeChoices) { choice in
                            Text(choice.title).tag(choice.scope)
                        }
                    }
                }

                Section("Name") {
                    TextField("Name", text: $draft.name, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)
        }
        // Keyed on the whole draft, so changing the fields or the scope re-counts as readily as
        // changing the pattern — all three change what the rule would hide.
        .task(id: draft) {
            await updatePreview()
        }
        // Rebuilt when the lists themselves change, which is not while anyone is typing.
        .task(id: ChoiceKey(accounts: accounts.count, sources: sources.count)) {
            scopeChoices = Self.choices(accounts: accounts, sources: sources)
        }
    }

    /// The sheet's chrome, which is the one part that genuinely differs by platform.
    ///
    /// macOS gets an explicit title and a Cancel/Save row rather than a `NavigationStack`. A
    /// navigation stack inside a sheet is an iOS shape: on the Mac it puts the two actions in a
    /// navigation bar at the top of a modal, which is not where anyone looks for them, and it
    /// leaves the sheet without a natural size.
    @ViewBuilder
    private func container(@ViewBuilder _ content: () -> some View) -> some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            content()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    // Saving an uncompilable pattern is allowed on purpose: a rule can be saved
                    // half-written and fixed later, and the list marks it as broken meanwhile. Only
                    // a rule that could never match anything is refused.
                    .disabled(!draft.isValid)
            }
            .padding(20)
        }
        .frame(width: 460, height: 520)
        #else
        NavigationStack {
            content()
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }
                            .disabled(!draft.isValid)
                    }
                }
        }
        #endif
    }

    private var title: LocalizedStringKey {
        draft.isExisting ? "Edit Rule" : "New Rule"
    }

    private func save() {
        onSave(draft)
        dismiss()
    }

    @ViewBuilder
    private var preview: some View {
        if let patternError {
            Label(patternError, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if !draft.isValid {
            if draft.pattern.isEmpty {
                Text("Enter something to match.")
            } else {
                Text("Choose at least one field to look in.")
            }
        } else if let matchCount {
            // Phrased as what it does to the library rather than as an abstract match count,
            // because that is the question being asked: is this rule too broad?
            //
            // Two `Text`s rather than one holding a ternary: the ternary produces a `String`, and
            // both inflection markup and localisation are applied only by the literal overload.
            if matchCount >= Self.previewLimit {
                Text("Hides more than \(Self.previewLimit) cached items.")
            } else {
                Text("Hides ^[\(matchCount) cached item](inflect: true).")
            }
        } else {
            Text("Counting…")
        }
    }

    /// One row of the scope picker, as a value.
    private struct ScopeChoice: Identifiable, Hashable {
        let id: String
        let title: String
        let scope: FilterScope
    }

    /// What the choices are derived from. A count of each is enough: accounts and feeds are added
    /// and removed, and a rename shows on the next open, which is not worth re-reading a whole
    /// subscription list per keystroke to catch.
    private struct ChoiceKey: Hashable {
        let accounts: Int
        let sources: Int
    }

    private static func choices(
        accounts: [AccountRecord],
        sources: [CachedSource]
    ) -> [ScopeChoice] {
        accounts.filter(\.isEnabled).map {
            ScopeChoice(id: "account:\($0.id)", title: $0.displayName, scope: .account($0.id))
        }
        + sources.filter(\.isSubscribed).map {
            ScopeChoice(id: "source:\($0.id)", title: $0.title, scope: .source($0.id))
        }
    }

    private func fieldToggle(_ title: String, _ field: FilterFields) -> some View {
        Toggle(title, isOn: Binding(
            get: { draft.fields.contains(field) },
            set: { isOn in
                if isOn { draft.fields.insert(field) } else { draft.fields.remove(field) }
            }
        ))
    }

    /// Recounts what the draft would hide.
    ///
    /// Debounced by sleeping first: `.task(id:)` cancels the previous run when the draft changes,
    /// so a keystroke inside the delay never starts a pass at all, and one that arrives mid-pass
    /// cancels it at the next batch.
    private func updatePreview() async {
        guard draft.isValid else {
            matchCount = nil
            patternError = nil
            return
        }

        do {
            try await Task.sleep(for: Self.previewDebounce)
        } catch {
            return
        }

        // Cleared *after* the wait, not before it, and that is a performance change rather than a
        // cosmetic one. Clearing first wrote two pieces of `@State` per keystroke, and each write
        // re-ran this whole `Form` — the scope picker included, which is a row per account and a
        // row per subscribed feed. Three body evaluations per character where one will do.
        //
        // It reads better too: the footer keeps the last count until a new one is ready instead of
        // flashing "Counting…" between every letter.
        matchCount = nil
        patternError = nil

        let engine = FilterEngine([draft.detachedRule()])
        if let failure = engine.compilationFailures[draft.id] {
            patternError = failure
            return
        }

        matchCount = try? await previewCounter().matchCount(for: engine, limit: Self.previewLimit)
    }

    /// The one counter this sheet uses, made on first need and kept.
    ///
    /// Deliberately not a fresh actor per pass. It keeps the stripped article bodies between passes
    /// — see `FilterReevaluator.matchCount(for:limit:)` — and that cache is the whole reason typing
    /// a pattern does not re-parse the entire cache's HTML per keystroke. A new actor each time
    /// starts cold and there is no saving at all.
    private func previewCounter() -> FilterReevaluator {
        if let counter { return counter }
        let created = FilterReevaluator(modelContainer: modelContext.container)
        counter = created
        return created
    }
}

#if DEBUG
#Preview {
    FilterRuleEditor(draft: FilterDraft()) { _ in }
        .modelContainer(FixtureData.previewContainer())
}
#endif
