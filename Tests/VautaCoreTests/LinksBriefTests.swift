// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Links in the brief and the reminders: a chain shows once, a changed decision shows both, a chain shares its reminder, and the brief
/// leaves out the items the minutes' ranking put aside.
@Suite("Links: brief and reminders")
struct LinksBriefTests {
    typealias F = BriefFixtures
    static let start = F.event().start

    static func date(days: Double) -> Date { start.addingTimeInterval(days * 86_400) }

    // MARK: 36 Brief

    @Test func aChainOfTasksAppearsOnceAsItsNewestOpenMemberCarriedOverSinceTheFirst() {
        let chain = [BriefTaskFact(task: F.task(1, "Send the revised budget to finance", meeting: 1), meetingDate: Self.date(days: -21)),
                     BriefTaskFact(task: F.task(2, "Send the budget to finance", meeting: 2), meetingDate: Self.date(days: -14)),
                     BriefTaskFact(task: F.task(3, "Send the revised budget to the finance team", meeting: 3), meetingDate: Self.date(days: -7)),
                     BriefTaskFact(task: F.task(4, "Book the venue", meeting: 3), meetingDate: Self.date(days: -7))]
        var facts = BriefFacts()
        facts.openTasks = chain
        let info = BriefChainInfo(newest: 3, mentions: 3, since: Self.date(days: -21))
        facts.taskChains = [1: info, 2: info, 3: info]
        let snapshot = BriefBuilder.assemble(F.assembly(facts: facts))
        let items = snapshot.section(.openTasks)?.items ?? []
        #expect(items.map(\.taskID).sorted { ($0 ?? 0) < ($1 ?? 0) } == [3, 4], "one row for the chain")
        let carried = try? #require(items.first { $0.taskID == 3 })
        #expect(carried?.carriedMentions == 3 && carried?.carriedSince == Self.date(days: -21))
        #expect(items.first { $0.taskID == 4 }?.carriedSince == nil)
        #expect(snapshot.section(.openTasks)?.total == 2, "the section counts chains")
        // Without chains the list is as it was.
        var plain = facts
        plain.taskChains = [:]
        #expect(BriefBuilder.assemble(F.assembly(facts: plain)).section(.openTasks)?.items.count == 4)
    }

    @Test func aChainMemberShownUnderLastTimeStandsForItsWholeChain() {
        let shown = F.task(3, "Send the revised budget to finance", meeting: 1)
        let earlier = F.task(1, "Send the budget to finance", meeting: 0)
        var facts = BriefFacts()
        facts.last = F.last(tasks: [shown])
        facts.openTasks = [BriefTaskFact(task: earlier, meetingDate: Self.date(days: -21))]
        let info = BriefChainInfo(newest: 3, mentions: 2, since: Self.date(days: -21))
        facts.taskChains = [1: info, 3: info]
        let snapshot = BriefBuilder.assemble(F.assembly(facts: facts))
        #expect(snapshot.section(.openTasks) == nil, "the earlier mention is not listed again")
        #expect(snapshot.section(.lastTime)?.items.contains { $0.taskID == 3 } == true)
    }

    @Test func aChangedDecisionShowsBothAndASameDecisionSaysWhenItWasFirstDecided() {
        let now = F.decision(10, "Budget capped at 48.200 €")
        let same = F.decision(11, "Keep the C-shaped shell")
        var facts = BriefFacts()
        facts.last = F.last(decisions: [now, same])
        facts.decisionLinks = [10: .changes(earlierText: "Budget capped at 40.000 €", earlierDate: Self.date(days: -30)), 11: .same(first: Self.date(days: -60))]
        let items = BriefBuilder.assemble(F.assembly(facts: facts)).section(.lastTime)?.items.filter { $0.kind == .decision } ?? []
        #expect(items.count == 2, "a confirmed 'changes' hides nothing")
        #expect(items[0].replacesDate == Self.date(days: -30) && items[0].replacesText == "Budget capped at 40.000 €" && items[0].firstDecided == nil)
        #expect(items[1].firstDecided == Self.date(days: -60) && items[1].replacesDate == nil)
    }

