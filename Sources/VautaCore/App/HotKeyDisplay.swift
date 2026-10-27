// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A global keyboard shortcut: Carbon virtual key code (a physical key
/// position) plus a Carbon modifier mask.
public struct HotKeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // Carbon modifier bits (Events.h).
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000
    static let allModifiers = command | shift | option | control

    /// The modifiers in Apple's display order (⌃⌥⇧⌘).
    public var modifierSymbols: String {
        var out = ""
        if modifiers & Self.control != 0 { out += "⌃" }
        if modifiers & Self.option != 0 { out += "⌥" }
        if modifiers & Self.shift != 0 { out += "⇧" }
        if modifiers & Self.command != 0 { out += "⌘" }
        return out
    }

    /// A global shortcut needs ⌃, ⌥ or ⌘: with only ⇧ (or nothing) it would
    /// steal ordinary typing from every app. Function keys are allowed alone.
    public var isValidGlobalShortcut: Bool {
        if Self.functionKeys[keyCode] != nil { return true }
        return modifiers & (Self.control | Self.option | Self.command) != 0
    }

    /// Converts AppKit modifier flags (`NSEvent.ModifierFlags.rawValue`) to Carbon.
    public static func carbonModifiers(cocoaFlags: UInt) -> UInt32 {
        var out: UInt32 = 0
        if cocoaFlags & (1 << 17) != 0 { out |= shift }
        if cocoaFlags & (1 << 18) != 0 { out |= control }
        if cocoaFlags & (1 << 19) != 0 { out |= option }
        if cocoaFlags & (1 << 20) != 0 { out |= command }
        return out
    }

    /// The text of the shortcut, e.g. "⌃⌥R".
    ///
    /// - Parameter keyLabel: the character the key types in the current
    ///   keyboard layout (from `UCKeyTranslate`); nil when unknown. Keys that
    ///   type no visible character (Return, arrows, F-keys…) use their symbols.
    public func displayString(keyLabel: (UInt32) -> String? = { _ in nil }) -> String {
        modifierSymbols + Self.keyName(keyCode, keyLabel: keyLabel)
    }

    static func keyName(_ keyCode: UInt32, keyLabel: (UInt32) -> String?) -> String {
        if keyCode == spaceKey { return String(localized: "Space", comment: "Name of the space bar in a keyboard shortcut") }
        if let special = specialKeys[keyCode] { return special }
        if let function = functionKeys[keyCode] { return function }
        if let label = keyLabel(keyCode)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !label.isEmpty,
           label.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return label
        }
        if let ansi = ansiKeys[keyCode] { return ansi }
        return String(localized: "Key \(keyCode)", comment: "Shortcut display for a key without a name; the argument is a number")
    }

    static let spaceKey: UInt32 = 0x31

    /// Keys whose symbol doesn't depend on the layout.
    static let specialKeys: [UInt32: String] = [
        0x24: "↩", 0x30: "⇥", 0x33: "⌫", 0x35: "⎋", 0x75: "⌦",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑", 0x4C: "⌤",
    ]

    static let functionKeys: [UInt32: String] = [
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18", 0x50: "F19", 0x5A: "F20",
    ]

    /// US ANSI letters and digits: the fallback when the layout can't be read.
    static let ansiKeys: [UInt32: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I",
        0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P", 0x0C: "Q", 0x0F: "R",
        0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9",
        0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x29: ";", 0x27: "'", 0x2B: ",", 0x2F: ".", 0x2C: "/", 0x2A: "\\", 0x32: "`",
    ]
}
