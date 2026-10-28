// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import EventKit
import Foundation
import Observation

extension BriefController {
    // MARK: Recording

    var isRecordingNow: Bool { seams?.isRecording?() ?? (recorder?.phase == .recording || recorder?.phase == .starting) }

    /// A recording that takes no linked calendar event can still be the in-person event the card is about: the card's
    /// event, when it has no meeting link and the card is inside the window `BriefRecordingMatch` uses. The recording takes that event as
    /// its calendar event (title, attendees and series, never the invitation's notes), so its attendees and series are saved like those of
    /// a meeting with a link and the next occurrence finds this one.
    func inPersonEventOnCard(at now: Date = .now) -> CalendarEventMatch? {
        guard prefs.enabled, let event = next?.event, event.service == nil, isWithinCard(event, now: now) else { return nil }
        return CalendarEventMatch(meeting: event.calendarMeeting, service: nil, occurrence: event.occurrence)
    }

    func inPersonOccurrenceOnCard(at now: Date = .now) -> BriefOccurrence? { inPersonEventOnCard(at: now)?.occurrence }

    /// A recording starts. When the event on screen is the one it takes (the same occurrence of the same event), the meeting keeps that
    /// brief when it ends, whether Meetings were unlocked then or not. A recording that takes no calendar event never carries one.
    func recordingStarted(recordingOccurrence: BriefOccurrence?) {
        removalTask?.cancel()
        recorder?.withdrawBriefNotification()
        armedTask?.cancel()
        armed = nil
        attachmentTask?.cancel()
        attachment = nil
        recordingBrief = nil
        recordingRun += 1
        guard prefs.enabled, let entry = next,
              BriefRecordingMatch.matches(entry.event.occurrence, at: .now, leadMinutes: prefs.leadMinutes, recordingOccurrence: recordingOccurrence)
        else { return }
        if !isLocked, let snapshot = entry.snapshot {
            keep(snapshot, showing: true)
            return
        }
        // Locked (the usual state): the deterministic brief is built anyway, with no model, no cache and nothing shown. Only its
        // references are kept, and the row appears when Meetings are unlocked.
        let occurrence = entry.event.occurrence
        let run = recordingRun
        attachmentTask = Task { [weak self] in
            guard let self, let snapshot = await self.snapshotForRecording(occurrence), !Task.isCancelled, self.recordingRun == run,
                  self.isRecordingNow else { return }
            self.keep(snapshot, showing: !self.isLocked)
        }
    }

    private func keep(_ snapshot: BriefSnapshot, showing: Bool) {
        if showing { recordingBrief = snapshot }
        guard snapshot.hasContent else { return }
        attachment = Attachment(references: BriefStoredReferences(snapshot: snapshot), occurrence: snapshot.occurrence, title: snapshot.title,
                                start: snapshot.start, end: snapshot.end, service: snapshot.service, recordedAt: .now)
    }

    /// The event of the occurrence is read again in full (the locked card holds only its title and time) and its brief built from the
    /// store alone.
    private func snapshotForRecording(_ occurrence: BriefOccurrence) async -> BriefSnapshot? {
        guard canRead, let source = activeSource else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(occurrence.startSeconds))
        let events = await source.events(from: start.addingTimeInterval(-1), to: start.addingTimeInterval(1), calendarIDs: selectedCalendars, matching: [occurrence])
        guard let event = events.first(where: { $0.occurrence == occurrence }) else { return nil }
        let entry: Entry
        if let build = seams?.build { entry = await build(event, false) } else { entry = await build(event, force: false, deterministic: true) }
        return entry.snapshot
    }

    /// The recording ended and the meeting was saved: its brief is stored with it (references and the verified agenda only).
    func recordingEnded(meetingID: Int64?) async {
        await attachmentTask?.value
        let held = attachment
        defer {
            resumePausedAgendas()
            recordingBrief = nil
            attachment = nil
            attachmentTask = nil
        }
        guard let meetingID, let held else { return }
        if let save = seams?.saveBrief {
            await save(held.references, meetingID, held.recordedAt)
        } else if let store = recorder?.store {
            try? await store.saveBrief(held.references, for: meetingID, at: held.recordedAt)
        } else {
            return
        }
        await cache.invalidate(.occurrence(held.occurrence))
        next = nil
        refreshNext()
    }

    /// The recording was discarded (nothing recorded): the brief is not kept.
    func recordingDiscarded() {
        resumePausedAgendas()
        attachmentTask?.cancel()
        recordingRun += 1
        recordingBrief = nil
        attachment = nil
    }
}
