import Foundation
import Testing

@testable import ReadReadModel

@Suite("ShortcutSettings")
struct ShortcutSettingsTests {

    // MARK: - Bindings

    @Test("A binding keeps one lowercased character")
    func normalisesKey() {
        // Lowercased because the shortcut is matched against the key, not the shifted glyph:
        // binding `L` and pressing `l` has to fire.
        #expect(KeyBinding(key: "L").key == "l")
        #expect(KeyBinding(key: "lo").key == "l")
        #expect(KeyBinding(key: "7").key == "7")
    }

    @Test("A binding refuses anything that is not a letter or digit", arguments: ["", " ", "\n", "\u{1B}", "→"])
    func rejectsNonCharacters(_ key: String) {
        let binding = KeyBinding(key: key)
        // Navigation keys must stay with the app: a shortcut on the right arrow would take the
        // keyboard away from the very list it acts on.
        #expect(!binding.isAssigned)
    }

    @Test("An unassigned binding carries no modifiers")
    func unassignedDropsModifiers() {
        // Otherwise "no shortcut, but with Command" is representable, and two of those compare
        // unequal while behaving identically.
        #expect(KeyBinding(key: "", modifiers: [.command]) == KeyBinding.unassigned)
    }

    @Test("Modifiers read in Apple's order")
    func displayName() {
        #expect(KeyBinding(key: "l").displayName == "L")
        #expect(KeyBinding(key: "l", modifiers: [.command]).displayName == "⌘L")
        #expect(
            KeyBinding(key: "l", modifiers: [.command, .shift, .option, .control]).displayName == "⌃⌥⇧⌘L"
        )
        #expect(KeyBinding.unassigned.displayName == "None")
    }

    // MARK: - Assignment

    @Test("The defaults are the keys the app documents")
    func defaults() {
        #expect(ShortcutSettings.default.readLater == KeyBinding(key: "l"))
        #expect(ShortcutSettings.default.openInBrowser == KeyBinding(key: "o"))
    }

    @Test("Assigning a key takes it away from whatever else held it")
    func assignmentIsExclusive() {
        var settings = ShortcutSettings.default
        settings.assign(KeyBinding(key: "o"), to: .readLater)

        // Two actions on one key is not a state worth representing: SwiftUI matches the first
        // shortcut it finds, so the loser would stop working with nothing to say why.
        #expect(settings.readLater == KeyBinding(key: "o"))
        #expect(!settings.openInBrowser.isAssigned)
    }

    @Test("The same key with a different modifier is not a conflict")
    func modifiersDisambiguate() {
        var settings = ShortcutSettings.default
        settings.assign(KeyBinding(key: "o", modifiers: [.command]), to: .readLater)

        #expect(settings.openInBrowser == KeyBinding(key: "o"))
        #expect(settings.conflict(for: KeyBinding(key: "o", modifiers: [.command]), excluding: .readLater) == nil)
    }

    @Test("Clearing a shortcut leaves the other alone")
    func clearingIsLocal() {
        var settings = ShortcutSettings.default
        settings.assign(.unassigned, to: .readLater)

        #expect(!settings.readLater.isAssigned)
        #expect(settings.openInBrowser == KeyBinding(key: "o"))
    }

    @Test("A conflict names the action already using the key")
    func conflictReporting() {
        let settings = ShortcutSettings.default
        #expect(settings.conflict(for: KeyBinding(key: "o"), excluding: .readLater) == .openInBrowser)
        #expect(settings.conflict(for: KeyBinding(key: "z"), excluding: .readLater) == nil)
        #expect(settings.conflict(for: .unassigned, excluding: .readLater) == nil)
    }

    // MARK: - Storage

    @Test("Settings round-trip through UserDefaults")
    func roundTrip() throws {
        let defaults = try #require(UserDefaults(suiteName: "shortcut-tests-\(UUID().uuidString)"))
        let store = ShortcutSettingsStore(defaults: defaults)

        var settings = ShortcutSettings.default
        settings.assign(KeyBinding(key: "b", modifiers: [.command, .option]), to: .readLater)
        store.save(settings)

        #expect(store.load() == settings)
    }

    @Test("Unreadable stored settings fall back to the defaults")
    func decodeFailureResets() throws {
        let name = "shortcut-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.set(Data("not json".utf8), forKey: "media.kitt.readread.shortcuts")

        // These are preferences, not data: resetting them beats refusing to launch.
        #expect(ShortcutSettingsStore(defaults: defaults).load() == .default)
    }
}
