// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Brief: the deterministic builder")
struct BriefBuilderTests {
    static let now = BriefFixtures.now
    static let event = BriefFixtures.event()
    static var start: Date { event.start }
    static func date(days: Double) -> Date { start.addingTimeInterval(days * 86_400) }

    static func hit(_ id: Int64, _ title: String = "Other meeting", text: String = "unrelated words", cosine: Double? = nil) -> BriefMeetingHit {
        BriefMeetingHit(meetingID: id, title: title, date: date(days: -30), text: text, segmentID: id * 10, t: 12, cosine: cosine)
    }

    static func doc(_ source: Int64, _ path: String, text: String = "words", cosine: Double? = nil, key: String? = nil) -> BriefDocumentHit {
        BriefDocumentHit(sourceID: source, relPath: path, fileName: (path as NSString).lastPathComponent, passageKey: key ?? "\(source)/\(path)#1", text: text, cosine: cosine)
    }

    static func people() -> [BriefPerson] {
        [BriefPerson(name: "Ana López", entityID: 5, lastMet: date(days: -7), meetingsTogether: 3), BriefPerson(name: "Luis Pérez", entityID: nil, lastMet: nil, meetingsTogether: 0)]
    }

    // MARK: Sections

    @Test func sectionsComeInTheDesignedOrderWithStableIDsAndLinks() {
        let d = (1...4).map { BriefFixtures.decision(Int64($0), "Decision number \($0)", segment: Int64($0 * 100)) }
        let tasks = (1...4).map { BriefFixtures.task(Int64($0), "Task number \($0)", ownerName: "Ana López", due: Self.date(days: Double($0)), segment: Int64($0 * 100)) }
        let questions = [BriefOpenQuestion(text: "Who signs off?", segmentID: 700, t: 30), BriefOpenQuestion(text: "What about the lease", segmentID: nil, t: nil)]
        var facts = BriefFacts()
        facts.people = Self.people()
        facts.last = BriefFixtures.last(decisions: d, tasks: tasks, questions: questions, materials: [BriefMaterial(sourceID: 3, relPath: "plan.pdf", name: "plan.pdf")])
        facts.openTasks = [BriefTaskFact(task: BriefFixtures.task(50, "A task from long ago", ownerName: "Ana López", meeting: 9), meetingDate: Self.date(days: -40))]
        var a = BriefFixtures.assembly(facts: facts)
        a.invitationLines = ["Agenda point one"]
        let snapshot = BriefBuilder.assemble(a)

        #expect(snapshot.sections.map(\.kind) == [.people, .lastTime, .openTasks, .documents, .invitation])
        #expect(snapshot.items.map(\.id) == (1...snapshot.items.count).map { "b\($0)" })
        let last = snapshot.section(.lastTime)!
        #expect(last.items.map(\.kind) == [.summary, .decision, .decision, .decision, .task, .task, .task, .openQuestion, .openQuestion])
        #expect(last.total == 1 + 4 + 4 + 2, "the section says how many there were before the cap")
        #expect(last.items[1].link == .segment(meetingID: 1, segmentID: 100) && last.items[1].decisionID == 1)
        #expect(last.items[4].link == .segment(meetingID: 1, segmentID: 100) && last.items[4].taskID == 1 && last.items[4].owner == "Ana López")
        #expect(last.items[7].link == .segment(meetingID: 1, segmentID: 700) && !last.items[7].fromMinutes)
        #expect(last.items[8].link == .meeting(meetingID: 1, t: nil) && last.items[8].fromMinutes, "an open question no segment holds: \"from the minutes\"")
        #expect(last.items[0].text == "The team compared two suppliers.", "the summary's first sentence")
        let people = snapshot.section(.people)!.items
        #expect(people[0].link == .person(entityID: 5) && people[0].meetingsTogether == 3 && people[1].link == .none && people[1].meetingsTogether == 0)
        #expect(snapshot.section(.documents)!.items.first?.link == .file(sourceID: 3, relPath: "plan.pdf"))
        #expect(snapshot.section(.invitation)!.items.first?.link == BriefLink.none)
        #expect(snapshot.hasContent && !snapshot.isFirstMeeting)
    }

