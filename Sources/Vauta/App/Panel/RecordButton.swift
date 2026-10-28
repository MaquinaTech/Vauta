// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The big record/stop button, its state line and the shortcut hint.
struct RecordButton: View {
    let model: RecorderModel
    /// Another call to action (a suggestion to record) is on screen and does the same thing: this one steps back.
    var isMuted = false
    @FocusState private var focused: Bool
    @Environment(\.colorSchemeContrast) private var systemContrast
    private var contrast: ColorSchemeContrast { systemContrast.snapshotResolved }

    var body: some View {
        VStack(spacing: 8) {
            // Not `.disabled` while busy: the system would grey the whole button, spinner included.
            Button { pressed() } label: {
                ZStack {
                    VautaOrb(mode: orbMode, diameter: isMuted ? 56 : 64, level: model.isRecording ? loudest : 0,
                             outlined: blocked && contrast == .increased)
                    if model.isBusy || restoringNow {
                        // Restoring or erasing is as long a wait as saving: the same working spinner.
                        BusyArc()
                    } else {
                        Image(systemName: model.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            .buttonStyle(OrbPressStyle())
            // Without Full Keyboard Access Tab skips buttons: Return starts or stops from the open panel (plain style, no default-button look).
            .keyboardShortcut(model.isBusy || restoringNow ? nil : KeyboardShortcut(.return, modifiers: []))
            .frame(width: 64, height: 64)
            // The system ring would follow the square frame: the button draws its own, round like the disc.
            .contentShape(Circle())
            .focusEffectDisabled()
            .focused($focused)
            .overlay {
                if focused {
                    Circle()
                        // The system's own focus colour (opaque with Increase Contrast, the system's alpha otherwise).
                        .strokeBorder(Color(nsColor: contrast == .increased ? NSColor.keyboardFocusIndicatorColor.withAlphaComponent(1)
                                            : NSColor.keyboardFocusIndicatorColor), lineWidth: 3)
                        .frame(width: (isMuted ? 56 : 64) + 8, height: (isMuted ? 56 : 64) + 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // While Vauta is busy the name says what is going on, not an action that would do nothing.
            .accessibilityLabel(model.isBusy || restoringNow ? Text(verbatim: statusText) : model.isRecording ? Text("Stop Recording") : Text("Start Recording"))
            .accessibilityRemoveTraits(model.isBusy || restoringNow ? .isButton : [])
            .accessibilityValue(Text(verbatim: accessibilityValue))
            // The shortcut is only advertised while it works: another app may hold it.
            .accessibilityHint(Text(verbatim: accessibilityHint))
            .help(helpText)
            // Room for the orbit and the rings around the sphere, so they never run into the rows above and below.
            .padding(.vertical, 10)

            if model.isRecording {
                Text(verbatim: model.elapsed)
                    .font(.system(.title2, design: .rounded).weight(.medium).monospacedDigit())
                    .contentTransition(.numericText())
                    .accessibilityLabel(Text("Elapsed time"))
                    .accessibilityValue(Text(verbatim: ElapsedTime.spoken(model.elapsedSeconds)))
            } else {
                Text(verbatim: statusText)
                    .font(.callout)
                    // Primary while the button can be used; secondary while Vauta is busy or the button is disabled.
                    .foregroundStyle(model.isBusy || blocked ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    // The button's name already says it (the action, or the state while busy): VoiceOver doesn't need the same words twice.
                    .accessibilityHidden(true)
            }
            hotKeyHint
        }
    }

    private var restoringNow: Bool { model.isReplacingData && !model.isRecording }

    private var helpText: Text {
        // Both the press and the shortcut are refused while the data is replaced: the tooltip says why.
        if restoringNow, let reason = PanelUnavailable.reason(for: model) { return Text(verbatim: reason) }
        if model.hotKeyAvailable {
            return model.isRecording ? Text("Stop and save (\(model.recordHotKeyText))") : Text("Start recording (\(model.recordHotKeyText))")
        }
        return model.isRecording ? Text("Stop and save") : Text("Start recording")
    }

    /// A press while busy changes nothing and says so (the alert sound and, for VoiceOver, the state in words).
    private func pressed() {
        guard model.isBusy || (model.isReplacingData && !model.isRecording) else {
            model.toggle()
            return
        }
        NSSound.beep()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: statusText, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The shortcut hint. It wraps instead of being cut, and uses the readable secondary style.
    @ViewBuilder private var hotKeyHint: some View {
        if model.isRecording {
            if model.hotKeyAvailable {
                Text("\(model.recordHotKeyText) to stop")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if model.isBusy || model.isReplacingData || model.missingModel != nil || (blocked && model.hotKeyAvailable) {
            // The shortcut does not work either while a permission is missing: nothing advertises it.
            EmptyView()
        } else if model.hotKeyAvailable {
            Text("\(model.recordHotKeyText) in any app")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HotKeyConflictHint(text: model.recordHotKeyText) { model.showSettings(.general) }
        }
    }

    /// A permission is missing, or the encrypted store could not be opened (a recording cannot start without it): the
    /// button stays available (to try again after the fix) but looks secondary, because the fix comes first.
    private var blocked: Bool {
        (model.permissionProblem != nil || (!model.storeAvailable && model.phase != .opening) || model.isReplacingData) && !model.isRecording
    }

    private var orbMode: VautaOrb.Mode {
        // While Vauta starts, saves, restores or erases, the orbit spins and the white spinner sits on the sphere.
        if model.isBusy || restoringNow { return .working }
        // Opaque, so the white glyph reads (4.5:1); it still looks quieter than the coloured button.
        if blocked { return .blocked(Self.blockedGrey) }
        // Stepping back is not being disabled: the button stays fully opaque (smaller, no glow, no orbit).
        if isMuted { return .muted }
        return model.isRecording ? .listening : .idle
    }

    /// The loudest channel, for the glow of the button while recording.
    private var loudest: Double { min(1, max(model.levels[.me] ?? 0, model.levels[.others] ?? 0)) }

    /// An opaque grey for each appearance (the system's secondary label is translucent and resolves light in both):
    /// white on #6E6E73 is 5.1:1 and on #636366 is 5.9:1, so the glyph passes 4.5:1.
    private static let blockedGrey = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x63 / 255, green: 0x63 / 255, blue: 0x66 / 255, alpha: 1)
            : NSColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1)
    })

    private var statusText: String {
        switch model.phase {
        case .opening: String(localized: "Opening your data…", comment: "Record button state while the store of meetings is being opened")
        case .starting: String(localized: "Starting…", comment: "Record button state")
        case .stopping: String(localized: "Saving the meeting…", comment: "Record button state while the transcript is saved")
        case _ where model.isErasing: String(localized: "Erasing your data…", comment: "Record button state while Erase Everything runs")
        case _ where model.isRestoring: String(localized: "Restoring your data…", comment: "Record button state while a backup is restored; parallel to “Erasing your data…” (a restore replaces the meetings and the context)")
        default: String(localized: "Start Recording", comment: "Caption under the record button: the visible name of the main action (title case in English like the other panel actions)")
        }
    }

    /// Why the button is secondary while the fix comes first; otherwise the shortcut, when it works.
    private var accessibilityHint: String {
        if blocked, !model.isBusy {
            if case .failed(let message) = model.phase { return message }
            if let reason = PanelUnavailable.reason(for: model) { return reason }
        }
        guard model.hotKeyAvailable, !model.isBusy, !restoringNow else { return "" }
        return String(localized: "Shortcut: \(model.recordHotKeyText)")
    }

    private var accessibilityValue: String {
        switch model.phase {
        // "Recording" alone is also the name of a Settings pane; a state needs its own key.
        case .recording: String(localized: "state.recording", defaultValue: "Recording",
                                comment: "State: a meeting is being recorded right now (not the Settings pane)")
        // While busy the name already says what is going on; repeating it as the value would read twice.
        case .starting, .stopping, .opening: ""
        case _ where restoringNow: ""
        default: String(localized: "Not recording", comment: "Record button state for VoiceOver")
        }
    }
}

/// The record button gives a little under the pointer, like a physical key (not with Reduce Motion).
private struct OrbPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// The spinner on the record button while Vauta is busy: one solid white arc, readable on the red and blue discs
/// (the system spinner's fading ticks are pale on them). It keeps turning, slowly, with Reduce Motion: a still arc would look stuck.
private struct BusyArc: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewLocalState private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(.white, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            .frame(width: 26, height: 26)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: reduceMotion ? 1.8 : 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

/// "⌃⌥R is used by another app. Change Shortcut": the shortcut didn't register, so the way to fix it is right
/// there. The sentence and the button sit on one line when they fit; otherwise the button goes under the text (a
/// real button, so Tab and Full Keyboard Access reach it). The icon has its own column, so a second line hangs
/// under the text, not under the icon.
struct HotKeyConflictHint: View {
    let text: String
    /// Under the record button the hint is centred; inside a card it follows the card's leading edge.
    var alignment: HorizontalAlignment = .center
    let change: () -> Void

    var body: some View {
        panelBody
    }

    private var panelBody: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                StatusSymbol.warning.image
                HStack(alignment: .firstTextBaseline, spacing: gap) {
                    sentence.fixedSize()
                    changeButton
                }
            }
            VStack(alignment: alignment, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    StatusSymbol.warning.image
                    sentence
                        .multilineTextAlignment(alignment == .center ? .center : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                changeButton
                    .padding(.leading, alignment == .center ? 0 : PanelMetrics.hintTextIndent)
            }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
        .accessibilityElement(children: .contain)
    }

    /// Between the sentence and the button: a space (8 pt in Japanese and Chinese, where the full-width stop
    /// sits against the button's edge).
    private var gap: CGFloat {
        let sentence = String(localized: "\(text) is used by another app.")
        let unspaced = sentence.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }
        // Japanese and Chinese: the full stop leaves no visible gap before a bordered button, so they get a clear one.
        return unspaced || "。！？".contains(sentence.last ?? " ") ? 8 : 4
    }

    private var sentence: Text {
        Text(String(localized: "\(text) is used by another app.")).foregroundStyle(.secondary)
    }

    private var changeButton: some View {
        // A real small button, like every other action in the panel (inline links are not used for actions).
        Button(String(localized: "Change Shortcut"), action: change)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .lineLimit(1)
            .fixedSize()
    }
}
