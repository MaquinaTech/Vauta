// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("App: global shortcuts")
struct AppHotKeyTests {
    /// ⌃⌥R and ⌃⌥M as 0.1.0 registered them (kVK_ANSI_R / kVK_ANSI_M, controlKey | optionKey).
    let record = HotKeyCombo(keyCode: 15, modifiers: 0x1800)
    let mark = HotKeyCombo(keyCode: 46, modifiers: 0x1800)

    @Test func usesTheLayoutsCharacter() {
        // AZERTY types "," on the ANSI M key; Dvorak types "p" on the ANSI R key.
        #expect(mark.displayString { $0 == 46 ? "," : nil } == "⌃⌥,")
        #expect(record.displayString { $0 == 15 ? "p" : nil } == "⌃⌥P")
    }

    @Test func fallsBackToTheANSINameWithoutALayout() {
        #expect(record.displayString() == "⌃⌥R")
        #expect(mark.displayString { _ in "" } == "⌃⌥M")
        #expect(mark.displayString { _ in "\u{10}" } == "⌃⌥M")   // a control character
    }

    @Test func modifiersFollowApplesOrder() {
        let all = HotKeyCombo(keyCode: 0, modifiers: HotKeyCombo.command | HotKeyCombo.shift | HotKeyCombo.option | HotKeyCombo.control)
        #expect(all.displayString() == "⌃⌥⇧⌘A")
        #expect(HotKeyCombo(keyCode: 0, modifiers: HotKeyCombo.command | HotKeyCombo.shift).modifierSymbols == "⇧⌘")
    }

    @Test func specialKeysUseSymbolsWhateverTheLayout() {
        let layout: (UInt32) -> String? = { _ in "x" }
        #expect(HotKeyCombo(keyCode: 0x24, modifiers: HotKeyCombo.control).displayString(keyLabel: layout) == "⌃↩")
        #expect(HotKeyCombo(keyCode: 0x7E, modifiers: HotKeyCombo.option).displayString(keyLabel: layout) == "⌥↑")
        #expect(HotKeyCombo(keyCode: 0x60, modifiers: 0).displayString(keyLabel: layout) == "F5")
        #expect(HotKeyCombo(keyCode: 0x31, modifiers: HotKeyCombo.control).displayString(keyLabel: layout) == "⌃Space")
    }

    @Test func globalShortcutsNeedARealModifier() {
        #expect(record.isValidGlobalShortcut)
        #expect(!HotKeyCombo(keyCode: 15, modifiers: 0).isValidGlobalShortcut)
        #expect(!HotKeyCombo(keyCode: 15, modifiers: HotKeyCombo.shift).isValidGlobalShortcut)
        #expect(HotKeyCombo(keyCode: 15, modifiers: HotKeyCombo.command | HotKeyCombo.shift).isValidGlobalShortcut)
        #expect(HotKeyCombo(keyCode: 0x7A, modifiers: 0).isValidGlobalShortcut)   // F1
    }

    @Test func convertsAppKitModifierFlags() {
        // NSEvent.ModifierFlags: shift 1<<17, control 1<<18, option 1<<19, command 1<<20; plus a device bit.
        let flags: UInt = (1 << 18) | (1 << 19) | 0x100
        #expect(HotKeyCombo.carbonModifiers(cocoaFlags: flags) == HotKeyCombo.control | HotKeyCombo.option)
        #expect(HotKeyCombo.carbonModifiers(cocoaFlags: (1 << 17) | (1 << 20)) == HotKeyCombo.shift | HotKeyCombo.command)
        #expect(HotKeyCombo.carbonModifiers(cocoaFlags: 0) == 0)
    }

    @Test func storedPreferenceFormatIsUnchanged() throws {
        let json = Data(#"{"keyCode":15,"modifiers":6144}"#.utf8)
        #expect(try JSONDecoder().decode(HotKeyCombo.self, from: json) == record)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mark)) as? [String: Int]
        #expect(encoded == ["keyCode": 46, "modifiers": 6144])
    }
}
