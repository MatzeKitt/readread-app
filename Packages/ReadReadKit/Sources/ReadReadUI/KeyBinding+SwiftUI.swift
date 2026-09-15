import ReadReadModel
import SwiftUI

extension KeyBinding {

    /// The SwiftUI shortcut for this binding, or `nil` when nothing is bound.
    ///
    /// Optional rather than a no-op shortcut because there is no "matches nothing" `KeyEquivalent`:
    /// an unassigned action has to omit the modifier entirely, which is what
    /// ``SwiftUICore/View/keyboardShortcut(_:)-8gonl`` below is for.
    var keyboardShortcut: KeyboardShortcut? {
        guard let character = key.first else { return nil }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: eventModifiers)
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    /// Whether a key press is this binding.
    ///
    /// Needed because a bare-letter `keyboardShortcut` on a toolbar button does not reliably win
    /// against a `List`'s own type-select on macOS: pressing `L` over the timeline jumped the
    /// selection to the next item beginning with "l" instead of saving anything. The list handles
    /// the key itself and consults this; see `TimelineList`.
    ///
    /// Compared case-insensitively, and Shift is ignored, matching ``recording(_:)`` — which drops
    /// Shift because the character it produced is already the shifted one.
    func matches(_ press: KeyPress) -> Bool {
        guard let expected = key.first else { return false }
        let actual = press.characters.first ?? press.key.character
        guard actual.lowercased() == expected.lowercased() else { return false }

        return press.modifiers.contains(.command) == modifiers.contains(.command)
            && press.modifiers.contains(.option) == modifiers.contains(.option)
            && press.modifiers.contains(.control) == modifiers.contains(.control)
    }

    /// Builds a binding from a key press the user made.
    ///
    /// Returns `nil` for anything that is not a plain character — arrows, tab, escape and the
    /// like — because those are how the app is navigated, and letting one be captured would take
    /// the keyboard away from the list it was recorded in.
    static func recording(_ press: KeyPress) -> KeyBinding? {
        // `characters` is what the keystroke produced; `key` is the physical key. Preferring the
        // former means a shifted or dead-key layout records the glyph the user actually saw.
        let character = press.characters.first ?? press.key.character
        guard character.isLetter || character.isNumber else { return nil }

        var modifiers: Modifiers = []
        if press.modifiers.contains(.command) { modifiers.insert(.command) }
        if press.modifiers.contains(.option) { modifiers.insert(.option) }
        if press.modifiers.contains(.control) { modifiers.insert(.control) }
        // Shift is deliberately dropped: the character it produced is already the shifted one, and
        // recording both would make `⇧1` and `!` two different bindings for one keystroke.
        return KeyBinding(key: String(character), modifiers: modifiers)
    }
}

extension View {

    /// Applies a binding's shortcut, or none at all when the action is unassigned.
    @ViewBuilder
    func keyboardShortcut(_ binding: KeyBinding) -> some View {
        if let shortcut = binding.keyboardShortcut {
            keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
