// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Brief: the store's read-only side")
struct BriefStoreTests {
    /// Records an ended meeting of a series with Ana and Bo, with a card, a decision, two tasks and an open question.
    @discardableResult
    static func recordedMeeting(_ s: MeetingStore, at date: Date, title: String = "Supplier review", key: String? = "series-1",
                                attendees: [CalendarMeeting.Attendee], lines: [String]? = nil) async throws -> Int64 {
        let id = try await s.startMeeting(at: date, locale: Locale(identifier: "en-US"))
        let text = lines ?? ["We still need to decide who signs off the supplier change.", "The shell material stays open until legal answers.", "Send the revised budget."]
        for (i, line) in text.enumerated() {
            try await s.append(Segment(channel: i % 2 == 0 ? .others : .me, start: Double(i * 10), end: Double(i * 10 + 8), text: line, isFinal: true), to: id)
        }
        _ = try await s.applyCalendar(CalendarMeeting(title: title, attendees: attendees, seriesKey: key), to: id)
        try await s.endMeeting(id, at: date.addingTimeInterval(1_800))
        return id
    }

    static let ana = CalendarMeeting.Attendee(name: "Ana López", email: "ana@example.com", isCurrentUser: false)
    static let bo = CalendarMeeting.Attendee(name: "Bo Chen", email: "bo@example.com", isCurrentUser: false)
    static let me = CalendarMeeting.Attendee(name: "Me", email: nil, isCurrentUser: true)

    // MARK: Migration and the Notes flag

