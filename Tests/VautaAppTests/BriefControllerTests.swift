// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// A calendar read that waits until the test lets it go, so loads can be interleaved.
actor BriefLoadGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        isOpen = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

struct BriefGatedSource: BriefEventSource {
    let gate: BriefLoadGate?
    let events: [BriefEvent]
    func events(from: Date, to: Date, calendarIDs: Set<String>) async -> [BriefEvent] {
        await gate?.wait()
        return events.filter { calendarIDs.contains($0.calendarID) }
    }
}

@MainActor
@Suite("Brief: the controller's loads")
struct BriefControllerTests {
    static func event(in minutes: Double = 5) -> BriefEvent {
        let start = Date.now.addingTimeInterval(minutes * 60)
        return BriefEvent(identifier: "evt-1", title: "Supplier review", start: start, end: start.addingTimeInterval(3_600), calendarID: "work",
                          attendees: [BriefAttendee(name: "Me", email: nil, isCurrentUser: true), BriefAttendee(name: "Ana López", email: nil)], service: .zoom)
    }

    static func snapshot(_ event: BriefEvent) -> BriefSnapshot {
        BriefSnapshot(occurrence: event.occurrence, title: event.title, start: event.start, end: event.end, service: event.service, seriesName: nil, mode: .keyword,
                      relatedSkipped: false,
                      sections: [BriefSection(kind: .people, items: [BriefItem(id: "b1", kind: .person, text: "Ana López")]),
                                 BriefSection(kind: .lastTime, items: [BriefItem(id: "b2", kind: .decision, text: "Keep the C-shaped shell")])])
    }

    /// Meetings' lock, which a test can open while a recording runs.
    final class Lock: @unchecked Sendable {
        var locked: Bool
        init(_ locked: Bool) { self.locked = locked }
    }

    final class BuildCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    final class Saved: @unchecked Sendable {
        var references: BriefStoredReferences?
        var meetingID: Int64?
    }

    static func controller(enabled: Bool, hintSeen: Bool = true, locked: Bool = false, lock: Lock? = nil, recording: Bool = false, saved: Saved? = nil,
                           gate: BriefLoadGate? = nil, event: BriefEvent = BriefControllerTests.event(), agenda: BriefAgendaState = .none,
                           onBuild: (@Sendable () -> Void)? = nil) throws -> BriefController {
        let suite = "vauta-brief-controller-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let controller = BriefController(defaults: defaults)
        controller.prefs.hintSeen = hintSeen
        controller.prefs.enabled = enabled
        controller.seams = BriefController.Seams(isLocked: { lock?.locked ?? locked }, source: BriefGatedSource(gate: gate, events: [event]),
                                                 build: { event, _ in
                                                     // A locked brief is never built with the agenda or the cache: the seam only returns what the real build would.
                                                     onBuild?()
                                                     var snapshot = BriefControllerTests.snapshot(event)
                                                     snapshot.agenda = agenda
                                                     return BriefController.Entry(event: event, snapshot: snapshot)
                                                 },
                                                 isRecording: { recording },
                                                 saveBrief: { references, id, _ in
                                                     saved?.references = references
                                                     saved?.meetingID = id
                                                 })
        return controller
    }

    @Test func thePanelRefreshAndTheUpcomingLoadDoNotCancelEachOther() async throws {
        let gate = BriefLoadGate()
        let controller = try Self.controller(enabled: true, gate: gate)
        // The panel opens, Upcoming opens, the calendar changes, Meetings unlock: all while the first read is still waiting.
        controller.refreshNext()
        controller.openUpcoming()
        controller.refreshNext()
        controller.openUpcoming()
        controller.refreshNext()
        await gate.release()
        await controller.settle()
        #expect(controller.next?.snapshot != nil, "the panel card has its brief, not \"Preparing brief…\"")
        guard case .entries(let entries) = controller.upcoming else {
            Issue.record("Upcoming stayed \(controller.upcoming)")
            return
        }
        #expect(entries.count == 1 && entries[0].snapshot != nil)
        #expect(!controller.upcomingBusy)
    }

    @Test func openingUpcomingFirstThenRefreshingThePanelKeepsBoth() async throws {
        let gate = BriefLoadGate()
        let controller = try Self.controller(enabled: true, gate: gate)
        controller.openUpcoming()
        controller.refreshNext()
        await gate.release()
        await controller.settle()
        #expect(controller.next?.snapshot != nil)
        if case .entries = controller.upcoming {} else { Issue.record("Upcoming stayed \(controller.upcoming)") }
    }

