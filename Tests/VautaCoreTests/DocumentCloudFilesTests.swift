// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Files the Mac does not hold: Google Drive shortcuts and files a cloud service keeps online only are skipped, counted and explained.
/// Vauta never opens them (opening a dataless file makes its File Provider download it) and never contacts an online service.
@Suite("Documents: Google Drive shortcuts and online-only files")
struct DocumentCloudFilesTests {
    private func record(_ path: String, state: DocumentFileRecord.State = .indexed, reason: DocumentSkipReason? = nil) -> DocumentFileRecord {
        DocumentFileRecord(id: Int64(path.hashValue & 0xFFFF), sourceID: 1, relPath: path, fileID: nil, size: 10, mtime: 1, hash: nil, format: .text, extractorVersion: 1,
                           title: nil, state: state, reason: reason, pages: nil, characters: 0, ocrPages: [], indexedAt: nil)
    }

    @Test func everyGoogleShortcutKindIsListedAsSkippedAndNeverOpened() throws {
        let folder = DocumentFolder()
        let names = ["Plan.gdoc", "Budget.gsheet", "Deck.gslides", "Sketch.gdraw", "Survey.gform", "Table.gtable", "Map.gmap", "Site.gsite", "Board.gjam", "Script.gscript"]
        for name in names { folder.write(name, #"{"url": "https://docs.google.com/document/d/abc/edit", "doc_id": "abc"}"#) }
        folder.write("fine.txt", "x")
        // A file nobody may read: listing it must not need to open it.
        let url = folder.url.appendingPathComponent("Plan.gdoc")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        let found = DocumentScanner.scan(folder.url, kind: .folder).files
        #expect(Set(found.filter { $0.skip == .googleDriveShortcut }.map(\.relPath)) == Set(names))
        #expect(found.filter { $0.skip == .googleDriveShortcut }.allSatisfy { $0.format == nil })
        #expect(found.first { $0.relPath == "fine.txt" }?.skip == nil)
        #expect(DocumentFormat.googleDriveExtensions.isDisjoint(with: DocumentFormat.exportAsPDFExtensions))
    }

    @Test func aShortcutIsPlannedAsSkippedOnceAndNeverQueued() {
        let shortcut = ScannedDocumentFile(relPath: "Plan.gdoc", size: 10, mtime: 1, format: nil, skip: .googleDriveShortcut)
        let first = DocumentSync.plan(scanned: [shortcut], known: [])
        #expect(first.skipped.map(\.reason) == [.googleDriveShortcut] && first.added.isEmpty)
        // Recorded already: the next scan plans nothing.
        let again = DocumentSync.plan(scanned: [shortcut], known: [record("Plan.gdoc", state: .skipped, reason: .googleDriveShortcut)])
        #expect(again.isEmpty)
    }

    @Test func aFileThatGetsDownloadedIsReadAfterAll() {
        #expect(DocumentSync.transient.contains(.cloudNotDownloaded) && DocumentSync.transient.contains(.iCloudNotDownloaded))
        #expect(!DocumentSync.transient.contains(.googleDriveShortcut), "a shortcut never turns into a document by itself")
        let now = ScannedDocumentFile(relPath: "Report.docx", size: 10, mtime: 1, format: .docx, skip: nil)
        let plan = DocumentSync.plan(scanned: [now], known: [record("Report.docx", state: .skipped, reason: .cloudNotDownloaded)])
        #expect(plan.retry.map(\.record.relPath) == ["Report.docx"], "downloaded in Finder: the next scan reads it")
    }

    @Test func theDatalessFlagIsTheSystemsAndOrdinaryFilesDoNotHaveIt() {
        #expect(DocumentScanner.datalessFlag == 0x4000_0000)
        let folder = DocumentFolder()
        let file = folder.write("a.txt", "x")
        #expect(!DocumentScanner.isDataless(file))
        #expect(!DocumentScanner.isDataless(folder.url.appendingPathComponent("missing.txt")))
    }

    @Test func aDatalessFileIsSkippedWithoutBeingOpened() throws {
        let folder = DocumentFolder()
        let placeholder = folder.write("Report.docx", "x")
        let local = folder.write("Local.docx", "x")
        // Nobody can read the placeholder, so listing it could not work by opening it; the system's flag is stood in for by a check on the path.
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: placeholder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: placeholder.path) }
        let fake: (URL) -> Bool = { $0.lastPathComponent == "Report.docx" }
        let skipped = DocumentScanner.describe(placeholder, relPath: "Report.docx", isDataless: fake)
        #expect(skipped?.skip == .cloudNotDownloaded && skipped?.format == .docx)
        #expect(DocumentScanner.describe(local, relPath: "Local.docx", isDataless: fake)?.skip == nil)
        // A shortcut is skipped as a shortcut whether or not its bytes are local.
        let shortcut = folder.write("Plan.gdoc", "{}")
        #expect(DocumentScanner.describe(shortcut, relPath: "Plan.gdoc", isDataless: { _ in true })?.skip == .googleDriveShortcut)
        // The plan records it once, and a later scan that finds it downloaded reads it.
        let plan = DocumentSync.plan(scanned: [skipped!], known: [])
        #expect(plan.skipped.map(\.reason) == [.cloudNotDownloaded] && plan.added.isEmpty)
    }

