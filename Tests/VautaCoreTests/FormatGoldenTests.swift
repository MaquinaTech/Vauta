// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore

/// Files as a build of today wrote them (`Fixtures/Formats`), which every later build must open. `SchemaFreezeTests` freezes what
/// is inside the database; these freeze the files around it:
///
/// - `snapshot-v2.golden`: the encrypted snapshot `vauta.db.enc` (envelope v2, LZ4), schema 38, one meeting with its minutes;
/// - `journal-v1.golden`: its journal `vauta.journal.enc` (version 1, three records), a recording that was going on when the app
///   stopped, so opening it is also the recovery after a crash;
/// - `backup-v1-format2.vautabackup`: a backup of the same store once the recording ended (ACTABK v1, format 2 with settings,
///   PBKDF2 at 1,000,000 iterations, the default when it was written).
///
/// The store files have names of their own here (`*.enc` stays ignored by Git, so a real store can't be committed by mistake);
/// a test copies them under the store's names.
///
/// They were written once by `writeGoldens` from invented content, with the test key and password below (public: they protect
/// nothing), and are never written again: a change that stops one of them opening breaks the stores and backups people have.
/// A new envelope, journal or backup version adds its own golden next to these and keeps them.
@Suite("Storage formats: files written by earlier builds still open")
struct FormatGoldenTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true).appendingPathComponent("Formats", isDirectory: true)
    static let key = SymmetricKey(data: Data((0..<32).map { UInt8($0) }))
    static let password = "a golden backup password, not a secret"
    /// The golden of each store file, by the file's name in a store.
    static let goldens = [MeetingStore.snapshotName: "snapshot-v2.golden", MeetingStore.journalName: "journal-v1.golden"]
    static let backupGolden = "backup-v1-format2.vautabackup"

    static let snapshotLines = ["We reviewed the golden budget of 1,200 euros", "El presupuesto revisado queda igual",
                                "予算を確認しました", "Nadia Ejemplo sends the figures on Friday"]
    static let journalLines = ["The recording goes on after the snapshot", "Second line of the first record",
                               "A line of the second record", "The last line, in the third record"]

    // MARK: The checks

    @Test func theFilesHaveTheVersionsTheyStandFor() throws {
        let snapshot = try Data(contentsOf: Self.folder.appendingPathComponent(Self.goldens[MeetingStore.snapshotName]!))
        #expect(snapshot.prefix(5) == Data("ACTA".utf8) + [2], "envelope v2")
        let journal = try Data(contentsOf: Self.folder.appendingPathComponent(Self.goldens[MeetingStore.journalName]!))
        #expect(journal.prefix(5) == Data("ACTJ".utf8) + [1], "journal version 1")
        let backup = try Data(contentsOf: Self.folder.appendingPathComponent(Self.backupGolden))
        #expect(backup.prefix(8) == Data("ACTABK".utf8) + [1, 1], "ACTABK version 1, PBKDF2-HMAC-SHA256")
        #expect(backup[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } == 1_000_000, "the count it was written with")
        for data in [snapshot, journal, backup] {
            #expect(data.range(of: Data("golden budget".utf8)) == nil && data.range(of: Data("SQLite format".utf8)) == nil, "nothing in clear")
        }
    }

    /// A store folder with copies of the goldens of the store files `names` (opening a store writes to it), and the test key.
    static func storeCopy(_ names: [String]) throws -> StoreFixture {
        let fixture = StoreFixture()
        try FileManager.default.createDirectory(at: fixture.dir, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.copyItem(at: folder.appendingPathComponent(goldens[name]!), to: fixture.dir.appendingPathComponent(name))
        }
        try fixture.keys.replace(with: key)
        return fixture
    }

    @Test func aStoreWithAJournalOpensWithEveryWriteAndRecoversTheRecording() async throws {
        let fixture = try Self.storeCopy([MeetingStore.snapshotName, MeetingStore.journalName])
        let store = try fixture.open(recover: true)
        try await Self.expectGoldenContent(store, recordingEnded: false)
        #expect(try await store.goldenPragma("PRAGMA integrity_check") == ["ok"])
        #expect(try await store.goldenPragma("PRAGMA foreign_key_check").isEmpty)
    }

    @Test func theRecordingIsInTheJournalNotInTheSnapshot() async throws {
        let fixture = try Self.storeCopy([MeetingStore.snapshotName])
        let store = try fixture.open(recover: true)
        #expect(try await store.meetings().map(\.title) == ["Golden snapshot meeting"], "without its journal the store has the first meeting only")
    }

    @Test func aBackupRestoresWithItsSettings() async throws {
        let file = try Data(contentsOf: Self.folder.appendingPathComponent(Self.backupGolden))
        let backup = try await MeetingStore.openBackup(file, password: Self.password)
        #expect(backup.manifest.format == 2 && backup.manifest.appVersion == "golden" && backup.meetings == 2)
        #expect(backup.preferences?.values["outputLanguage"] == .string("es-ES") && backup.preferences?.values["copyProtection"] == .bool(true))
        let fixture = StoreFixture()
        let store = try fixture.open()
        #expect(try await store.restore(backup) == RestoreSummary(replacedMeetings: 0, restoredMeetings: 2))
        try await Self.expectGoldenContent(store, recordingEnded: true)
        #expect(try await store.goldenPragma("PRAGMA integrity_check") == ["ok"])
        #expect(try await store.goldenPragma("PRAGMA foreign_key_check").isEmpty)
    }

    /// What `writeGoldens` put in: the meeting of the snapshot with its note, decision and task, the person they name, and the
    /// recording of the journal (all its lines; ended in the backup, recovered when the store opens).
    static func expectGoldenContent(_ store: MeetingStore, recordingEnded: Bool) async throws {
        let meetings = try await store.meetings().sorted { $0.id < $1.id }
        try #require(meetings.count == 2)
        let (first, second) = (meetings[0], meetings[1])
        #expect(first.title == "Golden snapshot meeting" && first.endedAt != nil)
        #expect(try await store.segments(of: first.id).map(\.text) == Self.snapshotLines)
        #expect(try await store.notes(first.id).map(\.text) == ["Check the golden budget"])
        let decisions = try await store.decisions(first.id)
        #expect(decisions.map(\.text) == ["Keep the golden budget"] && decisions.first?.segmentID != nil)
        let person = try #require(try await store.entities(.person).first { $0.name == "Nadia Ejemplo" })
        let tasks = try await store.tasks(first.id)
        #expect(tasks.map(\.text) == ["Send the figures"] && tasks.first?.ownerID == person.id)
        #expect(try await store.segments(of: second.id).map(\.text) == Self.journalLines, "every record of the journal")
        #expect(second.endedAt != nil, recordingEnded ? "ended before the backup" : "the recording that was going on is recovered")
    }

    // MARK: Writing them (once)

    /// Writes the goldens into the folder named by `VAUTA_WRITE_FORMAT_GOLDENS`. Run once for a new format version, never to
    /// refresh one: `swift test --filter FormatGoldenTests/writeGoldens` with the variable set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VAUTA_WRITE_FORMAT_GOLDENS"] != nil))
    func writeGoldens() async throws {
        let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["VAUTA_WRITE_FORMAT_GOLDENS"]), isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let fixture = StoreFixture()
        try FileManager.default.createDirectory(at: fixture.dir, withIntermediateDirectories: true)
        try fixture.keys.replace(with: Self.key)
        let store = try fixture.open()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let person = try await store.saveEntity(EntityDraft(kind: .person, name: "Nadia Ejemplo"))
        let first = try await store.startMeeting(at: start, locale: Locale(identifier: "en-US"))
        var ids: [Int64] = []
        for (i, line) in Self.snapshotLines.enumerated() {
            ids.append(try await store.append(Segment(channel: i % 2 == 0 ? .others : .me, start: Double(i * 10), end: Double(i * 10 + 8),
                                                     text: line, isFinal: true), to: first))
        }
        _ = try await store.endMeeting(first, at: start + 60, marksEchoes: false)
        try await store.setTitle("Golden snapshot meeting", of: first)
        _ = try await store.addNote(first, at: 5, text: "Check the golden budget")
        _ = try await store.addDecision(first, text: "Keep the golden budget", segmentID: ids[1], t: 10)
        _ = try await store.addTask(first, text: "Send the figures", ownerID: person, segmentID: ids[3], t: 30)
        try await store.flush()
        await store.drainWriter()
        // The recording after the snapshot: three journal records.
        var journalSize = 0
        let second = try await store.startMeeting(at: start + 3_600, locale: Locale(identifier: "es-ES"))
        for (record, lines) in [[0, 1], [2], [3]].enumerated() {
            for i in lines {
                _ = try await store.append(Segment(channel: .me, start: Double(i * 10), end: Double(i * 10 + 8), text: Self.journalLines[i], isFinal: true),
                                           to: second)
            }
            try await store.saveIfNeeded()
            await store.drainWriter()
            let size = (try fm.attributesOfItem(atPath: fixture.journalURL.path)[.size] as? NSNumber)?.intValue ?? 0
            #expect(size > journalSize, "record \(record) is in the journal")
            journalSize = size
        }
        for (name, golden) in Self.goldens {
            try fm.copyItem(at: fixture.dir.appendingPathComponent(name), to: out.appendingPathComponent(golden))
        }
        _ = try await store.endMeeting(second, at: start + 3_660, marksEchoes: false)
        let settings = BackupPreferences(values: ["outputLanguage": .string("es-ES"), "copyProtection": .bool(true)])
        let backup = try await store.createBackup(password: Self.password, appVersion: "golden", preferences: settings)
        try backup.write(to: out.appendingPathComponent(Self.backupGolden))
    }
}

extension MeetingStore {
    /// The rows of a pragma, as text, for the checks of the goldens.
    func goldenPragma(_ sql: String) throws -> [String] {
        try db.query(sql).map { $0.string(0) }
    }
}
