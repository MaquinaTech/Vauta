// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// "Last time" is shown only for a backend whose minutes passed its gate, and none has (docs/BRIEF.md). Without it the last meeting leads
/// "Related meetings", the open tasks of the people invited stay, and nothing says that the earlier meetings left nothing open.
@Suite("Brief: Last time only where it passed")
struct BriefLastTimeShippingTests {
    @Test func noBackendShowsItUntilOnePasses() {
        for backend in BriefBackend.allCases { #expect(!BriefLastTimeShipping.shows(backend: backend), "\(backend)") }
        #expect(!BriefLastTimeShipping.shows(backend: nil))
        #expect(BriefLastTimeShipping.shows(backend: .integrated, shipped: [.integrated]))
        #expect(!BriefLastTimeShipping.shows(backend: .apple, shipped: [.integrated]))
        #expect(!BriefLastTimeShipping.shows(backend: nil, shipped: [.integrated]), "a brief built without a model shows it only if every backend does")
        #expect(BriefLastTimeShipping.shows(backend: nil, shipped: Set(BriefBackend.allCases)))
    }

    static func facts(ownedTask: Bool = true) -> BriefFacts {
        var facts = BriefFacts()
        facts.people = [BriefPerson(name: "Ana López", entityID: 5, lastMet: BriefFixtures.now.addingTimeInterval(-7 * 86_400), meetingsTogether: 3)]
        let owned = BriefFixtures.task(2, "Send the revised budget", owner: 5, ownerName: "Ana López", segment: 200)
        facts.last = BriefFixtures.last(decisions: [BriefFixtures.decision(1, "Keep the C-shaped shell", segment: 100)],
                                        tasks: [BriefFixtures.task(3, "Book the factory visit", segment: 300)] + (ownedTask ? [owned] : []),
                                        questions: [BriefOpenQuestion(text: "Who signs off?", segmentID: 400, t: 30)])
        // As the store gathers them: the open tasks of the people invited, from every earlier meeting, the last one too.
        if ownedTask { facts.openTasks = [BriefTaskFact(task: owned, meetingDate: facts.last?.date)] }
        return facts
    }

    @Test func withoutItTheLastMeetingLeadsTheRelatedMeetingsAndTheOwnedTasksStay() throws {
        var a = BriefFixtures.assembly(facts: Self.facts())
        a.showsLastTime = false
        let snapshot = BriefBuilder.assemble(a)
        #expect(snapshot.section(.lastTime) == nil && snapshot.lastTimeHidden)
        let related = try #require(snapshot.section(.relatedMeetings))
        #expect(related.items.first?.link == .meeting(meetingID: 1, t: nil) && related.items.first?.text == "Supplier review")
        #expect(related.items.first?.detail == nil, "no line of the minutes comes with it")
        #expect(snapshot.section(.openTasks)?.items.map(\.text) == ["Send the revised budget"], "the task of someone invited stays; the unowned one went with the section")
        for word in ["Keep the C-shaped shell", "Who signs off", "The team compared"] {
            #expect(!snapshot.items.contains { $0.text.contains(word) }, "\(word) is a line of the last minutes")
        }
        #expect(!snapshot.isFirstMeeting && snapshot.hasContent)

        let shown = BriefBuilder.assemble(BriefFixtures.assembly(facts: Self.facts()))
        #expect(shown.section(.lastTime) != nil && !shown.lastTimeHidden && shown.section(.relatedMeetings) == nil, "with the section, as before")
        #expect(shown.digest != snapshot.digest)
    }

    @Test func thePanelCardShowsTheLastMeetingRatherThanNothingOpen() throws {
        var a = BriefFixtures.assembly(facts: Self.facts(ownedTask: false))
        a.showsLastTime = false
        let snapshot = BriefBuilder.assemble(a)
        #expect(snapshot.section(.openTasks) == nil)
        let card = BriefPanelCard.make(event: BriefFixtures.event(), snapshot: snapshot, locked: false, hot: false)
        guard case .ready(let ready) = card.content, case .lines(let lines) = ready.body else {
            Issue.record("expected the last meeting as the card's line, got \(card.content)")
            return
        }
        #expect(lines.map(\.link) == [.meeting(meetingID: 1, t: nil)])
        var nothing = BriefFacts()
        nothing.people = Self.facts().people
        nothing.last = BriefFixtures.last()
        let open = BriefPanelCard.make(event: BriefFixtures.event(), snapshot: BriefBuilder.assemble(BriefFixtures.assembly(facts: nothing)), locked: false, hot: false)
        guard case .ready(let shown) = open.content, case .lines = shown.body else {
            Issue.record("with the section, the summary line is the card's line")
            return
        }
    }
}
