// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Why an item is unconfirmed (`unconfirmed_reason`, schema 29) and the minutes' group of items that ranked out.
@Suite("Other possible items")
struct OtherPossibleItemsTests {
    // MARK: Migration and decoding

    @Test func migration29IsANewEntryThatOnlyAltersTheTwoTables() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db, upTo: 28)
        let before = try db.query("SELECT type, name, ifnull(sql, '') FROM sqlite_schema ORDER BY type, name").map { [$0.string(0), $0.string(1), $0.string(2)] }
        try Schema.migrate(db, upTo: 29)
        let after = try db.query("SELECT type, name, ifnull(sql, '') FROM sqlite_schema ORDER BY type, name").map { [$0.string(0), $0.string(1), $0.string(2)] }
        #expect(Set(before.filter { !after.contains($0) }.map { $0[1] }) == ["decisions", "tasks"])
        #expect(after.count == before.count, "no object was added or dropped")
        #expect(UnconfirmedReason.rankedOut == "rank", "the stored code never changes")
    }

    @Test func aSchema28StoreMigratesAndOldUnconfirmedRowsKeepTheirLook() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 28) { db in
            try StoreFixture.legacyMeeting(db)
            let now = Date.now.timeIntervalSince1970
            try db.query("INSERT INTO decisions(meeting_id, segment_id, t, text, source, created_at, unconfirmed) VALUES (1, 1, 0, 'Old doubt', 'llm', ?, 1)", [.real(now)])
            try db.query("INSERT INTO tasks(meeting_id, segment_id, t, text, owner_id, source, created_at, unconfirmed) VALUES (1, 1, 0, 'Old task', NULL, 'llm', ?, 1)", [.real(now)])
        }
        let store = try fx.open()
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        #expect(Schema.currentVersion >= 29)
        #expect(try await store.columnNames("decisions").contains("unconfirmed_reason"))
        #expect(try await store.columnNames("tasks").contains("unconfirmed_reason"))
        let decision = try #require(try await store.decisions(1).first)
        let task = try #require(try await store.tasks(1).first)
        #expect(decision.unconfirmed && decision.unconfirmedReason == nil && !decision.isRankedOut, "decodes as unknown: today's look")
        #expect(task.unconfirmed && task.unconfirmedReason == nil && !task.isRankedOut)
        let groups = OtherPossibleItems(decisions: [decision], tasks: [task])
        #expect(groups.isEmpty && groups.firmDecisions == [decision], "an old unconfirmed item stays in the main list")
    }

    private func store(with minutes: ValidatedMinutes) async throws -> (KnowledgeFixture, Int64) {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["one", "two", "three", "four"])
        try await f.store.applyMinutes(minutes, to: id)
        return (f, id)
    }

    private func segments(_ f: KnowledgeFixture, _ id: Int64) async throws -> [Int64] { try await f.store.segments(of: id).map(\.id) }

    private func proposed(_ f: KnowledgeFixture, _ id: Int64) async throws -> ValidatedMinutes {
        let s = try await segments(f, id)
        var m = ValidatedMinutes()
        m.decisions = [.init(text: "Firm decision", segment: s[0], t: 0),
                       .init(text: "Ranked out decision", segment: s[1], t: 10, unconfirmed: true, doubt: UnconfirmedReason.rankedOut),
                       .init(text: "Doubted decision", segment: s[2], t: 20, unconfirmed: true, doubt: "figures")]
        m.tasks = [.init(text: "Ranked out task", owner: nil, due: nil, segment: s[3], t: 30, unconfirmed: true, doubt: UnconfirmedReason.rankedOut),
                   .init(text: "Doubted task", owner: nil, due: nil, segment: s[0], t: 0, unconfirmed: true, doubt: "tentative"),
                   .init(text: "Firm task", owner: nil, due: nil, segment: s[1], t: 10, doubt: "stale: not stored when firm")]
        return m
    }

    @Test func theReasonIsStoredWithTheMinutesAndReadBack() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["one", "two", "three", "four"])
        try await f.store.applyMinutes(try await proposed(f, id), to: id)
        let decisions = try await f.store.decisions(id)
        #expect(decisions.map(\.unconfirmedReason) == [nil, "rank", "figures"])
        #expect(decisions.map(\.isRankedOut) == [false, true, false])
        let tasks = try await f.store.tasks(id)
        let byText = Dictionary(uniqueKeysWithValues: tasks.map { ($0.text, $0) })
        #expect(byText["Ranked out task"]?.isRankedOut == true)
        #expect(byText["Doubted task"]?.unconfirmedReason == "tentative" && byText["Doubted task"]?.isRankedOut == false)
        #expect(byText["Firm task"]?.unconfirmedReason == nil, "a firm item stores no reason")
        try await f.reopen()
        #expect(try await f.store.decisions(id).map(\.unconfirmedReason) == [nil, "rank", "figures"], "it survives a reopen")
    }

    // MARK: Grouping

    @Test func theGroupHoldsOnlyWhatRankedOutAndTheMainListKeepsTheRest() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["one", "two", "three", "four"])
        try await f.store.applyMinutes(try await proposed(f, id), to: id)
        let groups = OtherPossibleItems(decisions: try await f.store.decisions(id), tasks: try await f.store.tasks(id))
        #expect(groups.firmDecisions.map(\.text) == ["Firm decision", "Doubted decision"], "a doubted item keeps its place and its mark")
        #expect(groups.firmDecisions.last?.unconfirmed == true)
        #expect(groups.items.map(\.text) == ["Ranked out decision", "Ranked out task"], "in the order of the meeting")
        #expect(groups.count == 2)
    }

    @Test func aClosedTaskLeavesTheGroupAndAnEmptyGroupIsEmpty() {
        func task(_ id: Int64, _ status: TaskItem.Status, t: Double?, rank: Bool) -> TaskItem {
            TaskItem(id: id, meetingID: 1, segmentID: nil, t: t, text: "T\(id)", ownerID: nil, ownerName: nil, due: nil, status: status, source: "llm",
                     createdAt: .now, meetingTitle: nil, unconfirmed: true, unconfirmedReason: rank ? "rank" : "figures")
        }
        let groups = OtherPossibleItems(decisions: [], tasks: [task(1, .done, t: 5, rank: true), task(2, .open, t: nil, rank: true), task(3, .open, t: 1, rank: true),
                                                    task(4, .open, t: 2, rank: false)])
        #expect(groups.items.map(\.id) == ["t3", "t2"], "closed tasks and doubted ones are out; undated items come last")
        #expect(OtherPossibleItems(decisions: [], tasks: []).isEmpty)
    }

    /// The whole path of a meeting whose items the evidence check doubted softly: ranking, storage, grouping.
    @Test func softDoubtedItemsThatDidNotRankLandInTheGroupAndHardDoubtedOnesStayInTheMainList() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting((1...120).map { "Line \($0) is about subject number \($0) and nothing else." })
        let ids = try await f.store.segments(of: id).map(\.id)
        try #require(ids == Array(1...120).map(Int64.init))
        var m = MinutesRankingTests.thirty()
        m.decisions.append(MinutesRankingTests.item("Should we move the launch to September next year", seg: 4, doubt: "question"))
        let ranked = MinutesRankingTests.rank(m, MinutesRankingTests.meeting())
        try await f.store.applyMinutes(ranked, to: id)
        let stored = try await f.store.decisions(id)
        let groups = OtherPossibleItems(decisions: stored, tasks: [])
        let firm = stored.filter { !$0.unconfirmed }.count
        #expect(firm == MinutesRankingTests.limit)
        #expect(groups.count == stored.count - firm - 1, "everything that did not rank is in the group, but the question")
        #expect(groups.firmDecisions.filter(\.unconfirmed).map(\.unconfirmedReason) == ["question"])
        #expect(stored.contains { $0.unconfirmedReason == "rank:noAgreement" && $0.isRankedOut })
        #expect(!UnconfirmedReason.isRankedOut(nil) && !UnconfirmedReason.isRankedOut("noAgreement") && !UnconfirmedReason.isRankedOut("rankish"))
    }

    // MARK: Promotion and editing

    @Test func checkingEditingOrChangingAnItemClearsTheReason() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["one", "two", "three", "four"])
        try await f.store.applyMinutes(try await proposed(f, id), to: id)
        let decision = try #require(try await f.store.decisions(id).first { $0.isRankedOut })
        try await f.store.markDecisionChecked(decision.id)
        let checked = try #require(try await f.store.decisions(id).first { $0.id == decision.id })
        #expect(!checked.unconfirmed && checked.unconfirmedReason == nil && checked.source == "user")

        let task = try #require(try await f.store.tasks(id).first { $0.isRankedOut })
        var edited = task
        edited.text = "Ranked out task, reworded"
        try await f.store.updateTask(edited)
        let after = try #require(try await f.store.tasks(id).first { $0.id == task.id })
        #expect(!after.unconfirmed && after.unconfirmedReason == nil, "an edited item is the user's")

        let doubted = try #require(try await f.store.decisions(id).first { $0.unconfirmedReason == "figures" })
        try await f.store.updateDecision(doubted.id, text: "Doubted decision, fixed")
        let fixed = try #require(try await f.store.decisions(id).first { $0.id == doubted.id })
        #expect(!fixed.unconfirmed && fixed.unconfirmedReason == nil)

        let other = try #require(try await f.store.tasks(id).first { $0.unconfirmedReason == "tentative" })
        try await f.store.markTaskChecked(other.id)
        #expect(try await f.store.tasks(id).first { $0.id == other.id }?.unconfirmedReason == nil)
    }

    // MARK: Exports, email, detector keep their semantics

    @Test func exportsAndTheEmailTreatARankedOutItemAsAnyUnconfirmedItem() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["one", "two", "three", "four"])
        try await f.store.applyMinutes(try await proposed(f, id), to: id)

        let export = try #require(try await f.store.meetingExport(id))
        #expect(export.decisions.map(\.unconfirmed) == [false, true, true], "ranked out and doubted both carry the mark in the exports")
        #expect(export.tasks.first { $0.text == "Ranked out task" }?.unconfirmed == true)
        let markdown = MeetingExportRenderer.markdown(export, options: MeetingExportOptions())
        #expect(markdown.contains("Ranked out decision"), "nothing is removed from an export")

        let input = try #require(try await f.store.followUpEmailInput(id))
        let locale = Locale(identifier: "en")
        let plain = FollowUpEmail.drafts(input, options: FollowUpEmailOptions(locale: locale)).flatMap(\.lines).map(\.text).joined(separator: "\n")
        #expect(!plain.contains("Ranked out decision") && !plain.contains("Ranked out task"), "the default email leaves unconfirmed items out")
        #expect(plain.contains("Firm decision"))
        let all = FollowUpEmail.drafts(input, options: FollowUpEmailOptions(locale: locale, includeUnconfirmed: true)).flatMap(\.lines).map(\.text).joined(separator: "\n")
        #expect(all.contains("Ranked out decision") && all.contains("Ranked out task"))
    }
}