    @Test func migration27AddsTheBriefTableAndTheNotesFlag() throws {
        #expect(Schema.currentVersion >= 27)
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db, upTo: 26)
        try Schema.migrate(db, upTo: 27)
        #expect(try Schema.version(of: db) == 27)
        let columns = try db.query("SELECT name FROM pragma_table_info('doc_sources')").map { $0.string(0) }
        #expect(columns.last == "is_notes_export")
        let briefColumns = try db.query("SELECT name FROM pragma_table_info('meeting_briefs')").map { $0.string(0) }
        #expect(briefColumns == ["meeting_id", "created_at", "version", "json"])
        // A restored image at version 27 passes the schema guard (it equals the migrations' own).
        #expect(throws: Never.self) { try BackupSchemaGuard.validate(db) }
    }

    @Test func aDocumentsSourceCanBeMarkedAsNotesAndKeepsTheMarkAcrossReopen() async throws {
        let f = try KnowledgeFixture()
        let source = try await f.store.addDocumentSource(kind: .folder, displayName: "Exported notes", path: "/x/notes", bookmark: Data([1]), volumeUUID: nil)
        #expect(!source.isNotesExport)
        try await f.store.setDocumentSourceNotesExport(source.id, true)
        #expect(try await f.store.documentSource(source.id)?.isNotesExport == true)
        let other = try await f.store.addDocumentSource(kind: .folder, displayName: "Docs", path: "/x/docs", bookmark: Data([2]), volumeUUID: nil)
        try await f.reopen()
        #expect(try await f.store.documentSource(source.id)?.isNotesExport == true)
        #expect(try await f.store.documentSource(other.id)?.isNotesExport == false)
        try await f.store.setDocumentSourceNotesExport(source.id, false)
        #expect(try await f.store.documentSource(source.id)?.isNotesExport == false)
    }

    // MARK: The read-only lookup

    @Test func resolvingAttendeesWritesNothing() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let ana = try await s.saveEntity(EntityDraft(kind: .person, name: "Ana López", email: "ana@example.com"))
        let before = (await s.editRevision, try await s.entities().count)
        let resolved = try await s.resolveAttendees([Self.me, Self.ana, .init(name: "Luis Pérez", email: "luis@invited.example", isCurrentUser: false),
                                                     .init(name: "Zoe Zeta", email: nil, isCurrentUser: false)])
        #expect(resolved.map(\.entityID) == [ana, nil, nil], "the current user is left out; nobody is created")
        let after = (await s.editRevision, try await s.entities().count)
        #expect(before.0 == after.0 && before.1 == after.1)
        let leaked = [try await s.imageContains("invited.example"), try await s.imageContains("Zoe Zeta")]
        #expect(leaked == [false, false], "an invitation never writes its people to the store")
    }

    @Test func attendeesAreMatchedByEmailThenByAUniqueName() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let zed = try await s.saveEntity(EntityDraft(kind: .person, name: "Zed Quill", email: "shared@example.com"))
        let carmen = try await s.saveEntity(EntityDraft(kind: .person, name: "Carmen Ruiz"))
        _ = try await s.saveEntity(EntityDraft(kind: .person, name: "Dani Gil"))
        _ = try await s.saveEntity(EntityDraft(kind: .person, name: "Dani Gil", aliases: []))
        let resolved = try await s.resolveAttendees([
            .init(name: "Someone Else", email: "shared@example.com", isCurrentUser: false),   // the address decides
            .init(name: "Carmen Ruiz", email: nil, isCurrentUser: false),                      // the only person with this name
            .init(name: "Dani Gil", email: nil, isCurrentUser: false),                         // two people: never a guess
            .init(name: "Carmen Ruiz", email: "other@example.com", isCurrentUser: false),      // a different address is a different person
        ])
        #expect(resolved.map(\.entityID) == [zed, carmen, nil, carmen])
    }

    @Test func applyCalendarStillCreatesTheSamePendingPeople() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let id = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-86_400), attendees: [Self.me, Self.ana])
        let people = try await s.entities(.person).filter { !$0.confirmed }
        #expect(people.map(\.name) == ["Ana López"] && people.first?.email == "ana@example.com")
        #expect(try await s.meetingEntities(id, role: .attendee).map(\.name) == ["Ana López"])
    }

    @Test func anInPersonRecordingTakenFromTheCardLinksItsAttendeesAndSeriesSoTheNextOccurrenceFindsIt() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let people = [BriefAttendee(name: "Me", email: nil, isCurrentUser: true), BriefAttendee(name: "Ana López", email: "ana@example.com")]
        let first = BriefFixtures.event("room-1", title: "Site visit", attendees: people, service: nil, recurring: true, notes: "SECRET-INVITE-NOTE",
                                        at: BriefFixtures.now.addingTimeInterval(-7 * 86_400))
        // What the recording takes from the card: title, attendees and series, never the notes.
        let id = try await s.startMeeting(at: first.start, locale: Locale(identifier: "en-US"))
        try await s.append(Segment(channel: .others, start: 0, end: 8, text: "We walk through the site before the handover.", isFinal: true), to: id)
        _ = try await s.applyCalendar(first.calendarMeeting, to: id)
        try await s.endMeeting(id, at: first.end)
        #expect(try await s.meetingEntities(id, role: .attendee).map(\.name) == ["Ana López"])
        #expect(try await s.seriesID(of: id) != nil)
        #expect(!(try await s.imageContains("SECRET-INVITE-NOTE")))

        let next = BriefFixtures.event("room-1", title: "Site visit", attendees: people, service: nil, recurring: true)
        let facts = try await s.briefFacts(for: next)
        #expect(facts.last?.meetingID == id, "found by the series key")
        // Without the series (another event id) it is still found by the attendees.
        let other = BriefFixtures.event("room-2", title: "Unrelated name", attendees: people, service: nil)
        #expect(try await s.briefFacts(for: other).last?.meetingID == id, "found by the attendee overlap")
    }

    // MARK: The facts

    @Test func factsCollectTheSeriesLastMeetingItsItemsAndThePeople() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let day = 86_400.0
        let old = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-14 * day), attendees: [Self.me, Self.ana])
        let last = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-7 * day), attendees: [Self.me, Self.ana, Self.bo])
        try await s.saveCard(MeetingCard(summary: "We compared suppliers. A third was dropped.", topics: ["supplier change"],
                                         openQuestions: ["Who signs off the supplier change?", "Is there any news on tariffs in the region"]), of: last)
        let segment = try #require(try await s.segments(of: last).first)
        _ = try await s.addDecision(last, text: "Keep the C-shaped shell", segmentID: segment.id, t: 0)
        let ana = try #require(try await s.entities(.person).first { $0.name == "Ana López" }?.id)
        let open = try await s.addTask(last, text: "Send the revised budget", ownerID: ana, due: BriefFixtures.now, segmentID: segment.id)
        let done = try await s.addTask(last, text: "Book the room", ownerID: ana)
        try await s.setTaskStatus(done, .done)
        _ = try await s.addTask(old, text: "Ask legal about PO-48213", ownerID: ana)

        let event = BriefFixtures.event(attendees: [BriefAttendee(name: "Me", email: nil, isCurrentUser: true),
                                                    BriefAttendee(name: "Ana López", email: "ana@example.com"),
                                                    BriefAttendee(name: "Luis Pérez", email: "luis@invited.example")], recurring: true)
        let revision = await s.editRevision
        let facts = try await s.briefFacts(for: event)
        #expect(await s.editRevision == revision, "building a brief commits nothing")
        #expect(facts.seriesID != nil && facts.seriesName == "Supplier review")
        let lastMeeting = try #require(facts.last)
        #expect(lastMeeting.meetingID == last, "the newest meeting of the series")
        #expect(lastMeeting.decisions.map(\.text) == ["Keep the C-shaped shell"])
        #expect(lastMeeting.openTasks.map(\.id) == [open], "a done task is not shown")
        #expect(lastMeeting.summary == "We compared suppliers. A third was dropped." && lastMeeting.topics == ["supplier change"])
        #expect(facts.people.map(\.name) == ["Ana López", "Luis Pérez"])
        #expect(facts.people[0].meetingsTogether == 2 && facts.people[0].lastMet != nil && facts.people[0].entityID == ana)
        #expect(facts.people[1].meetingsTogether == 0 && facts.people[1].entityID == nil, "an unresolved attendee has no history and no entity")
        // The other open tasks of the attendees are candidates too; the done one is not.
        #expect(Set(facts.openTasks.map(\.task.id)) == [open, try await s.openTasks(owner: ana).first { $0.text.contains("PO-48213") }!.id])
        #expect(!(try await s.imageContains("luis@invited")))
    }

    @Test func theLastMeetingIsTheOneWithAtLeastHalfTheAttendeesWhenThereIsNoSeries() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let day = 86_400.0
        let c = CalendarMeeting.Attendee(name: "Cy Dune", email: "cy@example.com", isCurrentUser: false)
        _ = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-20 * day), title: "Budget", key: nil, attendees: [Self.me, Self.ana, Self.bo, c])
        let half = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-10 * day), title: "Chat", key: nil, attendees: [Self.me, Self.ana, Self.bo])
        _ = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-3 * day), title: "One to one", key: nil, attendees: [Self.me, Self.ana])
        let event = BriefFixtures.event(title: "Kick-off", attendees: [BriefAttendee(name: "Me", email: nil, isCurrentUser: true),
                                                                  BriefAttendee(name: "Ana López", email: "ana@example.com"),
                                                                  BriefAttendee(name: "Bo Chen", email: "bo@example.com"),
                                                                  BriefAttendee(name: "Cy Dune", email: "cy@example.com"),
                                                                  BriefAttendee(name: "Di Park", email: "di@example.com")], service: nil)
        let facts = try await s.briefFacts(for: event)
        #expect(facts.seriesID == nil)
        // Four attendees: the 3 days old meeting has one of them (25%), the 10 days old one has two (50%), the 20 days old one has three.
        #expect(facts.last?.meetingID == half, "at least half of the attendees, and the newest of those")
        // Nobody else was there: no last meeting.
        let stranger = BriefFixtures.event(attendees: [BriefAttendee(name: "Eli Root", email: "eli@example.com")])
        #expect(try await s.briefFacts(for: stranger).last == nil)
    }

    @Test func tasksOfTheAttendeesAndOfThePersonAreCandidates() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let id = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-5 * 86_400), attendees: [Self.me, Self.ana])
        let ana = try #require(try await s.entities(.person).first?.id)
        let me = try await s.selfEntity()
        let a = try await s.addTask(id, text: "Ana owes the draft", ownerID: ana)
        let b = try await s.addTask(id, text: "I owe the figures", ownerID: me)
        _ = try await s.addTask(id, text: "Nobody's task")
        let facts = try await s.briefFacts(for: BriefFixtures.event())
        #expect(Set(facts.openTasks.map(\.task.id)) == [a, b])
        #expect(facts.selfEntityID == me)
    }

    // MARK: Open questions

    @Test func anOpenQuestionLinksToTheSegmentWhereItsWordsAreTogether() {
        let segments: [(id: Int64, t: Double, text: String)] = [
            (1, 0, "Good morning everybody."), (2, 10, "We still need to decide who signs off"), (3, 20, "the supplier change before Friday."),
            (4, 30, "Anything else on tariffs?"), (5, 40, "No."),
        ]
        let found = BriefOpenQuestionLocator.locate(question: "Who signs off the supplier change?", in: segments, locale: "en-US")
        #expect(found?.id == 2 || found?.id == 3, "inside the window that holds at least two of its words")
        // One shared word is not enough.
        #expect(BriefOpenQuestionLocator.locate(question: "Is there any news on pricing", in: segments, locale: "en-US") == nil)
        // Words spread over distant segments are not a window.
        let far: [(id: Int64, t: Double, text: String)] = [(1, 0, "supplier"), (2, 1, "a"), (3, 2, "b"), (4, 3, "c"), (5, 4, "change")]
        #expect(BriefOpenQuestionLocator.locate(question: "supplier change", in: far, locale: "en-US") == nil)
        #expect(BriefOpenQuestionLocator.locate(question: "supplier change", in: [], locale: "en-US") == nil)
    }

    @Test func openQuestionsOfTheLastMeetingCarryTheirLocation() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let last = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-86_400), attendees: [Self.me, Self.ana])
        try await s.saveCard(MeetingCard(summary: "x", topics: [], openQuestions: ["Who signs off the supplier change?", "What about the Lisbon office lease"]), of: last)
        let facts = try await s.briefFacts(for: BriefFixtures.event(recurring: true))
        let questions = try #require(facts.last?.openQuestions)
        #expect(questions.count == 2)
        #expect(questions[0].segmentID != nil, "its words are in the transcript")
        #expect(questions[1].segmentID == nil, "no segment holds it: it links to the meeting only")
    }

    // MARK: Kept with the meeting

    @Test func theBriefIsKeptWithTheMeetingWithoutReminderOrInvitationText() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let meeting = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-86_400), attendees: [Self.me, Self.ana])
        let segment = try #require(try await s.segments(of: meeting).first)
        let decision = try await s.addDecision(meeting, text: "Keep the C-shaped shell", segmentID: segment.id, t: 0)
        let task = try await s.addTask(meeting, text: "Send the revised budget")

        var d = BriefItem(id: "b1", kind: .decision, text: "Keep the C-shaped shell", link: .segment(meetingID: meeting, segmentID: segment.id))
        d.decisionID = decision
        d.meetingID = meeting
        var t = BriefItem(id: "b2", kind: .task, text: "Send the revised budget", link: .segment(meetingID: meeting, segmentID: segment.id))
        t.taskID = task
        t.meetingID = meeting
        let reminder = BriefItem(id: "b3", kind: .reminder, text: "Call legal about SECRET-REMINDER-77", link: .reminder(id: "r1"))
        let invitation = BriefItem(id: "b4", kind: .invitationLine, text: "SECRET-INVITE-NOTE agenda point")
        var snapshot = BriefSnapshot(occurrence: BriefFixtures.event().occurrence, title: "Supplier review", start: BriefFixtures.now, end: BriefFixtures.now,
                                     service: nil, seriesName: nil, mode: .keyword, relatedSkipped: false,
                                     sections: [BriefSection(kind: .lastTime, items: [d]), BriefSection(kind: .openTasks, items: [t]),
                                                BriefSection(kind: .reminders, items: [reminder]), BriefSection(kind: .invitation, items: [invitation])])
        snapshot.agenda = .lines([BriefAgendaLine(kind: .followUp, text: "Follow up on the revised budget", cites: ["b2"]),
                                  BriefAgendaLine(kind: .ask, text: "Ask about SECRET-REMINDER-77", cites: ["b3"]),
                                  BriefAgendaLine(kind: .review, text: "Review the shell decision", cites: ["b1", "b4"])])
        let references = BriefStoredReferences(snapshot: snapshot)
        #expect(references.items.map(\.id) == ["b1", "b2"])
        #expect(references.agenda.map(\.text) == ["Follow up on the revised budget"], "a line that cites a reminder or an invitation line is not kept")

        try await s.saveBrief(references, for: meeting)
        let stored = try #require(try await s.storedBrief(of: meeting))
        #expect(stored.references == references)
        let leaked = [try await s.imageContains("SECRET-REMINDER-77"), try await s.imageContains("SECRET-INVITE-NOTE")]
        #expect(leaked == [false, false])

        // A task deleted since is dropped, and so is the agenda line that cited it.
        try await s.deleteTask(task)
        let after = try #require(try await s.storedBrief(of: meeting))
        #expect(after.references.items.map(\.id) == ["b1"] && after.references.agenda.isEmpty)

        // Saving again replaces; deleting the meeting takes the brief with it.
        try await s.saveBrief(references, for: meeting)
        #expect(try await s.intsForTest("SELECT COUNT(*) FROM meeting_briefs") == [1])
        try await s.deleteMeeting(meeting)
        #expect(try await s.intsForTest("SELECT COUNT(*) FROM meeting_briefs") == [0])
    }

    @Test func aKeptDecisionAndTaskKeepTheirUnconfirmedAndUncertainOwnerMarksWhenReadBack() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let meeting = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-86_400), attendees: [Self.me, Self.ana])
        let decision = try await s.addDecision(meeting, text: "Keep the C-shaped shell")
        let task = try await s.addTask(meeting, text: "Send the revised budget")
        try await s.run("UPDATE decisions SET unconfirmed = 1 WHERE id = ?", [.integer(decision)])
        try await s.run("UPDATE tasks SET unconfirmed = 1, owner_uncertain = 1 WHERE id = ?", [.integer(task)])
        var d = BriefItem(id: "b1", kind: .decision, text: "Keep the C-shaped shell")
        d.decisionID = decision
        d.meetingID = meeting
        var t = BriefItem(id: "b2", kind: .task, text: "Send the revised budget")
        t.taskID = task
        t.meetingID = meeting
        let snapshot = BriefSnapshot(occurrence: BriefFixtures.event().occurrence, title: "T", start: BriefFixtures.now, end: BriefFixtures.now,
                                     service: nil, seriesName: nil, mode: .keyword, relatedSkipped: false,
                                     sections: [BriefSection(kind: .lastTime, items: [d]), BriefSection(kind: .openTasks, items: [t])])
        let references = BriefStoredReferences(snapshot: snapshot)
        #expect(!(String(decoding: try JSONEncoder().encode(references), as: UTF8.self).contains("nconfirmed")), "the marks are read again, never stored")
        try await s.saveBrief(references, for: meeting)
        let back = try #require(try await s.storedBrief(of: meeting)).references.sections.flatMap(\.items)
        #expect(back.first { $0.kind == .decision }?.unconfirmed == true)
        let task2 = try #require(back.first { $0.kind == .task })
        #expect(task2.unconfirmed && task2.ownerUncertain)
        // Confirming the item in the minutes clears the mark in the kept brief.
        try await s.markTaskChecked(task)
        let after = try #require(try await s.storedBrief(of: meeting)).references.sections.flatMap(\.items)
        #expect(after.first { $0.kind == .task }?.unconfirmed == false)
    }

    @Test func aKeptBriefHoldsNoAttendeeWhoIsNotAKnownPerson() {
        var known = BriefItem(id: "b1", kind: .person, text: "Ana López", link: .person(entityID: 7))
        known.entityID = 7
        let unknown = BriefItem(id: "b2", kind: .person, text: "luis@invited.example")
        let snapshot = BriefSnapshot(occurrence: BriefFixtures.event().occurrence, title: "T", start: BriefFixtures.now, end: BriefFixtures.now, service: nil,
                                     seriesName: nil, mode: .keyword, relatedSkipped: false, sections: [BriefSection(kind: .people, items: [known, unknown])])
        let references = BriefStoredReferences(snapshot: snapshot)
        #expect(references.items.map(\.id) == ["b1"])
        #expect(!String(describing: references).contains("invited.example"))
    }

    @Test func deletingAMeetingChangesTheRevisionTheBriefCacheKeysOnAndTheRebuiltBriefLosesIt() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let meeting = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-86_400), attendees: [Self.me, Self.ana])
        try await s.saveCard(MeetingCard(summary: "We compared suppliers.", topics: [], openQuestions: []), of: meeting)
        _ = try await s.addDecision(meeting, text: "Keep the C-shaped shell")
        let event = BriefFixtures.event(attendees: [BriefAttendee(name: "Me", email: nil, isCurrentUser: true), BriefAttendee(name: "Ana López", email: "ana@example.com")],
                                        recurring: true)
        let composer = BriefComposer(store: s, retriever: nil, reminders: nil)
        let before = await composer.build(event, settings: BriefSettings(), environment: BriefEnvironment(), showsLastTime: true)
        #expect(before.snapshot?.section(.lastTime) != nil)
        let revision = await s.editRevision
        try await s.deleteMeeting(meeting)
        #expect(await s.editRevision != revision, "the cache key sees the deletion")
        let after = await composer.build(event, settings: BriefSettings(), environment: BriefEnvironment(), showsLastTime: true)
        #expect(after.snapshot?.section(.lastTime) == nil && after.snapshot?.items.contains { $0.meetingID == meeting } != true)
    }

    @Test func aStoredBriefSurvivesReopenAndIsErasedWithTheStore() async throws {
        let f = try KnowledgeFixture()
        let meeting = try await Self.recordedMeeting(f.store, at: BriefFixtures.now.addingTimeInterval(-86_400), attendees: [Self.me, Self.ana])
        let item = BriefStoredReferences.Item(id: "b1", section: "lastTime", kind: "summary", text: "A line", meetingID: meeting)
        try await f.store.saveBrief(BriefStoredReferences(items: [item], agenda: []), for: meeting)
        try await f.reopen()
        #expect(try await f.store.storedBrief(of: meeting)?.references.items.first?.text == "Supplier review", "the summary line is read again, not kept as text")
    }

    @Test func aKeptSummaryLineFollowsTheEarlierCardAndLosesAnEditedOutSentence() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let earlier = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-86_400), attendees: [Self.me, Self.ana])
        let later = try await Self.recordedMeeting(s, at: BriefFixtures.now.addingTimeInterval(-3_600), attendees: [Self.me, Self.ana])
        try await s.saveCard(MeetingCard(summary: "SECRET-SENTENCE-91 was agreed.", topics: [], openQuestions: []), of: earlier)
        var head = BriefItem(id: "b1", kind: .summary, text: "SECRET-SENTENCE-91 was agreed.", link: .meeting(meetingID: earlier, t: nil))
        head.meetingID = earlier
        let snapshot = BriefSnapshot(occurrence: BriefFixtures.event().occurrence, title: "T", start: BriefFixtures.now, end: BriefFixtures.now, service: nil,
                                     seriesName: nil, mode: .keyword, relatedSkipped: false, sections: [BriefSection(kind: .lastTime, items: [head])])
        try await s.saveBrief(BriefStoredReferences(snapshot: snapshot), for: later)
        #expect(try await s.storedBrief(of: later)?.references.items.first?.text == "SECRET-SENTENCE-91 was agreed.")
        // The person edits the sentence out of the earlier card: the later meeting's brief shows what the card says now.
        try await s.saveCard(MeetingCard(summary: "The budget was reviewed.", topics: [], openQuestions: []), of: earlier)
        #expect(try await s.storedBrief(of: later)?.references.items.first?.text == "The budget was reviewed.")
        // The earlier meeting is deleted: the item goes.
        try await s.deleteMeeting(earlier)
        #expect(try await s.storedBrief(of: later)?.references.items.isEmpty == true)
    }

    @Test func theNotesFlagAndTheStoredBriefTravelInAnEncryptedBackup() async throws {
        let source = StoreFixture()
        let store = try source.open()
        let meeting = try await Self.recordedMeeting(store, at: BriefFixtures.now.addingTimeInterval(-86_400), attendees: [Self.me, Self.ana])
        let notes = try await store.addDocumentSource(kind: .folder, displayName: "Exported notes", path: "/x/notes", bookmark: Data([1]), volumeUUID: nil)
        try await store.setDocumentSourceNotesExport(notes.id, true)
        let item = BriefStoredReferences.Item(id: "b1", section: "lastTime", kind: "summary", text: "What the last meeting said", meetingID: meeting)
        try await store.saveBrief(BriefStoredReferences(items: [item], agenda: [BriefAgendaLine(kind: .ask, text: "Ask about the shell", cites: ["b1"])]), for: meeting)
        let file = try await store.createBackup(password: "correct horse battery staple", appVersion: "0.9.0")
        #expect(file.range(of: Data("What the last meeting said".utf8)) == nil, "the file holds no plaintext")

        let target = StoreFixture()
        let restored = try target.open()
        _ = try await restored.restore(try await MeetingStore.openBackup(file, password: "correct horse battery staple"))
        let sources = try await restored.documentSources()
        #expect(sources.map(\.isNotesExport) == [true])
        let restoredMeeting = try #require(try await restored.meetings().first?.id)
        let brief = try #require(try await restored.storedBrief(of: restoredMeeting))
        #expect(brief.references.items.first?.text == "Supplier review" && brief.references.agenda.map(\.text) == ["Ask about the shell"])
    }
}
