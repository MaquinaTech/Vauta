// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Storage: translations")
struct StorageTranslationTests {
    private let day: TimeInterval = 86_400

    /// A finished meeting with one "Others" segment translated into Spanish.
    private func record(_ store: MeetingStore, at date: Date = .now, text: String = "We should ship on Friday",
                        translation: String? = "Deberíamos publicar el viernes") async throws -> (meeting: Int64, segment: Int64) {
        let meeting = try await store.startMeeting(at: date)
        let segmentID = try await store.append(segment(.others, 0, text), to: meeting)
        if let translation { try await store.saveTranslation(translation, language: "es", of: segmentID) }
        try await store.endMeeting(meeting, at: date + 60)
        return (meeting, segmentID)
    }

    @Test func version10StoreMigratesAndGainsTheTable() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 10)
        let store = try fx.open()
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        #expect(try await store.columnNames("segment_translations") == ["segment_id", "lang", "text"])
        #expect(try await store.segments(of: 1).count == 2, "old data is untouched")
        #expect(try await store.translations(of: 1).isEmpty)
        let id = try await store.segments(of: 1)[1].id
        try await store.saveTranslation("respuesta traducida", language: "en", of: id)
        #expect(try await store.translations(of: 1).map(\.text) == ["respuesta traducida"])
    }

    @Test func translationsAreStoredPerLanguageAndReplaceEarlierOnes() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (meeting, segmentID) = try await record(store)
        try await store.saveTranslation("Nous devrions livrer vendredi", language: "fr", of: segmentID)
        try await store.saveTranslation("Deberíamos lanzar el viernes", language: "es", of: segmentID)
        let all = try await store.translations(of: meeting)
        #expect(all.map(\.language) == ["es", "fr"])
        #expect(all.first?.text == "Deberíamos lanzar el viernes", "the same language replaces the earlier text")
        #expect(all.allSatisfy { $0.segmentID == segmentID })
    }

    @Test func aSegmentThatNoLongerExistsStoresNothing() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        try await store.saveTranslation("huérfana", language: "es", of: 9_999)
        #expect(try await store.rowCount("segment_translations") == 0)
    }

    @Test func aLateTranslationIsStoredAfterTheMeetingEnded() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (meeting, segmentID) = try await record(store, translation: "de Apple")
        let stored = try await store.saveLateTranslation("del servidor", language: "es", of: segmentID,
                                                         inMeeting: meeting, source: "We should ship on Friday")
        #expect(stored)
        #expect(try await store.translations(of: meeting).map(\.text) == ["del servidor"], "it replaces Apple's text")
    }

    @Test func aLateTranslationOfADeletedMeetingStoresNothing() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (meeting, segmentID) = try await record(store, translation: nil)
        try await store.deleteMeeting(meeting)
        let stored = try await store.saveLateTranslation("tarde", language: "es", of: segmentID,
                                                         inMeeting: meeting, source: "We should ship on Friday")
        #expect(!stored)
        #expect(try await store.rowCount("segment_translations") == 0)
    }

    @Test func aLateTranslationNeverLandsOnAReusedRowOrAnotherMeeting() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let first = try await record(store, translation: nil)
        try await store.deleteMeeting(first.meeting)
        // A new meeting may reuse the freed row IDs; the old answer must not land on it.
        let second = try await record(store, text: "A different sentence", translation: nil)
        let wrongText = try await store.saveLateTranslation("tarde", language: "es", of: second.segment,
                                                            inMeeting: first.meeting, source: "We should ship on Friday")
        let wrongMeeting = try await store.saveLateTranslation("tarde", language: "es", of: second.segment,
                                                               inMeeting: second.meeting + 1, source: "A different sentence")
        #expect(!wrongText && !wrongMeeting)
        #expect(try await store.rowCount("segment_translations") == 0)
    }

    @Test func aLateTranslationAfterEraseEverythingStoresNothing() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let (meeting, segmentID) = try await record(store, translation: nil)
        try await store.eraseEverything()
        let stored = try await store.saveLateTranslation("tarde", language: "es", of: segmentID,
                                                         inMeeting: meeting, source: "We should ship on Friday")
        #expect(!stored)
        #expect(try await store.rowCount("segment_translations") == 0)
    }

    @Test func translationsBelongToTheirMeeting() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let first = try await record(store, translation: "primera")
        let second = try await record(store, translation: "segunda")
        #expect(try await store.translations(of: first.meeting).map(\.text) == ["primera"])
        #expect(try await store.translations(of: second.meeting).map(\.text) == ["segunda"])
    }

    @Test func deletingTheMeetingRemovesTheTranslationsWithoutATrace() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let kept = try await record(store, translation: "se queda")
        let word = "zztraducidoxq"
        let gone = try await record(store, translation: "Esto contiene \(word)")
        #expect(try await store.imageContains(word))
        try await store.deleteMeeting(gone.meeting)
        #expect(try await store.rowCount("segment_translations") == 1)
        #expect(try await !store.imageContains(word), "no trace in the database after compaction")
        #expect(try await store.translations(of: kept.meeting).count == 1)
    }

    @Test func rawTextPurgeRemovesTranslationsButKeepsTheMeeting() async throws {
        let fx = StoreFixture()
        let store = try fx.open(knowledgeDays: 365)
        let word = "zzpurgadoxq"
        let old = try await record(store, at: .now - Double(MeetingStore.retentionDays + MeetingStore.distillGraceDays + 1) * day,
                                   translation: "Texto \(word)")
        let recent = try await record(store, translation: "reciente")
        #expect(try await store.purgeExpired() > 0)
        #expect(try await store.meeting(old.meeting) != nil, "the meeting itself is kept")
        #expect(try await store.translations(of: old.meeting).isEmpty)
        #expect(try await !store.imageContains(word))
        #expect(try await store.translations(of: recent.meeting).count == 1)
    }

    @Test func translationsAreEncryptedOnDiskAndSurviveTheJournal() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await store!.flush()
        let meeting = try await store!.startMeeting(at: .now)
        let segmentID = try await store!.append(segment(.others, 0, "Original sentence"), to: meeting)
        let word = "zzjournalxq"
        try await store!.saveTranslation("Frase con \(word)", language: "es", of: segmentID)
        try await store!.saveIfNeeded()
        let journal = try Data(contentsOf: fx.journalURL)
        #expect(journal.range(of: Data(word.utf8)) == nil, "the journal holds no plaintext")
        store = nil   // no endMeeting, no final save

        store = try fx.open(recover: true)
        #expect(try await store!.translations(of: meeting).map(\.text) == ["Frase con \(word)"])
        try await store!.flush()
        let snapshot = try Data(contentsOf: fx.snapshotURL)
        #expect(snapshot.range(of: Data(word.utf8)) == nil)
    }

    @Test func backupAndRestoreCarryTheTranslations() async throws {
        let source = StoreFixture()
        let original = try source.open()
        let (_, segmentID) = try await record(original, translation: "viaja en la copia")
        let file = try await original.createBackup(password: "correct horse battery staple", appVersion: "0.9.0")
        #expect(file.range(of: Data("viaja en la copia".utf8)) == nil, "the archive is encrypted")
        let backup = try await MeetingStore.openBackup(file, password: "correct horse battery staple")

        let target = StoreFixture()
        var store: MeetingStore? = try target.open()
        _ = try await store!.restore(backup)
        #expect(try await store!.translations(of: 1).map(\.text) == ["viaja en la copia"])
        #expect(try await store!.translations(of: 1).first?.segmentID == segmentID)
        try await store!.flush()
        store = nil
        let reopened = try target.open()
        #expect(try await reopened.translations(of: 1).count == 1)
    }

    @Test func aBackupFromBeforeTranslationsRestoresAndMigrates() async throws {
        let source = StoreFixture()
        let image = try source.legacyImage(schema: 10)
        let packed = try image.withSerializedBytes(SnapshotEnvelope.pack)
        let manifest = BackupManifest(format: 1, appVersion: "0.8.0", schemaVersion: 10, createdAt: .now, meetingCount: 1)
        let file = try BackupArchive.seal(packed: packed, manifest: manifest, password: "correct horse battery staple",
                                          iterations: BackupArchive.minimumIterations)
        let backup = try await MeetingStore.openBackup(file, password: "correct horse battery staple")
        let target = StoreFixture()
        let store = try target.open()
        _ = try await store.restore(backup)
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        #expect(try await store.rowCount("segment_translations") == 0)
        let id = try await store.segments(of: 1)[0].id
        try await store.saveTranslation("ok", language: "es", of: id)
        #expect(try await store.translations(of: 1).count == 1)
    }

    @Test func eraseEverythingRemovesTranslations() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let word = "zzborradoxq"
        _ = try await record(store, translation: "Texto \(word)")
        try await store.eraseEverything()
        #expect(try await store.rowCount("segment_translations") == 0)
        #expect(try await !store.imageContains(word))
    }
}
