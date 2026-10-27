// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Helpers for the shortcut fields. Labels follow the current keyboard
/// layout (⌃⌥R on QWERTY; the same key shows its own character on AZERTY or
/// Dvorak), as everywhere else in Vauta (`GlobalHotKey.displayString`).
@MainActor
enum HotKeyFormatter {
    static func display(_ spec: Preferences.HotKeySpec) -> String {
        GlobalHotKey.displayString(spec)
    }

    /// Carbon modifier mask of AppKit modifier flags.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= HotKeyRules.command }
        if flags.contains(.shift) { mods |= HotKeyRules.shift }
        if flags.contains(.option) { mods |= HotKeyRules.option }
        if flags.contains(.control) { mods |= HotKeyRules.control }
        return mods
    }

    /// Whether another app has registered the shortcut: registers it briefly
    /// under a probe id and releases it at once.
    static func isFree(_ spec: Preferences.HotKeySpec) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, EventHotKeyID(signature: 0x4143_5450 /* 'ACTP' */, id: 99),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        UnregisterEventHotKey(ref)
        return true
    }
}

/// A shortcut field: click it, type the new shortcut, or press Esc to cancel.
/// Vauta's own shortcuts are paused while it listens, so typing the current
/// record shortcut doesn't start a recording.
struct HotKeyRecorder: View {
    let recorder: RecorderModel
    let label: String
    @Binding var spec: Preferences.HotKeySpec
    /// Vauta's other shortcuts (they must all differ).
    let others: [Preferences.HotKeySpec]
    let defaultSpec: Preferences.HotKeySpec