    @Test func aSectionWithNothingInItIsOmittedAndAFirstMeetingSaysSo() {
        let empty = BriefBuilder.assemble(BriefFixtures.assembly())
        #expect(empty.sections.isEmpty && empty.isFirstMeeting && !empty.hasContent)
        var facts = BriefFacts()
        facts.people = [BriefPerson(name: "Luis Pérez", entityID: nil, lastMet: nil, meetingsTogether: 0)]
        let first = BriefBuilder.assemble(BriefFixtures.assembly(facts: facts))
        #expect(first.sections.map(\.kind) == [.people] && first.isFirstMeeting && !first.hasContent, "unknown people alone are no reason for a notification")
        facts.people = Self.people()
        #expect(BriefBuilder.assemble(BriefFixtures.assembly(facts: facts)).hasContent, "someone met before is")
    }

    @Test func theChecksMarksOfTheMinutesTravelWithTheItems() {
        var facts = BriefFacts()
        facts.last = BriefFixtures.last(decisions: [BriefFixtures.decision(1, "Maybe keep the shell", unconfirmed: true)],
                                        tasks: [BriefFixtures.task(2, "Order samples", due: Self.date(days: -2), unconfirmed: true)])
        var uncertain = BriefFixtures.task(3, "Call the supplier", ownerName: "Speaker 2")
        uncertain.ownerUncertain = true
        facts.last = BriefFixtures.last(decisions: facts.last!.decisions, tasks: facts.last!.openTasks + [uncertain])
        let items = BriefBuilder.assemble(BriefFixtures.assembly(facts: facts)).section(.lastTime)!.items
        #expect(items.first { $0.kind == .decision }?.unconfirmed == true)
        let order = items.first { $0.taskID == 2 }
        #expect(order?.unconfirmed == true && order?.overdue == true, "past due at the meeting: shown with a label, not colour only")
        #expect(items.first { $0.taskID == 3 }?.ownerUncertain == true)
    }

    @Test func aTaskDueTodayIsNotOverdue() {
        let now = BriefFixtures.now
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        #expect(!BriefBuilder.isOverdue(today, now: now), "due is a whole day: today's task is due, not overdue")
        #expect(BriefBuilder.isOverdue(yesterday, now: now))
        #expect(!BriefBuilder.isOverdue(nil, now: now))
        let event = BriefFixtures.event()
        var facts = BriefFacts()
        facts.openTasks = [BriefFixtures.task(1, "Due today", due: today), BriefFixtures.task(2, "Due yesterday", due: yesterday)]
            .map { BriefTaskFact(task: $0, meetingDate: Self.date(days: -7)) }
        let items = BriefBuilder.assemble(BriefFixtures.assembly(event, facts: facts)).section(.openTasks)!.items
        #expect(items.first { $0.taskID == 1 }?.overdue == false && items.first { $0.taskID == 2 }?.overdue == true)
        #expect(items.first?.taskID == 2, "only the overdue one sorts first")
    }

    /// The brief for a meeting days away must not call work late that is not due yet: it says "due before this meeting" instead.
    @Test func aTaskDueBetweenTodayAndAMeetingDaysAwayIsNotOverdue() {
        let calendar = Calendar.current
        let now = BriefFixtures.now
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        // The meeting is a week away.
        let event = BriefFixtures.event(in: 7 * 24 * 60)
        #expect(BriefBuilder.isOverdue(day(-1), now: now) && !BriefBuilder.isDueBeforeMeeting(day(-1), at: event.start, now: now), "late is late, not 'before the meeting'")
        #expect(!BriefBuilder.isOverdue(day(2), now: now) && BriefBuilder.isDueBeforeMeeting(day(2), at: event.start, now: now))
        #expect(!BriefBuilder.isOverdue(day(0), now: now) && BriefBuilder.isDueBeforeMeeting(day(0), at: event.start, now: now))
        #expect(!BriefBuilder.isDueBeforeMeeting(day(7), at: event.start, now: now), "due on the day of the meeting is not before it")
        #expect(!BriefBuilder.isDueBeforeMeeting(day(9), at: event.start, now: now))
        var facts = BriefFacts()
        facts.openTasks = [BriefFixtures.task(1, "Late", due: day(-1)), BriefFixtures.task(2, "Soon", due: day(2)), BriefFixtures.task(3, "After", due: day(9))]
            .map { BriefTaskFact(task: $0, meetingDate: Self.date(days: -7)) }
        let items = BriefBuilder.assemble(BriefFixtures.assembly(event, facts: facts)).section(.openTasks)!.items
        let marks = Dictionary(uniqueKeysWithValues: items.map { ($0.taskID ?? 0, ($0.overdue, $0.dueBeforeMeeting)) })
        #expect(marks[1]?.0 == true && marks[1]?.1 == false)
        #expect(marks[2]?.0 == false && marks[2]?.1 == true)
        #expect(marks[3]?.0 == false && marks[3]?.1 == false)
    }

