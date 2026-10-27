// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore

@Suite struct DocumentStorageTests {
    // MARK: Migration 23

    @Test func aStoreAtSchema22MigratesToTheDocumentTables() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 22)
        let store = try fx.open()
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        #expect(try await store.columnNames("doc_sources") == ["id", "kind", "display_name", "path", "bookmark", "volume_uuid", "paused", "attached_meeting_id", "added_at", "is_notes_export"])
        #expect(try await store.columnNames("meeting_materials") == ["meeting_id", "source_id", "rel_path"])
        #expect(try await store.documentSources().isEmpty)
        // The old data is still there.
        #expect(try await store.meetings().count == 1)
    }

    @Test func documentSourcesSurviveAJournalReplay() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        let meeting = try await store!.startMeeting(at: .now)
        try await store!.append(Segment(channel: .others, start: 0, end: 4, text: "hello team", isFinal: true), to: meeting)
        try await store!.endMeeting(meeting, at: .now + 60)
        try await store!.flush()
        let source = try await store!.addDocumentSource(kind: .folder, displayName: "Projects", path: "/Users/x/Projects", bookmark: Data([1, 2, 3]), volumeUUID: "UUID-1")
        try await store!.setDocumentSourcePaused(source.id, true)
        try await store!.linkMaterial(meeting: meeting, source: source.id, relPath: "a/b.pdf")
        try await store!.saveIfNeeded()   // appends to the journal; no snapshot
        store = nil
        store = try fx.open()
        let reloaded = try #require(try await store!.documentSources().first)
        #expect(reloaded.displayName == "Projects" && reloaded.bookmark == Data([1, 2, 3]) && reloaded.paused && reloaded.volumeUUID == "UUID-1")
        #expect(try await store!.meetingMaterials(meeting).linked.map(\.relPath) == ["a/b.pdf"])
    }

    @Test func deletingAMeetingRemovesItsAttachedSourcesAndLinks() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let meeting = try await store.startMeeting(at: .now)
        try await store.append(Segment(channel: .others, start: 0, end: 4, text: "hello team", isFinal: true), to: meeting)
        try await store.endMeeting(meeting, at: .now + 60)
        let library = try await store.addDocumentSource(kind: .folder, displayName: "Lib", path: "/l", bookmark: Data([1]), volumeUUID: nil)
        try await store.addDocumentSource(kind: .file, displayName: "m.pdf", path: "/m.pdf", bookmark: Data([2]), volumeUUID: nil, attachedMeeting: meeting)
        try await store.linkMaterial(meeting: meeting, source: library.id, relPath: "x.pdf")
        #expect(try await store.documentSources().count == 2)
        try await store.deleteMeeting(meeting)
        #expect(try await store.documentSources().map(\.displayName) == ["Lib"])
        #expect(try await store.rowCount("meeting_materials") == 0)
    }

    @Test func nothingOfTheIndexIsEverJournaledOrInTheMainStore() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let source = try await store.addDocumentSource(kind: .folder, displayName: "Lib", path: "/l", bookmark: Data([1]), volumeUUID: nil)
        let meeting = try await store.startMeeting(at: .now)
        try await store.linkMaterial(meeting: meeting, source: source.id, relPath: "x")
        let tables = try await store.stringsForTest("SELECT name FROM sqlite_schema WHERE type = 'table'").compactMap { $0 }
        for banned in ["passages", "passages_fts", "passage_vectors", "files"] { #expect(!tables.contains(banned), "\(banned) is not a main-store table") }
        let ops = await store.journaledSQLForTests()
        #expect(ops.allSatisfy { !$0.contains("passages") && !$0.contains("docs.") && !$0.contains("FROM files") })
        // And the source code of the store never names the documents image.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/VautaCore")
        let text = try String(contentsOf: root.appendingPathComponent("Documents/MeetingStore+Documents.swift"), encoding: .utf8)
        #expect(!text.contains("passages") && !text.contains("docs."))
    }

    // MARK: The documents key

    @Test func theDocumentsKeyIsDerivedWithAFixedLabel() {
        let main = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let derived = DocumentIndex.derivedKey(from: main).withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        let mainHex = main.withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        #expect(derived != mainHex)
        // A test vector: this label never changes, or every existing index becomes unreadable.
        #expect(DocumentIndex.keyLabel == "vauta.documents.v1")
        let again = DocumentIndex.derivedKey(from: main).withUnsafeBytes { Data($0).map { String(format: "%02x", $0) }.joined() }
        #expect(derived == again)
        #expect(derived == "6b4d4b0d18ef3327f87b7e39b7df0547c07f1a5ff91706630dd5be11d741b8ed")
    }

    @Test func eraseEverythingRemovesTheImageAndTheMarkerAndKeysRotate() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let dir = await store.storeDirectory
        let before = await store.documentsKey()
        let index = try DocumentIndex(directory: dir, key: before)
        try await index.markPending(source: 1, scanned: ScannedDocumentFile(relPath: "a.txt", size: 1, mtime: 1, format: .text), format: .text)
        try await index.save()
        try Data("{}".utf8).write(to: dir.appendingPathComponent(StoreFiles.documentsMarker))
        let docsFile = dir.appendingPathComponent(DocumentIndex.fileName)
        #expect(FileManager.default.fileExists(atPath: docsFile.path))
        let oldImage = try Data(contentsOf: docsFile)
        try await store.eraseEverything()
        #expect(!FileManager.default.fileExists(atPath: docsFile.path))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(StoreFiles.documentsMarker).path))
        // A copy of the old image (a backup, a disk remnant) is unreadable: the key it needs is gone.
        let after = await store.documentsKey()
        #expect(before != after)
        try oldImage.write(to: docsFile)
        let fresh = try DocumentIndex(directory: dir, key: after)
        #expect(fresh.wasRebuilt)
    }

    @Test func aBackupCarriesTheSourcesButNotTheIndex() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        try await store.addDocumentSource(kind: .folder, displayName: "Projects", path: "/p", bookmark: Data([9]), volumeUUID: nil)
        let dir = await store.storeDirectory
        let index = try DocumentIndex(directory: dir, key: await store.documentsKey())
        try await index.markPending(source: 1, scanned: ScannedDocumentFile(relPath: "secret-name.txt", size: 1, mtime: 1, format: .text), format: .text)
        try await index.save()
        let file = try await store.createBackup(password: "a long enough backup password", appVersion: "test")
        #expect(file.range(of: Data("secret-name".utf8)) == nil)
        let opened = try await MeetingStore.openBackup(file, password: "a long enough backup password")
        #expect(opened.documentSources == 1)
        // Restoring brings the sources back and clears the image that belonged to the data being replaced.
        let other = StoreFixture()
        let target = try other.open()
        let targetIndex = try DocumentIndex(directory: await target.storeDirectory, key: await target.documentsKey())
        try await targetIndex.markPending(source: 1, scanned: ScannedDocumentFile(relPath: "old.txt", size: 1, mtime: 1, format: .text), format: .text)
        try await targetIndex.save()
        _ = try await target.restore(opened)
        #expect(try await target.documentSources().map(\.displayName) == ["Projects"])
        #expect(!FileManager.default.fileExists(atPath: await target.storeDirectory.appendingPathComponent(DocumentIndex.fileName).path))
    }
}

extension MeetingStore {
    /// The SQL of the journal ops waiting to be written (test only).
    func journaledSQLForTests() -> [String] { pendingOps.map(\.sql) }
}
