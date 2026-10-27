// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The panel's Follow-up card after a meeting. It keeps only identifiers, counts and a time; nothing in it can create
/// anything, and while Meetings are locked it shows no counts and no titles.
extension RecorderModel {
    /// The card as the panel draws it now.
    var followUpCard: FollowUpCard.Content {
        _ = followUpTick
        return FollowUpCard.content(followUpPending, now: AppClock.now, recording: phase != .idle || isRecording, enabled: preferences.actions.followUpCardEnabled)
    }

    /// The minutes of a recorded meeting are ready: look for the follow-up meetings (never while recording) and remember what there is
    /// to review. An imported recording is not a meeting the person was in, so it gets no card.
    func noteMinutesReady(_ meetingID: Int64) async {
        guard !followUpHandled.contains(meetingID), let store, (try? await store.isImported(meetingID: meetingID)) != true else { return }
        // Only the minutes of a meeting that has just ended: rewriting an old meeting's minutes is not "ready after the meeting".
        guard let ended = (try? await store.meeting(meetingID))?.endedAt, AppClock.now.timeIntervalSince(ended) < FollowUpCard.lifetime else { return }
        let idle = phase == .idle
        if idle, ActionsRelease.followUpDetection { _ = try? await store.detectFollowUps(meetingID) }
        await updatePending(meetingID, detected: idle)
    }

    /// Meetings whose minutes finished during a recording are looked at when it ends.
    func detectDeferredFollowUps() async {
        guard let store else { return }
        for pending in followUpPending where !pending.detected {
            if ActionsRelease.followUpDetection { _ = try? await store.detectFollowUps(pending.meetingID) }
            await updatePending(pending.meetingID, detected: true, readyAt: pending.readyAt)
        }
    }

    private func updatePending(_ meetingID: Int64, detected: Bool, readyAt: Date = .now) async {
        guard let store else { return }
        let tasks = ((try? await store.tasks(meetingID)) ?? []).filter { $0.status == .open }.count
        let followUps = ((try? await store.followUps(meetingID)) ?? []).filter { $0.state == .suggested }.count
        followUpPending.removeAll { $0.meetingID == meetingID }
        followUpPending.append(FollowUpPending(meetingID: meetingID, readyAt: readyAt, tasks: tasks, followUps: followUps, detected: detected))
        scheduleFollowUpExpiry()
    }

    /// The card goes away 2 hours after the newest minutes; the panel is told then.
    private func scheduleFollowUpExpiry() {
        followUpExpiry?.cancel()
        guard let at = FollowUpCard.expiry(followUpPending) else { return }
        followUpExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, at.timeIntervalSinceNow + 1)))
            guard !Task.isCancelled else { return }
            self?.followUpPending.removeAll { $0.readyAt.addingTimeInterval(FollowUpCard.lifetime) < .now }
            self?.followUpTick += 1
        }
    }

    /// Review…: Touch ID or the password if Meetings are locked, then the newest meeting in the Follow-up sheet, with the others to
    /// go through by "Next Meeting".
    func reviewFollowUp() {
        let list = FollowUpCard.visible(followUpPending, now: AppClock.now)
        guard let newest = list.last else { return }
        Task {
            guard await authorizeHistory() else { return }
            let others = list.dropLast().reversed().map(\.meetingID)
            // The sheet offers the others through Next Meeting, so the card goes for all of them.
            let reviewed = Set(list.map(\.meetingID))
            followUpHandled.formUnion(reviewed)
            followUpPending.removeAll { reviewed.contains($0.meetingID) }
            showWindow("meetings")
            history?.requestFollowUpReview(meetingID: newest.meetingID, others: others)
        }
    }

    /// The card's close button: the minutes stay in Meetings, the card goes.
    func dismissFollowUpCard() {
        followUpHandled.formUnion(followUpPending.map(\.meetingID))
        followUpPending = []
        followUpExpiry?.cancel()
    }
}