    @Test func theStoreFillsTheBriefsChainsAndDecisionLinksFromConfirmedLinksOnly() async throws {
        let s = try await LinksStoreTests.Series(meetings: 3)
        try await s.store.applyMinutes(s.minutes(0, tasks: [(LinksStoreTests.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(LinksStoreTests.later, false, nil)]), to: s.ids[1])
        try await s.store.applyMinutes(s.minutes(2, tasks: [(LinksStoreTests.later + " today", false, nil)]), to: s.ids[2])
        _ = try await s.pass(1)
        _ = try await s.pass(2)
        var facts = BriefFacts()
        try await s.store.addLinksForTest(to: &facts)
        #expect(facts.taskChains.isEmpty, "suggestions are not facts")
        for meeting in 1...2 { for link in try await s.store.links(ofMeeting: s.ids[meeting]) { try await s.store.confirmLink(link.id) } }
        try await s.store.addLinksForTest(to: &facts)
        #expect(facts.taskChains.count == 3 && Set(facts.taskChains.values.map(\.newest)).count == 1)
        #expect(facts.taskChains.values.first?.mentions == 3)
    }

    // MARK: 41 Ranked-out items are left out of the brief

    @Test func theBriefLeavesOutRankedOutItemsButKeepsDoubtedOnes() async throws {
        #expect(BriefPolicy.leavesOutRankedOutItems, "decided on 2026-10-25")
        let s = try await LinksStoreTests.Series()
        try await s.store.applyMinutes(s.minutes(0, decisions: [("Firm decision about the shell", false, nil), ("Ranked out decision about nothing", true, "rank"),
                                                              ("Doubted decision about figures 5", true, "figures")],
                                                 tasks: [("Firm task for the team", false, nil), ("Ranked out task for nobody", true, "rank:noAgreement"),
                                                         ("Doubted task about money", true, "tentative")]), to: s.ids[0])
        let event = BriefFixtures.event(attendees: [BriefAttendee(name: "Me", email: nil, isCurrentUser: true)])
        let last = try #require(try await s.store.briefLastMeetingForTest(s.ids[0], leavesOutRankedOut: true))
        let byDefault = try #require(try await s.store.briefLastMeetingForTest(s.ids[0]))
        let withAll = try #require(try await s.store.briefLastMeetingForTest(s.ids[0], leavesOutRankedOut: false))
        #expect(byDefault.decisions.map(\.text) == last.decisions.map(\.text) && byDefault.openTasks.count == 2, "the default leaves them out")
        #expect(withAll.decisions.count == 3 && withAll.openTasks.count == 3)
        #expect(last.decisions.map(\.text) == ["Firm decision about the shell", "Doubted decision about figures 5"])
        #expect(last.openTasks.map(\.text).sorted() == ["Doubted task about money", "Firm task for the team"])
        _ = event
    }

    // MARK: 42 A chain shares its reminder

    @Test func useThisReminderOnAnotherChainMemberWritesNothing() async throws {
        let s = try await LinksStoreTests.Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(LinksStoreTests.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(LinksStoreTests.later, false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        let writer = FakeActionWriter()
        let service = ActionService(store: s.store, writer: writer)
        let first = try #require(try await s.store.tasks(s.ids[0]).first), second = try #require(try await s.store.tasks(s.ids[1]).first)
        func draft(_ task: TaskItem) -> ReminderDraft {
            ReminderDraft.make(task: task, selfEntityID: nil, containerID: "list-work", meetingTitle: "Weekly sync", meetingDate: LinkFixture.base)
        }
        guard case .added(let row) = await service.addReminder(task: first, draft: draft(first)) else { Issue.record("not added"); return }
        #expect(writer.writes == 1)
        // Not confirmed yet: the other task is a different task, so it can have its own reminder (or the list's own duplicate check speaks).
        #expect(try await s.store.chainMembers(ofTask: second.id).isEmpty)
        try await s.store.confirmLink(try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id))
        #expect(try await s.store.chainMembers(ofTask: second.id) == [first.id])
        guard case .duplicate(.chainReminder(let found)) = await service.addReminder(task: second, draft: draft(second)) else { Issue.record("not found"); return }
        #expect(found.id == row.id)
        #expect(writer.writes == 1, "nothing was written")
        let linked = await service.useExisting(task: second, finding: .chainReminder(found))
        #expect(linked?.state == .linked && linked?.itemID == row.itemID)
        #expect(writer.writes == 1)
        // A linked row is never removed from Reminders, and the first task's own row stays.
        #expect(await service.remove(actionID: try #require(linked).id) == .notRemovable)
        #expect(try await s.store.liveAction(target: .reminder, source: .task, sourceID: first.id)?.state == .created)
    }
}

extension MeetingStore {
    func addLinksForTest(to facts: inout BriefFacts) throws { try addLinks(to: &facts) }
    func briefLastMeetingForTest(_ id: Int64, leavesOutRankedOut: Bool = BriefPolicy.leavesOutRankedOutItems) throws -> BriefLastMeeting? {
        try briefLastMeeting(id, leavesOutRankedOut: leavesOutRankedOut)
    }
}