    @Test func theCountsSplitGoogleShortcutsFromOnlineOnlyFiles() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Alpha document about the quarterly marketing plan and its launch.")
        fx.files.write("Plan.gdoc", "{}")
        fx.files.write("Budget.gsheet", "{}")
        try await fx.open()
        let source = try await fx.add()
        let counts = try await fx.index.counts(source: source.id)
        #expect(counts.googleShortcuts == 2 && counts.onlineOnly == 0 && counts.skipped == 2 && counts.indexed == 1)
        // Online-only files, as the scanner records them.
        for name in ["Q1.docx", "Q2.docx", "Q3.pdf"] {
            try await fx.index.markSkipped(source: source.id, scanned: ScannedDocumentFile(relPath: name, size: 10, mtime: 1, format: .docx, skip: .cloudNotDownloaded),
                                           reason: .cloudNotDownloaded)
        }
        try await fx.index.markSkipped(source: source.id, scanned: ScannedDocumentFile(relPath: "Q4.docx", size: 10, mtime: 1, format: .docx, skip: .iCloudNotDownloaded),
                                       reason: .iCloudNotDownloaded)
        let all = try await fx.index.counts(source: source.id)
        #expect(all.googleShortcuts == 2 && all.onlineOnly == 4 && all.skipped == 6)
        let snapshot = await fx.indexer.snapshot()
        #expect(snapshot.googleShortcuts == 2 && snapshot.onlineOnly == 4)
    }

    @Test func theSkippedFilesSheetHasAWordingForEachNewReason() {
        for reason in [DocumentSkipReason.cloudNotDownloaded, .googleDriveShortcut] {
            #expect(!reason.localizedText.isEmpty)
            #expect(DocumentSkipReason(rawValue: reason.rawValue) == reason)
        }
        #expect(DocumentSkipReason.cloudNotDownloaded.rawValue == "cloud" && DocumentSkipReason.googleDriveShortcut.rawValue == "google_drive")
    }

    @Test func aFileThatBecomesAPlaceholderAfterTheScanIsNeverOpened() async throws {
        let fx = try DocsFixture()
        try await fx.open()
        // The listing found both files here; by the time the queue reaches "Evicted.txt" macOS has turned it into a placeholder.
        var probe = FileProbe()
        probe.notOnThisMac = { $0.lastPathComponent == "Evicted.txt" ? .cloudNotDownloaded : nil }
        await fx.indexer.setProbe(probe)
        fx.files.write("Evicted.txt", "Alpha document about the quarterly marketing plan and its launch.")
        fx.files.write("Here.txt", "Beta document about vendor contracts and renewal clauses.")
        let source = try await fx.add()
        #expect(fx.extractor.times("Evicted.txt") == 0, "a placeholder is never read: reading it would make its provider download it")
        #expect(fx.extractor.times("Here.txt") == 1)
        let counts = try await fx.index.counts(source: source.id)
        #expect(counts.onlineOnly == 1 && counts.skipped == 1 && counts.indexed == 1)
        #expect(try await fx.search("quarterly marketing plan").isEmpty)
    }

    @Test func aFileThatIsNotOnThisMacIsWorkedOutFromTheSystemsFlagAndICloudStatus() {
        let folder = DocumentFolder()
        let file = folder.write("a.txt", "x")
        #expect(DocumentScanner.notOnThisMac(file) == nil)
        #expect(DocumentScanner.notOnThisMac(file, isDataless: { _ in true }) == .cloudNotDownloaded)
    }

    @Test func aFolderThatIsNotOnThisMacIsNotListedButIsCounted() throws {
        let folder = DocumentFolder()
        folder.write("top.txt", "x")
        folder.write("Cloud/inside.txt", "x")
        folder.write("Docs/Cloud2/deep.txt", "x")
        let found = DocumentScanner.scan(folder.url, kind: .folder, isDataless: { ["Cloud", "Cloud2"].contains($0.lastPathComponent) }).files
        #expect(Set(found.map(\.relPath)) == ["top.txt", "Cloud/", "Docs/Cloud2/"], "the person is told about each folder; nothing inside is listed")
        #expect(found.filter { $0.relPath.hasSuffix("/") }.allSatisfy { $0.skip == .cloudNotDownloaded && $0.format == nil })
    }

    @Test func filesIndexedUnderAFolderThatWasEvictedStayInTheIndex() {
        let known = [record("Cloud/inside.txt"), record("Cloud/deeper/more.txt"), record("Cloudy.txt"), record("gone.txt")]
        let scanned = [ScannedDocumentFile(relPath: "Cloud/", size: 0, mtime: 0, format: nil, skip: .cloudNotDownloaded)]
        let plan = DocumentSync.plan(scanned: scanned, known: known)
        #expect(Set(plan.removed.map(\.relPath)) == ["Cloudy.txt", "gone.txt"], "only what is under the evicted folder stays; a name that merely starts alike goes with the rest")
    }

    @Test func theSourceFolderItselfNotOnThisMacIsNotListed() throws {
        let folder = DocumentFolder()
        folder.write("inside.txt", "x")
        let rootName = folder.url.lastPathComponent
        var listed = false
        let result = DocumentScanner.scan(folder.url, kind: .folder, isDataless: { url in
            if url.standardizedFileURL.path != folder.url.standardizedFileURL.path { listed = true }
            return true
        })
        #expect(result.rootNotOnThisMac && result.files.map(\.relPath) == [rootName + "/"] && result.files.first?.skip == .cloudNotDownloaded)
        #expect(!listed, "nothing was asked about the folder's contents: it was not enumerated")
    }

    @Test func aSourceWithOnlyFoldersNotOnThisMacShowsTheWarning() async throws {
        let fx = try DocsFixture()
        fx.files.write("a.txt", "Alpha document about the quarterly marketing plan and its launch.")
        fx.files.write("Drive/one.txt", "x")
        fx.files.write("Drive2/two.txt", "x")
        try await fx.open()
        var probe = FileProbe()
        probe.scan = { root, kind in DocumentScanner.scan(root, kind: kind, isDataless: { ["Drive", "Drive2"].contains($0.lastPathComponent) }) }
        await fx.indexer.setProbe(probe)
        let source = try await fx.add()
        let counts = try await fx.index.counts(source: source.id)
        #expect(counts.onlineOnlyFolders == 2 && counts.onlineOnly == 0 && counts.notOnThisMac == 2 && counts.skipped == 2 && counts.indexed == 1)
        let skipped = try await fx.index.skipped(source: source.id)
        #expect(Set(skipped.map(\.relPath)) == ["Drive/", "Drive2/"])
    }

    @Test func theScanOfASourceRunsOnAThreadThatForbidsDownloads() async throws {
        let policy = SharedBox<Int32>(-1)
        let folder = DocumentFolder()
        folder.write("a.txt", "x")
        // The probe's own scan is what the indexer calls: its default goes through the dedicated thread.
        let result = await FileProbe().scan(folder.url, .folder)
        #expect(result.files.map(\.relPath) == ["a.txt"])
        let onThread = try await runOnDedicatedThread { getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) }
        policy.mutate { $0 = onThread }
        #expect(policy.value == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    @Test func aThreadForReadingFilesForbidsDownloads() async throws {
        let policy = try await runOnDedicatedThread { getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) }
        #expect(policy == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        // The passage viewer and the image preview read on such a thread too: Vauta never downloads a file, not even one that is shown.
        let viewer = try await runWithDeadline(seconds: 5) { getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) }
        #expect(viewer == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }
}