    @Test func aReminderDueYesterdayIsOverdueNotDueBeforeTheMeeting() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: BriefFixtures.now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        var a = BriefFixtures.assembly(BriefFixtures.event(in: 3 * 24 * 60))
        a.reminders = [BriefReminder(id: "1", title: "Call Ana López about it", due: day(-1), listID: "L", listName: "Work"),
                       BriefReminder(id: "2", title: "Call Ana López again", due: day(1), listID: "L", listName: "Work")]
        let items = BriefBuilder.assemble(a).section(.reminders)!.items
        let late = items.first { $0.link == .reminder(id: "1") }
        let soon = items.first { $0.link == .reminder(id: "2") }
        #expect(late?.overdue == true && late?.dueBeforeMeeting == false)
        #expect(soon?.overdue == false && soon?.dueBeforeMeeting == true)
    }

    // MARK: Open tasks

    @Test func openTasksPutWhatIsOverdueFirstThenWhatThePersonOwes() {
        let me: Int64 = 99
        var facts = BriefFacts()
        facts.selfEntityID = me
        let a = BriefFixtures.task(1, "Overdue, someone else", owner: 5, due: Self.date(days: -3))
        let b = BriefFixtures.task(2, "Mine, no date", owner: me, ownerName: "Me")
        let c = BriefFixtures.task(3, "Others, next week", owner: 5, due: Self.date(days: 6))
        let d = BriefFixtures.task(4, "Others, no date", owner: 5, created: 5_000)
        let e = BriefFixtures.task(5, "Overdue and mine", owner: me, due: Self.date(days: -1))
        let done = BriefFixtures.task(6, "Already done", owner: 5, status: .done)
        facts.openTasks = [a, b, c, d, e, done].map { BriefTaskFact(task: $0, meetingDate: Self.date(days: -7)) }
        let keyword = BriefBuilder.assemble(BriefFixtures.assembly(facts: facts)).section(.openTasks)!
        #expect(keyword.items.compactMap(\.taskID) == [5, 1, 2, 3, 4], "done is never shown; overdue first, then mine, then by due date")
        #expect(keyword.items.first?.isYours == true && keyword.items.first?.overdue == true)

        // With the search model the topic re-orders inside the same candidates; below the floor a task is not dropped.
        var semantic = BriefFixtures.assembly(facts: facts, mode: .semantic)
        semantic.taskCosines = [1: 0.9, 2: 0.2, 3: 0.3, 4: 0.8, 5: 0.1]
        let ranked = BriefBuilder.assemble(semantic).section(.openTasks)!
        #expect(ranked.items.compactMap(\.taskID) == [5, 1, 2, 4, 3], "the related one (0.8) goes before the one only due earlier; the unrelated one stays")
        #expect(ranked.total == 5)
    }

    @Test func aTaskAlreadyShownUnderLastTimeIsNotRepeated() {
        let shown = BriefFixtures.task(1, "Send the revised budget", owner: 5)
        var facts = BriefFacts()
        facts.last = BriefFixtures.last(tasks: [shown])
        facts.openTasks = [BriefTaskFact(task: shown, meetingDate: nil), BriefTaskFact(task: BriefFixtures.task(2, "Book the room", owner: 5), meetingDate: nil)]
        let snapshot = BriefBuilder.assemble(BriefFixtures.assembly(facts: facts))
        #expect(snapshot.section(.openTasks)!.items.compactMap(\.taskID) == [2])
    }

    // MARK: Related meetings

    @Test func relatedMeetingsPassOnTheRawCosineAndNeverOnABoost() {
        var a = BriefFixtures.assembly(mode: .semantic)
        a.facts.last = BriefFixtures.last(id: 1)
        a.meetingHits = [Self.hit(1, "The series meeting", cosine: 0.95), Self.hit(2, "Close", cosine: 0.80), Self.hit(3, "Just below", cosine: 0.64),
                         Self.hit(4, "Near", cosine: 0.70), Self.hit(5, "No cosine", cosine: nil), Self.hit(6, "Also near", cosine: 0.69),
                         Self.hit(7, "Edge", cosine: 0.66), Self.hit(2, "Close again", cosine: 0.77)]
        let section = BriefBuilder.assemble(a).section(.relatedMeetings)!
        #expect(section.items.map(\.meetingID) == [2, 4, 6], "best first, at most three; a meeting appears once")
        #expect(section.total == 4, "7 passes too, so \"Show all (4)\"")
        #expect(!section.items.contains { $0.meetingID == 1 }, "the meeting already shown under Last time is not repeated")
        #expect(BriefBuilder.floor == Double(SemanticRanker.relatedFloor), "the floor is the one Ask uses")
        #expect(section.items.first?.link == .segment(meetingID: 2, segmentID: 20))
    }

    @Test func theKeywordGateNeedsTwoWordsOrACodeOrARareName() {
        let query = "Supplier change, shell material and PO-48213 for Contoso"
        func passes(_ text: String) -> Bool { BriefKeywordGate.passes(query: query, text: text, locale: "en-US") }
        #expect(passes("We discussed the supplier change and what to do next"))
        #expect(!passes("The supplier was late again"), "one shared word is a coincidence")
        #expect(!passes("Lunch plans for the week and the weather"))
        #expect(passes("Invoice po-48213 was paid on time"), "a code")
        #expect(passes("Contoso asked for a quote"), "a rare name")
        #expect(!passes("The company sent a quote"))
        // Spanish and Japanese use the same gate with their own words.
        #expect(BriefKeywordGate.passes(query: "cambio de proveedor y material de la carcasa", text: "hablamos del cambio de proveedor y de la carcasa", locale: "es-ES"))
        #expect(BriefKeywordGate.passes(query: "サプライヤー変更と予算", text: "サプライヤー変更について予算も議論した", locale: "ja-JP"))
    }

    @Test func withoutTheSearchModelTheKeywordGateDecidesAndALowCosineStillMeansNothing() {
        var a = BriefFixtures.assembly(mode: .keyword, query: "supplier change shell material budget")
        a.meetingHits = [Self.hit(2, "Good", text: "the supplier change and the shell material were discussed"), Self.hit(3, "Weather", text: "rain tomorrow, bring a coat"),
                         Self.hit(4, "One word", text: "the budget"), Self.hit(5, "Cosine only", text: "unrelated", cosine: 0.99)]
        #expect(BriefBuilder.assemble(a).section(.relatedMeetings)!.items.map(\.meetingID) == [2], "keyword mode never trusts a cosine it did not compute")
    }

    @Test func aGenericTitleWithNoHistorySkipsTheRelatedSections() {
        var a = BriefFixtures.assembly(query: "Weekly sync", sufficient: false)
        a.facts.last = BriefFixtures.last(materials: [BriefMaterial(sourceID: 3, relPath: "agenda.md", name: "agenda.md")])
        a.meetingHits = [Self.hit(2, text: "weekly sync everything")]
        a.documentHits = [Self.doc(1, "a.md", text: "weekly sync")]
        a.reminders = [BriefReminder(id: "r", title: "Weekly sync prep", due: nil, listID: "L", listName: "Work")]
        let snapshot = BriefBuilder.assemble(a)
        #expect(snapshot.relatedSkipped)
        #expect(snapshot.section(.relatedMeetings) == nil && snapshot.section(.reminders) == nil)
        #expect(snapshot.section(.documents)!.items.map(\.kind) == [.material], "the last meeting's own files are not noise; retrieved passages are skipped")
        #expect(!BriefQuery.isSufficient("Weekly sync", locale: "en-US") && BriefQuery.isSufficient("Supplier review budget 2027", locale: "en-US"))
    }

    // MARK: Documents and notes

    @Test func documentsListTheMeetingsFilesFirstThenOnePassagePerFile() {
        var a = BriefFixtures.assembly(mode: .semantic)
        a.facts.notesSourceIDs = [8]
        a.facts.last = BriefFixtures.last(materials: [BriefMaterial(sourceID: 3, relPath: "plan.pdf", name: "plan.pdf")])
        a.documentHits = [Self.doc(3, "plan.pdf", cosine: 0.9), Self.doc(4, "budget.xlsx", text: "Q3 total", cosine: 0.7, key: "k1"),
                          Self.doc(4, "budget.xlsx", text: "Q4 total", cosine: 0.8, key: "k2"), Self.doc(8, "weekly.md", text: "supplier call", cosine: 0.75),
                          Self.doc(5, "weak.txt", cosine: 0.5), Self.doc(6, "boost.txt", cosine: nil), Self.doc(9, "x.md", cosine: 0.68), Self.doc(10, "y.md", cosine: 0.67)]
        let items = BriefBuilder.assemble(a).section(.documents)!.items
        #expect(items.map(\.kind) == [.material, .document, .note, .document])
        #expect(items.map(\.text) == ["plan.pdf", "budget.xlsx", "weekly.md", "x.md"], "the file the meeting carries is not offered twice; one passage per file, the best")
        #expect(items[1].link == .passage(key: "k2", sourceID: 4, relPath: "budget.xlsx") && items[1].detail == "Q4 total")
        #expect(items[2].kind == .note, "a file of a folder marked as exported Notes is badged \"Note\"")
    }

    // MARK: Reminders

    @Test func remindersComeFromTheNameOfAnAttendeeOrTheTopic() {
        let r = { (id: String, title: String, days: Double?) in BriefReminder(id: id, title: title, due: days.map { Self.date(days: $0) }, listID: "L", listName: "Work") }
        var a = BriefFixtures.assembly(query: "supplier change shell material budget")
        a.reminders = [r("1", "Call Ana López about the invoice", 2), r("2", "Pay the supplier invoice for the shell", -3), r("3", "Buy milk", nil),
                       r("4", "Dentist on Friday", 1), r("5", "Ask Ana to send the shell drawings", nil), r("6", "Review shell material supplier quote", 4),
                       r("7", "Send flowers to Lopez", nil)]
        let section = BriefBuilder.assemble(a).section(.reminders)!
        #expect(section.items.map(\.text).prefix(3).allSatisfy { $0.contains("Ana") || $0.lowercased().contains("shell") })
        #expect(section.items.count == 3 && section.total == 4, "at most three; Buy milk and the dentist are noise")
        #expect(section.items.first?.link == .reminder(id: "1") && section.items.allSatisfy(\.isYours))
        let late = section.items.first { $0.text.hasPrefix("Pay") }
        #expect(late == nil || (late?.overdue == true && late?.dueBeforeMeeting == false), "three days late is overdue, never \"before this meeting\"")
        #expect(!section.items.contains { $0.text == "Send flowers to Lopez" }, "\"Lopez\" is not Ana López's name")
    }

    @Test func remindersFollowTheCosineWhenTheSearchModelRanks() {
        let r = { (id: String, title: String) in BriefReminder(id: id, title: title, due: nil, listID: "L", listName: "Work") }
        var a = BriefFixtures.assembly(mode: .semantic)
        a.reminders = [r("1", "Phone the vendor"), r("2", "Prepare the quote"), r("3", "Buy milk"), r("4", "Ask Ana about it")]
        a.reminderCosines = ["1": 0.7, "2": 0.9, "3": 0.5, "4": 0.1]
        #expect(BriefBuilder.assemble(a).section(.reminders)!.items.map(\.link) == [.reminder(id: "4"), .reminder(id: "2"), .reminder(id: "1")],
                "a name first, then by cosine; under 0.65 nothing")
    }

    // MARK: Determinism and precedence

    @Test func theSameInputsGiveTheSameSnapshotAndAChangeShowsInTheHash() {
        var facts = BriefFacts()
        facts.people = Self.people()
        facts.last = BriefFixtures.last(decisions: [BriefFixtures.decision(1, "Keep the shell", segment: 5)], tasks: [BriefFixtures.task(2, "Send budget", due: Self.date(days: 2))])
        var a = BriefFixtures.assembly(facts: facts, mode: .semantic)
        a.meetingHits = [Self.hit(2, cosine: 0.8), Self.hit(3, cosine: 0.7)]
        let first = BriefBuilder.assemble(a), second = BriefBuilder.assemble(a)
        #expect(first == second && first.digest == second.digest)
        a.meetingHits[0] = Self.hit(2, text: "different words", cosine: 0.8)
        #expect(BriefBuilder.assemble(a).digest != first.digest || BriefBuilder.assemble(a).items.map(\.detail) != first.items.map(\.detail))
        a.facts.last = BriefFixtures.last(decisions: [BriefFixtures.decision(1, "Drop the shell", segment: 5)])
        #expect(BriefBuilder.assemble(a).digest != first.digest)
    }

    @Test func theSeriesAndTheAttendeesChooseLastTimeWhateverTheTopicSaysElsewhere() {
        // Every team discusses "a remote control": the topic alone would bring in the wrong team's meeting.
        var a = BriefFixtures.assembly(mode: .semantic, query: "remote control design")
        a.facts.last = BriefFixtures.last(id: 10, title: "Our team, last time", decisions: [BriefFixtures.decision(1, "Use a C-shaped shell", meeting: 10)])
        a.meetingHits = [Self.hit(77, "Another team's remote control", cosine: 0.97), Self.hit(10, "Our team, last time", cosine: 0.9)]
        let snapshot = BriefBuilder.assemble(a)
        #expect(snapshot.section(.lastTime)!.items.allSatisfy { $0.meetingID == 10 })
        #expect(snapshot.section(.relatedMeetings)!.items.map(\.meetingID) == [77], "the other team is only ever \"related\"")
    }
}
