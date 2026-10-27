// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import AppKit
import SwiftUI

/// Menu-bar panel states that need the store (names, marks, notes), shortcut conflicts, and the menu-bar icon.
extension SnapshotScenes {
    /// Like `panelScene`, with a configuration that can read the sample store.
    /// `focusing` is the text of the field being edited: it gets the keyboard focus (and its ring), like in real use.
    static func storePanelScene(_ name: String, focusing: ((RecorderModel) -> String)? = nil,
                                        configure: @escaping @MainActor (RecorderModel, SnapshotFixture) async -> Void) -> SnapshotScene {
        SnapshotScene(name: "panel-\(name)", size: panelSize, fitHeight: true, isPanel: true) { fixture in
            let recorder = await fixture.makeRecorder()
            await configure(recorder, fixture)
            let view = RecorderPanel(model: recorder)
                .environment(\.panelMaxHeight, airPanelHeight)
                .background(Color(nsColor: .windowBackgroundColor))
            return .init(view: AnyView(view), after: {
                guard let focusing else { return }
                focusField(containing: focusing(recorder))
            })
        }
    }

    /// Moves the keyboard focus of our own snapshot window to the text field that holds `text`
    /// (inside the window only: it never activates the app or takes the keyboard from another one).
    private static func focusField(containing text: String) {
        func find(in view: NSView) -> NoCopyTextView? {
            if let field = view as? NoCopyTextView, field.string == text { return field }
            for sub in view.subviews { if let found = find(in: sub) { return found } }
            return nil
        }
        for window in NSApp.windows {
            if let root = window.contentView, let field = find(in: root) {
                window.makeFirstResponder(field)
                return
            }
        }
    }

    static func people(_ fixture: SnapshotFixture) async -> [Entity] {
        (try? await fixture.world.store.entities(.person)) ?? []
    }

    static var panelCoverage: [SnapshotScene] {
        [
            // The shortcuts that Live Translation and Mark a Moment could not register.
            storePanelScene("hotkey-taken-translation") { recorder, fixture in
                recording(recorder, fixture)
                recorder.translationHotKeyAvailable = false
            },
            storePanelScene("hotkey-taken-mark") { recorder, fixture in
                recording(recorder, fixture)
                recorder.markHotKeyAvailable = false
            },
            // Marks counted, the last quick notes, and who "Others" is (named chips and attendee chips).
            storePanelScene("recording-others-named") { recorder, fixture in
                recording(recorder, fixture)
                let people = await people(fixture)
                recorder.marks = (0..<3).map { MeetingMark(id: Int64($0 + 1), meetingID: 1, t: Double($0) * 90 + 40) }
                recorder.notepad.rows = [
                    NoteRow(note: MeetingNote(id: 1, meetingID: 1, t: 95, text: fixture.content.livePoints.first ?? "Beta build is stable"), expansion: nil),
                    NoteRow(note: MeetingNote(id: 2, meetingID: 1, t: 310, text: fixture.content.liveTasks.first ?? "Write the release notes"), expansion: nil),
                ]
                // Real participants: "Me" is never named as one of the others.
                let others = people.filter { !$0.isSelf }
                recorder.othersNamed = Array(others.prefix(1))
                recorder.attendees = Array(others.prefix(4))
            },
            // Typing a name nobody has yet: the way to add a person.
            // The query is the start of a localized person's name, so every language shows a suggestion.
            storePanelScene("recording-others-query", focusing: { $0.othersQuery }) { recorder, fixture in
                recording(recorder, fixture)
                let people = await people(fixture)
                let query = String(people.first { !$0.isSelf }?.displayName.prefix(2) ?? "Ma")
                recorder.othersQuery = query
                recorder.othersHits = people.filter { !$0.isSelf }.prefix(2).map { NameHit(target: .entity($0.id), text: $0.displayName) }
                recorder.othersHitsQuery = query
            },
            // The typed name is the user's own: the text stays and the field says why nothing was added.
            storePanelScene("recording-others-self", focusing: { $0.othersQuery }) { recorder, fixture in
                recording(recorder, fixture)
                recorder.othersQuery = Channel.me.displayName
                recorder.othersNotice = String(localized: "“\(Channel.me.displayName)” is always you. Name the other participants here.",
                                               comment: "Hint under the name field of the other participants when the user typed their own name; the argument is the channel name (Me)")
            },
            // The model could not take live notes.
            storePanelScene("recording-notes-error") { recorder, fixture in
                recording(recorder, fixture)
                recorder.livePoints = fixture.content.livePoints
                recorder.liveNotesError = RecorderModel.liveNotesNotice(for: LLMError.network(from: URLError(.timedOut)))
            },
            // Live Translation is on but there is no language to translate into yet.
            storePanelScene("translation-no-target") { recorder, fixture in
                recorder.liveTranslation.installSnapshotEnabledIdle()
                recorder.liveTranslation.installSnapshotNoTarget()
                recorder.preferences.transcriptionLanguage = SnapshotMode.catalog?.language(matching: fixture.captionSample.pair.source.minimalIdentifier)?.id
            },
            menuBarStates,
        ]
    }

    /// Every state of the menu-bar icon, on a strip like the menu bar, with what VoiceOver says about it beside it (in the language of the render).
    private static var menuBarStates: SnapshotScene {
        SnapshotScene(name: "menubar-states", size: CGSize(width: 460, height: 480), fitHeight: true, isFloating: true) { fixture in
            var rows: [(String, RecorderModel)] = []
            @MainActor func row(_ name: String, _ change: @MainActor (RecorderModel) -> Void) async {
                let recorder = await fixture.makeRecorder()
                change(recorder)
                rows.append((name, recorder))
            }
            await row("Idle") { _ in }
            await row("Idle, a meeting can be recorded") { recorder in
                let call = CallDescription(appName: fixture.content.callApp, family: .zoom, service: nil)
                recorder.suggestion = RecordingSuggestion(event: nil, call: call)
            }
            await row("Idle, with notices") { recorder in
                recorder.lastStopReason = .sleep
                recorder.nothingRecorded = true
            }
            await row("Idle, needs attention") { $0.lastError = "x" }
            await row("Starting or saving") { $0.phase = .starting }
            await row("Recording") { recorder in
                recorder.phase = .recording
                recorder.elapsedSeconds = 754
            }
            await row("Recording, warning") { recorder in
                recorder.phase = .recording
                recorder.elapsedSeconds = 754
                recorder.silenceWarning = SilenceNotice(title: "x", detail: "x")
            }
            await row("Recording, stopping soon") { recorder in
                recorder.phase = .recording
                recorder.elapsedSeconds = 754
                recorder.autoStopRemaining = 90
            }
            await row("Recording, stopping soon, warning") { recorder in
                recorder.phase = .recording
                recorder.elapsedSeconds = 754
                recorder.autoStopRemaining = 90
                recorder.silenceWarning = SilenceNotice(title: "x", detail: "x")
            }
            await row("Restoring a backup") { $0.isRestoring = true }
            await row("Erasing everything") { $0.isErasing = true }
            await row("Failed") { $0.phase = .failed("x") }
            let preferences = fixture.preferences
            let view = VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 14) {
                        MenuBarLabel(model: item.1, preferences: preferences)
                            .font(.system(size: 14))
                            .frame(minWidth: 70, minHeight: 24)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        Text(verbatim: MenuBarLabel(model: item.1, preferences: preferences).accessibilityValue).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(width: 460, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
            return .init(view: AnyView(view))
        }
    }
}
#endif
