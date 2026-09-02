// Shortcuts.swift
// Glance
//
// Global hotkey identities, registered with sindresorhus/KeyboardShortcuts.
//
// The names are persistent keys: KeyboardShortcuts stores each user-assigned
// combination in UserDefaults under the raw string, so renaming one silently
// discards whatever the user had bound to it.

import KeyboardShortcuts

extension KeyboardShortcuts.Name {

    /// Begin a new region selection. Default ⌥⇧G.
    static let newCapture = Self(
        "newCapture",
        default: .init(.g, modifiers: [.option, .shift])
    )

    /// Toggle Ghost Mode on the active PiP. Default ⌥G.
    ///
    /// This one matters more than most: Ghost Mode makes the panel ignore mouse
    /// events entirely, so a global hotkey is the guaranteed way back out.
    static let toggleGhostMode = Self(
        "toggleGhostMode",
        default: .init(.g, modifiers: [.option])
    )
}