    @ViewLocalState private var recording = false
    @ViewLocalState private var problem: String?
    @ViewLocalState private var monitor: Any?
    @AccessibilityFocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        LabeledContent(label) {
                HStack(spacing: 6) {
                    // Before the field, so the field ends on the same edge as the other trailing controls
                    // (the button is always laid out, so a customized row's field doesn't move left of the others).
                    Button {
                        // The other shortcut may have taken this default meanwhile.
                        problem = others.contains(defaultSpec) ? HotKeyRules.Issue.sameAsOther.message : nil
                        if problem == nil { spec = defaultSpec }
                        // The button hides itself now: say what happened and keep VoiceOver on the shortcut field.
                        fieldFocused = true
                        if let problem {
                            AccessibilityNotification.Announcement(problem).post()
                        } else {
                            let shortcut = HotKeyFormatter.display(defaultSpec)
                            AccessibilityNotification.Announcement(String(localized: "Shortcut changed to \(shortcut)", comment: "VoiceOver announcement; the argument is a keyboard shortcut")).post()
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help(String(localized: "Restore the default shortcut", comment: "Shortcut recorder reset button"))
                    .accessibilityLabel(String(localized: "Restore Default Shortcut", comment: "Accessibility label of the shortcut recorder's reset button"))
                    .opacity(spec == defaultSpec ? 0 : 1)
                    .disabled(spec == defaultSpec)
                    .accessibilityHidden(spec == defaultSpec)
                    Button { recording ? stop() : start() } label: {
                        // Sized by the wider of the prompt and the shortcut, so its row never reflows and neither is cut off.
                        ZStack {
                            Text(prompt).hidden()
                            Text(listening ? prompt : display)
                        }
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(minWidth: 124)
                    }
                    // Listening is drawn: an accent ring around the field (also while a refusal is shown and it still listens).
                    .overlay {
                        if listening {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .padding(-2)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel(label)
                    .accessibilityValue(listening ? String(localized: "Waiting for a shortcut", comment: "Accessibility value")
                                                  : display)
                    .accessibilityHint(String(localized: "Activate, then type the new shortcut. Press Escape to cancel.", comment: "Accessibility hint"))
                    .accessibilityFocused($fieldFocused)
                }
            }
            // The refusal is its own full-width line under the row, so the label and field stay on one line.
            if let problem = shownProblem {
                NoticeLabel(Text(problem), status: .warning)
            }
        }
        .onDisappear(perform: stop)
        // Listening ends when the window stops being the active one.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private var prompt: String { String(localized: "Type shortcut…", comment: "Shortcut recorder while waiting for keys") }

    /// What the field shows: listening for keys, and the reason a shortcut was refused.
    private var listening: Bool { recording || snapshotState?.listening == true }
    private var shownProblem: String? { problem ?? snapshotState?.problem }

    #if VAUTA_DIAGNOSTICS
    @Environment(\.snapshotHotKeyStates) private var snapshotStates
    private var snapshotState: SnapshotHotKeyState? { snapshotStates[label] }
    #else
    private var snapshotState: SnapshotHotKeyState? { nil }
    #endif

    private static let systemKeys: Set<UInt32> = [UInt32(kVK_ANSI_W), UInt32(kVK_ANSI_Q), UInt32(kVK_ANSI_Comma), UInt32(kVK_ANSI_H), UInt32(kVK_ANSI_M)]

    /// Re-evaluated when the keyboard layout changes.
    private var display: String {
        _ = recorder.keyboardLayoutRevision
        return HotKeyFormatter.display(spec)
    }

    private func start() {
        problem = nil
        recording = true
        recorder.setHotKeysSuspended(true)
        // Local monitors run on the main thread; the typed keys go nowhere else.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { event in
            guard event.type == .keyDown else {
                // A click anywhere else ends listening, after the click itself was handled.
                Task { @MainActor in stop() }
                return event
            }
            // Window and app commands (⌘W, ⌘Q, ⌘, ⌘H, ⌘M) keep working and end listening.
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, Self.systemKeys.contains(UInt32(event.keyCode)) {
                Task { @MainActor in stop() }
                return event
            }
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        // Registers the shortcuts again (the new one if it changed).
        recorder.setHotKeysSuspended(false)
    }

    private func issue(keyCode: UInt32, modifiers: UInt32) -> HotKeyRules.Issue? {
        for other in others {
            if let issue = HotKeyRules.issue(keyCode: keyCode, modifiers: modifiers, other: (other.keyCode, other.modifiers)) { return issue }
        }
        return others.isEmpty ? HotKeyRules.issue(keyCode: keyCode, modifiers: modifiers, other: nil) : nil
    }

    private func handle(_ event: NSEvent) {
        let modifiers = HotKeyFormatter.carbonModifiers(event.modifierFlags)
        let keyCode = UInt32(event.keyCode)
        if keyCode == UInt32(kVK_Escape) && modifiers == 0 {
            stop()
            return
        }
        let candidate = Preferences.HotKeySpec(keyCode: keyCode, modifiers: modifiers)
        // Checked while Vauta's own shortcuts are still paused, so only other
        // apps' registrations count as "in use".
        var accepted = false
        if candidate == spec {
            problem = nil
        } else if let issue = issue(keyCode: keyCode, modifiers: modifiers) {
            problem = issue.message
        } else if !HotKeyFormatter.isFree(candidate) {
            problem = HotKeyRules.Issue.inUseByAnotherApp.message
        } else {
            accepted = true
        }
        if accepted { spec = candidate }
        stop()
        // Focus stays on the button: say what happened (the problem label under the field isn't read by itself).
        if let problem {
            AccessibilityNotification.Announcement(problem).post()
        } else if accepted {
            let shortcut = HotKeyFormatter.display(candidate)
            AccessibilityNotification.Announcement(String(localized: "Shortcut changed to \(shortcut)", comment: "VoiceOver announcement; the argument is a keyboard shortcut")).post()
        }
    }
}

/// A shortcut field's state drawn by the snapshot renderer (it never listens to the keyboard).
struct SnapshotHotKeyState: Sendable {
    var listening = false
    var problem: String?
}

#if VAUTA_DIAGNOSTICS
private struct SnapshotHotKeyStatesKey: EnvironmentKey { static let defaultValue: [String: SnapshotHotKeyState] = [:] }

extension EnvironmentValues {
    /// Per shortcut name: the state its field shows in a snapshot.
    var snapshotHotKeyStates: [String: SnapshotHotKeyState] {
        get { self[SnapshotHotKeyStatesKey.self] }
        set { self[SnapshotHotKeyStatesKey.self] = newValue }
    }
}
#endif
