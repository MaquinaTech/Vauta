// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

/// Long-content states of the Meetings window: a title and minutes far longer than the layout expects.
/// The title comes from the per-language sample content. The text is only on screen (the store is not changed), so the scenes that follow are not affected.
extension SnapshotScenes {
    static var longContent: [SnapshotScene] {
        [
            meetingsAfterScene("long-title", prepare: { history, fixture in
                history.selectedID = fixture.world.featuredMeetingID
                await history.loadDetail()
            }, apply: { history, fixture in
                let id = fixture.world.featuredMeetingID
                // In the language being rendered, so the header and sidebar truncation is checked per script (CJK included).
                let longTitle = BriefSample.forLanguage(fixture.language).longTitle
                if let index = history.meetings.firstIndex(where: { $0.id == id }) {
                    let old = history.meetings[index]
                    history.meetings[index] = MeetingStore.Meeting(id: old.id, startedAt: old.startedAt, endedAt: old.endedAt, title: longTitle,
                                                                   locale: old.locale, outputLocale: old.outputLocale, sourceApp: old.sourceApp)
                }
                if var draft = history.draft {
                    draft.title = longTitle
                    history.draft = draft
                    history.draft?.markSaved(draft.changes)
                }
            }),
        ]
    }
}
#endif
