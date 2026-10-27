// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Rules and display for global shortcuts given as a Carbon virtual key code
/// and a Carbon modifier mask (what `RegisterEventHotKey` takes).
public enum HotKeyRules {
    /// Carbon modifier bits (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000
    public static let allModifiers = command | shift | option | control

    /// Why a shortcut cannot be used.
    public enum Issue: Equatable, Sendable {
        /// Needs ⌘, ⌃ or ⌥ (only function keys work alone).
        case needsModifier
        /// macOS or every app already uses it (⌘Q, ⌘Tab, ⌘Space…).
        case reservedBySystem
        /// It is the other Vauta shortcut.
        case sameAsOther
        /// Another app registered it first.
        case inUseByAnotherApp

        public var message: String {
            switch self {
            case .needsModifier:
                String(localized: "Use at least one of ⌘, ⌃ or ⌥ with the key.", comment: "Shortcut recorder error")
            case .reservedBySystem:
                String(localized: "This shortcut is used by macOS. Choose a different one.", comment: "Shortcut recorder error")
            case .sameAsOther:
                String(localized: "Vauta already uses this shortcut for the other action.", comment: "Shortcut recorder error")
            case .inUseByAnotherApp:
                String(localized: "This shortcut is used by another app. Choose a different one.", comment: "Shortcut recorder error")
            }
        }
    }

    /// Checks a shortcut before saving it (`other` is Vauta's other shortcut).
    public static func issue(keyCode: UInt32, modifiers: UInt32, other: (keyCode: UInt32, modifiers: UInt32)?) -> Issue? {
        let mods = modifiers & allModifiers
        if mods & (command | control | option) == 0 && !functionKeys.keys.contains(keyCode) { return .needsModifier }
        if reserved.contains(Combo(keyCode: keyCode, modifiers: mods)) { return .reservedBySystem }
        if let other, other.keyCode == keyCode, other.modifiers & allModifiers == mods { return .sameAsOther }
        return nil
    }

    /// Modifier symbols in the standard macOS order: ⌃⌥⇧⌘.
    public static func modifierSymbols(_ modifiers: UInt32) -> String {
        var out = ""
        if modifiers & control != 0 { out += "⌃" }
        if modifiers & option != 0 { out += "⌥" }
        if modifiers & shift != 0 { out += "⇧" }
        if modifiers & command != 0 { out += "⌘" }
        return out
    }

    /// Names of keys that do not type a character; nil for character keys,
    /// whose label depends on the keyboard layout.
    public static func specialKeyName(_ keyCode: UInt32) -> String? {
        if let f = functionKeys[keyCode] { return "F\(f)" }
        return switch keyCode {
        case 36: "↩"
        case 48: "⇥"
        case 49: String(localized: "Space", comment: "Name of the space bar in a keyboard shortcut")
        case 51: "⌫"
        case 53: "⎋"
        case 117: "⌦"
        case 115: "↖"
        case 119: "↘"
        case 116: "⇞"
        case 121: "⇟"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: nil
        }
    }

    // kVK_F1… key codes → function key number.
    static let functionKeys: [UInt32: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
        105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    private struct Combo: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    /// Shortcuts macOS or every app relies on (ANSI key codes).
    private static let reserved: Set<Combo> = [
        Combo(keyCode: 12, modifiers: command),            // ⌘Q
        Combo(keyCode: 13, modifiers: command),            // ⌘W
        Combo(keyCode: 4, modifiers: command),             // ⌘H
        Combo(keyCode: 46, modifiers: command),            // ⌘M
        Combo(keyCode: 48, modifiers: command),            // ⌘Tab
        Combo(keyCode: 48, modifiers: command | shift),    // ⌘⇧Tab
        Combo(keyCode: 50, modifiers: command),            // ⌘`
        Combo(keyCode: 49, modifiers: command),            // ⌘Space
        Combo(keyCode: 49, modifiers: control),            // ⌃Space
        Combo(keyCode: 49, modifiers: control | command),  // ⌃⌘Space
        Combo(keyCode: 49, modifiers: option | command),   // ⌥⌘Space
        Combo(keyCode: 43, modifiers: command),            // ⌘,
        Combo(keyCode: 20, modifiers: command | shift),    // ⌘⇧3
        Combo(keyCode: 21, modifiers: command | shift),    // ⌘⇧4
        Combo(keyCode: 23, modifiers: command | shift),    // ⌘⇧5
        Combo(keyCode: 12, modifiers: control | command),  // ⌃⌘Q
        Combo(keyCode: 53, modifiers: option | command),   // ⌥⌘⎋
        Combo(keyCode: 3, modifiers: control | command),   // ⌃⌘F
    ]
}
