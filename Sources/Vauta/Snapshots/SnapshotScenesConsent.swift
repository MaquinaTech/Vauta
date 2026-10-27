// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// Consent helper and old-copy scenes.
extension SnapshotScenes {
    /// The panel while recording, with the consent helper in the given state.
    /// `meetingLanguage` is the language the meeting is spoken in (nil = the interface language).
    private static func consentPanel(_ name: String, meetingLanguage: String? = nil,
                                     otherThan: String? = nil, instead: String? = nil,
                                     _ change: @escaping @MainActor (inout ConsentPrompt) -> Void = { _ in }) -> SnapshotScene {
        panelScene(name) { recorder, fixture in
            recording(recorder, fixture)
            var meetingLanguage = meetingLanguage
            if let otherThan, let instead, fixture.language.hasPrefix(otherThan) { meetingLanguage = instead }
            if let meetingLanguage {
                recorder.recordingLanguage = SnapshotMode.catalog?.language(matching: meetingLanguage)
            }
            var prompt = ConsentPrompt(ConsentNotice.resolve(meetingLocale: meetingLanguage ?? recorder.recordingLanguage?.id ?? fixture.language))
            change(&prompt)
            recorder.consentPrompt = prompt
        }
    }

    private static func leftoversScene(_ name: String, setAside: Int, oldFolder: Bool) -> SnapshotScene {
        settingsScene(name, .status, size: CGSize(width: 1020, height: 760)) { _, fixture in
            try? fixture.world.stageLeftovers(setAside: setAside, oldFolder: oldFolder)
        }
    }

    static var consent: [SnapshotScene] {
        [
            consentPanel("consent"),
            // A meeting in another language than the interface: the notice is written for the others.
            // (German is the other language, except in the German interface, where it is French.)
            consentPanel("consent-other-language", meetingLanguage: "de-DE", otherThan: "de", instead: "fr-FR"),
            consentPanel("consent-copied") { $0.copied = true },
            // A fixed sample time, so the image is the same on every run.
            consentPanel("consent-informed") { $0.informedAt = Calendar.current.date(bySettingHour: 9, minute: 52, second: 0, of: AppClock.now) },
            // A meeting where the user has not marked the participants as informed: no line in the header.
            meetingsAfterScene("summary-not-informed", prepare: { history, fixture in
                history.selectedID = fixture.world.meetingIDs[1]
                await history.loadDetail()
            }, apply: { _, _ in }),
            leftoversScene("status-leftovers", setAside: 2, oldFolder: false),
            leftoversScene("status-leftovers-old-folder", setAside: 0, oldFolder: true),
            leftoversScene("status-leftovers-both", setAside: 2, oldFolder: true),
        ]
    }
}
#endif
