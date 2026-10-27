// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The notification before a meeting and its two buttons. The notification names the event only when titles may be shown in
/// notifications, and never carries anything from the brief.
extension BriefController {
    /// The settings `CalendarWatcher` schedules the wake-up with; nil when no notification goes out.
    func wakePlan() -> BriefWakePlan? {
        let value = prefs.snapshot
        guard value.notifies else { return nil }
        return BriefWakePlan(leadMinutes: value.leadMinutes, ledger: ledger)
    }

    /// The moment of a notification came. The occurrences are marked first (synchronously), so none is due twice; then the event is
    /// read in full, its brief built, and the notification sent only if the brief has something in it.
    func briefDue(_ due: [BriefOccurrence]) {
        let now = Date.now
        for occurrence in due { ledger.markSent(occurrence, at: now) }
        Task { await notify(due) }
    }

    private func notify(_ due: [BriefOccurrence]) async {
        guard canRead, let eventSource, let recorder, recorder.phase != .recording, recorder.phase != .starting else { return }
        let now = Date.now
        let lead = prefs.leadMinutes
        let calendars = recorder.calendar.selected
        _ = rules
        // Only the due occurrences are asked for: meetings already in progress cannot crowd them out of the reader's two slots.
        let events = await eventSource.events(from: now.addingTimeInterval(-BriefEventSelector.lateGrace), to: now.addingTimeInterval(Double(lead + 2) * 60),
                                              calendarIDs: calendars, matching: Set(due))
        guard let event = events.first(where: { due.contains($0.occurrence) }) else { return }
        let remaining = event.start.timeIntervalSince(now)
        // Less than a minute and a half left: the card in the panel is enough.
        guard remaining >= 90 else { return }
        let entry = await build(event, force: false)
        guard let snapshot = entry.snapshot, snapshot.hasContent else { return }
        let minutes = Int((remaining / 60).rounded())
        recorder.post(.brief(minutesBefore: minutes, eventTitle: recorder.calendar.showTitleInNotifications ? event.title : nil, occurrence: event.occurrence))
        lastNotified = BriefController.withoutNotes(event)
        removalTask?.cancel()
        let start = event.start
        removalTask = Task { [weak recorder] in
            try? await Task.sleep(for: .seconds(max(1, start.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            recorder?.withdrawBriefNotification()
        }
        refreshNext()
    }

    static func withoutNotes(_ event: BriefEvent) -> BriefEvent {
        BriefEvent(identifier: event.identifier, title: event.title, start: event.start, end: event.end, calendarID: event.calendarID,
                   isAllDay: false, currentUserDeclined: false, attendees: event.attendees, isRecurring: event.isRecurring, service: event.service,
                   eventIdentifier: event.eventIdentifier)
    }

    // MARK: Buttons

    /// "Open Brief": asks for Touch ID, then shows Upcoming.
    func openBrief() {
        guard let recorder else { return }
        Task {
            guard await recorder.authorizeHistory() else { return }
            recorder.history?.showUpcoming()
            await recorder.openMeeting(nil)
        }
    }

    /// "Record at Start": a one-shot suggestion when the meeting starts. It never records by itself. After a relaunch the notification
    /// still names the occurrence, and the event is read again.
    func armRecordAtStart(occurrence: BriefOccurrence? = nil) {
        Task { [weak self] in
            guard let self, let event = await self.eventToArm(occurrence) else { return }
            self.arm(event)
        }
    }

    func eventToArm(_ occurrence: BriefOccurrence?) async -> BriefEvent? {
        if let last = lastNotified, occurrence == nil || last.occurrence == occurrence { return last }
        guard let occurrence, let source = activeSource else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(occurrence.startSeconds))
        let events = await source.events(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(1), calendarIDs: selectedCalendars, matching: [occurrence])
        guard let event = events.first(where: { $0.occurrence == occurrence }) else { return nil }
        return BriefController.withoutNotes(event)
    }

    /// Takes back "Record at Start": nothing is suggested when the meeting starts.
    func cancelArmed() {
        armedTask?.cancel()
        armedTask = nil
        armed = nil
    }

    private func arm(_ event: BriefEvent) {
        let start = event.start
        // Pressed long after the meeting began: there is nothing to remind.
        guard start.timeIntervalSinceNow > -BriefEventSelector.lateGrace else { return }
        armedTask?.cancel()
        armed = event.occurrence
        lastNotified = event
        armedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, start.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.armed == event.occurrence else { return }
            self.armed = nil
            self.recorder?.suggestScheduled(event)
        }
    }
}
