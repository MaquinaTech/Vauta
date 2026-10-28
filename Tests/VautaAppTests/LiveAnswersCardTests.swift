// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Vauta
@testable import VautaCore

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}

/// The Answers card of the panel: which rows it holds, what is announced, and the texts of its states. The detector and the model are
/// not involved: the card only follows the events it is given.
@Suite("App: live answers card")
@MainActor
struct LiveAnswersCardTests {
    static let content = AutoAnswerContent(answer: "The contract expires in March.", claims: [
        .init(text: "March", cites: [.init(kind: .thisMeeting, segmentID: 4, meetingID: 1, t: 123)])])

    private func row(_ question: String, t: Double = 100, content: AutoAnswerContent = content) -> AnswerRow {
        AnswerRow(question: question, channel: .others, t: t, content: content)
    }

    private func model() -> (LiveAnswersModel, Locked<[String]>) {
        let model = LiveAnswersModel()
        let spoken = Locked([String]())
        model.announce = { text in spoken.withLock { $0.append(text) } }
        return (model, spoken)
    }

    @Test func aQuestionBeingAnsweredNeverMakesACardAlone() {
        let (model, _) = model()
        #expect(!model.isVisible)
        model.apply(.answering(AnsweringRow(question: "When?", channel: .others, t: 1)))
        #expect(!model.isVisible && model.rows.isEmpty && !model.isWorking, "most questions end without an answer: a card that comes and goes is noise")
        model.apply(.answer(row("A?")))
        #expect(model.isVisible)
    }

    @Test func aPauseNothingElseShowsMakesACardAloneAndOneTheChannelWarningsCoverDoesNot() {
        let (model, _) = model()
        for pause in [LiveAnswerPause.modelUnavailable, .tooWarm, .noSources] {
            model.apply(.paused(pause))
            #expect(model.isVisible && model.visiblePause == pause && model.rows.isEmpty, "before the first answer a paused feature must not look like a working one")
            model.apply(.paused(nil))
            #expect(!model.isVisible && model.visiblePause == nil, "the card leaves when the cause clears")
        }
        model.apply(.paused(.transcriptBehind))
        #expect(!model.isVisible, "the warning of the lagging channel already says it")
        model.apply(.answer(row("A?")))
        #expect(model.visiblePause == .transcriptBehind, "the line rides on a card that is there for another reason")
        model.apply(.paused(nil))
        #expect(model.visiblePause == nil)
    }

    @Test func aQuestionBeingAnsweredNeverAddsARowToACardThatIsThere() {
        let (model, _) = model()
        model.apply(.answer(row("Earlier?")))
        let working = AnsweringRow(question: "When?", channel: .others, t: 1)
        model.apply(.answering(working))
        #expect(model.rows.count == 1 && model.isWorking, "the open answer does not move: only the header shows that something is going on")
        model.apply(.withdrawn(working.id))
        #expect(model.rows.count == 1 && !model.isWorking)
    }

    @Test func aQuestionBeingAnsweredBecomesTheAnswerAndOpens() {
        let (model, spoken) = model()
        model.showsHint = true
        let working = AnsweringRow(question: "When does it expire?", channel: .others, t: 100)
        model.apply(.answering(working))
        #expect(model.rows.isEmpty && model.isWorking)
        model.apply(.answer(AnswerRow(id: working.id, storedID: nil, question: working.question, channel: .others, t: 100, content: Self.content)))
        #expect(model.rows.count == 1 && model.openID == working.id && !model.isWorking)
        #expect(spoken.withLock { $0 } == ["Answer available"], "only that an answer is there, never what it says")
    }

