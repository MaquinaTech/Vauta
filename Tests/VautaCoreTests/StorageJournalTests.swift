// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore

@Suite("Storage journal")
struct StorageJournalTests {
    @Test func legacyCarraySQLIsRewritten() {
        #expect(MeetingStore.legacySQL("SELECT id FROM t WHERE id IN carray(?)") == "SELECT id FROM t WHERE id IN (SELECT value FROM json_each(?))")
        #expect(MeetingStore.legacySQL("WHERE s.meeting_id IN carray(?4)") == "WHERE s.meeting_id IN (SELECT value FROM json_each(?4))")
        #expect(MeetingStore.legacySQL("INSERT INTO x SELECT ?, value, ? FROM carray(?)") == "INSERT INTO x SELECT ?, value, ? FROM json_each(?)")
        #expect(MeetingStore.legacySQL("SELECT 1") == "SELECT 1")
    }

    @Test func codecRoundTripsEveryParameterType() throws {
        let ops = [
            JournalOp(sql: "INSERT INTO t VALUES (?, ?, ?, ?, ?, ?)",
                      params: [nil, .integer(-42), .real(3.25), .text("ñandú «x»"), .blob(Data([0, 1, 2])), .ids([1, 2, 3])]),
            JournalOp(sql: "DELETE FROM t", params: []),
        ]
        let encoded = Journal.encode(ops)
        #expect(try Journal.decode(Data(encoded.bytes)) == ops)
        #expect(throws: StoreError.self) { try Journal.decode(Data(encoded.bytes) + [0]) }
    }

    /// A 0.1.0 store (schema 7) with a journal written by 0.1.0: Spanish
    /// speaker labels and `carray()` ID lists. Replay runs first, then
    /// migration 8 converts the replayed labels too.
    @Test func legacyJournalIsReplayedBeforeMigrating() async throws {
        let fx = StoreFixture()
        let generation = Journal.newGeneration()
        try fx.writeLegacyStore(schema: 7, generation: generation)
        let journalKey = Journal.key(from: try #require(fx.keys.key))
        let records: [[JournalOp]] = [
            [
                JournalOp(sql: "INSERT INTO meetings(started_at) VALUES (?)", params: [.real(Date.now.timeIntervalSince1970)]),
                JournalOp(sql: "INSERT INTO segments(meeting_id, speaker, start, end, text) VALUES (?, ?, ?, ?, ?)",
                          params: [.integer(2), .text("Yo"), .real(0), .real(1), .text("hola desde el diario")]),
                JournalOp(sql: "INSERT INTO segments(meeting_id, speaker, start, end, text) VALUES (?, ?, ?, ?, ?)",
                          params: [.integer(2), .text("Otros"), .real(2), .real(3), .text("respuesta del diario")]),
                JournalOp(sql: "INSERT INTO segments(meeting_id, speaker, start, end, text) VALUES (?, ?, ?, ?, ?)",
                          params: [.integer(2), .text("Otros"), .real(4), .real(5), .text("zzborrarxq")]),
            ],
            [
                JournalOp(sql: "DELETE FROM segments WHERE meeting_id = ? AND id IN carray(?)", params: [.integer(2), .ids([5])]),
                JournalOp(sql: "INSERT INTO marks(meeting_id, t, label) SELECT value, 0, 'mark' FROM carray(?)", params: [.ids([1, 2])]),
                // Verbatim 0.1.0 statement (MeetingStore+Context, meeting attendees).
                JournalOp(sql: "INSERT INTO entities(kind, name, created_at) VALUES ('person', 'Ana', 0)", params: []),
                JournalOp(sql: "INSERT OR IGNORE INTO meeting_entities(meeting_id, entity_id, role) SELECT ?, value, ? FROM carray(?)",
                          params: [.integer(2), .text("attendee"), .ids([1])]),
            ],
        ]
        for (seq, ops) in records.enumerated() {
            let record = try Journal.seal(Journal.encode(ops), seq: UInt64(seq), generation: generation, key: journalKey)
            try Journal.append(record, generation: generation, to: fx.journalURL)
        }

        var store: MeetingStore? = try fx.open(recover: true)
        #expect(try await store!.pragma("user_version") == Schema.currentVersion)
        #expect(try await store!.speakerCodes(1) == ["me", "others"])
        #expect(try await store!.speakerCodes(2) == ["me", "others"])
        #expect(try await store!.segments(of: 2).map(\.text) == ["hola desde el diario", "respuesta del diario"])
        #expect(try await store!.search("zzborrarxq").isEmpty)
        #expect(try await store!.search("diario").count == 2)
        #expect(try await store!.rowCount("marks") == 2, "the whole carray() record was replayed")
        #expect(try await store!.rowCount("meeting_entities") == 1)
        #expect(!fx.exists(fx.journalURL), "the replayed journal is folded into a new snapshot")
        store = nil
        store = try fx.open()
        #expect(try await store!.segments(of: 2).count == 2)
    }

    @Test func recordingAppendsOnlyToTheJournalAndRecoversTornTail() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await store!.flush()
        let snapshotBefore = try Data(contentsOf: fx.snapshotURL)
        let id = try await store!.startMeeting(at: .now)
        let word = "zzdiarioxq"
        for i in 0..<200 {
            try await store!.append(segment(i % 2 == 0 ? .me : .others, Double(i), "fragmento \(i) con \(word) y algo de texto de relleno"), to: id)
            if i % 20 == 19 { try await store!.saveIfNeeded() }
        }
        let journal = try Data(contentsOf: fx.journalURL)
        #expect(try Data(contentsOf: fx.snapshotURL) == snapshotBefore, "autosave while recording leaves the snapshot alone")
        #expect(journal.starts(with: Journal.magic) && journal.count < 64_000)
        #expect(journal.range(of: Data(word.utf8)) == nil, "the journal holds no plaintext")
        #expect(fx.permissions(fx.journalURL) == 0o600)
        store = nil   // like kill -9: no endMeeting, no final save

        try journal.dropLast(7).write(to: fx.journalURL)   // power cut in the middle of the last record
        store = try fx.open(recover: true)
        #expect(try await store!.segments(of: id).count == 180)
        #expect(!fx.exists(fx.journalURL))
        #expect(try await store!.meeting(id)?.endedAt != nil, "the recovered meeting is closed")
    }