    @Test func aLoadThatWasLeftWaitingStartsAgainOnceNothingIsLoading() async throws {
        let controller = try Self.controller(enabled: true)
        controller.locked()
        guard case .loading = controller.upcoming else { Issue.record("locked: \(controller.upcoming)"); return }
        controller.resumeUpcomingIfIdle()
        await controller.settle()
        if case .entries = controller.upcoming {} else { Issue.record("resumed: \(controller.upcoming)") }
    }

    @Test func withTheBriefOffTheCardIsTheOneTimeOfferAndNothingIsBuilt() async throws {
        let controller = try Self.controller(enabled: false, hintSeen: false)
        controller.refreshNext()
        await controller.settle()
        #expect(controller.panelCard?.content == .setUp && controller.offersSetUp)
        #expect(controller.next?.snapshot == nil, "a title and a time, no brief")
        controller.prefs.hintSeen = true
        #expect(controller.panelCard == nil && !controller.offersSetUp, "Not Now and Set Up both end the offer")
        controller.refreshNext()
        await controller.settle()
        #expect(controller.next == nil, "and the calendar is no longer looked at for it")
    }

    @Test func turningTheBriefOnEndsTheOfferAndBuildsTheCard() async throws {
        let controller = try Self.controller(enabled: false, hintSeen: false)
        controller.refreshNext()
        await controller.settle()
        controller.prefs.enabled = true
        controller.refreshNext()
        await controller.settle()
        #expect(controller.prefs.hintSeen)
        if case .ready? = controller.panelCard?.content {} else { Issue.record("card: \(String(describing: controller.panelCard?.content))") }
        #expect(!controller.offersSetUp)
    }

    @Test func lockedMeetingsShowOnlyTheTitleAndTime() async throws {
        let controller = try Self.controller(enabled: true, locked: true)
        controller.refreshNext()
        await controller.settle()
        #expect(controller.panelCard?.content == .locked)
        #expect(controller.next?.snapshot == nil)
    }

    // MARK: Recording

    @Test func aRecordingStartedWhileMeetingsAreLockedKeepsItsBriefAndShowsItAfterUnlocking() async throws {
        let lock = Lock(true)
        let saved = Saved()
        let event = Self.event()
        let controller = try Self.controller(enabled: true, lock: lock, recording: true, saved: saved, event: event)
        controller.refreshNext()
        await controller.settle()
        #expect(controller.next?.snapshot == nil, "locked: the card holds the title and time only")

        controller.recordingStarted(recordingOccurrence: event.occurrence)
        await controller.settle()
        #expect(controller.attachment != nil, "the references are kept although Meetings were locked")
        #expect(controller.recordingRow == nil, "and nothing is shown while locked")

        lock.locked = false
        controller.unlocked()
        #expect(controller.recordingRow != nil, "the row appears after unlocking")

        await controller.recordingEnded(meetingID: 42)
        #expect(saved.meetingID == 42 && saved.references?.items.isEmpty == false, "the brief is saved with the meeting")
        #expect(controller.attachment == nil && controller.recordingRow == nil)
    }

    @Test func aRecordingOfAnotherOccurrenceKeepsNoBriefEvenWhenLocked() async throws {
        let lock = Lock(true)
        let saved = Saved()
        let event = Self.event()
        let controller = try Self.controller(enabled: true, lock: lock, recording: true, saved: saved, event: event)
        controller.refreshNext()
        await controller.settle()
        controller.recordingStarted(recordingOccurrence: nil)
        await controller.settle()
        await controller.recordingEnded(meetingID: 9)
        #expect(controller.attachment == nil && saved.meetingID == nil)
    }

    static func inPersonEvent(in minutes: Double = 5) -> BriefEvent {
        let start = Date.now.addingTimeInterval(minutes * 60)
        return BriefEvent(identifier: "evt-room", title: "Site visit", start: start, end: start.addingTimeInterval(3_600), calendarID: "work",
                          attendees: [BriefAttendee(name: "Me", email: nil, isCurrentUser: true), BriefAttendee(name: "Ana López", email: nil)])
    }

    @Test func anInPersonEventOnTheCardKeepsItsBriefWhenRecorded() async throws {
        let saved = Saved()
        let event = Self.inPersonEvent()
        let controller = try Self.controller(enabled: true, recording: true, saved: saved, event: event)
        controller.refreshNext()
        await controller.settle()
        // CalendarWatcher.currentEvent finds events with a link only, so the recording's own occurrence is nil; the card's takes over.
        let occurrence = try #require(controller.inPersonOccurrenceOnCard())
        #expect(occurrence == event.occurrence)
        let linked: BriefOccurrence? = nil
        controller.recordingStarted(recordingOccurrence: linked ?? occurrence)
        #expect(controller.recordingRow != nil)
        await controller.recordingEnded(meetingID: 5)
        #expect(saved.meetingID == 5)
    }

