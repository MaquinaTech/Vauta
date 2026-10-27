// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Links to earlier meetings: migration 30, the store's side of a pass, and what the person decides.
@Suite("Links: storage")
struct LinksStoreTests {
    typealias F = LinkFixture

    /// Two or three meetings of one series, a week apart, with the model's decisions and tasks.
    struct Series {
        let f: KnowledgeFixture
        var store: MeetingStore { f.store }
        var ids: [Int64] = []
        var segments: [[MeetingStore.StoredSegment]] = []

        init(meetings: Int = 2) async throws {
            f = try KnowledgeFixture()
            let seriesID = try await f.store.saveSeries(MeetingSeries(titlePattern: "Weekly sync"))
            for i in 0..<meetings {
                let id = try await f.meeting(["We keep the budget.", "Ana will send the numbers."], at: F.base.addingTimeInterval(Double(i - meetings) * 7 * F.day))
                try await f.store.setSeries(seriesID, of: id)
                try await f.store.executeForTest("UPDATE meetings SET title = 'Weekly sync' WHERE id = ?", [.integer(id)])
                ids.append(id)
                segments.append(try await f.store.segments(of: id))
            }
        }

        func minutes(_ meeting: Int, decisions: [(String, Bool, String?)] = [], tasks: [(String, Bool, String?)] = []) -> ValidatedMinutes {
            var m = ValidatedMinutes()
            m.title = "Weekly sync"
            m.summary = "Summary"
            let segs = segments[meeting]
            m.decisions = decisions.map { text, unconfirmed, reason in
                var item = ValidatedMinutes.Item(text: text, segment: segs[0].id, t: segs[0].start)
                item.unconfirmed = unconfirmed
                item.doubt = reason
                return item
            }
            m.tasks = tasks.map { text, unconfirmed, reason in
                var task = ValidatedMinutes.Task(text: text, owner: nil, due: nil, segment: segs[1].id, t: segs[1].start)
                task.unconfirmed = unconfirmed
                task.doubt = reason
                return task
            }
            return m
        }

        func pass(_ meeting: Int, policy: LinkPolicy = LinkPolicy()) async throws -> [LinkProposal] {
            let inputs = try #require(try await store.linkInputs(meetingID: ids[meeting], policy: policy))
            let proposals = LinkEngine(sources: inputs.sources, pool: inputs.pool, vectors: [:], exclusions: inputs.exclusions, policy: policy).run()
            try await store.replaceSuggestions(meetingID: ids[meeting], proposals: proposals)
            return proposals
        }
    }

    private func ids(_ s: Series) async throws -> [Int64] {
        let first = try await s.store.tasks(s.ids[0]).map(\.id), second = try await s.store.tasks(s.ids[1]).map(\.id)
        return first + second
    }

    static let earlier = "Send the revised budget to the finance team"
    static let later = "Send the budget to the finance team"

    // MARK: 40 Migration 30