    @Test func tamperedRecordAndEverythingAfterItAreDiscarded() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await store!.flush()
        let id = try await store!.startMeeting(at: .now)
        for i in 0..<3 {
            try await store!.append(segment(.me, Double(i), "manipulado \(i)"), to: id)
            try await store!.saveIfNeeded()
        }
        store = nil
        var forged = try Data(contentsOf: fx.journalURL)
        forged[forged.count - 100] ^= 0x01   // inside the last record
        try forged.write(to: fx.journalURL)
        store = try fx.open(recover: true)
        #expect(try await store!.segments(of: id).count == 2)
    }

    @Test func journalOfAnotherGenerationIsIgnored() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await store!.flush()
        let id = try await store!.startMeeting(at: .now)
        try await store!.append(segment(.me, 0, "de otra generación"), to: id)
        try await store!.saveIfNeeded()
        let staleJournal = try Data(contentsOf: fx.journalURL)
        try await store!.endMeeting(id, at: .now)
        #expect(!fx.exists(fx.journalURL), "ending the meeting writes a snapshot and removes the journal")
        store = nil
        try staleJournal.write(to: fx.journalURL)
        store = try fx.open(recover: true)
        #expect(try await store!.segments(of: id).count == 1, "nothing is duplicated")
        #expect(!fx.exists(fx.journalURL))
    }

    @Test func editsGoToTheJournalThenToTheSnapshot() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        try await store.append(segment(.me, 0, "hola"), to: id)
        try await store.endMeeting(id, at: .now)
        try await store.setTitle("Título editado", of: id)
        #expect(fx.exists(fx.journalURL), "an edit reaches the journal immediately")
        try await store.flush()
        #expect(!fx.exists(fx.journalURL), "and moves into the snapshot on save")
        #expect(try await store.meeting(id)?.title == "Título editado")
    }
}
