// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore

@Suite struct DocumentIndexerTests {
    @Test func addingAFolderIndexesItsFilesAndSearchFindsThem() async throws {
        let fx = try DocsFixture()
        fx.files.write("notes/roadmap.md", "# Roadmap\n\nThe beta ships in March after the sync fixes land.\n")
        fx.files.write("budget.csv", "Region,Revenue\nNorth,1200\nSouth,800\n")
        fx.files.write("ignored.bin", Data([1, 2, 3]))
        try await fx.open()
        try await fx.add()
        let snapshot = await fx.indexer.snapshot()
        let counts = try #require(snapshot.sources.first?.counts)
        #expect(counts.files == 2 && counts.indexed == 2 && counts.skipped == 0)
        let hits = try await fx.search("when does the beta ship")
        #expect(hits.first?.fileName == "roadmap.md")
        #expect(hits.first?.text.contains("beta ships in March") == true)
        #expect(hits.first?.locator == .section(path: ["Roadmap"], block: 2))
        let revenue = try await fx.search("revenue for the South region")
        #expect(revenue.first?.fileName == "budget.csv")
    }

    @Test func aNewFileIsIndexedAfterAScan() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Alpha document about apples and oranges for the fruit stand.")
        try await fx.open()
        let source = try await fx.add()
        fx.files.write("b.txt", "Beta document about the quarterly marketing plan and its launch.")
        await fx.indexer.changed(source.id)
        try await fx.settle()
        let hits = try await fx.search("marketing plan launch")
        #expect(hits.first?.fileName == "b.txt")
    }

    @Test func aChangeDuringAScanIsNotDropped() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Alpha document about apples and oranges for the fruit stand.")
        try await fx.open()
        let source = try await fx.add()
        // A scan in flight (the folder's watcher started it) that listed the folder before the new file was written.
        await fx.indexer.holdScan(source.id)
        fx.files.write("b.txt", "Beta document about the quarterly marketing plan and its launch.")
        await fx.indexer.changed(source.id)
        #expect(await fx.indexer.rescan[source.id] == false, "the change waits for the scan in flight instead of being dropped")
        // That scan ends; its owner lists the folder again.
        await fx.indexer.releaseScan(source.id)
        await fx.indexer.sync(source.id)
        try await fx.settle()
        #expect(await fx.indexer.rescan.isEmpty)
        #expect(try await fx.search("marketing plan launch").first?.fileName == "b.txt")
    }

    @Test func aTouchedFileIsNotReadAgainButAChangedOneIs() async throws {
        let fx = try DocsFixture()
        let file = fx.files.write("a.txt", "Original text about the migration timeline and rollout owners.")
        try await fx.open()
        let source = try await fx.add()
        #expect(fx.extractor.times("a.txt") == 1)
        // Same bytes, new date: only the date changes.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: file.path)
        await fx.indexer.changed(source.id)
        try await fx.settle()
        #expect(fx.extractor.times("a.txt") == 1)
        // Other bytes: read again, and the old passage is gone.
        fx.files.write("a.txt", "Replacement text about the pricing review and discount approvals.")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(240)], ofItemAtPath: file.path)
        await fx.indexer.changed(source.id)
        try await fx.settle()
        #expect(fx.extractor.times("a.txt") == 2)
        #expect(try await fx.search("migration timeline rollout").isEmpty)
        #expect(try await fx.search("pricing review discount").first?.fileName == "a.txt")
    }

    @Test func aRenamedFileKeepsItsPassagesWithoutBeingReadAgain() async throws {
        let fx = try DocsFixture()
        let file = fx.files.write("old-name.txt", "Passage about the vendor contract renewal and its termination clauses.")
        try await fx.open()
        let source = try await fx.add()
        let before = try await fx.search("vendor contract renewal").first
        try FileManager.default.moveItem(at: file, to: fx.files.url.appendingPathComponent("new-name.txt"))
        await fx.indexer.changed(source.id)
        try await fx.settle()
        let after = try await fx.search("vendor contract renewal").first
        #expect(after?.fileName == "new-name.txt")
        #expect(after?.id == before?.id)
        // The key and the keyword terms follow the new name in the header: the old name no longer finds the file, the new one does.
        #expect(after?.key != before?.key)
        #expect(try await fx.search("old").isEmpty)
        #expect(try await fx.search("new").first?.fileName == "new-name.txt")
        #expect(fx.extractor.count == 1)
    }

    @Test func aDeletedFileLeavesTheIndex() async throws {
        let fx = try DocsFixture()
        let file = fx.files.write("gone.txt", "Content about the security audit findings and remediation plan.")
        try await fx.open()
        let source = try await fx.add()
        #expect(try await fx.search("security audit").count == 1)
        try FileManager.default.removeItem(at: file)
        await fx.indexer.changed(source.id)
        try await fx.settle()
        #expect(try await fx.search("security audit").isEmpty)
        #expect(try await fx.index.totalPassages() == 0)
    }

    @Test func removingASourceDeletesItsIndexAndSavesAtOnce() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Confidential merger planning text about acquisition targets.")
        try await fx.open()
        let source = try await fx.add()
        try await fx.index.save()
        let plain = try await fx.index.plainImage()
        #expect(plain.range(of: Data("merger".utf8)) != nil)
        try await fx.indexer.removeSource(source.id)
        #expect(try await fx.search("merger planning").isEmpty)
        #expect(try await fx.meetingStore.documentSources().isEmpty)
        let reopened = try DocumentIndex(directory: await fx.meetingStore.storeDirectory, key: await fx.meetingStore.documentsKey())
        #expect(try await reopened.totalPassages() == 0)
        #expect(try await reopened.plainImage().range(of: Data("merger".utf8)) == nil)
    }

    @Test func theFileOnDiskIsEncrypted() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Distinctive sentence about zeppelin maintenance schedules and hangar access.")
        try await fx.open()
        try await fx.add()
        try await fx.index.save()
        let raw = try Data(contentsOf: await fx.meetingStore.storeDirectory.appendingPathComponent(DocumentIndex.fileName))
        #expect(raw.starts(with: Data("ACTA".utf8)))
        #expect(raw.range(of: Data("zeppelin".utf8)) == nil)
        #expect(fx.store.permissions(await fx.meetingStore.storeDirectory.appendingPathComponent(DocumentIndex.fileName)) == 0o600)
    }

    @Test func reopeningTheIndexKeepsItsContent() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Persisted passage about onboarding checklists for new engineers.")
        try await fx.open()
        try await fx.add()
        try await fx.index.save()
        let reopened = try DocumentIndex(directory: await fx.meetingStore.storeDirectory, key: await fx.meetingStore.documentsKey())
        #expect(!reopened.wasRebuilt)
        #expect(try await reopened.search("onboarding checklists", limit: 3).count == 1)
    }

    @Test func aDamagedOrForeignIndexIsRebuiltAndNeverBlocksOpening() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Some indexed passage about training budgets and conference travel.")
        try await fx.open()
        try await fx.add()
        try await fx.index.save()
        let dir = await fx.meetingStore.storeDirectory
        let file = dir.appendingPathComponent(DocumentIndex.fileName)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: file)
        let rebuilt = try DocumentIndex(directory: dir, key: await fx.meetingStore.documentsKey())
        #expect(rebuilt.wasRebuilt)
        #expect(try await rebuilt.totalPassages() == 0)
        // And a key that changed (Erase rotated it) makes an old file unreadable too.
        try await fx.index.markPending(source: 1, scanned: ScannedDocumentFile(relPath: "x.txt", size: 1, mtime: 1, format: .text), format: .text)
        try await fx.index.save()
        let other = try DocumentIndex(directory: dir, key: DocumentIndex.derivedKey(from: .init(size: .bits256)))
        #expect(other.wasRebuilt)
    }

    @Test func aPausedSourceIsNotReadUntilResumed() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Text about the paused source and when it should be read again.")
        try await fx.open()
        let url = fx.files.url
        let source = try await fx.indexer.addSource(url, isDirectory: true)
        try await fx.indexer.setPaused(source.id, true)
        try await Task.sleep(for: .milliseconds(300))
        let paused = await fx.indexer.snapshot()
        #expect(paused.sources.first?.state == .paused)
        try await fx.indexer.setPaused(source.id, false)
        try await fx.settle()
        #expect(try await fx.search("paused source").count == 1)
        #expect(try await fx.meetingStore.documentSource(source.id)?.paused == false)
    }

    @Test func nothingIsReadWhileARecordingRunsAndItResumesTwoMinutesAfter() async throws {
        let fx = try DocsFixture()
        fx.environment.set(IndexerEnvironment(isRecording: true))
        fx.files.write("a.txt", "Text that must wait for the recording to end before it is read.")
        try await fx.open()
        _ = try await fx.indexer.addSource(fx.files.url, isDirectory: true)
        try await Task.sleep(for: .milliseconds(400))
        #expect(fx.extractor.count == 0)
        let waiting = await fx.indexer.snapshot()
        #expect(waiting.pause == .recording)
        fx.environment.set(IndexerEnvironment())
        await fx.indexer.environmentChanged()
        // The loop re-checks every 30 s while paused; the test wakes it by kicking again after the stop.
        await fx.indexer.stop()
        await fx.indexer.start(background: false)
        // Wait for the read itself: right after a restart the snapshot can report nothing pending before the scan has run.
        #expect(await becomes { fx.extractor.count == 1 })
        try await fx.settle()
        #expect(fx.extractor.count == 1, "read once, not again")
    }

    @Test func aFileThatFailsIsSkippedWithItsReasonAndTheRestContinue() async throws {
        let fx = try DocsFixture()
        fx.files.write("bad.txt", "This one will fail to read.")
        fx.files.write("good.txt", "This one reads fine and mentions the quarterly offsite agenda.")
        fx.extractor.failures["bad.txt"] = .passwordProtected
        try await fx.open()
        let source = try await fx.add()
        let skipped = try await fx.index.skipped(source: source.id)
        #expect(skipped.map(\.name) == ["bad.txt"])
        #expect(skipped.first?.reason == .passwordProtected)
        #expect(try await fx.search("offsite agenda").count == 1)
    }

    @Test func aFileThatTakesTooLongIsSkippedAsTimedOut() async throws {
        let fx = try DocsFixture()
        fx.files.write("slow.txt", "Slow file.")
        try await fx.open()
        let slow = RecordingExtractor()
        slow.delay = .seconds(5)
        // A short deadline through a wrapper extractor that throws the way the real deadline does.
        struct Timing: DocumentExtracting {
            func extract(_ url: URL, format: DocumentFormat) async throws -> ExtractedDocument { throw DocumentExtractionError(.timedOut) }
            func recognize(_ url: URL, format: DocumentFormat, pages: [Int]) async throws -> [DocumentUnit] { [] }
        }
        await fx.indexer.stop()
        fx.indexer = DocumentIndexer(store: fx.meetingStore, index: fx.index, access: fx.access, extractor: Timing())
        await fx.indexer.start(background: false)
        let source = try await fx.add()
        #expect(try await fx.index.skipped(source: source.id).first?.reason == .timedOut)
    }

    @Test func theCrashGuardSkipsTheFileThatKilledVauta() async throws {
        let fx = try DocsFixture()
        let poison = fx.files.write("poison.pdf", Data("%PDF-1.4 not really".utf8))
        fx.files.write("fine.txt", "A normal file that mentions the retrospective format and actions.")
        try await fx.open()
        let source = try await fx.add()
        await fx.indexer.stop()
        // The process died while reading poison.pdf: the marker is still there at the next launch.
        let values = try poison.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let marker = DocumentIndexer.CrashMarker(source: source.id, relPath: "poison.pdf", size: Int64(values.fileSize ?? 0),
                                                 mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0, key: await fx.indexer.markerKey())
        try JSONEncoder().encode(marker).write(to: await fx.meetingStore.storeDirectory.appendingPathComponent(StoreFiles.documentsMarker))
        try await fx.index.eraseAll()
        let again = RecordingExtractor()
        fx.indexer = DocumentIndexer(store: fx.meetingStore, index: fx.index, access: fx.access, extractor: again)
        await fx.indexer.start(background: false)
        try await fx.settle()
        let skipped = try await fx.index.skipped(source: source.id)
        #expect(skipped.first?.name == "poison.pdf" && skipped.first?.reason == .crashed)
        #expect(again.times("poison.pdf") == 0)
        #expect(again.times("fine.txt") == 1)
        // The marker is gone once recovered.
        #expect(!FileManager.default.fileExists(atPath: await fx.meetingStore.storeDirectory.appendingPathComponent(StoreFiles.documentsMarker).path))
    }

    @Test func theMarkerNamesTheFileByNumberAndHashNeverByName() throws {
        let key = SymmetricKey(size: .bits256)
        let marker = DocumentIndexer.CrashMarker(source: 3, relPath: "Clients/Acme secret.pdf", size: 10, mtime: 5, key: key)
        #expect(marker.path != DocumentIndexer.CrashMarker(source: 3, relPath: "Clients/Acme secret.pdf", size: 10, mtime: 5, key: SymmetricKey(size: .bits256)).path, "keyed: no dictionary hashing")
        let text = String(decoding: try JSONEncoder().encode(marker), as: UTF8.self)
        #expect(!text.contains("Acme") && !text.contains("secret") && !text.contains(".pdf"))
    }

    @Test func aDisconnectedDriveKeepsItsIndexAndComesBack() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Indexed text about the offsite venue shortlist and catering.")
        try await fx.open()
        let source = try await fx.add()
        fx.access.setDisconnected(source.id, true)
        await fx.indexer.changed(source.id)
        let state = await fx.indexer.snapshot().sources.first?.state
        #expect(state == .disconnected)
        // Still searchable while the drive is away.
        #expect(try await fx.search("offsite venue").count == 1)
        fx.access.setDisconnected(source.id, false)
        await fx.indexer.volumesChanged()
        let back = await fx.indexer.snapshot().sources.first?.state
        if case .upToDate = back {} else { Issue.record("expected up to date, got \(String(describing: back))") }
    }

    @Test func aMissingSourceOffersLocateAndKeepsMatchingFilesByPath() async throws {
        let fx = try DocsFixture()
        let home = DocumentFolder()
        let original = home.write("Projects/a.txt", "Text about the launch checklist and the final go no go meeting.")
        try await fx.open()
        let source = try await fx.indexer.addSource(original.deletingLastPathComponent(), isDirectory: true)
        try await fx.settle()
        let moved = DocumentFolder()
        try FileManager.default.moveItem(at: original.deletingLastPathComponent(), to: moved.url.appendingPathComponent("Projects"))
        await fx.indexer.changed(source.id)
        let status = await fx.indexer.snapshot().sources.first
        #expect(status?.state == .notFound && status?.needsLocate == true)
        try await fx.indexer.relocate(source.id, to: moved.url.appendingPathComponent("Projects"))
        try await fx.settle()
        #expect(fx.extractor.times("a.txt") == 1, "the unchanged file was matched, not read again")
        #expect(try await fx.search("launch checklist").count == 1)
    }

    @Test func duplicateAndNestedSourcesAndTheOwnContainerAreRefused() async throws {
        let fx = try DocsFixture()
        fx.files.write("sub/a.txt", "Some text in a subfolder.")
        try await fx.open()
        _ = try await fx.indexer.addSource(fx.files.url, isDirectory: true)
        await #expect(throws: DocumentSourceError.alreadyIncluded(fx.files.url.lastPathComponent)) {
            _ = try await fx.indexer.addSource(fx.files.url.appendingPathComponent("sub"), isDirectory: true)
        }
        await #expect(throws: DocumentSourceError.ownData) {
            _ = try await fx.indexer.addSource(await fx.meetingStore.storeDirectory, isDirectory: true)
        }
    }

    @Test func theTotalCapStopsIndexingAndMarksFilesIndexFull() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "First file with some words in it about gardening tools.")
        try await fx.open()
        // Fills the index to its cap with a stand-in row, then adds one more file.
        let scanned = ScannedDocumentFile(relPath: "huge.txt", size: 1, mtime: 1, format: .text)
        let id = try await fx.index.markPending(source: 999, scanned: scanned, format: .text)
        try await fx.index.finish(fileID: id, state: .indexed, title: nil, pages: nil, characters: DocumentLimits.maxTotalCharacters, ocrPages: [])
        let source = try await fx.add()
        let skipped = try await fx.index.skipped(source: source.id)
        #expect(skipped.first?.reason == .indexFull)
        #expect(await fx.indexer.snapshot().indexFull)
    }

    @Test func meetingMaterialsRestrictASearchToTheirFiles() async throws {
        let fx = try DocsFixture()
        fx.files.write("one.txt", "The shared planning keyword zebra appears in the first file only.")
        fx.files.write("two.txt", "The shared planning keyword zebra also appears in the second file.")
        try await fx.open()
        let source = try await fx.add()
        let all = try await fx.search("zebra planning")
        #expect(all.count == 2)
        let only = try await fx.search("zebra planning", filter: DocumentFilter([.init(source: source.id, relPath: "two.txt")]))
        #expect(only.map(\.fileName) == ["two.txt"])
    }
}

extension DocumentIndex {
    func plainImage() throws -> Data { try db.withSerializedBytes { Data($0) } }
}
