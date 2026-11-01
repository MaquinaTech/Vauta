// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// Several meetings chosen in the Meetings list (⌘- or ⇧-click): what can be done to all of them at once.
extension MeetingsModel {
    /// More than one meeting is chosen: the detail shows how many instead of a meeting.
    var choosesSeveral: Bool { selection.count > 1 }

    /// The chosen meetings, in the list's order.
    var chosenMeetings: [MeetingStore.Meeting] { meetings.filter { selection.contains($0.id) } }

    /// None of the chosen meetings is being recorded (or was left open by one): they can be deleted together.
    var canDeleteChosen: Bool {
        choosesSeveral && !chosenMeetings.contains { $0.id == activeMeetingID || $0.endedAt == nil }
    }

    /// What the list's selection becomes when the list asks for `chosen`. In Ask the list picks the one meeting a question is
    /// about, so a ⌘-click there moves to the meeting it adds rather than adding it.
    func listSelection(for chosen: Set<Int64>) -> Set<Int64> {
        guard mode == .ask, chosen.count > 1 else { return chosen }
        if let added = chosen.subtracting(selection).first { return [added] }
        return selection.count == 1 ? selection : chosen.min().map { [$0] } ?? chosen
    }

    /// Several chosen meetings are only ever ones the list shows: a filter, a deletion or a purge that hides some takes them
    /// out of the choice, so nothing hidden is deleted with the rest.
    func keepChosenVisible() {
        guard selection.count > 1 else { return }
        let visible = Set(visibleMeetings.map(\.id))
        if !selection.isSubset(of: visible) { selection = selection.intersection(visible) }
    }

    /// Asks to delete the chosen meetings; the confirmation says whether reminders or events Vauta made from them stay.
    func confirmDeleteChosen() {
        guard canDeleteChosen else { return }
        let chosen = chosenMeetings
        Task {
            var keepsCreated = false
            for meeting in chosen where !keepsCreated {
                let kept = (try? await store.createdActionCounts(ofMeeting: meeting.id)) ?? (reminders: 0, events: 0)
                keepsCreated = kept.reminders + kept.events > 0
            }
            pendingDeletion = .meetings(chosen, keepsCreated: keepsCreated)
        }
    }

    /// Deletes the meetings one after the other, as one deletion each would; a failure stops there and says so, and the ones
    /// before it stay deleted. The list then chooses nothing.
    func deleteMeetings(_ ids: [Int64]) async {
        noteActivity()
        draft = nil
        for id in ids {
            do {
                try await store.deleteMeeting(id)
                await llm?.forgetKeptTranscripts(meetingID: id)
            } catch {
                present(String(localized: "Couldn’t delete the meeting", comment: "Alert title"), error)
                break
            }
        }
        selection = []
        await reload()
    }
}
