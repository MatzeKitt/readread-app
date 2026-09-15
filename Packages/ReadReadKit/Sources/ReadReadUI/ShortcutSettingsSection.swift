import ReadReadModel
import SwiftUI

/// The keyboard shortcuts section of Settings.
///
/// One row per action, each showing its current key and offering to record a new one.
struct ShortcutSettingsSection: View {

    @Bindable var settings: SettingsModel

    /// The action currently listening for a keystroke. At most one at a time, so starting a second
    /// recording cancels the first rather than leaving two rows both claiming the next key.
    @State private var recording: ShortcutSettings.Action?

    var body: some View {
        Section {
            ForEach(ShortcutSettings.Action.allCases) { action in
                ShortcutRow(
                    action: action,
                    binding: settings.shortcuts[action],
                    isRecording: recording == action,
                    onRecord: { recording = recording == action ? nil : action },
                    onCapture: { capture($0, for: action) },
                    onClear: {
                        settings.shortcuts[action] = .unassigned
                        recording = nil
                    }
                )
            }
        } header: {
            Text("Keyboard Shortcuts")
        } footer: {
            Text("""
            Shortcuts act on the selected item. They are unmodified single keys by default, which \
            is why the app has no text fields in the timeline for them to interfere with — hold \
            Command, Option or Control while recording to add a modifier.
            """)
        }
    }

    private func capture(_ binding: KeyBinding, for action: ShortcutSettings.Action) {
        // `assign` unbinds whatever else held the key, so the two rows can never both claim it —
        // SwiftUI would match one and leave the other silently dead.
        settings.shortcuts.assign(binding, to: action)
        recording = nil
    }
}

/// One shortcut row: what the key does, what it is, and a way to change it.
private struct ShortcutRow: View {

    let action: ShortcutSettings.Action
    let binding: KeyBinding
    let isRecording: Bool
    let onRecord: () -> Void
    let onCapture: (KeyBinding) -> Void
    let onClear: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                Text(action.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button(action: onRecord) {
                (isRecording ? Text("Press a key…") : Text(binding.displayName))
                    .font(.body.monospaced())
                    .frame(minWidth: 90)
                    .contentShape(.rect)
            }
            .buttonStyle(.bordered)
            // Labelled here rather than by combining the row: an accessibility dump of the running
            // app showed `.accessibilityElement(children: .combine)` swallowing this button and the
            // row's text outright, leaving only the Clear button reachable — the row could be
            // cleared but never recorded.
            .accessibilityLabel("\(action.title) shortcut")
            .accessibilityValue(binding.isAssigned ? Text(binding.displayName) : Text("No shortcut"))
            .accessibilityHint(isRecording ? Text("Press the key to assign") : Text("Activate, then press a key"))
            // The button is what receives the keystroke, so it has to hold focus while recording —
            // otherwise the press goes to the settings window and the row never sees it.
            .focused($isFocused)
            .onKeyPress { press in
                guard isRecording else { return .ignored }
                guard let recorded = KeyBinding.recording(press) else {
                    // Arrows, Tab and Escape stay with the window: capturing one would take
                    // navigation away from wherever the shortcut is later used.
                    return .ignored
                }
                onCapture(recorded)
                return .handled
            }
            .onChange(of: isRecording) { _, recording in
                isFocused = recording
            }

            Button("Clear", systemImage: "xmark.circle.fill") {
                onClear()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(!binding.isAssigned)
            .help("Remove this shortcut")
            .accessibilityLabel("Clear \(action.title) shortcut")
        }
    }
}
