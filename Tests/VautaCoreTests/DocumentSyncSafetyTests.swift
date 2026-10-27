// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A gate a test opens when it wants a fake slow operation to go on.
actor ScanGate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var arrived = 0

    func wait() async {
        arrived += 1
        guard !open else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        open = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

/// Waits (up to `seconds`) until `condition` holds.
func becomes(seconds: Double = 240, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

/// A scan, an erase, a recording or a slow disk can overlap: none of them may leave a removed source's files in the index,
/// block quitting, or make the index write while a meeting records.
@Suite struct DocumentSyncSafetyTests {
    private func slowScan(_ gate: ScanGate) -> FileProbe {
        var probe = FileProbe()
        probe.scan = { root, kind in
            await gate.wait()
            return DocumentScanner.scan(root, kind: kind)
        }
        return probe
    }

    @Test func removingASourceWhileItsFolderIsScannedLeavesNothingInTheIndex() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Alpha document about the quarterly marketing plan and its launch.")
        try await fx.open()
        let source = try await fx.add()
        let gate = ScanGate()
        await fx.indexer.setProbe(slowScan(gate))
        fx.files.write("b.txt", "Beta document about vendor contracts and renewal clauses.")
        let scan = Task { [indexer = fx.indexer!] in await indexer.changed(source.id) }
        #expect(await becomes { await gate.arrived == 1 })
        try await fx.indexer.removeSource(source.id)
        await gate.release()
        await scan.value
        #expect(try await fx.index.files(source: source.id).isEmpty)
        #expect(try await fx.index.allFileSourceIDs().isEmpty)
        #expect(try await fx.search("vendor contracts renewal").isEmpty)
    }

    @Test func aReplacedStoreIsNotRepopulatedByAScanThatStartedBefore() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Alpha document about the quarterly marketing plan and its launch.")
        try await fx.open()
        let source = try await fx.add()
        let gate = ScanGate()
        await fx.indexer.setProbe(slowScan(gate))
        fx.files.write("b.txt", "Beta document about vendor contracts and renewal clauses.")
        let scan = Task { [indexer = fx.indexer!] in await indexer.changed(source.id) }
        #expect(await becomes { await gate.arrived == 1 })
        // Erase Everything: the store has no sources any more.
        try await fx.meetingStore.removeDocumentSource(source.id)
        await fx.indexer.resetAfterReplacement()
        await gate.release()
        await scan.value
        #expect(try await fx.index.allFileSourceIDs().isEmpty)
        #expect(try await fx.index.totalFiles() == 0)
    }

    @Test func aHungDiskNeverHoldsUpQuitting() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Alpha document about the quarterly marketing plan and its launch.")
        try await fx.open()
        let source = try await fx.add()
        // The disk does not answer until the test lets it go (at the end): nothing below can depend on how long a wait lasts.
        let disk = SharedValue(false)
        defer { disk.set(true) }
        var probe = FileProbe()
        probe.stat = { _ in blockUntil(disk); return nil }
        probe.hash = { _, _ in blockUntil(disk); return nil }
        await fx.indexer.setProbe(probe)
        await fx.indexer.setIODeadline(60)
        // A changed file: hashing it blocks; a new file: reading it blocks on its date.
        fx.files.write("a.txt", "Alpha document rewritten with other words about hiring plans for next year.")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(500)], ofItemAtPath: fx.files.url.appendingPathComponent("a.txt").path)
        fx.files.write("b.txt", "Beta document about vendor contracts and renewal clauses.")
        let sync = Task { [indexer = fx.indexer!] in await indexer.changed(source.id) }
        #expect(await becomes { fx.extractor.count >= 0 })
        // The actor stays free while the disk does not answer, and quitting does not wait for it: both return with the disk still hung.
        _ = await fx.indexer.snapshot()
        await fx.indexer.stop()
        #expect(disk.value == false)
        sync.cancel()
    }

    @Test func aRecordingDefersTheScanAndTheSaveUntilItEnds() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Alpha document about the quarterly marketing plan and its launch.")
        try await fx.open()
        let source = try await fx.add()
        fx.environment.set(IndexerEnvironment(isRecording: true))
        fx.files.write("b.txt", "Beta document about vendor contracts and renewal clauses.")
        await fx.indexer.changed(source.id)
        #expect(try await fx.index.files(source: source.id).map(\.relPath) == ["a.txt"], "nothing is scanned while a meeting records")
        let during = await fx.indexer.snapshot()
        #expect(during.sources.first?.state == .pausedForPower(.recording))
        fx.environment.set(IndexerEnvironment())
        await fx.indexer.environmentChanged()
        #expect(await becomes { (try? await fx.search("vendor contracts renewal").first?.fileName) == "b.txt" })
    }

    @Test func aNetworkVolumeWaitsForTheChargerAndIsPolled() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Alpha document about the quarterly marketing plan and its launch.")
        try await fx.open()
        var probe = FileProbe()
        probe.isLocalVolume = { _ in false }
        await fx.indexer.setProbe(probe)
        fx.environment.set(IndexerEnvironment(onBattery: true))
        let source = try await fx.indexer.addSource(fx.files.url, isDirectory: true)
        #expect(try await fx.index.files(source: source.id).isEmpty, "a network volume is not scanned on battery")
        fx.environment.set(IndexerEnvironment())
        await fx.indexer.environmentChanged()
        #expect(await becomes { (try? await fx.search("quarterly marketing plan").first?.fileName) == "a.txt" })
        // A change on the share is found by the 30-minute scan (no events there).
        fx.files.write("c.txt", "Gamma document about the data retention policy and legal holds.")
        await fx.indexer.syncPolled()
        #expect(await becomes { (try? await fx.search("data retention policy").first?.fileName) == "c.txt" })
    }

    @Test func aSingleFileSourceIsPolledNotWatched() async throws {
        let fx = try DocsFixture()
        let file = fx.files.write("solo.txt", "Original text about the migration timeline and rollout owners.")
        try await fx.open()
        let source = try await fx.indexer.addSource(file, isDirectory: false)
        try await fx.settle()
        fx.files.write("solo.txt", "Replacement text about the pricing review and discount approvals.")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(500)], ofItemAtPath: file.path)
        await fx.indexer.syncPolled()
        #expect(await becomes { (try? await fx.search("pricing review discount").first?.fileName) == "solo.txt" })
        #expect(try await fx.search("migration timeline").isEmpty)
        _ = source
    }

    @Test func aBetterExtractorReReadsEachFileOnceNotAtEveryScan() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.md", "# Notes\n\nPassage about the vendor contract renewal and its termination clauses.\n")
        fx.files.write("b.md", "# Plan\n\nPassage about the hiring plan for next year and headcount.\n")
        try await fx.open()
        let source = try await fx.add()
        #expect(fx.extractor.count == 2)
        // Pretend both were read by an older extractor.
        for record in try await fx.index.files(source: source.id) { try await fx.index.setExtractorVersion(fileID: record.id, 0) }
        await fx.indexer.changed(source.id)
        try await fx.settle()
        #expect(await becomes { fx.extractor.count == 4 })
        for record in try await fx.index.files(source: source.id) { #expect(record.extractorVersion == DocumentFormat.markdown.extractorVersion) }
        // The next scans find nothing outdated, and read nothing.
        let known = try await fx.index.files(source: source.id)
        let scanned = DocumentScanner.scan(fx.files.url, kind: .folder).files
        #expect(DocumentSync.plan(scanned: scanned, known: known).outdated.isEmpty)
        await fx.indexer.changed(source.id)
        await fx.indexer.changed(source.id)
        try await fx.settle()
        #expect(fx.extractor.count == 4)
    }

    @Test func outdatedFilesWaitBehindNewOnes() async throws {
        let fx = try DocsFixture()
        fx.files.write("old.md", "# Old\n\nPassage about the vendor contract renewal and its termination clauses.\n")
        try await fx.open()
        let source = try await fx.add()
        let old = try #require(try await fx.index.files(source: source.id).first)
        try await fx.index.setExtractorVersion(fileID: old.id, 0)
        try await fx.index.requeue(source: source.id, onlyFormat: .markdown, olderThan: 1)
        // A bigger new file still goes first.
        fx.files.write("new.md", "# New\n\nPassage about the hiring plan for next year and headcount, with more words so it is bigger.\n")
        let scanned = try #require(DocumentScanner.scan(fx.files.url, kind: .folder).files.first { $0.relPath == "new.md" })
        try await fx.index.markPending(source: source.id, scanned: scanned, format: .markdown)
        let queue = try await fx.index.queue(limit: 5, sources: [source.id])
        #expect(queue.map(\.relPath) == ["new.md", "old.md"])
    }

    @Test func aRenamedFileTakesItsNewNameInTheStoredPassageHeader() async throws {
        let fx = try DocsFixture()
        let file = fx.files.write("Old.txt", "Passage about the vendor contract renewal and its termination clauses.")
        try await fx.open()
        let source = try await fx.add()
        let before = try #require(try await fx.search("vendor contract renewal").first)
        #expect(before.text.hasPrefix("Old"))
        try FileManager.default.moveItem(at: file, to: fx.files.url.appendingPathComponent("New.txt"))
        await fx.indexer.changed(source.id)
        try await fx.settle()
        let after = try #require(try await fx.search("vendor contract renewal").first)
        #expect(after.text.hasPrefix("New") && !after.text.contains("Old"))
        // The key is what a fresh read of the renamed file would give, so the next edit does not re-embed every passage.
        #expect(after.key != before.key)
        #expect(after.key == PassageChunker.key(after.locator, after.text))
        #expect(try await fx.search("Old").isEmpty)
        #expect(try await fx.search("New").first?.fileName == "New.txt")
    }

    @Test func theSaveIntervalGrowsWithTheImage() {
        #expect(DocumentIndexer.saveInterval(imageBytes: 1 << 20) == 60)
        #expect(DocumentIndexer.saveInterval(imageBytes: 50 << 20) == 300)
    }

    @Test func locatingASourceFollowsTheRulesOfAddingOne() async throws {
        let fx = try DocsFixture()
        fx.files.write("one/a.txt", "Alpha document about the quarterly marketing plan and its launch.")
        fx.files.write("two/b.txt", "Beta document about vendor contracts and renewal clauses.")
        fx.files.write("two/inner/c.txt", "Gamma document about the data retention policy and legal holds.")
        try await fx.open()
        let one = try await fx.add(folder: "one")
        let two = try await fx.add(folder: "two")
        // Another source's place, and a place inside it, are refused; so is a folder that holds Vauta's data.
        #expect(await thrown { try await fx.indexer.relocate(one.id, to: fx.files.url.appendingPathComponent("two/inner")) } as? DocumentSourceError == DocumentSourceError.alreadyIncluded(two.displayName))
        #expect(await thrown { try await fx.indexer.relocate(one.id, to: fx.files.url) } as? DocumentSourceError == DocumentSourceError.containsExisting(two.displayName))
        #expect(await thrown { try await fx.indexer.relocate(one.id, to: fx.files.url, ownData: [fx.files.url.appendingPathComponent("one")]) } as? DocumentSourceError == DocumentSourceError.ownData)
        // Its own place is fine.
        try await fx.indexer.relocate(one.id, to: fx.files.url.appendingPathComponent("one"))
    }

    @Test func attachingAFileSaysWhyItCannotBeAttachedAndLinksLibraryFiles() async throws {
        let fx = try DocsFixture()
        let meeting = try await fx.meetingStore.startMeeting(at: .now)
        fx.files.write("lib/notes.md", "# Notes\n\nPassage about the vendor contract renewal and its termination clauses.\n")
        fx.files.write("lib/.hidden/secret.md", "# Secret\n\nPassage about the hiring plan for next year and headcount.\n")
        let solo = fx.files.write("solo.txt", "Standalone text about the data retention policy and legal holds.")
        try await fx.open()
        _ = try await fx.add(folder: "lib")
        #expect(await thrown { try await fx.indexer.attachMaterial(fx.files.write("deck.key", "x"), to: meeting) } as? DocumentSourceError == DocumentSourceError.unsupportedFile)
        // Inside a library folder and indexed: linked.
        try await fx.indexer.attachMaterial(fx.files.url.appendingPathComponent("lib/notes.md"), to: meeting)
        // Inside a library folder but never listed by its scan (a hidden folder): attached as a source of its own, so Ask finds it.
        try await fx.indexer.attachMaterial(fx.files.url.appendingPathComponent("lib/.hidden/secret.md"), to: meeting)
        try await fx.settle()
        let materials = try await fx.meetingStore.meetingMaterials(meeting)
        #expect(materials.linked.map(\.relPath) == ["notes.md"])
        #expect(materials.attached.map(\.displayName) == ["secret.md"])
        #expect(try await fx.search("hiring plan headcount", filter: fx.meetingStore.materialsFilter(meeting)).first?.fileName == "secret.md")
        // A file that is itself a single-file source of the library is linked, not refused.
        let library = try await fx.indexer.addSource(solo, isDirectory: false)
        try await fx.indexer.attachMaterial(solo, to: meeting)
        #expect(try await fx.meetingStore.meetingMaterials(meeting).linked.contains { $0.source == library.id && $0.relPath == "solo.txt" })
    }

    @Test func aMaterialSaysHowItIsDoing() async throws {
        let fx = try DocsFixture()
        let meeting = try await fx.meetingStore.startMeeting(at: .now)
        let good = fx.files.write("good.txt", "Standalone text about the data retention policy and legal holds.")
        let bad = fx.files.write("bad.txt", "")
        try await fx.open()
        try await fx.indexer.attachMaterial(good, to: meeting)
        try await fx.indexer.attachMaterial(bad, to: meeting)
        try await fx.settle()
        let attached = try await fx.meetingStore.meetingMaterials(meeting).attached
        let states = await [attached[0], attached[1]].asyncMap { await fx.indexer.materialState(source: $0.id, relPath: nil) }
        let byName = Dictionary(uniqueKeysWithValues: zip(attached.map(\.displayName), states))
        #expect(byName["good.txt"] == .ready)
        if case .skipped(let reason, _)? = byName["bad.txt"] { #expect(reason == .noText) } else { Issue.record("an empty file should be skipped, got \(String(describing: byName["bad.txt"]))") }
        fx.access.setDisconnected(attached[0].id, true)
        await fx.indexer.changed(attached[0].id)
        #expect(await fx.indexer.materialState(source: attached[0].id, relPath: nil) == .unavailable(.disconnected))
    }
}

/// The error `body` throws, if any (an `#expect(throws:)` closure can't capture the non-Sendable fixture).
func thrown(_ body: () async throws -> Void) async -> (any Error)? {
    do { try await body(); return nil } catch { return error }
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var out: [T] = []
        for element in self { out.append(await transform(element)) }
        return out
    }
}