    /// A new answer must not move the panel's scroll: on a short screen it hid Mark a Moment and the quick note (and the person may be
    /// typing in the quick note). The panel's source has no programmatic scroll.
    @Test func theArrivalOfAnAnswerNeverScrollsThePanel() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/Vauta/App/Panel/RecorderPanel.swift", "Sources/Vauta/App/Panel/PanelWarnings.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(!source.contains("scrollTo(") && !source.contains("ScrollViewReader"), "\(path) scrolls the panel")
        }
    }

    @Test func theFirstRunHintCountsAsSeenOnlyOnceItWasOnScreen() {
        let (model, _) = model()
        model.showsHint = true
        #expect(!model.hintCountsAsSeen, "below the fold of the panel it was never read")
        model.hintAppeared()
        #expect(model.hintCountsAsSeen)
        model.showsHint = false
        #expect(!model.hintCountsAsSeen, "a new hint starts unseen")
        model.hintAppeared()
        #expect(!model.hintCountsAsSeen, "no hint, nothing to have seen")
    }

    @Test func aNewAnswerLeavesTheRowThePersonOpenedToReadAndWaitsFolded() {
        let (model, _) = model()
        let a = row("A?"), b = row("B?"), c = row("C?")
        model.apply(.answer(a))
        model.apply(.answer(b))
        #expect(model.openID == b.id, "the newest was open: the next one takes over")
        model.toggleOpen(a.id)
        model.apply(.answer(c))
        #expect(model.openID == a.id, "the older row being read stays open")
        #expect(model.rows.map(\.id) == [c.id, b.id, a.id] && !model.isOpen(c.id))
        model.toggleOpen(a.id)
        let d = row("D?")
        model.apply(.answer(d))
        #expect(model.openID == d.id, "nothing was open: the new answer opens")
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// On a short screen a card below the live notes is out of sight and nothing says an answer arrived: it comes first in the
    /// scrolling part, ahead of the notes (the tools stay pinned or scroll as before).
    @Test func theAnswersCardComesBeforeTheLiveNotesInTheScrollingPart() throws {
        let panel = try source("Sources/Vauta/App/Panel/RecorderPanel.swift")
        let middle = try #require(panel.range(of: "@ViewBuilder private var middle"))
        let body = panel[middle.upperBound...]
        let answers = try #require(body.range(of: "AnswersCard("))
        let notes = try #require(body.range(of: "LiveNotesView("))
        #expect(answers.lowerBound < notes.lowerBound)
    }

    @Test func anAbortedStartStopsTheDetector() throws {
        let lifecycle = try source("Sources/Vauta/App/RecorderModel+Lifecycle.swift")
        let abort = try #require(lifecycle.range(of: "func abortStart("))
        let body = lifecycle[abort.upperBound...].prefix(1_500)
        #expect(body.contains("stopLiveAnswers()"))
    }

    @Test func atMostThreeRowsStayAndTheNewestIsOpen() {
        let (model, _) = model()
        let rows = (1...4).map { row("Question \($0)?", t: Double($0)) }
        for r in rows { model.apply(.answer(r)) }
        #expect(model.rows.count == 3)
        #expect(model.rows.map(\.question) == ["Question 4?", "Question 3?", "Question 2?"], "newest first; the oldest left the panel")
        #expect(model.openID == rows[3].id && !model.isOpen(rows[2].id))
        model.toggleOpen(rows[2].id)
        #expect(model.isOpen(rows[2].id) && !model.isOpen(rows[3].id))
    }

    @Test func withdrawnAndDismissedRowsLeaveAndTheNextAnswerOpens() {
        let (model, _) = model()
        let a = row("A?"), b = row("B?")
        model.apply(.answer(a)); model.apply(.answer(b))
        var dismissed: [AnswerRow] = []
        model.onDismiss = { dismissed.append($0) }
        model.dismiss(b.id)
        #expect(model.rows.map(\.question) == ["A?"] && model.openID == a.id && dismissed.map(\.question) == ["B?"])
        model.apply(.withdrawn(a.id))
        #expect(model.rows.isEmpty && model.openID == nil && !model.isVisible)
    }

    @Test func keepingTellsTheOwnerAndTogglesTheState() {
        let (model, _) = model()
        let a = AnswerRow(question: "A?", channel: .others, t: 1, content: Self.content)
        model.apply(.answer(a))
        var kept: [Bool] = []
        model.onKeep = { _, on in kept.append(on) }
        model.toggleKeep(a.id)
        #expect(model.isKept(a.id) && kept == [true])
        model.toggleKeep(a.id)
        #expect(!model.isKept(a.id) && kept == [true, false])
    }

    @Test func stoppingTheWorkTellsTheOwnerWhichRowsAndIgnoresWhatComesLater() {
        let (model, _) = model()
        model.showsHint = true
        let working = AnsweringRow(question: "A?", channel: .others, t: 1)
        model.apply(.answering(working))
        var stopped: [UUID] = []
        model.onStop = { stopped.append($0) }
        model.stopWorking()
        #expect(stopped == [working.id] && model.rows.isEmpty && !model.isWorking)
        // The answer that was already on its way, and a second "working" event, do not bring the card back.
        model.apply(.answering(working))
        model.apply(.answer(AnswerRow(id: working.id, question: "A?", channel: .others, t: 1, content: Self.content)))
        #expect(model.rows.isEmpty && model.openID == nil && !model.isWorking)
    }

    @Test func aDismissedAnswerStaysDismissedWhateverTheDetectorSaysLater() {
        let (model, spoken) = model()
        let a = row("A?")
        model.apply(.answer(a))
        model.dismiss(a.id)
        model.apply(.answer(a))
        #expect(model.rows.isEmpty && spoken.withLock { $0 }.count == 1, "no second announcement")
    }

    @Test func copyProtectionKeepsTheAnswerOffTheClipboard() {
        let (model, _) = model()
        let a = row("A?")
        model.apply(.answer(a))
        model.copyProtected = { true }
        #expect(model.copyableText(a.id) == nil && model.copiedID == nil)
        model.copyProtected = { false }
        #expect(model.copyableText(a.id)?.contains("The contract expires in March.") == true && model.copiedID == a.id)
    }

    @Test func turnOffOnTheHintTurnsTheFeatureOffAndCountsTheHintAsSeen() {
        let (model, _) = model()
        model.showsHint = true
        var answered: [Bool] = [], off = 0
        model.onHintAnswered = { answered.append($0) }
        model.onTurnOff = { off += 1 }
        model.turnOffFromHint()
        #expect(!model.showsHint && answered == [false] && off == 1)
    }

    @Test func theCopyShortcutIsNotAWindowWideKeyEquivalent() throws {
        // A button shortcut would take ⌘C from the note field and from selected transcript text; the answer copies through the
        // row's own copy command, which only runs while that row has the keyboard.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Vauta/App/Panel/AnswersCard.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(!source.contains("keyboardShortcut") && source.contains(".onCopyCommand"))
    }

    @Test func aNewAnswerNeitherMakesThePanelKeyNorMovesTheKeyboard() {
        let (model, _) = model()
        let field = NSTextField(string: "")
        let host = NSHostingView(rootView: AnswersCard(model: model))
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: true)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 400))
        host.frame = NSRect(x: 0, y: 40, width: 360, height: 360)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 24)
        container.addSubview(host); container.addSubview(field)
        window.contentView = container
        window.makeFirstResponder(field)
        let responder = window.firstResponder
        let wasKey = window.isKeyWindow
        model.apply(.answer(row("When does it expire?")))
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        #expect(window.isKeyWindow == wasKey && window.firstResponder === responder, "the card appears without taking the keyboard")
    }

    @Test func aCardWithAnOpenMixedAnswerAndTwoFoldedRowsStaysWithinABudgetForShortScreens() {
        let (model, _) = model()
        let mixed = AutoAnswerContent(answer: "The contract expires in March, the pilot budget was fifty thousand euros and onboarding takes two weeks.", claims: [
            .init(text: "March", cites: [.init(kind: .thisMeeting, segmentID: 4, meetingID: 1, t: 123)]),
            .init(text: "Budget", cites: [.init(kind: .pastMeeting, segmentID: 9, meetingID: 2, t: 40, title: "Pilot kickoff", date: 1_790_000_000)]),
            .init(text: "Onboarding", cites: [.init(kind: .document, fileName: "Onboarding.pdf", locator: "p. 4", sourceID: 1, relPath: "Onboarding.pdf", passageID: 1, quote: "two weeks")])])
        model.apply(.answer(row("Earlier question one?", t: 10)))
        model.apply(.answer(row("Earlier question two?", t: 20)))
        model.apply(.answer(row("When does it expire and what did the pilot cost?", t: 30, content: mixed)))
        let host = NSHostingView(rootView: AnswersCard(model: model).frame(width: 328))
        let height = host.fittingSize.height
        #expect(height > 100 && height <= 340, "\(height)")
    }

    @Test func theHintIsAnsweredOnce() {
        let (model, _) = model()
        model.showsHint = true
        #expect(model.isVisible)
        var accepted: [Bool] = []
        model.onHintAnswered = { accepted.append($0) }
        model.answerHint(accepted: true)
        #expect(!model.showsHint && accepted == [true] && !model.isVisible)
    }

    @Test func theCopiedTextHasTheQuestionTheAnswerAndItsSources() {
        let text = LiveAnswersModel.plainText(row("When does the contract expire?"))
        #expect(text.hasPrefix("When does the contract expire?\n\nThe contract expires in March.\n\n"))
        #expect(text.contains("This meeting (02:03)"))
    }

    @Test func everyPauseHasItsOwnSentence() {
        let texts = [LiveAnswerPause.modelUnavailable, .tooWarm, .transcriptBehind, .noSources].map { AnswersCard.pauseText($0) }
        #expect(Set(texts).count == 4 && texts.allSatisfy { $0.hasPrefix("Live answers paused:") || !$0.isEmpty })
    }

    @Test func eachSourceKindHasItsOwnGlyphAndLabel() {
        let kinds: [AutoAnswerContent.Cite.Kind] = [.thisMeeting, .pastMeeting, .document]
        #expect(Set(kinds.map { QuestionsGlyphs.symbol($0) }).count == 3, "colour is never the only difference")
        let cites = [AutoAnswerContent.Cite(kind: .thisMeeting), .init(kind: .pastMeeting, title: "Weekly sync", date: 1_790_000_000), .init(kind: .document, fileName: "Budget.xlsx")]
        let labels = cites.map { QuestionsGlyphs.label($0) }
        #expect(labels[0] == "From this meeting" && labels[1].contains("Weekly sync") && labels[2].contains("Budget.xlsx"))
    }
}
