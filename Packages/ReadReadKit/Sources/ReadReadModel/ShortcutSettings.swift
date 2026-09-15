import Foundation

/// A key the user can press to run an action in the timeline.
///
/// Stored as a character plus a modifier mask rather than as a SwiftUI `KeyboardShortcut`, because
/// this has to round-trip through `UserDefaults` and `KeyEquivalent` is neither `Codable` nor
/// inspectable — you cannot ask one what character it holds.
public struct KeyBinding: Sendable, Equatable, Codable {

    /// Modifiers, as a mask. Mirrors SwiftUI's `EventModifiers` without depending on SwiftUI here,
    /// so the model layer stays free of it and the values are stable on disk.
    public struct Modifiers: OptionSet, Sendable, Equatable, Codable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let shift = Modifiers(rawValue: 1 << 1)
        public static let option = Modifiers(rawValue: 1 << 2)
        public static let control = Modifiers(rawValue: 1 << 3)
    }

    /// A single character, lowercased. Empty means the action has no shortcut at all, which is a
    /// legitimate choice rather than a broken binding.
    public private(set) var key: String

    public private(set) var modifiers: Modifiers

    public init(key: String, modifiers: Modifiers = []) {
        self.key = Self.normalise(key)
        self.modifiers = self.key.isEmpty ? [] : modifiers
    }

    /// Nothing bound.
    public static let unassigned = KeyBinding(key: "")

    public var isAssigned: Bool { !key.isEmpty }

    /// Keeps exactly one character, lowercased.
    ///
    /// Lowercased because a shortcut is matched against the key, not the shifted glyph: binding
    /// `L` and pressing `l` has to fire, and on macOS a capital letter in a `keyboardShortcut`
    /// silently implies Shift.
    private static func normalise(_ key: String) -> String {
        guard let character = key.lowercased().first, character.isLetter || character.isNumber else {
            return ""
        }
        return String(character)
    }

    /// How the binding reads in the interface: `⌘⇧L`.
    public var displayName: String {
        guard isAssigned else { return String(localized: "None") }
        var text = ""
        // Apple's documented order for modifier glyphs, which is not the order of the option set.
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }
}

/// The keys that run timeline actions.
///
/// Configurable because a bare letter is a strong claim on the keyboard: it is the fastest way to
/// work, and also the most likely to collide with a habit from whatever reader someone used
/// before.
public struct ShortcutSettings: Sendable, Equatable, Codable {

    /// The actions a key can be bound to.
    ///
    /// An enum rather than two loose properties so the settings screen, the conflict check and the
    /// timeline all iterate the same list — adding a third action should not mean finding three
    /// places that hard-code two.
    public enum Action: String, Sendable, CaseIterable, Codable, Identifiable {
        case readLater
        case openInBrowser

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .readLater: String(localized: "Add to Read Later")
            case .openInBrowser: String(localized: "Open in Browser")
            }
        }

        /// What the key does when the action is already done — Read Later toggles, opening does
        /// not. Stated here so the settings screen can explain it.
        public var detail: String {
            switch self {
            case .readLater: String(localized: "Saves the selected item, or removes it if it is already saved.")
            case .openInBrowser: String(localized: "Opens the selected item's link in your browser.")
            }
        }

        public var defaultBinding: KeyBinding {
            switch self {
            case .readLater: KeyBinding(key: "l")
            case .openInBrowser: KeyBinding(key: "o")
            }
        }
    }

    public var readLater: KeyBinding
    public var openInBrowser: KeyBinding

    public init(
        readLater: KeyBinding = Action.readLater.defaultBinding,
        openInBrowser: KeyBinding = Action.openInBrowser.defaultBinding
    ) {
        self.readLater = readLater
        self.openInBrowser = openInBrowser
    }

    public static let `default` = ShortcutSettings()

    public subscript(action: Action) -> KeyBinding {
        get {
            switch action {
            case .readLater: readLater
            case .openInBrowser: openInBrowser
            }
        }
        set {
            switch action {
            case .readLater: readLater = newValue
            case .openInBrowser: openInBrowser = newValue
            }
        }
    }

    /// Assigns a binding, unassigning whatever else held that key.
    ///
    /// Two actions on one key is not a state worth representing: SwiftUI matches the first
    /// `keyboardShortcut` it finds, so the loser would simply stop working with nothing to say
    /// why. Taking the key away from the other action makes the collision visible in the very
    /// place it was created.
    public mutating func assign(_ binding: KeyBinding, to action: Action) {
        if binding.isAssigned {
            for other in Action.allCases where other != action {
                if self[other] == binding { self[other] = .unassigned }
            }
        }
        self[action] = binding
    }

    /// The action already using a binding, if any.
    public func conflict(for binding: KeyBinding, excluding action: Action) -> Action? {
        guard binding.isAssigned else { return nil }
        return Action.allCases.first { $0 != action && self[$0] == binding }
    }
}

/// Reads and writes ``ShortcutSettings``.
///
/// `@unchecked Sendable` for the same reason as ``ReadingSettingsStore``: `UserDefaults` is
/// documented as thread-safe but is not marked `Sendable`, and this type only touches one key.
public struct ShortcutSettingsStore: @unchecked Sendable {

    private static let key = "media.kitt.readread.shortcuts"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ShortcutSettings {
        guard let data = defaults.data(forKey: Self.key),
              let settings = try? JSONDecoder().decode(ShortcutSettings.self, from: data)
        else {
            return .default
        }
        return settings
    }

    public func save(_ settings: ShortcutSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