    @Test func theCardsOccurrenceIsTakenOnlyForAnInPersonEventInsideTheWindowAndWithTheBriefOn() async throws {
        let linked = try Self.controller(enabled: true)
        linked.refreshNext()
        await linked.settle()
        #expect(linked.inPersonOccurrenceOnCard() == nil, "an event with a link is found by the calendar watcher")

        let off = try Self.controller(enabled: false, hintSeen: false, event: Self.inPersonEvent())
        off.refreshNext()
        await off.settle()
        #expect(off.inPersonOccurrenceOnCard() == nil, "no brief, no occurrence")

        let early = try Self.controller(enabled: true, event: Self.inPersonEvent(in: 25))
        early.refreshNext()
        await early.settle()
        #expect(early.inPersonOccurrenceOnCard() == nil, "25 minutes before the start is outside the 10-minute window")
    }

    @Test func theInPersonEventOnTheCardBecomesTheRecordingsCalendarEventWithoutItsNotes() async throws {
        let plain = Self.inPersonEvent()
        let event = BriefEvent(identifier: plain.identifier, title: plain.title, start: plain.start, end: plain.end, calendarID: plain.calendarID,
                               attendees: plain.attendees, isRecurring: true, invitationNotes: "SECRET-INVITE-NOTE")
        let controller = try Self.controller(enabled: true, event: event)
        controller.refreshNext()
        await controller.settle()
        let match = try #require(controller.inPersonEventOnCard())
        #expect(match.occurrence == event.occurrence && match.service == nil)
        #expect(match.meeting == event.calendarMeeting && match.meeting.title == "Site visit")
        #expect(match.meeting.attendees.contains { $0.name == "Ana López" }, "the attendees are saved with the recording")
        #expect(match.meeting.seriesKey == event.identifier, "a recurring in-person event keeps its series")
        #expect(!String(describing: match).contains("SECRET-INVITE-NOTE"))
    }

    @Test func anAgendaThatWaitedForARecordingIsAskedForAgainWhenItEndsAndNothingElseIs() async throws {
        let builds = Saved()
        let counter = BuildCount()
        let controller = try Self.controller(enabled: true, saved: builds, agenda: .paused, onBuild: { counter.add() })
        controller.refreshNext()
        await controller.settle()
        let before = counter.count
        #expect(before >= 1 && controller.next?.snapshot?.agenda == .paused)
        controller.resumePausedAgendas()
        // The rebuild is scheduled, not immediate: wait for it (up to 10 s on a loaded machine) instead of a fixed pause.
        for _ in 0..<100 where counter.count <= before {
            try await Task.sleep(for: .milliseconds(100))
            await controller.settle()
        }
        #expect(counter.count > before, "the paused agenda is built again once the recording ends")

        let quiet = BuildCount()
        let plain = try Self.controller(enabled: true, onBuild: { quiet.add() })
        plain.refreshNext()
        await plain.settle()
        let once = quiet.count
        plain.resumePausedAgendas()
        try await Task.sleep(for: .milliseconds(200))
        await plain.settle()
        #expect(quiet.count == once, "nothing waits, so nothing is rebuilt")
    }

    // MARK: Dropping what ended

    @Test func upcomingEntriesAreDroppedThirtyMinutesAfterTheEventEnds() async throws {
        let event = Self.event()
        let controller = try Self.controller(enabled: true, event: event)
        controller.openUpcoming()
        await controller.settle()
        guard case .entries = controller.upcoming else { Issue.record("Upcoming: \(controller.upcoming)"); return }
        await controller.pruneNow(now: event.end.addingTimeInterval(BriefCache.retention - 60))
        if case .entries = controller.upcoming {} else { Issue.record("kept until 30 minutes after the end, not \(controller.upcoming)") }
        await controller.pruneNow(now: event.end.addingTimeInterval(BriefCache.retention + 60))
        #expect(controller.upcoming == .none)
    }

    // MARK: Record at Start

    @Test func recordAtStartFindsTheEventAgainAfterARelaunch() async throws {
        let event = Self.event()
        let controller = try Self.controller(enabled: true, event: event)
        #expect(controller.lastNotified == nil, "a relaunch forgot the notification")
        let found = await controller.eventToArm(event.occurrence)
        #expect(found?.occurrence == event.occurrence && found?.invitationNotes == nil)
        let other = await controller.eventToArm(BriefOccurrence(identifier: "gone", start: event.start))
        #expect(other == nil, "an event that was cancelled is not armed")
        let none = await controller.eventToArm(nil)
        #expect(none == nil)
    }
}
