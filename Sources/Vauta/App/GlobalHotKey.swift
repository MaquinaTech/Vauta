// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Carbon.HIToolbox

/// A global keyboard shortcut through Carbon's hot-key API: it works whatever
/// app is in front and, unlike an event monitor, needs no Accessibility
/// permission (macOS only reports THIS combination, never the rest of the
/// keyboard).
@MainActor
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: @MainActor () -> Void
    private let hotKeyID: UInt32
    let combo: HotKeyCombo
    /// False when another app already holds the combination.
    private(set) var isRegistered = false

    private static let signature: OSType = 0x5641_5554   // 'VAUT'

    /// `id` tells shortcuts apart: each handler only answers its own.
    init(_ combo: HotKeyCombo, id: UInt32, action: @escaping @MainActor () -> Void) {
        self.action = action
        self.hotKeyID = id
        self.combo = combo
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers keyboard events on the main thread.
            return MainActor.assumeIsolated {
                let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                guard pressed.signature == GlobalHotKey.signature, pressed.id == me.hotKeyID else { return OSStatus(eventNotHandledErr) }
                me.action()
                return noErr
            }
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
        guard installed == noErr else { handlerRef = nil; return }
        let registered = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            hotKeyRef = nil
            return
        }
        isRegistered = true
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    // MARK: Display

    /// The shortcut as the current keyboard layout types it (⌃⌥R on US
    /// English; the same physical key shows its own letter on AZERTY or Dvorak).
    static func displayString(_ combo: HotKeyCombo) -> String {
        combo.displayString(keyLabel: keyLabel)
    }

    /// The character `keyCode` types without modifiers in the current layout.
    static func keyLabel(_ keyCode: UInt32) -> String? {
        // Input methods (Japanese, Chinese…) have no key layout of their own:
        // fall back to the ASCII-capable layout they type with.
        let sources = [TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                       TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()].compactMap { $0 }
        guard let raw = sources.lazy.compactMap({ TISGetInputSourceProperty($0, kTISPropertyUnicodeKeyLayoutData) }).first
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
