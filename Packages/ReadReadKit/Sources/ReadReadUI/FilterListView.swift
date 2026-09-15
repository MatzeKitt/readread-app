import ReadReadModel
import ReadReadSync
import SwiftData
import SwiftUI

/// The list of ignore rules, with the editor and the "what did this hide" list hanging off it.
struct FilterListView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(AppServices.self) private var services

    /// Fetched in a fixed order and then re-sorted for display; see ``sorted(_:)``.
    @Query(sort: \FilterRule.createdAt, order: .reverse) private var rules: [FilterRule]

    /// The rule being edited, or a new one. `nil` when the sheet is closed.
    @State private var editing: FilterDraft?

    /// Set while a re-evaluation pass is running, so the list can say that the store is catching
    /// up rather than looking as though nothing happened.
    @State private var isReapplying = false

    /// What the last pass changed, shown briefly so an edit that hid nothing is distinguishable
    /// from one that has not run yet.
    @State private var lastOutcome: FilterReevaluator.Outcome?

    /// Patterns that failed to compile, keyed by rule id.
    ///
    /// Takes the rules rather than reading them, so the caller can build the map once. As a
    /// computed property it was read from inside the `ForEach`, which meant constructing a whole
    /// `FilterEngine` — and so compiling every rule's pattern — once per *row*: a rule set of `n`
    /// cost `n²` regex compilations per body evaluation, and a regex costs far more to build than
    /// to run. `FilteredItemsView` already builds its engine once in `body` for exactly this
    /// reason.
    private static func compilationFailures(of rules: [FilterRule]) -> [UUID: String] {
        FilterEngine(rules).compilationFailures
    }

    /// The rules in the order they are shown: by the label each row actually displays.
    ///
    /// Sorted here rather than in the `@Query`, because the sort key is ``FilterRule/effectiveName``
    /// — a computed property, which a `SortDescriptor` over a persistent model cannot address. A
    /// rule with no name shows its pattern instead, so sorting on the stored `name` would file
    /// every unnamed rule together under the empty string and leave the visible list looking
    /// unsorted.
    ///
    /// `localizedStandardCompare` rather than `<`: `<` on `String` compares Unicode scalars, which
    /// files every capital ahead of every lowercase letter and sorts „Ärger" after "Zeit". This is
    /// the Finder's ordering, so it also reads a run of digits as a number.
    static func sorted(_ rules: [FilterRule]) -> [FilterRule] {
        rules.sorted { left, right in
            let order = left.effectiveName.localizedStandardCompare(right.effectiveName)
            // Two rules can legitimately share a label. Falling through to a stable tiebreak keeps
            // those two from swapping places on every redraw.
            return order == .orderedSame ? left.createdAt < right.createdAt : order == .orderedAscending
        }
    }

    var body: some View {
        let failures = Self.compilationFailures(of: rules)
        let rules = Self.sorted(rules)

        return List {
            Section {
                if rules.isEmpty {
                    // Inline rather than an `.overlay`, which would cover the whole list including
                    // its header, and with it the only way to add a first rule.
                    ContentUnavailableView(
                        "No Rules",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Add a rule to hide items whose title or text you would rather not see.")
                    )
                }

                ForEach(rules) { rule in
                    FilterRuleRow(
                        rule: rule,
                        failure: failures[rule.id],
                        onEnabledChanged: { persist(rule) }
                    )
                    .contentShape(.rect)
                    .onTapGesture { editing = FilterDraft(rule) }
                    .contextMenu {
                        Button("Edit…", systemImage: "pencil") { editing = FilterDraft(rule) }
                        // Duplicated from `onDelete` rather than relying on it: swipe-to-delete is
                        // an iOS gesture, and on the Mac this menu is the only way to remove a row.
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(rule) }
                    }
                }
                .onDelete(perform: delete)
            } header: {
                HStack {
                    Text("Ignore Rules")
                    Spacer()
                    status
                    // In the section rather than the toolbar: inside a `Settings` window a view's
                    // toolbar items are merged into the tab bar, so "Add Rule" ended up as an
                    // unlabelled icon sitting beside General / Refreshing / Filters.
                    Button("Add Rule", systemImage: "plus") {
                        editing = FilterDraft()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            } footer: {
                // States the model plainly, because "filter" reads to some people as "show only".
                // Says where the hidden items went, now that this screen no longer leads there:
                // the list moved to the sidebar, which is where someone notices the absence.
                Text("Rules only hide. An item is hidden if any enabled rule matches it, and hidden items are left out of every count — they are listed under Filtered Items in the sidebar.")
            }
        }
        .sheet(item: $editing) { draft in
            FilterRuleEditor(draft: draft) { saved in
                apply(saved)
            }
        }
        .navigationTitle("Filters")
    }

    /// What the last re-evaluation did, or that one is running.
    @ViewBuilder
    private var status: some View {
        if isReapplying {
            ProgressView()
                .controlSize(.small)
        } else if let lastOutcome, lastOutcome.changed > 0 {
            Text("\(lastOutcome.hidden) hidden, \(lastOutcome.revealed) shown")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Editing

    private func apply(_ draft: FilterDraft) {
        let rule: FilterRule

        if let existing = rules.first(where: { $0.id == draft.id }) {
            existing.name = draft.name
            existing.pattern = draft.pattern
            existing.fields = draft.fields
            existing.matchKind = draft.matchKind
            existing.isCaseSensitive = draft.isCaseSensitive
            existing.scope = draft.scope
            existing.isEnabled = draft.isEnabled
            existing.updatedAt = .now
            rule = existing
        } else {
            rule = FilterRule(
                id: draft.id,
                name: draft.name,
                pattern: draft.pattern,
                fields: draft.fields,
                matchKind: draft.matchKind,
                isCaseSensitive: draft.isCaseSensitive,
                scope: draft.scope,
                isEnabled: draft.isEnabled
            )
            modelContext.insert(rule)
        }

        persist(rule)
    }

    /// - Parameter offsets: Positions in the *displayed* order, which is what the `ForEach`
    ///   handed out — so they are resolved against ``sorted(_:)`` rather than against `rules`.
    private func delete(at offsets: IndexSet) {
        let shown = Self.sorted(rules)
        delete(offsets.map { shown[$0] })
    }

    private func delete(_ rule: FilterRule) {
        delete([rule])
    }

    private func delete(_ doomed: [FilterRule]) {
        for rule in doomed {
            // The tombstone is queued before the row goes, while its id is still readable, and is
            // committed by the same save. Without it the rule would come straight back on the next
            // pull from another device.
            try? SyncOutbox.recordFilterDeletion(id: rule.id, in: modelContext)
            modelContext.delete(rule)
        }
        try? modelContext.save()
        services.syncSoon()
        reapply()
    }

    private func persist(_ rule: FilterRule) {
        try? SyncOutbox.record(rule, in: modelContext)
        try? modelContext.save()
        // Pushed promptly rather than on the next thirty-second tick: a filter is edited and then
        // immediately looked for on the other device.
        services.syncSoon()
        reapply()
    }

    /// Walks the cache and re-applies every rule.
    ///
    /// Unavoidable, and the reason the editor is honest about taking a moment: `isFilteredOut` is a
    /// stored column — that is what makes the sidebar counts a `fetchCount` rather than a scan — so
    /// a rule change is stale until every row has been looked at again.
    private func reapply() {
        let container = modelContext.container
        isReapplying = true

        Task {
            let reevaluator = FilterReevaluator(modelContainer: container)
            let outcome = try? await reevaluator.reapplyAll()
            isReapplying = false
            lastOutcome = outcome
        }
    }
}

// MARK: - Rows

private struct FilterRuleRow: View {

    /// `@Bindable` so the switch drives the model directly.
    ///
    /// The alternative — a `Binding` built from a closure the parent passes in — needs that closure
    /// to be `@Sendable`, and it necessarily captures the `FilterRule` it acts on, which is not.
    @Bindable var rule: FilterRule

    let failure: String?

    /// Called after the switch has already changed the model, to persist and re-evaluate.
    let onEnabledChanged: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.effectiveName)
                    .lineLimit(1)

                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let failure {
                    // Shown rather than swallowed: a rule whose pattern will not compile filters
                    // nothing, and looks exactly like a rule that is working.
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            Spacer()

            Toggle("Enabled", isOn: $rule.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                // Named after the rule it switches. `labelsHidden` keeps "Enabled" as the
                // accessibility label, which is true of every row — so a list of rules read as
                // a column of identical switches with no way to tell which one was in hand.
                .accessibilityLabel("Enable \(rule.effectiveName)")
                .onChange(of: rule.isEnabled) {
                    rule.updatedAt = .now
                    onEnabledChanged()
                }
        }
        .padding(.vertical, 2)
    }

    private var summary: String {
        var parts = [rule.matchKind.displayName.lowercased(), "“\(rule.pattern)”"]
        parts.append(String(localized: "in \(FilterDraft.describe(rule.fields))"))
        if rule.isCaseSensitive { parts.append(String(localized: "· case-sensitive")) }
        return parts.joined(separator: " ")
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        FilterListView()
    }
    .modelContainer(FixtureData.previewContainer())
}
#endif
