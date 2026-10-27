// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Brief: what the panel, the notification and the recording show")
struct BriefPresentationTests {
    static let now = BriefFixtures.now

    private func candidate(_ id: String, in minutes: Double) -> BriefWakeCandidate {
        let event = BriefFixtures.event(id, in: minutes)
        return BriefWakeCandidate(occurrence: event.occurrence, start: event.start)
    }

    @Test func theWakeIsTheEarliestNotificationNotYetSent() {
        var ledger = BriefNotificationLedger()
        let a = candidate("a", in: 40), b = candidate("b", in: 90)
        #expect(BriefWake.next([b, a], now: Self.now, leadMinutes: 10, ledger: ledger) == a.start.addingTimeInterval(-600))
        ledger.markSent(a.occurrence, at: Self.now)
        #expect(BriefWake.next([a, b], now: Self.now, leadMinutes: 10, ledger: ledger) == b.start.addingTimeInterval(-600), "a sent one is never due twice")
        #expect(BriefWake.next([a, b], now: Self.now, leadMinutes: 0, ledger: ledger) == nil, "Off")
        #expect(BriefWake.next([candidate("started", in: -5)], now: Self.now, leadMinutes: 10, ledger: BriefNotificationLedger()) == nil)
    }

    @Test func aNotificationThatIsAlreadyDueIsDueNowAndOnlyOnce() {
        var ledger = BriefNotificationLedger()
        let soon = candidate("soon", in: 6)
        #expect(BriefWake.due([soon], now: Self.now, leadMinutes: 10, ledger: ledger) == [soon.occurrence])
        #expect(BriefWake.next([soon], now: Self.now, leadMinutes: 10, ledger: ledger)! <= Self.now.addingTimeInterval(1))
        ledger.markSent(soon.occurrence, at: Self.now)
        #expect(BriefWake.due([soon], now: Self.now, leadMinutes: 10, ledger: ledger).isEmpty)
        #expect(BriefWake.due([candidate("far", in: 60)], now: Self.now, leadMinutes: 10, ledger: ledger).isEmpty)
    }

    @Test func aRecordingCarriesTheBriefOnlyWhileItsCardIsShownAndForItsOwnOccurrence() {
        let event = BriefFixtures.event("e", in: 5)
        let mine = event.occurrence
        #expect(BriefRecordingMatch.matches(mine, at: Self.now, leadMinutes: 10, recordingOccurrence: mine))
        #expect(!BriefRecordingMatch.matches(mine, at: Self.now, leadMinutes: 10, recordingOccurrence: nil), "an ad-hoc recording near the event takes no brief")
        let other = BriefFixtures.event("other", title: event.title, in: 5).occurrence
        #expect(!BriefRecordingMatch.matches(mine, at: Self.now, leadMinutes: 10, recordingOccurrence: other), "same title, another event")
        let nextWeek = BriefFixtures.event("e", in: 5 + 7 * 24 * 60).occurrence
        #expect(!BriefRecordingMatch.matches(mine, at: Self.now, leadMinutes: 10, recordingOccurrence: nextWeek), "same series, another occurrence")
        #expect(!BriefRecordingMatch.matches(mine, at: Self.now.addingTimeInterval(-3600), leadMinutes: 10, recordingOccurrence: mine), "too early")
        #expect(!BriefRecordingMatch.matches(mine, at: Self.now.addingTimeInterval(3600), leadMinutes: 10, recordingOccurrence: mine), "long after the start")
    }

    @Test func noAgendaIsShownUntilABackendPassedTheGates() {
        #expect(!BriefRankingShipping.searchModelRanks, "keywords rank the brief")
        #expect(BriefAgendaShipping.shipped.isEmpty, "nothing has been measured, so nothing ships")
        #expect(BriefAgendaShipping.decision(backend: .apple) == .hidden)
        #expect(BriefAgendaShipping.decision(backend: nil) == .hidden)
        #expect(BriefAgendaShipping.decision(backend: .apple, shipped: [.apple]) == .run)
        #expect(BriefAgendaShipping.decision(backend: .integrated, shipped: [.apple]) == .hidden)
        #expect(BriefAgendaShipping.decision(backend: nil, shipped: [.apple]) == .needsModel)
    }

