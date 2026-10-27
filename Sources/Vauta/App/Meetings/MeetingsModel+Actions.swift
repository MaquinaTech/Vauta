// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The Follow-up sheet and what leads to it.
extension MeetingsModel {
    /// ⇧⌘U, File › Follow Up… and the toolbar button: the sheet needs a meeting that is not being recorded and that has minutes (or tasks
    /// written by hand) to follow up. ⇧⌘U is free in Meetings and the menu bar (`ActionsScanTests`).
    var canOpenFollowUp: Bool { mode == .meetings && shownMeeting != nil && !isActive && (cardSource != nil || !tasks.isEmpty) }

    func openFollowUp() {
        guard canOpenFollowUp, let id = shownMeeting?.id else { return }
        noteActivity()
        Task { await actions.openFollowUp(meetingID: id) }
    }

    /// The panel's card: Review… opens the meeting (the newest one, with the others to go through) in the Follow-up sheet.
    func reviewFollowUp(meetingID: Int64, others: [Int64]) async {
        mode = .meetings
        showingUpcoming = false
        selectedID = meetingID
        await loadDetail()
        guard selectedID == meetingID, !isActive else { return }
        await actions.openFollowUp(meetingID: meetingID, others: others)
    }

    /// Review… in the panel: now if the window is showing, else when it has loaded.
    func requestFollowUpReview(meetingID: Int64, others: [Int64]) {
        if isShowing {
            Task { await reviewFollowUp(meetingID: meetingID, others: others) }
        } else {
            pendingFollowUpReview = (meetingID, others)
        }
    }

    func consumePendingFollowUpReview() async {
        guard let review = pendingFollowUpReview else { return }
        pendingFollowUpReview = nil
        await reviewFollowUp(meetingID: review.meetingID, others: review.others)
    }

    /// "Show in Transcript" in the reminder editor: the draft stays; the sheet steps aside.
    func showInTranscript(_ task: TaskItem) {
        guard let meeting = task.meetingID else { return }
        actions.page = nil
        if let segment = task.segmentID { open(meeting: meeting, segment: segment) } else if let t = task.t { open(meeting: meeting, at: t) } else { open(meeting: meeting) }
    }
}

extension ActionsModel {
    /// The sheet was dismissed by the system (not by Cancel or Done): an editor keeps its draft; the Follow-up sheet is closed.
    func dismissedExternally() {
        if page == .followUp { closeSheet() } else { page = nil }
    }
}
