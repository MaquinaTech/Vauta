// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `decisions.unconfirmed`, `tasks.unconfirmed` and `tasks.owner_uncertain` (schema 16).
@Suite("Storage: minutes verification flags")
struct StorageMinutesFlagsTests {
    @Test func schema15StoreMigratesWithNothingMarked() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 15) { db in
            try StoreFixture.legacyMeeting(db)
            let now = Date.now.timeIntervalSince1970
            try db.query("INSERT INTO decisions(meeting_id, segment_id, t, text, source, created_at) VALUES (1, 1, 0, 'Keep it', 'llm', ?)", [.real(now)])
            try db.query("INSERT INTO tasks(meeting_id, segment_id, t, text, owner_id, source, created_at) VALUES (1, 1, 0, 'Send it', NULL, 'llm', ?)", [.real(now)])
        }
        let store = try fx.open()
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        #expect(try await store.columnNames("decisions").suffix(2) == ["unconfirmed", "unconfirmed_reason"])
        #expect(try await store.columnNames("tasks").suffix(5) == ["unconfirmed", "owner_uncertain", "owner_speaker_id", "due_day", "unconfirmed_reason"])
        #expect(try await store.decisions(1).map(\.unconfirmed) == [false])
        #expect(try await store.tasks(1).map { [$0.unconfirmed, $0.ownerUncertain] } == [[false, false]])
    }

    private func meetingWithMinutes(_ f: KnowledgeFixture) async throws -> (id: Int64, owner: Int64) {
        let id = try await f.meeting(["Please send the report", "I'll send it"])
        let segment = try #require(try await f.store.segments(of: id).first)
        let owner = try await f.store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        var minutes = ValidatedMinutes()
        minutes.decisions = [.init(text: "Ship 40 units", segment: segment.id, t: 0, unconfirmed: true),
                             .init(text: "Keep the plan", segment: segment.id + 1, t: 10)]
        minutes.tasks = [.init(text: "Send the report", owner: owner, due: nil, segment: segment.id, t: 0, unconfirmed: true, ownerUncertain: true),
                         .init(text: "Call the client", owner: nil, due: nil, segment: segment.id + 1, t: 10, unconfirmed: false, ownerUncertain: true)]
        try await f.store.applyMinutes(minutes, to: id)
        return (id, owner)
    }

    @Test func namingASpeakerAfterwardsRecomputesTheOwnerMarks() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        let bea = try await store.saveEntity(EntityDraft(kind: .person, name: "Bea"))
        var minutes = ValidatedMinutes()
        minutes.tasks = [.init(text: "Plan the launch", owner: ana, due: nil, segment: m.segments[1], t: 2, unconfirmed: false, ownerUncertain: true)]
        try await store.applyMinutes(minutes, to: m.meeting)
        #expect(try await store.refreshOwnerMarks(m.meeting) == 0, "nobody is named: still not confirmed")
        let speaker = try await m.speaker(.others, 1).id
        _ = try await store.assignSpeaker(speaker, toEntity: ana)
        #expect(try await store.refreshOwnerMarks(m.meeting) == 1)
        #expect(try await store.tasks(m.meeting).first?.ownerUncertain == false, "the confident speaker is Ana")
        _ = try await store.assignSpeaker(speaker, toEntity: bea)
        #expect(try await store.refreshOwnerMarks(m.meeting) == 1)
        let task = try #require(try await store.tasks(m.meeting).first)
        #expect(task.ownerUncertain && task.ownerID == ana, "the owner is kept; the mark follows the speakers")
        // The user's own edits are never touched.
        var edited = task
        edited.text = "Plan the launch Thursday"
        try await store.updateTask(edited)
        _ = try await store.assignSpeaker(speaker, toEntity: ana)
        #expect(try await store.refreshOwnerMarks(m.meeting) == 0)
    }

    @Test func turningSpeakersOffMarksTheOwnersTheSpeakersAloneBacked() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        try await m.finalize()
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        var minutes = ValidatedMinutes()
        minutes.tasks = [.init(text: "Plan the launch", owner: ana, due: nil, segment: m.segments[1], t: 2, unconfirmed: false, ownerUncertain: true)]
        try await store.applyMinutes(minutes, to: m.meeting)
        _ = try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        #expect(try await store.refreshOwnerMarks(m.meeting) == 1)
        #expect(try await store.tasks(m.meeting).first?.ownerUncertain == false, "the confident speaker is Ana")
        try await store.setSpeakersOff(true, meetingID: m.meeting)
        try await store.clearSpeakers(meetingID: m.meeting)
        #expect(try await store.refreshOwnerMarks(m.meeting) == 1, "the evidence is gone: the mark comes back")
        let task = try #require(try await store.tasks(m.meeting).first)
        #expect(task.ownerUncertain && task.ownerID == ana)
    }

    @Test func applyMinutesStoresTheFlags() async throws {
        let f = try KnowledgeFixture()
        let (id, _) = try await meetingWithMinutes(f)
        #expect(try await f.store.decisions(id).map(\.unconfirmed).sorted { !$0 && $1 } == [false, true])
        let tasks = try await f.store.tasks(id)
        let send = try #require(tasks.first { $0.text == "Send the report" })
        #expect(send.unconfirmed && send.ownerUncertain)
        // A task without an owner has nobody to doubt.
        let call = try #require(tasks.first { $0.text == "Call the client" })
        #expect(!call.unconfirmed && !call.ownerUncertain)
        // Survives a restart.
        try await f.reopen()
        #expect(try await f.store.tasks(id).first { $0.text == "Send the report" }?.unconfirmed == true)
    }

    @Test func theUsersEditsClearTheMarks() async throws {
        let f = try KnowledgeFixture()
        let (id, owner) = try await meetingWithMinutes(f)
        var send = try #require(try await f.store.tasks(id).first { $0.text == "Send the report" })
        // Status alone changes nothing about what the model claimed.
        send.status = .done
        try await f.store.updateTask(send)
        #expect(try await f.store.tasks(id).first { $0.id == send.id }.map { $0.unconfirmed && $0.ownerUncertain && $0.source == "llm" } == true)
        // Choosing the same owner again changes nothing; changing the owner confirms it.
        send.status = .open
        send.text = "Send the report today"
        try await f.store.updateTask(send)
        var saved = try #require(try await f.store.tasks(id).first { $0.id == send.id })
        #expect(!saved.unconfirmed && saved.ownerUncertain && saved.source == "user", "the text is the user's now; the owner still is the model's")
        saved.ownerID = nil
        try await f.store.updateTask(saved)
        saved = try #require(try await f.store.tasks(id).first { $0.id == send.id })
        #expect(!saved.ownerUncertain)
        _ = owner
        let decision = try #require(try await f.store.decisions(id).first { $0.unconfirmed })
        try await f.store.updateDecision(decision.id, text: decision.text)
        #expect(try await f.store.decisions(id).first { $0.id == decision.id }?.unconfirmed == true, "saving the same text keeps the mark")
        try await f.store.updateDecision(decision.id, text: "Ship 50 units")
        #expect(try await f.store.decisions(id).first { $0.id == decision.id }?.unconfirmed == false)
    }

    @Test func tasksAndDecisionsTheUserWritesAreNeverMarked() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["hello", "world"])
        _ = try await f.store.addTask(id, text: "Mine")
        _ = try await f.store.addDecision(id, text: "Mine too")
        #expect(try await f.store.tasks(id).allSatisfy { !$0.unconfirmed && !$0.ownerUncertain })
        #expect(try await f.store.decisions(id).allSatisfy { !$0.unconfirmed })
    }
}
