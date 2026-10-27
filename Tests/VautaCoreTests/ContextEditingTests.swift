// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Pure logic behind the context editor: alias lists, the self entity's
/// name, merge/delete summaries and the re-analysis progress.
@Suite("Context · editing logic")
struct ContextEditingTests {
    private func entity(_ id: Int64, _ name: String, kind: EntityKind = .person, email: String? = nil,
                        aliases: [String] = [], isSelf: Bool = false) -> Entity {
        Entity(id: id, kind: kind, name: name, note: nil, email: email, source: "user", confirmed: true, aliases: aliases,
               lastSeen: nil, mentionCount: 0, isSelf: isSelf)
    }

    // MARK: Alias lists

    @Test(arguments: [
        "Juanma, Juan M.",
        "Juanma; Juan M.",
        "Juanma、Juan M.",
        "Juanma，Juan M.",
        "Juanma،Juan M.",
        "Juanma؛ Juan M.",
        "Juanma\nJuan M.",
        "Juanma\r\nJuan M.",
        " Juanma ,, ; Juan M. ,",
    ])
    func aliasSeparatorsAcrossScripts(_ text: String) {
        #expect(AliasList.parse(text) == ["Juanma", "Juan M."])
    }

    @Test func aliasDuplicatesIgnoreCaseAccentsAndWidth() {
        #expect(AliasList.parse("José, jose, JOSÉ, Ｊｏｓｅ, Pepe") == ["José", "Pepe"])
        #expect(AliasList.parse(" , ;\n").isEmpty)
    }

    @Test func addingSkipsTheNameAndExistingAliases() {
        let out = AliasList.adding("juanma, Juan Manuel, Juancho", to: ["Juanma"], name: "Juan Manuel")
        #expect(out == ["Juanma", "Juancho"])
        #expect(AliasList.adding("", to: ["A"], name: "B") == ["A"])
        #expect(AliasList.isSeparator("、") && AliasList.isSeparator("\n") && !AliasList.isSeparator("-"))
    }

    // MARK: Self entity name

    @Test func selfEntityKeepsItsStoredNameUnlessRenamed() {
        let me = entity(1, MeetingStore.legacySelfName, isSelf: true)
        let shown = SelfEntityName.fieldText(for: me)
        #expect(shown == me.displayName && shown != MeetingStore.legacySelfName)
        #expect(SelfEntityName.storedName(typed: shown, for: me) == MeetingStore.legacySelfName)
        #expect(SelfEntityName.storedName(typed: "  \(shown) ", for: me) == MeetingStore.legacySelfName)
        #expect(SelfEntityName.storedName(typed: "", for: me) == MeetingStore.legacySelfName)
        #expect(SelfEntityName.storedName(typed: "Marta", for: me) == "Marta")
    }

    @Test func otherEntitiesStoreWhatIsTyped() {
        let ana = entity(2, "Ana")
        #expect(SelfEntityName.fieldText(for: ana) == "Ana")
        #expect(SelfEntityName.storedName(typed: "Ana B", for: ana) == "Ana B")
        #expect(SelfEntityName.storedName(typed: "Me", for: nil) == "Me")
        let renamedMe = entity(1, "Marta", isSelf: true)
        #expect(SelfEntityName.fieldText(for: renamedMe) == "Marta")
        #expect(SelfEntityName.storedName(typed: "Maya", for: renamedMe) == "Maya")
    }

    // MARK: Merge and delete summaries

    @Test func mergeSummaryCountsWhatMovesAndSkipsKnownAliases() {
        let source = entity(1, "Juanma", email: "jm@example.com", aliases: ["Juan M.", "Juanito"])
        let target = entity(2, "Juan Manuel", aliases: ["juan m."])
        var f = EntityFootprint()
        f.aliases = [EntityAlias(text: "Juan M.", origin: .user), EntityAlias(text: "Juanito", origin: .learned)]
        f.mentions = 12
        f.meetings = 4
        f.tasks = 2
        f.relations = 1
        f.email = "jm@example.com"
        f.hasNote = true
        let s = MergeSummary(source: source, footprint: f, target: target)
        #expect(s.newAliases == ["Juanito", "Juanma"])
        #expect(s.mentions == 12 && s.meetings == 4 && s.tasks == 2 && s.relations == 1)
        #expect(s.movesEmail && !s.dropsEmail && s.dropsNote && !s.isEmpty)
    }

    @Test func mergeSummaryKeepsTheTargetEmailAndNeverMovesThePronoun() {
        let me = entity(1, MeetingStore.legacySelfName, email: "me@example.com", isSelf: true)
        let target = entity(2, "Marta", email: "marta@example.com")
        var f = EntityFootprint()
        f.email = "me@example.com"
        let s = MergeSummary(source: me, footprint: f, target: target)
        #expect(s.newAliases.isEmpty)
        #expect(!s.movesEmail && s.dropsEmail)
        let empty = MergeSummary(source: entity(3, "Marta"), footprint: EntityFootprint(), target: target)
        #expect(empty.isEmpty)
    }

    @Test func deletionSummarySeparatesRemovedFromDetached() {
        var f = EntityFootprint()
        #expect(!DeletionSummary(footprint: f).removesAnything && !DeletionSummary(footprint: f).detachesAnything)
        f.aliases = [EntityAlias(text: "A", origin: .calendar)]
        f.tasks = 3
        let s = DeletionSummary(footprint: f)
        #expect(s.aliases == 1 && s.tasks == 3 && s.removesAnything && s.detachesAnything)
        // Attendance alone is a link that goes away.
        var attended = EntityFootprint()
        attended.meetings = 2
        #expect(DeletionSummary(footprint: attended).removesAnything)
    }

    // MARK: Re-analysis progress

    @Test func reanalysisCountsEveryOutcome() {
        var p = ReanalysisProgress()
        #expect(p.state == .idle && !p.isRunning)
        p.start(total: 4)
        #expect(p.isRunning && p.current == 1 && p.fractionCompleted == 0)
        var found = AnalysisSummary()
        found.mentions = 3
        found.ambiguous = 1
        p.record(found)
        var skipped = AnalysisSummary()
        skipped.skipped = true
        p.record(skipped)
        p.recordFailure()
        #expect(p.current == 4 && p.processed == 3)
        found.corrections = 2
        p.record(found)
        p.finish()
        #expect(p.state == .finished && p.analyzed == 2 && p.skipped == 1 && p.failed == 1 && p.fractionCompleted == 1)
        #expect(p.found.mentions == 6 && p.found.ambiguous == 2 && p.found.corrections == 2)
    }

    @Test func reanalysisIgnoresResultsAfterCancelAndBeyondTotal() {
        var p = ReanalysisProgress()
        p.record(AnalysisSummary())
        #expect(p.processed == 0)
        p.start(total: 2)
        p.record(AnalysisSummary())
        p.cancel()
        p.record(AnalysisSummary())
        p.recordFailure()
        p.finish()
        #expect(p.state == .cancelled && p.processed == 1 && p.total == 2)

        p.start(total: 1)
        #expect(p.state == .running && p.processed == 0)
        p.record(AnalysisSummary())
        p.record(AnalysisSummary())
        #expect(p.processed == 1)
        p.cancel()
        p.finish()
        #expect(p.state == .cancelled)
    }

    @Test func reanalysisWithNothingToDo() {
        var p = ReanalysisProgress()
        p.start(total: 0)
        #expect(p.current == 0 && p.fractionCompleted == 1)
        p.finish()
        #expect(p.state == .finished)
    }
}
