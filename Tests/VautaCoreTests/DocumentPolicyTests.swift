// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite struct DocumentPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func indexingWaitsWhileARecordingRunsAndTwoMinutesAfter() {
        let recording = IndexerPolicy.decide(IndexerEnvironment(isRecording: true), now: now)
        #expect(!recording.text && !recording.ocr && !recording.embeddings && recording.pause == .recording)
        let justStopped = IndexerPolicy.decide(IndexerEnvironment(recordingStoppedAt: now.addingTimeInterval(-60)), now: now)
        #expect(!justStopped.text && justStopped.pause == .recording)
        let later = IndexerPolicy.decide(IndexerEnvironment(recordingStoppedAt: now.addingTimeInterval(-121)), now: now)
        #expect(later.text && later.ocr && later.embeddings && later.pause == nil)
    }

    @Test func lowPowerModeAndAHotMacPauseEverything() {
        let lowPower = IndexerPolicy.decide(IndexerEnvironment(lowPowerMode: true), now: now)
        #expect(!lowPower.text && lowPower.pause == .lowPower)
        for state in [ProcessInfo.ThermalState.serious, .critical] {
            let hot = IndexerPolicy.decide(IndexerEnvironment(thermalState: state), now: now)
            #expect(!hot.text && hot.pause == .thermal)
        }
        #expect(IndexerPolicy.decide(IndexerEnvironment(thermalState: .fair), now: now).text)
    }

    @Test func onBatteryOnlyTextContinues() {
        let battery = IndexerPolicy.decide(IndexerEnvironment(onBattery: true), now: now)
        #expect(battery.text && !battery.ocr && !battery.embeddings && battery.pause == nil)
    }

    @Test func theLimitsAreTheDocumentedOnes() {
        #expect(DocumentLimits.maxSources == 50 && DocumentLimits.maxFilesPerSource == 20_000)
        #expect(DocumentLimits.maxPDFBytes == 200_000_000 && DocumentLimits.maxOfficeBytes == 50_000_000 && DocumentLimits.maxImageBytes == 30_000_000)
        #expect(DocumentLimits.maxPDFPages == 2_000 && DocumentLimits.maxSlides == 500)
        #expect(DocumentLimits.maxCharactersPerFile == 2_000_000 && DocumentLimits.maxTotalCharacters == 60_000_000)
        #expect(DocumentLimits.maxOCRPagesPerFile == 300 && DocumentLimits.maxOCRPagesPerDay == 3_000)
        #expect(DocumentLimits.textExtractionSeconds == 60 && DocumentLimits.ocrPageSeconds == 20)
    }

    @Test func theQueueReadsSmallTextFilesBeforeLargePDFs() async throws {
        let fx = try DocsFixture()
        fx.files.write("big.pdf", PDFFixtures.make(pages: Array(repeating: "A long document page with enough words to count as text on the page.", count: 5)))
        fx.files.write("small.txt", "A small text file.")
        fx.files.write("medium.md", String(repeating: "A line of markdown about onboarding.\n", count: 50))
        try await fx.open()
        await fx.indexer.stop()
        let source = try await fx.meetingStore.addDocumentSource(kind: .folder, displayName: "x", path: fx.files.url.path, bookmark: Data(fx.files.url.path.utf8), volumeUUID: nil)
        let scan = DocumentScanner.scan(fx.files.url, kind: .folder)
        for file in scan.files { try await fx.index.markPending(source: source.id, scanned: file, format: file.format!) }
        let queue = try await fx.index.queue(limit: 10, sources: [source.id])
        #expect(queue.map(\.name) == ["small.txt", "medium.md", "big.pdf"])
    }

    // MARK: Sync planner

    private func record(_ path: String, size: Int64 = 10, mtime: Double = 1, id: String? = nil, state: DocumentFileRecord.State = .indexed,
                        reason: DocumentSkipReason? = nil, version: Int = 1) -> DocumentFileRecord {
        DocumentFileRecord(id: Int64(path.hashValue & 0xFFFF), sourceID: 1, relPath: path, fileID: id, size: size, mtime: mtime, hash: nil, format: .text,
                           extractorVersion: version, title: nil, state: state, reason: reason, pages: nil, characters: 0, ocrPages: [], indexedAt: nil)
    }

    private func scanned(_ path: String, size: Int64 = 10, mtime: Double = 1, id: String? = nil, skip: DocumentSkipReason? = nil) -> ScannedDocumentFile {
        ScannedDocumentFile(relPath: path, size: size, mtime: mtime, fileID: id, format: .text, skip: skip)
    }

    @Test func theSyncPlanFindsNewChangedRenamedAndRemovedFiles() {
        let known = [record("same.txt"), record("changed.txt"), record("old-name.txt", id: "1:5"), record("gone.txt")]
        let found = [scanned("same.txt"), scanned("changed.txt", mtime: 2), scanned("new-name.txt", id: "1:5"), scanned("new.txt")]
        let plan = DocumentSync.plan(scanned: found, known: known)
        #expect(plan.added.map(\.relPath) == ["new.txt"])
        #expect(plan.changed.map(\.scanned.relPath) == ["changed.txt"])
        #expect(plan.renamed.map(\.scanned.relPath) == ["new-name.txt"])
        #expect(plan.removed.map(\.relPath) == ["gone.txt"])
        #expect(DocumentSync.plan(scanned: [scanned("same.txt")], known: [record("same.txt")]).isEmpty)
    }

    @Test func skippedFilesAreRetriedOnlyWhenTheirReasonCanClear() {
        let known = [record("icloud.txt", state: .skipped, reason: .iCloudNotDownloaded), record("bad.txt", state: .skipped, reason: .unreadable),
                     record("full.txt", state: .skipped, reason: .indexFull)]
        let found = [scanned("icloud.txt"), scanned("bad.txt"), scanned("full.txt")]
        #expect(DocumentSync.plan(scanned: found, known: known, indexHasRoom: true).retry.map(\.scanned.relPath).sorted() == ["full.txt", "icloud.txt"])
        #expect(DocumentSync.plan(scanned: found, known: known, indexHasRoom: false).retry.map(\.scanned.relPath) == ["icloud.txt"])
        // Changed bytes always retry.
        #expect(DocumentSync.plan(scanned: [scanned("bad.txt", mtime: 9)], known: [known[1]]).retry.count == 1)
    }

    @Test func anOlderExtractorVersionRequeuesAFile() {
        let plan = DocumentSync.plan(scanned: [scanned("a.txt")], known: [record("a.txt", version: 0)])
        #expect(plan.outdated.count == 1)
    }

    @Test func iCloudPlaceholdersAndExportOnlyFilesAreListedAsSkipped() throws {
        let folder = DocumentFolder()
        folder.write("Deck.key", Data([1]))
        folder.write("Sheet.xls", Data([1]))
        folder.write("fine.txt", "x")
        folder.write("movie.mp4", Data([1]))
        folder.write(".hidden.txt", "x")
        folder.write("~$lock.docx", "x")
        folder.write("node_modules/dep.md", "x")
        try FileManager.default.createSymbolicLink(at: folder.url.appendingPathComponent("link.txt"), withDestinationURL: folder.url.appendingPathComponent("fine.txt"))
        let found = DocumentScanner.scan(folder.url, kind: .folder).files.sorted { $0.relPath < $1.relPath }
        #expect(found.map(\.relPath) == ["Deck.key", "Sheet.xls", "fine.txt"])
        #expect(found.first { $0.relPath == "Deck.key" }?.skip == .exportAsPDF)
        #expect(found.first { $0.relPath == "fine.txt" }?.skip == nil)
    }

    @Test func aDeepFolderStopsAtTheDepthLimit() {
        let folder = DocumentFolder()
        let deep = (0..<(DocumentLimits.maxDepth + 3)).map { "d\($0)" }.joined(separator: "/")
        folder.write("\(deep)/too-deep.txt", "x")
        folder.write("d0/shallow.txt", "x")
        let found = DocumentScanner.scan(folder.url, kind: .folder).files.map(\.relPath)
        #expect(found == ["d0/shallow.txt"])
    }
}