    @Test func migration30IsANewEntryAndKeepsThePublishedOnes() throws {
        #expect(Schema.currentVersion >= 30)
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db, upTo: 29)
        let before = try db.query("SELECT type, name, ifnull(sql, '') FROM sqlite_schema ORDER BY type, name").map { [$0.string(0), $0.string(1), $0.string(2)] }
        try db.query("INSERT INTO meetings(started_at) VALUES (1)")
        try Schema.migrate(db, upTo: 30)
        #expect(try Schema.version(of: db) == 30)
        #expect(try db.query("SELECT name FROM pragma_table_info('item_links')").map { $0.string(0) } ==
                ["id", "kind", "src_id", "dst_id", "rel", "state", "method", "score", "evidence", "recipe", "created_at", "decided_at", "prior"])
        #expect(try db.query("SELECT name FROM pragma_table_info('item_vectors')").count == 7)
        #expect(try db.query("SELECT name FROM pragma_table_info('item_link_dismissals')").map { $0.string(0) } ==
                ["kind", "src_meeting_id", "src_key", "dst_meeting_id", "dst_key", "decided_at"])
        #expect(try db.query("SELECT links_recipe FROM meetings").first?.int(0) == 0, "an older meeting has not been through a pass")
        #expect(throws: Never.self) { try BackupSchemaGuard.validate(db) }
        let after = try db.query("SELECT type, name, ifnull(sql, '') FROM sqlite_schema ORDER BY type, name").map { [$0.string(0), $0.string(1), $0.string(2)] }
        #expect(Set(before.filter { !after.contains($0) }.map { $0[1] }) == ["meetings"], "only ALTER TABLE rewrote earlier SQL")
        // The checks hold: a link to itself, and a 'changes' link between tasks.
        try db.query("INSERT INTO item_links(kind, src_id, dst_id, rel, method, recipe, created_at) VALUES ('task', 1, 2, 'same', 'keyword', 1, 0)")
        #expect(throws: (any Error).self) { try db.query("INSERT INTO item_links(kind, src_id, dst_id, rel, method, recipe, created_at) VALUES ('task', 1, 1, 'same', 'keyword', 1, 0)") }
        #expect(throws: (any Error).self) { try db.query("INSERT INTO item_links(kind, src_id, dst_id, rel, method, recipe, created_at) VALUES ('task', 3, 4, 'changes', 'keyword', 1, 0)") }
        #expect(throws: (any Error).self) { try db.query("INSERT INTO item_links(kind, src_id, dst_id, rel, method, recipe, created_at) VALUES ('task', 1, 2, 'same', 'keyword', 1, 0)") }
    }

    @Test func deletingAnItemOrAMeetingTakesItsVectorsLinksAndDismissalsWithIt() async throws {
        var s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        let proposals = try await s.pass(1)
        #expect(proposals.count == 1)
        let link = try #require(try await s.store.links(ofMeeting: s.ids[1]).first)
        try await s.store.dismissLink(link.id)
        let task = try #require(try await s.store.tasks(s.ids[0]).first)
        try await s.store.executeForTest("INSERT INTO item_vectors(kind, item_id, model, dims, scale, recipe, emb) VALUES ('task', ?, 'm', 2, 1, 1, x'0102')", [.integer(task.id)])
        try await s.store.deleteTask(task.id)
        #expect(try await s.store.intsForTest("SELECT count(*) FROM item_vectors") == [0])
        #expect(try await s.store.intsForTest("SELECT count(*) FROM item_links") == [0])
        #expect(try await s.store.intsForTest("SELECT count(*) FROM item_link_dismissals") == [1], "a dismissal is by content and goes with its meeting")
        try await s.store.executeForTest("DELETE FROM meetings WHERE id = ?", [.integer(s.ids[0])])
        #expect(try await s.store.intsForTest("SELECT count(*) FROM item_link_dismissals") == [0])
        s.ids.removeAll()
    }

    // MARK: 33 Confirming

    @Test func confirmingMakesBothItemsThePersonsAndARewriteKeepsThem() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        let row = try #require(try await s.store.linkRows(ofMeeting: s.ids[1]).values.first)
        #expect(row.link.state == .suggested && row.earlierText == Self.earlier && row.earlierMeetingID == s.ids[0])
        #expect(try await s.store.confirmLink(row.link.id))
        #expect(try await s.store.tasks(s.ids[0]).first?.source == "user")
        #expect(try await s.store.tasks(s.ids[1]).first?.source == "user")
        // Rewrite both meetings' minutes with the same and with other items: the linked ones stay, no twin appears.
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [("Something else entirely", false, nil)]), to: s.ids[1])
        #expect(try await s.store.tasks(s.ids[0]).count == 1)
        let kept = try await s.store.tasks(s.ids[1])
        #expect(kept.contains { $0.text == Self.later }, "the confirmed task survives the rewrite")
        #expect(try await s.store.links(ofMeeting: s.ids[1]).first?.state == .confirmed)
    }

    @Test func aSubstantialEditReturnsConfirmedLinksToSuggestionsAndASmallOneDoesNot() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        let id = try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id)
        try await s.store.confirmLink(id)
        var task = try #require(try await s.store.tasks(s.ids[1]).first)
        task.text = Self.later + " today"
        try await s.store.updateTask(task)
        #expect(try await s.store.itemLink(id)?.state == .confirmed, "a small edit keeps the link")
        task.text = "Book the offsite venue and the catering for the whole department"
        try await s.store.updateTask(task)
        #expect(try await s.store.itemLink(id)?.state == .suggested, "a different text needs review")
        _ = try await s.pass(1)
        #expect(try await s.store.itemLink(id)?.state == .suggested, "a later pass keeps the link that waits for review")
        #expect(try await s.store.links(ofMeeting: s.ids[1]).map(\.id) == [id])
        // The earlier end edited instead: the later meeting's next pass keeps it too.
        let t = try await Series()
        try await t.store.applyMinutes(t.minutes(0, tasks: [(Self.earlier, false, nil)]), to: t.ids[0])
        try await t.store.applyMinutes(t.minutes(1, tasks: [(Self.later, false, nil)]), to: t.ids[1])
        _ = try await t.pass(1)
        let linkID = try #require(try await t.store.links(ofMeeting: t.ids[1]).first?.id)
        try await t.store.confirmLink(linkID)
        var first = try #require(try await t.store.tasks(t.ids[0]).first)
        first.text = "Book the offsite venue and the catering for the whole department"
        try await t.store.updateTask(first)
        _ = try await t.pass(1)
        #expect(try await t.store.itemLink(linkID)?.state == .suggested, "the earlier end re-worded: still waiting for review after the next pass")
    }

    @Test func restoringADismissalDoesNotGiveAnItemAConfirmedLinkAndASuggestion() async throws {
        let s = try await Series(meetings: 3)
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.earlier + " now", false, nil)]), to: s.ids[1])
        try await s.store.applyMinutes(s.minutes(2, tasks: [(Self.later, false, nil)]), to: s.ids[2])
        _ = try await s.pass(2)
        let proposed = try await s.store.links(ofMeeting: s.ids[2])
        let first = try #require(proposed.first)
        try await s.store.dismissLink(first.id)
        // Another earlier item is confirmed for the same newer item.
        let otherEarlier = try #require(try await ids(s).first { $0 != first.srcID && $0 != first.dstID })
        try await s.store.executeForTest(
            "INSERT INTO item_links(kind, src_id, dst_id, rel, state, method, recipe, created_at) VALUES ('task', ?, ?, 'same', 'confirmed', 'keyword', 1, 0)",
            [.integer(first.srcID), .integer(otherEarlier)])
        try await s.store.restoreLink(first.id)
        let rows = try await s.store.links(ofMeeting: s.ids[2]).filter { $0.srcID == first.srcID }
        #expect(rows.filter { $0.state == .suggested }.isEmpty, "the item has a confirmed link: the restored one is not offered next to it")
        #expect(try await s.store.itemLink(first.id)?.state == .dismissed)
    }

    @Test func undoLinkMakesAConfirmedLinkASuggestionAgain() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, decisions: [("Keep the C-shaped shell for the launch", false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, decisions: [("Keep the C-shaped shell for the launch units", false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        let id = try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id)
        try await s.store.confirmLink(id)
        #expect(try await s.store.firstOfChain(kind: .decision, id: try #require(try await s.store.decisions(s.ids[1]).first?.id))?.date == F.base.addingTimeInterval(-14 * F.day))
        try await s.store.undoLink(id)
        #expect(try await s.store.itemLink(id)?.state == .suggested)
    }

    // MARK: 38 Dismissals

    @Test func aDismissalSurvivesARewriteOfEitherMeetingAndAnEditLiftsIt() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        let id = try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id)
        try await s.store.dismissLink(id)
        #expect(try await s.pass(1).isEmpty, "never suggested again")
        // Rewrite either meeting: the model's items get new ids, the same words.
        let oldIDs = try await ids(s)
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        #expect(Set(try await ids(s)).isDisjoint(with: oldIDs), "new ids")
        #expect(try await s.pass(1).isEmpty, "the dismissal is by content and survives the rewrite")
        let dismissed = try await s.store.dismissedLinks(ofMeeting: s.ids[1])
        #expect(dismissed.count == 1 && dismissed[0].earlierText == Self.earlier && dismissed[0].newerText == Self.later)
        // Restore: suggested again at the next pass.
        try await s.store.restoreDismissal(dismissed[0])
        #expect(try await s.pass(1).count == 1)
        #expect(try await s.store.dismissedLinks(ofMeeting: s.ids[1]).isEmpty)
    }

    @Test func aSubstantialEditOfADismissedItemLiftsTheDismissal() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        _ = try await s.pass(1)
        try await s.store.dismissLink(try #require(try await s.store.links(ofMeeting: s.ids[1]).first?.id))
        var task = try #require(try await s.store.tasks(s.ids[0]).first)
        task.text = "Book the offsite venue and the catering for the whole department"
        try await s.store.updateTask(task)
        task.text = Self.earlier + " "   // back to the words of the first (the edit before was substantial)
        #expect(try await s.store.dismissedLinks(ofMeeting: s.ids[1]).isEmpty, "the old words are gone from the earlier item")
    }

    // MARK: 37 Who is eligible

    @Test func rankedOutItemsAreNeitherSourcesNorCandidatesUntilChecked() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, true, "rank")]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        #expect(try await s.pass(1).isEmpty, "a ranked-out earlier item is not a candidate")
        // As a source.
        let t = try await Series()
        try await t.store.applyMinutes(t.minutes(0, tasks: [(Self.earlier, false, nil)]), to: t.ids[0])
        try await t.store.applyMinutes(t.minutes(1, tasks: [(Self.later, true, "rank:noAgreement")]), to: t.ids[1])
        #expect(try await t.pass(1).isEmpty, "a ranked-out new item has no suggestion")
        let inputs = try #require(try await t.store.linkInputs(meetingID: t.ids[1], policy: LinkPolicy()))
        #expect(inputs.sources.isEmpty && inputs.pool.count == 1)
        // Mark as Checked makes it eligible.
        try await t.store.markTaskChecked(try #require(try await t.store.tasks(t.ids[1]).first?.id))
        #expect(try await t.pass(1).count == 1)
        // Not embedded either: the items without a vector exclude ranked-out ones.
        let u = try await Series()
        try await u.store.applyMinutes(u.minutes(0, tasks: [(Self.earlier, true, "rank"), ("Call the venue about the catering", false, nil)]), to: u.ids[0])
        let missing = try await u.store.itemsWithoutVectors(meetingID: u.ids[0], model: F.space.model)
        #expect(missing.map(\.text) == ["Call the venue about the catering"])
    }

    @Test func doubtedItemsStayEligibleAndTheDevSwitchTurnsThemOff() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, true, "figures")]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, true, "tentative")]), to: s.ids[1])
        #expect(try await s.pass(1).count == 1)
        var strict = LinkPolicy()
        strict.includesDoubted = false
        #expect(try await s.pass(1, policy: strict).isEmpty)
        #expect(try await s.store.linkRows(ofMeeting: s.ids[1]).isEmpty, "the strict pass replaced it")
        _ = try await s.pass(1)
        let doubted = try #require(try await s.store.linkRows(ofMeeting: s.ids[1]).values.first)
        #expect(doubted.earlierUnconfirmed && doubted.earlierUnconfirmedReason == "figures", "the earlier item keeps its Unconfirmed mark")
        // Confirming a link does not check the items.
        try await s.store.confirmLink(doubted.link.id)
        #expect(try await s.store.tasks(s.ids[0]).first?.unconfirmed == true)
    }

    @Test func tasksWithNoMeetingAreNeverSourcesOrCandidates() async throws {
        let s = try await Series()
        try await s.store.addTask(nil, text: Self.earlier)
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil)]), to: s.ids[1])
        let inputs = try #require(try await s.store.linkInputs(meetingID: s.ids[1], policy: LinkPolicy()))
        #expect(inputs.pool.isEmpty)
    }

    // MARK: 35 Recipe

    @Test func aRecipeBumpReplacesOnlySuggestedRows() async throws {
        let s = try await Series(meetings: 3)
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil), ("Review the hiring plan for the engineering team", false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [(Self.later, false, nil), ("Review the hiring plan with the engineering team", false, nil)]), to: s.ids[1])
        let first = try await s.pass(1)
        #expect(first.count == 2)
        let links = try await s.store.links(ofMeeting: s.ids[1])
        let confirmed = try #require(links.first { $0.recipe == LinkPolicy.recipe })
        try await s.store.confirmLink(confirmed.id)
        try await s.store.executeForTest("UPDATE meetings SET links_recipe = 0")
        #expect(try await s.store.meetingsNeedingLinks(recipe: 1, days: 400, now: F.base).contains(s.ids[1]))
        _ = try await s.pass(1)
        let after = try await s.store.links(ofMeeting: s.ids[1])
        #expect(after.contains { $0.id == confirmed.id && $0.state == .confirmed }, "a confirmed row stays")
        #expect(after.filter { $0.state == .suggested }.count == 1 && after.count == 2)
        #expect(try await s.store.linksRecipe(s.ids[1]) == LinkPolicy.recipe)
    }

    // MARK: 39 Rewriting an earlier meeting

    @Test func rewritingAnEarlierMeetingNamesTheLaterMeetingsThatLostASuggestion() async throws {
        let s = try await Series(meetings: 3)
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        try await s.store.applyMinutes(s.minutes(1, tasks: [("Plan the room for the offsite", false, nil)]), to: s.ids[1])
        try await s.store.applyMinutes(s.minutes(2, tasks: [(Self.later, false, nil)]), to: s.ids[2])
        _ = try await s.pass(2)
        #expect(try await s.store.links(ofMeeting: s.ids[2]).count == 1)
        let pointing = try await s.store.applyMinutes(s.minutes(0, tasks: [("Something else entirely to do", false, nil)]), to: s.ids[0])
        #expect(pointing == [s.ids[2]])
        #expect(try await s.store.links(ofMeeting: s.ids[2]).isEmpty, "the rewrite took the suggestion with the item")
        // A rewrite that no suggestion points into names nobody.
        #expect(try await s.store.applyMinutes(s.minutes(1, tasks: [("Plan the room for the offsite", false, nil)]), to: s.ids[1]).isEmpty)
    }

    // MARK: Vectors

    @Test func itemVectorsAreStoredPerModelAndReplacedWhenTheTextChanges() async throws {
        let s = try await Series()
        try await s.store.applyMinutes(s.minutes(0, tasks: [(Self.earlier, false, nil)]), to: s.ids[0])
        let task = try #require(try await s.store.tasks(s.ids[0]).first)
        let (q, scale) = try #require(VectorIndex.quantize([1, 2, 3, 4]))
        try await s.store.storeItemVectors([(.task, task.id, q, scale)], model: F.space.model)
        #expect(try await s.store.itemsWithoutVectors(meetingID: s.ids[0], model: F.space.model).isEmpty)
        #expect(try await s.store.itemsWithoutVectors(meetingID: s.ids[0], model: "embeddinggemma-2@other").count == 1, "another space has none")
        var edited = task
        edited.text = Self.earlier + " now"
        try await s.store.updateTask(edited)
        #expect(try await s.store.itemsWithoutVectors(meetingID: s.ids[0], model: F.space.model).count == 1, "the trigger dropped the old words' vector")
        try await s.store.storeItemVectors([(.task, task.id, q, scale)], model: F.space.model)
        try await s.store.dropItemVectors(modelPrefix: "embeddinggemma-2@")
        #expect(try await s.store.intsForTest("SELECT count(*) FROM item_vectors") == [0])
    }
}