    private func snapshot(_ event: BriefEvent, sections: [BriefSection]) -> BriefSnapshot {
        BriefSnapshot(occurrence: event.occurrence, title: event.title, start: event.start, end: event.end, service: nil, seriesName: nil, mode: .keyword,
                      relatedSkipped: false, sections: sections)
    }

    @Test func aLockedCardHoldsNoTextFromTheBrief() {
        let event = BriefFixtures.event("e", title: "Supplier review")
        var person = BriefItem(id: "b1", kind: .person, text: "Ana López")
        person.meetingsTogether = 2
        let summary = BriefItem(id: "b2", kind: .summary, text: "SECRET minutes sentence.")
        let brief = snapshot(event, sections: [BriefSection(kind: .people, items: [person]), BriefSection(kind: .lastTime, items: [summary])])
        let locked = BriefPanelCard.make(event: event, snapshot: brief, locked: true, hot: false)
        #expect(locked.content == .locked)
        #expect(locked.summary.title == "Supplier review")
        #expect(!"\(locked)".contains("SECRET") && !"\(locked)".contains("Ana"))
        let open = BriefPanelCard.make(event: event, snapshot: brief, locked: false, hot: false)
        guard case .ready(let ready) = open.content, case .lines(let lines) = ready.body else { Issue.record("expected lines"); return }
        #expect(lines.map(\.text) == ["SECRET minutes sentence."])
        #expect(ready.peopleCount == 1)
    }

    @Test func theCardSaysFirstMeetingNothingOpenBuildingAndHot() {
        let event = BriefFixtures.event("e")
        var stranger = BriefItem(id: "b1", kind: .person, text: "Jordan Lee")
        stranger.meetingsTogether = 0
        var known = stranger
        known.meetingsTogether = 3
        let first = BriefPanelCard.make(event: event, snapshot: snapshot(event, sections: [BriefSection(kind: .people, items: [stranger])]), locked: false, hot: false)
        guard case .ready(let a) = first.content else { Issue.record("expected ready"); return }
        #expect(a.body == .firstMeeting)
        let nothing = BriefPanelCard.make(event: event, snapshot: snapshot(event, sections: [BriefSection(kind: .people, items: [known])]), locked: false, hot: false)
        guard case .ready(let b) = nothing.content else { Issue.record("expected ready"); return }
        #expect(b.body == .nothingOpen)
        #expect(BriefPanelCard.make(event: event, snapshot: nil, locked: false, hot: false).content == .building)
        #expect(BriefPanelCard.make(event: event, snapshot: nil, locked: false, hot: true).content == .paused)
    }

    @Test func aKeptBriefReadsBackAsSectionsWithoutInventingHistory() {
        let refs = BriefStoredReferences(items: [
            .init(id: "b1", section: "people", kind: "person", text: "Ana", entityID: 4),
            .init(id: "b2", section: "lastTime", kind: "decision", text: "Keep the shell", meetingID: 7, decisionID: 2, segmentID: 31),
            .init(id: "b3", section: "documents", kind: "document", text: "Plan.pdf", sourceID: 2, relPath: "Plan.pdf", passageKey: "p1"),
        ], agenda: [])
        let sections = refs.sections
        #expect(sections.map(\.kind) == [.people, .lastTime, .documents])
        #expect(sections[0].items[0].historyKnown == false && sections[0].items[0].link == .person(entityID: 4))
        #expect(sections[1].items[0].link == .segment(meetingID: 7, segmentID: 31))
        #expect(sections[2].items[0].link == .passage(key: "p1", sourceID: 2, relPath: "Plan.pdf"))
    }
}
