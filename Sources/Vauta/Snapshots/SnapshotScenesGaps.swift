// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

// The states the other scene files miss: the panel while it opens the store or starts a
// recording, the import sheet while it reads the file or saves, Ask when the model fails or
// nothing can be verified, the minutes bar with no minutes yet or a plain failure, the
// shortcut field listening or refusing a shortcut, and the content of the popovers.

extension SnapshotScenes {
    static var gaps: [SnapshotScene] { panelGaps + sheetGaps + meetingsGaps + settingsGaps + popovers }

    // MARK: Panel

    private static var panelGaps: [SnapshotScene] {
        [
            panelScene("opening") { recorder, _ in recorder.phase = .opening },
            panelScene("starting") { recorder, _ in recorder.phase = .starting },
        ]
    }

    // MARK: Import sheet

    private static var sheetGaps: [SnapshotScene] {
        [
            // The file is still being read: no file card yet.
            sheetScene("import-inspecting", width: 440) { fixture, _ in
                let model = await importer(fixture, phase: .inspecting)
                model.file = nil
                return AnyView(ImportRecordingSheet(model: model))
            },
            sheetScene("import-saving", width: 440) { fixture, _ in
                AnyView(ImportRecordingSheet(model: await importer(fixture, phase: .saving)))
            },
        ]
    }

    // MARK: Meetings

    private static var meetingsGaps: [SnapshotScene] {
        [
            // The model failed and no passage matched: the failure callout and "No passages match".
            meetingsScene("ask-failed") { history, fixture in
                history.mode = .ask
                history.ask.question = fixture.content.askQuestion
                history.ask.answeredQuestion = fixture.content.askQuestion
                history.ask.passages = []
                history.ask.failure = JobErrorCode.server.localizedDescription
            },
            // An answer none of whose claims could be checked: unverified marks and the caution note inside the answer card.
            meetingsScene("ask-unverified") { history, fixture in
                history.mode = .ask
                await prepareAsk(history.ask, fixture)
                if let answer = history.ask.answer {
                    history.ask.answer = VerifiedAnswer(
                        answer: answer.answer,
                        claims: answer.claims.map { .init(id: $0.id, text: $0.text, citations: $0.citations, verified: false) })
                }
            },
            // A finished meeting without minutes: the offer to write them.
            // Nothing of the featured meeting's minutes is drawn: the offer sits above the empty placeholders, not above the model's text.
            meetingsAfterScene("minutes-none", prepare: featured) { history, _ in
                history.jobs = []
                history.cardSource = nil
                history.decisions = []
                history.tasks = []
                history.openQuestions = []
                history.suggestions = []
                if var draft = history.draft {
                    draft.summary = ""
                    draft.topicsText = ""
                    history.draft = draft
                    history.draft?.markSaved(draft.changes)
                }
            },
            // A failure that only needs another try (no model guide).
            meetingsAfterScene("minutes-failed-server", prepare: featured) { history, fixture in
                if let job = await job(fixture, .failed, code: .server) { history.jobs = [job] }
                history.cardSource = nil
            },
        ]
    }

    // MARK: Settings

    private static var settingsGaps: [SnapshotScene] {
        let record = String(localized: "Start or stop recording", comment: "Shortcut name")
        let translation = String(localized: "Turn Live Translation on or off", comment: "Shortcut name")
        return [
            settingsScene("general-hotkey-listening", .general, hotKeys: [record: SnapshotHotKeyState(listening: true)]),
            settingsScene("general-hotkey-refused", .general,
                          hotKeys: [translation: SnapshotHotKeyState(listening: true, problem: HotKeyRules.Issue.inUseByAnotherApp.message)]),
        ]
    }

    // MARK: Popovers (their content, at the popover's own size)

    private static func popoverScene(_ name: String, width: CGFloat, build: @escaping @MainActor (SnapshotFixture) async -> AnyView) -> SnapshotScene {
        SnapshotScene(name: "popover-\(name)", size: CGSize(width: width, height: 200), fitHeight: true, isSheet: true) { fixture in
            _ = await fixture.makeRecorder()
            let view = await build(fixture)
            return .init(view: AnyView(view.background(Color(nsColor: .windowBackgroundColor))))
        }
    }

    private static var popovers: [SnapshotScene] {
        [
            // Settings → Recording → Add Language…
            popoverScene("speech-languages", width: 280) { fixture in
                let speech = fixture.settings.speech
                await speech.refresh()
                return AnyView(LanguageChoiceList(choices: speech.languagesToAdd.map { .init(id: $0.id, name: $0.displayName) }) { _ in })
            },
            // Settings → Translation → Add Language…
            popoverScene("translation-languages", width: 280) { fixture in
                let targets = fixture.captionSample.targets.filter { $0.availability != .installed }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                return AnyView(LanguageChoiceList(choices: targets.map { .init(id: $0.id, name: $0.name) }) { _ in })
            },
            // Network Activity → the info button.
            popoverScene("network-about", width: 420) { _ in AnyView(NetworkAboutNote()) },
            // A task's due date → the calendar (a fixed date, so every round shows the same month).
            popoverScene("due-date", width: 320) { _ in
                let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 16)) ?? AppClock.now
                return AnyView(DueDatePicker(date: .constant(date)).fixedSize())
            },
        ]
    }
}
#endif
