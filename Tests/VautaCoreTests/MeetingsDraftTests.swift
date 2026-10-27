// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Autosaved drafts of the meetings window and single-line text input.
@Suite("Meetings · drafts")
struct MeetingsDraftTests {
    static let card = MeetingCard(summary: "Model summary", topics: ["Budget", "Hiring"], openQuestions: ["Who?"])

    @Test func untouchedDraftIsClean() {
        let d = MeetingDraft(meetingID: 1, title: nil, card: Self.card)
        #expect(!d.isDirty && d.changes.isEmpty)
        #expect(d.title.isEmpty, "an untitled meeting shows a placeholder, not the automatic title")
        #expect(d.topicsText == "Budget, Hiring")
    }

    @Test func renamingOnlyWritesTheTitle() {
        var d = MeetingDraft(meetingID: 1, title: nil, card: Self.card)
        d.title = "  Weekly sync\n"
        #expect(d.changes == MeetingDraft.Changes(title: .some("Weekly sync"), card: nil),
                "a rename must not save the card (it would become the user's card)")
        d.markSaved(d.changes)
        #expect(!d.isDirty)
        d.title = ""
        #expect(d.changes.title == .some(nil), "an emptied title goes back to the automatic one")
    }

    @Test func editsTypedWhileSavingStayDirty() {
        var d = MeetingDraft(meetingID: 1, title: "A", card: nil)
        d.summary = "First"
        let inFlight = d.changes
        d.summary = "First and more"
        d.markSaved(inFlight)
        #expect(d.isDirty && d.changes.card?.summary == "First and more")
    }

    @Test func editingTheCardKeepsStoredOpenQuestions() throws {
        var d = MeetingDraft(meetingID: 1, title: "T", card: Self.card)
        d.summary = "My summary"
        let card = try #require(d.changes.card)
        #expect(card.summary == "My summary" && card.topics == ["Budget", "Hiring"])
        #expect(card.openQuestions == nil, "nil keeps the stored open questions")
        #expect(d.changes.title == nil)
    }

    @Test func whitespaceAndSeparatorsAreNotEdits() {
        var d = MeetingDraft(meetingID: 1, title: "T", card: Self.card)
        d.summary = "Model summary \n"
        d.topicsText = "Budget ,Hiring,"
        d.title = "T "
        #expect(!d.isDirty)
    }

    @Test func topicsAcceptTheCommaOfEachScript() {
        #expect(MeetingDraft.topics("予算、採用，計画") == ["予算", "採用", "計画"])
        #expect(MeetingDraft.topics("ميزانية، توظيف") == ["ميزانية", "توظيف"])
        #expect(MeetingDraft.topics(" a ; b\nc ,, ") == ["a", "b", "c"])
    }

    @Test func rebaseKeepsEditsAndTakesNewValues() {
        var d = MeetingDraft(meetingID: 1, title: nil, card: nil)
        d.title = "Mine"
        // The model finishes the minutes while the user edits the title.
        d.rebase(title: "Model title", card: Self.card)
        #expect(d.title == "Mine")
        #expect(d.summary == "Model summary" && d.topicsText == "Budget, Hiring")
        #expect(d.changes == MeetingDraft.Changes(title: .some("Mine"), card: nil))

        d.summary = "Edited"
        d.rebase(title: "Model title", card: MeetingCard(summary: "Newer", topics: ["Other"]))
        #expect(d.summary == "Edited" && d.topicsText == "Other")
        #expect(d.changes.card?.summary == "Edited")
    }

    @Test func taskDraftTracksEdits() {
        let task = TaskItem(id: 7, meetingID: 1, segmentID: nil, t: nil, text: "Send report", ownerID: nil, ownerName: nil,
                            due: nil, status: .open, source: "llm", createdAt: .now, meetingTitle: nil)
        var d = TaskDraft(task)
        #expect(!d.isDirty && d.canSave)
        d.hasDue = true
        #expect(d.isDirty && d.edited.due != nil)
        d.hasDue = false
        d.text = "Send\r\nthe report "
        #expect(d.edited.text == "Send the report")
        d.text = "  "
        #expect(!d.canSave)
    }

    @Test func singleLineFlattening() {
        #expect(SingleLineText.flatten("a\r\nb\rc\nd") == "a b c d")
        #expect(SingleLineText.flatten("one\u{2028}two\u{2029}three\u{85}four") == "one two three four")
        #expect(SingleLineText.flatten("line\n\n\n next") == "line next")
        #expect(SingleLineText.flatten("Ana\r\nBea\n\n Carlos ", separator: ", ") == "Ana, Bea, Carlos")
        #expect(SingleLineText.flatten("no breaks", separator: ", ") == "no breaks")
        #expect(SingleLineText.flatten("no breaks  here") == "no breaks  here")
        #expect(SingleLineText.containsBreak("x\u{2028}y") && !SingleLineText.containsBreak("x y"))
    }
}
