// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// What the review of the links phase found: undo that gives items back, suggestions that keep their rows, chains of one task per meeting,
/// restores that stay, and the model check on the keyword pass.
@Suite("Links: review fixes")
struct LinksReviewTests {
    typealias F = LinkFixture
    typealias Series = LinksStoreTests.Series
    static let earlier = LinksStoreTests.earlier
    static let later = LinksStoreTests.later

    private static func insertSuggestion(_ s: Series, src: Int64, dst: Int64) async throws -> Int64 {
        try await s.store.executeForTest("""
            INSERT INTO item_links(kind, src_id, dst_id, rel, state, method, score, recipe, created_at) VALUES ('task', ?, ?, 'same', 'suggested', 'keyword', 0.9, 1, 0)
            """, [.integer(src), .integer(dst)])
        return try #require(try await s.store.intsForTest("SELECT max(id) FROM item_links").first)
    }

    // MARK: Undo gives the items back

    @Test func undoingAConfirmationGivesTheItemsBackToTheModel() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        let id = try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id)
        try await s.store.confirmLink(id)
        #expect(try await s.store.tasks(s.ids[1]).first?.source == "user")
        try await s.store.undoLink(id)
        #expect(try await s.store.tasks(s.ids[0]).first?.source == "llm", "a real undo")
        #expect(try await s.store.tasks(s.ids[1]).first?.source == "llm")
        #expect(try await s.store.itemLink(id)?.state == .suggested)
        // A rewrite after the undo replaces the model's items, as it did before the link.
        try await s.store.applyMinutes(s.minutes(1, tasks: [("Something else entirely", false, nil)]), to: s.ids[1])
        #expect(try await s.store.tasks(s.ids[1]).map(\.text) == ["Something else entirely"])
    }

    @Test func anItemEditedAfterTheConfirmationStaysThePersonsOnUndo() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        let id = try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id)
        try await s.store.confirmLink(id)
        var edited = try #require(try await s.store.tasks(s.ids[1]).first)
        edited.text += " today"
        try await s.store.updateTask(edited)
        try await s.store.undoLink(id)
        #expect(try await s.store.tasks(s.ids[1]).first?.source == "user", "edited since")
        #expect(try await s.store.tasks(s.ids[0]).first?.source == "llm")
    }

    @Test func anItemHeldByAnotherConfirmedLinkStaysThePersonsOnUndo() async throws {
        let s = try await Series(meetings: 3)
        for i in 0..<3 { try await s.store.applyMinutes(s.minutes(i, tasks: [(Self.earlier, false, nil)]), to: s.ids[i]) }
        let tasks = try await (0..<3).asyncMap { try #require(try await s.store.tasks(s.ids[$0]).first) }
        let upper = try await Self.insertSuggestion(s, src: tasks[2].id, dst: tasks[1].id)
        let lower = try await Self.insertSuggestion(s, src: tasks[1].id, dst: tasks[0].id)
        try await s.store.confirmLink(lower)
        try await s.store.confirmLink(upper)
        try await s.store.undoLink(upper)
        #expect(try await s.store.tasks(s.ids[2]).first?.source == "llm", "only the confirmation made it the person's")
        #expect(try await s.store.tasks(s.ids[1]).first?.source == "user", "the other link still holds the middle task")
        #expect(try await s.store.tasks(s.ids[0]).first?.source == "user")
    }

    // MARK: Suggestions keep their rows

    @Test func aPassKeepsTheRowOfASuggestionItMakesAgainSoAClickStillFindsIt() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        let id = try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id)
        _ = try await s.pass(1)
        #expect(try await s.store.links(ofMeeting: s.ids[1]).map(\.id) == [id], "same pair, same row")
        // A pass that no longer proposes it removes it.
        try await s.store.replaceSuggestions(meetingID: s.ids[1], proposals: [])
        #expect(try await s.store.itemLink(id) == nil)
    }

    @Test func answeringARowThatWasReplacedReportsFalseAndChangesNothing() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        let id = try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id)
        try await s.store.replaceSuggestions(meetingID: s.ids[1], proposals: [])
        #expect(try await s.store.confirmLink(id) == false)
        #expect(try await s.store.dismissLink(id) == false)
        #expect(try await s.store.tasks(s.ids[1]).first?.source == "llm")
    }

    // MARK: Chains

    @Test func twoTasksOfOneMeetingNeverJoinOneChain() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil), ("Send the budget to the finance team today", false, nil)]), to: s.ids[1])
        let earlierID = try #require(try await s.store.tasks(s.ids[0]).first?.id)
        let mine = try await s.store.tasks(s.ids[1])
        let one = try await Self.insertSuggestion(s, src: mine[0].id, dst: earlierID)
        let two = try await Self.insertSuggestion(s, src: mine[1].id, dst: earlierID)
        #expect(try await s.store.confirmLink(one))
        #expect(try await s.store.confirmLink(two) == false, "the second would put two tasks of one meeting in one chain")
        #expect(try await s.store.itemLink(two) == nil, "and is withdrawn")
        #expect(try await s.store.linkChains(.task).first?.count == 2)
        // The pass does not offer the chain's tasks to another item of a meeting that is already in it.
        let inputs = try #require(try await s.store.linkInputs(meetingID: s.ids[1], policy: LinkPolicy()))
        #expect(inputs.exclusions.chainMeetings[LinkExclusions.item(.task, earlierID)] == Set([s.ids[0], s.ids[1]]))
    }

    @Test func aMeetingBetweenTwoChainMembersCanStillLinkToTheOlderOne() async throws {
        let s = try await Series(meetings: 3)
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        try await s.store.applyMinutes(s.minutes(2, tasks: [(Self.later + " now", false, nil)]), to: s.ids[2])
        let oldest = try #require(try await s.store.tasks(s.ids[0]).first?.id), newest = try #require(try await s.store.tasks(s.ids[2]).first?.id)
        try await s.store.confirmLink(try await Self.insertSuggestion(s, src: newest, dst: oldest))
        let inputs = try #require(try await s.store.linkInputs(meetingID: s.ids[1], policy: LinkPolicy()))
        let proposals = LinkEngine(sources: inputs.sources, pool: inputs.pool, vectors: [:], exclusions: inputs.exclusions, policy: LinkPolicy()).run()
        #expect(proposals.map(\.dstID) == [oldest], "the newer member is not earlier than this meeting")
        let later = try #require(try await s.store.linkInputs(meetingID: s.ids[2], policy: LinkPolicy()))
        #expect(later.exclusions.superseded[LinkExclusions.item(.task, oldest)] != nil)
    }

    @Test func markingAChainDoneSetsEveryStatusAndOneUndoPutsThemBack() async throws {
        let s = try await Series(meetings: 3)
        for i in 0..<3 { try await s.store.applyMinutes(s.minutes(i, tasks: [(Self.earlier, false, nil)]), to: s.ids[i]) }
        let ids = try await (0..<3).asyncMap { try #require(try await s.store.tasks(s.ids[$0]).first?.id) }
        try await s.store.setTaskStatus(ids[1], .dropped)
        let before = try await s.store.setTaskStatuses(ids, .done)
        #expect(before.map(\.status) == [.open, .dropped, .open])
        #expect(try await s.store.tasks(s.ids[0]).first?.status == .done)
        try await s.store.restoreTaskStatuses(before)
        #expect(try await ids.asyncMap { id in try #require(try await s.store.tasks(ids: [id]).first).status } == [.open, .dropped, .open])
    }

    // MARK: Dismissals and restores

    @Test func aSmallEditKeepsADismissedPairInTheListSoItCanBeRestored() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        try await s.store.dismissLink(try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id))
        var task = try #require(try await s.store.tasks(s.ids[1]).first)
        task.text += " today"
        try await s.store.updateTask(task)
        let listed = try await s.store.dismissedLinks(ofMeeting: s.ids[1])
        #expect(listed.count == 1 && listed[0].newerText == Self.later + " today")
        #expect(try await s.store.restoreDismissal(listed[0]))
        #expect(try await s.store.links(ofMeeting: s.ids[1]).first?.state == .suggested)
    }

    @Test func aRestoredSuggestionSurvivesTheNextPassAndKeepsTheCaps() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil), ("Call the venue about the catering", false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        let id = try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id)
        try await s.store.dismissLink(id)
        // The pass proposes the item's other candidate meanwhile.
        let other = try #require(try await s.store.tasks(s.ids[0]).first { $0.text.hasPrefix("Call") }?.id)
        let mine = try #require(try await s.store.tasks(s.ids[1]).first?.id)
        try await s.store.replaceSuggestions(meetingID: s.ids[1], proposals: [LinkProposal(kind: .task, srcID: mine, dstID: other, relation: .same, method: .keyword, score: 0.6)])
        try await s.store.restoreLink(id)
        let rows = try await s.store.links(ofMeeting: s.ids[1])
        #expect(rows.map(\.id) == [id], "one suggestion per item: the restored one wins")
        // The next pass does not drop it, and does not add a second one for the same item.
        try await s.store.replaceSuggestions(meetingID: s.ids[1], proposals: [LinkProposal(kind: .task, srcID: mine, dstID: other, relation: .same, method: .keyword, score: 0.6)])
        #expect(try await s.store.links(ofMeeting: s.ids[1]).map(\.id) == [id])
        try await s.store.replaceSuggestions(meetingID: s.ids[1], proposals: [])
        #expect(try await s.store.links(ofMeeting: s.ids[1]).map(\.id) == [id], "kept until the person decides it")
    }

    @Test func restoringAfterARewriteHasNoRowAndSaysSo() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        try await s.store.dismissLink(try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id))
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        let listed = try await s.store.dismissedLinks(ofMeeting: s.ids[1])
        #expect(listed.count == 1)
        #expect(try await s.store.restoreDismissal(listed[0]) == false, "the caller runs the pass again")
        #expect(try await s.pass(1).count == 1)
    }

    // MARK: Recipes

    @Test func aMeetingWithMinutesAndNoItemsRecordsItsRecipe() async throws {
        let rig = try await LinksServiceTests.rig()
        let seriesless = try await rig.fixture.meeting(["Nothing to decide today."], locale: "en-US", outputLocale: "en-US", at: LinkFixture.base.addingTimeInterval(1_000))
        #expect(await rig.service.linkPass(seriesless) == 0)
        #expect(try await rig.store.linksRecipe(seriesless) == 0, "no minutes yet: the pass runs again when they exist")
        var minutes = ValidatedMinutes()
        minutes.title = "Quiet"
        minutes.summary = "Nothing"
        try await rig.store.applyMinutes(minutes, to: seriesless)
        #expect(await rig.service.linkPass(seriesless) == 0)
        #expect(try await rig.store.linksRecipe(seriesless) == LinkPolicy.recipe)
        #expect(!(try await rig.store.meetingsNeedingLinks(recipe: LinkPolicy.recipe, days: 4_000, now: LinkFixture.base).contains(seriesless)))
    }

    @Test func aDecisionEditIsOneTransaction() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, decisions: [("Keep the C-shaped shell for the launch", false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, decisions: [("Keep the C-shaped shell for the launch units", false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        let id = try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id)
        try await s.store.confirmLink(id)
        let decision = try #require(try await s.store.decisions(s.ids[1]).first)
        try await s.store.updateDecision(decision.id, text: "Budget capped for the whole department at fifty thousand")
        #expect(try await s.store.itemLink(id)?.state == .suggested)
        #expect(try await s.store.decisions(s.ids[1]).first?.text == "Budget capped for the whole department at fifty thousand")
    }

    // MARK: Words of the item's own language

    @Test func reversalWordsAndMonthAbbreviationsBelongToTheItemsLanguage() {
        func verdict(_ newer: String, _ earlier: String, language: String, locale: String? = nil) -> LinkDifference.Verdict {
            LinkDifference.judge(kind: .decision, newer: newer, earlier: earlier, locale: locale ?? language, language: language)
        }
        // French "reporter" is a noun in English and Spanish "reporte" a report: no reversal outside their language.
        #expect(verdict("The reporter keeps the launch plan", "Keep the launch plan", language: "en") == .same)
        #expect(verdict("El reporte mantiene el plan de lanzamiento", "Mantener el plan de lanzamiento", language: "es") == .same)
        if case .changes = verdict("Reporter le lancement du plan", "Lancement du plan", language: "fr") {} else { Issue.record("French reporter is a reversal in French") }
        // "may 3 users" is no date; "May 3" and "3 mar." are.
        let lower = LinkDifference.read("Ship it, may 3 times", profile: LanguageProfile(identifier: "en"), language: "en")
        #expect(lower.dates.isEmpty)
        let capital = LinkDifference.read("Ship it on May 3", profile: LanguageProfile(identifier: "en"), language: "en")
        #expect(capital.dates.count == 1)
        let stop = LinkDifference.read("Entrega el 3 mar. sin falta", profile: LanguageProfile(identifier: "es"), language: "es")
        #expect(stop.dates.count == 1)
        let wrongLanguage = LinkDifference.read("Entrega el 3 Dez sin falta", profile: LanguageProfile(identifier: "es"), language: "es")
        #expect(wrongLanguage.dates.isEmpty, "German abbreviations are not read in a Spanish item")
    }

    // MARK: The service

    @Test func theModelCheckAlsoRunsAfterTheKeywordPassWhenThereIsNoSearchModel() async throws {
        var policy = LinkPolicy()
        policy.modelCheck = true
        let rig = try await LinksServiceTests.rig(choice: ModelProviderSettings.Embeddings.none, policy: policy, onDevice: true,
                                                  checkReply: #"{"pairs":[{"id":"p1","relation":"unrelated","differs":""}]}"#)
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { await rig.service.linkTraces.contains { $0.pass == .checked } })
        let checked = try #require(await rig.service.linkTraces.first { $0.pass == .checked })
        #expect(checked.modelCalls == 1 && checked.vectors == 0, "the check ran on the keyword result")
        #expect(try await rig.store.links(ofMeeting: rig.later).isEmpty, "the model said unrelated")
        #expect(!rig.embedder.texts.value.contains(LinksServiceTests.hiring), "no item was embedded")
    }

    @Test func aPassThatWaitedKeepsItsCheckAndRunsItInTheEmbedJob() async throws {
        var policy = LinkPolicy()
        policy.modelCheck = true
        let rig = try await LinksServiceTests.rig(choice: ModelProviderSettings.Embeddings.none, policy: policy, onDevice: true,
                                                  checkReply: #"{"pairs":[{"id":"p1","relation":"unrelated","differs":""}]}"#)
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { await rig.service.linkTraces.contains { $0.pass == .checked } })
        try await rig.store.executeForTest("DELETE FROM item_links")
        rig.environment.mutate { $0.lowPowerMode = true }
        #expect(await rig.service.linkPass(rig.later, check: true) == nil)
        #expect(await rig.service.linksWaitingCheck == [rig.later])
        let before = await rig.service.linkTraces.filter { $0.pass == .checked }.count
        rig.environment.mutate { $0 = IndexerEnvironment() }
        await rig.service.environmentChanged()
        await rig.service.runWaitingLinkPasses()
        #expect(await eventually { await rig.service.linkTraces.filter { $0.pass == .checked }.count > before })
        #expect(await rig.service.linksWaitingCheck.isEmpty)
    }

    @Test func anEditReachesAPassAfterTheDebounceAndTheWindowIsTold() async throws {
        let rig = try await LinksServiceTests.rig()
        let told = SharedBox<[Int64]>([])
        await rig.service.setLinksChangedHandler { id in told.mutate { $0.append(id) } }
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { await rig.service.linkTraces.contains { $0.pass == .vector } })
        #expect(told.value.contains(rig.later), "the open window is told when a pass wrote its suggestions")
        try await rig.store.executeForTest("DELETE FROM item_links")
        told.mutate { $0 = [] }
        await rig.service.setLinkEditDelayForTest(.milliseconds(5))
        await rig.service.itemsChanged(meetingID: rig.later)
        #expect(await eventually { try await rig.store.links(ofMeeting: rig.later).count == 1 })
        #expect(await eventually { told.value.contains(rig.later) })
    }

    @Test func rewritingAnEarlierMeetingRunsThePassOfTheLaterOneAgain() async throws {
        let rig = try await LinksServiceTests.rig()
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { await rig.service.linkTraces.contains { $0.pass == .vector } })
        let old = try #require(try await rig.store.links(ofMeeting: rig.later).first)
        await rig.service.regenerateMinutes(rig.earlier)
        #expect(await eventually {
            let now = try await rig.store.links(ofMeeting: rig.later)
            return now.count == 1 && now[0].dstID != old.dstID
        })
    }

    @Test func aQueuedItemJobDoesNotEmbedChunksAgainUnlessTheyAreOutOfDateAndNeverWithLinksOff() async throws {
        let rig = try await LinksServiceTests.rig()
        await rig.service.meetingEnded(rig.later)
        #expect(await eventually { await rig.service.linkTraces.contains { $0.pass == .vector } })
        #expect(await rig.service.waitUntilQueueIdle())
        func rerun() async throws -> Int {
            let before = rig.embedder.documentsEmbedded
            try await rig.store.enqueueJob(.embed, meeting: rig.later)
            #expect(await rig.service.waitUntilQueueIdle())
            return rig.embedder.documentsEmbedded - before
        }
        #expect(try await rerun() == 0, "chunks in the search model's space and current: nothing to embed for an items-only job")
        // The text moved (a speaker was renamed, a line corrected): the chunks are embedded again.
        try await rig.store.executeForTest("UPDATE segments SET text = text || ' (corrected)' WHERE meeting_id = ?", [.integer(rig.later)])
        #expect(try await rerun() > 0)
        #expect(try await rerun() == 0)
        // The vector size changed under the same model name.
        await rig.service.forgetDimensionsForTest(model: ConceptEmbedder.space.model, dimensions: 999)
        #expect(try await rerun() > 0)
        // Links off: every embed job embeds the chunks as it always did.
        await rig.service.setLinkPolicy(nil)
        #expect(try await rerun() > 0)
    }
}

extension LLMService {
    func forgetDimensionsForTest(model: String, dimensions: Int) { knownDimensions[model] = dimensions }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
