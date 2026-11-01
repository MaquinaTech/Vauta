// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import CoreText
import CryptoKit
import Foundation
import PDFKit
import SwiftUI
import Testing
@testable import Vauta
@testable import VautaCore

/// A database key kept in memory: these tests never touch the Keychain.
private final class MemoryKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// A source access without the sandbox: a bookmark is the path as bytes.
private struct PathAccess: SourceAccessing {
    func makeBookmark(for url: URL) throws -> (data: Data, volumeUUID: String?) { (Data(url.path.utf8), nil) }
    func resolve(_ source: DocumentSource) -> SourceResolution {
        let path = String(decoding: source.bookmark, as: UTF8.self)
        return FileManager.default.fileExists(atPath: path) ? .resolved(url: URL(fileURLWithPath: path), renewed: nil) : .notFound
    }
    func begin(_ url: URL) -> Bool { false }
    func end(_ url: URL) {}
}

/// A folder of generated files, removed afterwards.
private final class Scratch {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-app-docs-\(UUID().uuidString)", isDirectory: true)
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func folder(_ name: String, files: [String: String] = [:]) -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, text) in files { try? Data(text.utf8).write(to: folder.appendingPathComponent(file)) }
        return folder
    }
}

@MainActor
private func until(_ seconds: Double = 240, _ condition: () async -> Bool) async -> Bool {
    // Stretched under a sanitizer (`VAUTA_TEST_TIME_SCALE`, set by the sanitizers workflow), as in VautaCoreTests' `TestTiming`.
    let scale = ProcessInfo.processInfo.environment["VAUTA_TEST_TIME_SCALE"].flatMap(Double.init).map { max(1, $0) } ?? 1
    let deadline = Date().addingTimeInterval(seconds * scale)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

@MainActor
private final class Pane {
    let scratch = Scratch()
    let store: MeetingStore
    let index: DocumentIndex
    let model: DocumentsModel
    let defaults = UserDefaults(suiteName: "vauta-app-docs-\(UUID().uuidString)")!
    /// The store's folder, removed with the pane.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-app-store-\(UUID().uuidString)", isDirectory: true)

    deinit { try? FileManager.default.removeItem(at: directory) }

    init() async throws {
        store = try MeetingStore(directory: directory, keyStore: MemoryKey())
        index = try DocumentIndex(directory: directory, key: await store.documentsKey())
        model = DocumentsModel(store: store, index: index, access: PathAccess(), environment: { IndexerEnvironment() }, defaults: defaults)
        model.start(llm: nil)
        _ = await until { await self.model.indexer?.snapshot().sources.isEmpty == true }
    }

    func added(_ folder: URL) async -> DocumentSourceStatus? {
        model.add([folder])
        _ = await until { !self.model.notes.isEmpty }
        return nil
    }
}

@Suite @MainActor struct DocumentsPaneModelTests {
    @Test func aDuplicateOrNestedFolderIsRefusedAndAParentThatHoldsASourceToo() async throws {
        let pane = try await Pane()
        let projects = pane.scratch.folder("Projects", files: ["a.txt": "Alpha text about the offsite and its catering."])
        let inner = pane.scratch.folder("Projects/Inner", files: ["b.txt": "Beta text about the launch plan."])
        _ = await pane.added(projects)
        #expect(pane.model.notes == [.added("Projects")])
        pane.model.notes = []
        pane.model.add([projects])
        #expect(await until { !pane.model.notes.isEmpty })
        #expect(pane.model.notes == [.alreadyIncluded("Projects")])
        pane.model.notes = []
        pane.model.add([inner])
        #expect(await until { !pane.model.notes.isEmpty })
        #expect(pane.model.notes == [.alreadyIncluded("Projects")], "a folder inside a source is already read")
        // A folder that holds a source is refused too (the person removes the inner one first).
        let other = pane.scratch.folder("Elsewhere/Deep", files: ["c.txt": "Gamma text about the budget review."])
        pane.model.notes = []
        pane.model.add([other])
        #expect(await until { !pane.model.notes.isEmpty })
        pane.model.notes = []
        pane.model.add([other.deletingLastPathComponent()])
        #expect(await until { !pane.model.notes.isEmpty })
        #expect(pane.model.notes == [.containsExisting("Deep")])
    }

    @Test func addingSeveralItemsSaysWhatBecameOfEachNotOnlyTheLast() async throws {
        let pane = try await Pane()
        let projects = pane.scratch.folder("Projects", files: ["a.txt": "Alpha text about the offsite and its catering."])
        let handbook = pane.scratch.folder("Handbook", files: ["b.txt": "Beta text about the launch plan."])
        _ = await pane.added(projects)
        pane.model.notes = []
        // One already included, one new, one of Vauta's own: three results, in order, whichever comes last.
        pane.model.add([projects, handbook, pane.store.storeDirectory])
        #expect(await until { pane.model.notes.count == 3 })
        #expect(pane.model.notes == [.alreadyIncluded("Projects"), .added("Handbook"), .ownData])
    }

    @Test func anUnsupportedMaterialIsSaidInTheMeetingAndEveryMaterialHasAState() async throws {
        let pane = try await Pane()
        let meetingID = try await pane.store.startMeeting(at: .now)
        let meetings = MeetingsModel(store: pane.store)
        meetings.documentsModel = pane.model
        meetings.selectedID = meetingID
        let good = pane.scratch.folder("Attach", files: ["notes.txt": "Standalone text about the data retention policy and legal holds.", "deck.key": "x"])
        meetings.attachMaterials([good.appendingPathComponent("deck.key"), good.appendingPathComponent("notes.txt")])
        #expect(await until { !meetings.materialsNotes.isEmpty && meetings.materials.count == 1 })
        // The note is the meeting's own: Settings → Documents says nothing about it.
        #expect(meetings.materialsNotes == [.unsupported], "\(meetings.materialsNotes)")
        #expect(pane.model.notes.isEmpty)
        // The row's state is asked of the indexer until the file has been read.
        #expect(await until { await meetings.refreshMaterialStates(); return meetings.materialStates.values.first == .ready })
    }

    @Test func aFailedLocateIsSaidAndASuccessfulOneClearsTheNotes() {
        #expect(DocumentsModel.Note.note(for: DocumentSourceError.wrongKind) == .failed)
        #expect(DocumentsModel.Note.note(for: DocumentSourceError.ownData) == .ownData)
        #expect(DocumentsModel.Note.note(for: DocumentSourceError.alreadyIncluded("X")) == .alreadyIncluded("X"))
        #expect(DocumentsModel.Note.note(for: DocumentSourceError.unsupportedFile) == .unsupported)
        #expect(DocumentsModel.Note.note(for: CocoaError(.fileReadNoPermission)) == .failed)
    }

    @Test func aCheckFromAnotherDayShowsTheDate() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_791_450_000)
        let today = DocumentSourceStatus.checkedText(now.addingTimeInterval(-3600), now: now, calendar: calendar)
        let lastWeek = DocumentSourceStatus.checkedText(now.addingTimeInterval(-7 * 86_400), now: now, calendar: calendar)
        #expect(today == now.addingTimeInterval(-3600).formatted(date: .omitted, time: .shortened))
        #expect(lastWeek == now.addingTimeInterval(-7 * 86_400).formatted(date: .abbreviated, time: .shortened))
        #expect(lastWeek.count > today.count, "another day carries a date")
    }

    @Test func everyMaterialStateHasWordsAndASymbolAndOnlyTheUnusableOnesAreProblems() {
        let states: [MaterialState] = [.waiting, .indexing, .readingImages(left: 3), .ready, .partial, .skipped(.passwordProtected, .pdf), .unavailable(.disconnected),
                                       .unavailable(.noPermission), .unavailable(.notFound)]
        for state in states { #expect(!state.text.isEmpty && !state.symbol.isEmpty) }
        #expect(MaterialState.skipped(.tooLarge, .pdf).isProblem && MaterialState.unavailable(.disconnected).isProblem)
        #expect(!MaterialState.ready.isProblem && !MaterialState.waiting.isProblem && !MaterialState.partial.isProblem)
        #expect(MaterialState.skipped(.passwordProtected, .pdf).text == DocumentSkipReason.passwordProtected.localizedText)
        #expect(MaterialState.ready.isUsable && !MaterialState.skipped(.noText, .pdf).isUsable && !MaterialState.waiting.isUsable)
    }

    @Test func vautasOwnDataCanNotBeASource() async throws {
        let pane = try await Pane()
        pane.model.add([pane.store.storeDirectory])
        #expect(await until { !pane.model.notes.isEmpty })
        #expect(pane.model.notes == [.ownData])
        #expect(pane.model.notes.first?.text.contains("Vauta") == true)
    }

    @Test func removingASourceDeletesItsIndexAndTheSource() async throws {
        let pane = try await Pane()
        let folder = pane.scratch.folder("Handbook", files: ["a.txt": "The handbook says the zeppelin hangar rental is approved for June."])
        _ = await pane.added(folder)
        #expect(await until { ((try? await pane.index.totalPassages()) ?? 0) > 0 })
        let status = try #require(await pane.model.indexer?.snapshot().sources.first)
        pane.model.remove(status)
        #expect(await until { ((try? await pane.index.totalPassages()) ?? 1) == 0 })
        #expect(await until { ((try? await pane.store.documentSources())?.isEmpty) == true })
        #expect(await until { pane.model.snapshot.sources.isEmpty })
    }

    @Test func pausingASourcePersistsInTheStore() async throws {
        let pane = try await Pane()
        let folder = pane.scratch.folder("Reports", files: ["a.txt": "Quarterly report text about revenue and the regional teams."])
        _ = await pane.added(folder)
        let status = try #require(await pane.model.indexer?.snapshot().sources.first)
        pane.model.setPaused(status, true)
        #expect(await until { ((try? await pane.store.documentSources())?.first?.paused) == true })
        pane.model.setPaused(status, false)
        #expect(await until { ((try? await pane.store.documentSources())?.first?.paused) == false })
    }

    @Test func pathsShowTheHomeFolderAsATildeAndPagesAreCountedFromCharacters() {
        #expect(DocumentsModel.abbreviated("/Users/maya/Documents/Projects", home: "/Users/maya") == "~/Documents/Projects")
        #expect(DocumentsModel.abbreviated("/Users/maya", home: "/Users/maya") == "~")
        #expect(DocumentsModel.abbreviated("/Volumes/Backup/Photos", home: "/Users/maya") == "/Volumes/Backup/Photos")
        #expect(DocumentsModel.abbreviated("/Users/mayabel/x", home: "/Users/maya") == "/Users/mayabel/x")
        #expect(DocumentsModel.pages(characters: 0) == 0)
        #expect(DocumentsModel.pages(characters: 10) == 1)
        #expect(DocumentsModel.pages(characters: 60_000_000) == 25_000)
    }
}

@Suite @MainActor struct PassageViewerTests {
    /// A PDF with `pages` pages; page 4 carries `text` (the others a short marker).
    private func pdf(_ text: String) -> PDFDocument? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for page in 1...4 {
            context.beginPDFPage(nil)
            let body = page == 4 ? text : "Onboarding page \(page)"
            let attributed = NSAttributedString(string: body, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0),
                                                 CGPath(rect: CGRect(x: 56, y: 56, width: 500, height: 680), transform: nil), nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)
    }

    private func window(showing view: PassagePDFView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view.layoutSubtreeIfNeeded()
        return window
    }

    @Test func aPDFOpensAtItsPageWithTheQuoteSelected() async throws {
        let document = try #require(pdf("New hires get laptop access on day one and badge access on day two."))
        let view = PassagePDFView()
        view.document = document
        view.onReady = { PDFPassageView.showPassage(in: $0, document: document, page: 4, quote: "LAPTOP access on day ONE", ocr: false) }
        let window = window(showing: view)
        defer { window.close() }
        #expect(await until(10) { view.currentSelection != nil })
        #expect(view.currentSelection?.string?.lowercased().contains("laptop access on day one") == true)
        #expect(view.currentPage == document.page(at: 3))
        // The highlight is drawn with the view, as ordinary views above the page: yellow pixels on screen.
        #expect(await until(10) { yellowPixels(in: view) > 200 }, "the quote is highlighted on screen, not only selected")
    }

    /// Pixels of `view` as it is drawn on screen (not the page rendered alone).
    private func yellowPixels(in view: NSView) -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        var yellow = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if c.redComponent > 0.9, c.greenComponent > 0.8, c.blueComponent < 0.7 { yellow += 1 }
        } }
        return yellow
    }

    @Test func theViewerSheetShowsTheQuoteHighlightedOnScreen() async throws {
        let document = try #require(pdf("New hires get laptop access on day one and badge access on day two."))
        let passage = DocumentPassage(id: 1, key: "k", fileID: 1, sourceID: 2, relPath: "Onboarding.pdf", fileName: "Onboarding.pdf", format: .pdf, locator: .page(4),
                                      text: "Onboarding\nNew hires get laptop access on day one and badge access on day two.")
        let request = PassageViewerRequest(citation: DocumentCitation(passage, quote: "laptop access on day one"))
        let model = PassageViewerModel(preview: passage, availability: .available, request: request, pdf: document)
        let host = NSHostingView(rootView: PassageViewer(model: model, done: {}))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 560)
        defer { window.close() }
        var found = 0
        #expect(await until(15) {
            host.layoutSubtreeIfNeeded()
            found = yellowPixels(in: host)
            return found > 200
        }, "yellow pixels on screen: \(found)")
    }

    @Test func aScannedPageIsShownWithoutASelectionAndWithoutAChangedWarning() async throws {
        let document = try #require(pdf("A page whose words are only in the picture of the scan."))
        let view = PassagePDFView()
        view.document = document
        view.onReady = { PDFPassageView.showPassage(in: $0, document: document, page: 4, quote: "words are only in the picture", ocr: true) }
        let window = window(showing: view)
        defer { window.close() }
        #expect(await until(10) { view.currentPage == document.page(at: 3) })
        #expect(view.currentSelection == nil)
        // The result of showing it is "no selection", which is not a reason to say the passage changed: the viewer decides that from
        // the file's size and date.
        #expect(PDFPassageView.showPassage(in: view, document: document, page: 4, quote: "words are only in the picture", ocr: true) == false)
    }

    @Test func aQuoteThatIsNotOnThePageLeavesThePageShownWithoutASelection() async throws {
        let document = try #require(pdf("The real text of page four."))
        let view = PassagePDFView()
        view.document = document
        let window = window(showing: view)
        defer { window.close() }
        #expect(PDFPassageView.showPassage(in: view, document: document, page: 4, quote: "text the page does not have", ocr: false) == false)
        #expect(view.currentPage == document.page(at: 3))
        #expect(view.currentSelection == nil)
    }

    @Test func theViewerOffersLocateOnlyWhenTheSourceCanBePointedAt() {
        let passage = DocumentPassage(id: 1, key: "k", fileID: 1, sourceID: 2, relPath: "a.pdf", fileName: "a.pdf", format: .pdf, locator: .page(1), text: "T\nbody")
        let request = PassageViewerRequest(citation: DocumentCitation(passage))
        let missing = PassageViewerModel(preview: passage, availability: .unavailable(.notFound), request: request, canLocate: true)
        let offline = PassageViewerModel(preview: passage, availability: .unavailable(.disconnected), request: request)
        let open = PassageViewerModel(preview: passage, availability: .available, request: request, appName: "Preview", opened: true)
        #expect(missing.canLocate && missing.isOffline && !missing.canOpen)
        #expect(!offline.canLocate && offline.isOffline)
        #expect(open.canOpen && !open.canLocate && !open.isOffline)
    }

    @Test func aPlaceholderFileOffersNeitherOpenNorQuickLookBecauseThoseWouldDownloadIt() {
        let passage = DocumentPassage(id: 1, key: "k", fileID: 1, sourceID: 2, relPath: "a.pdf", fileName: "a.pdf", format: .pdf, locator: .page(1), text: "T\nbody")
        let request = PassageViewerRequest(citation: DocumentCitation(passage))
        let online = PassageViewerModel(preview: passage, availability: .notOnThisMac, request: request, appName: "Preview", opened: true)
        #expect(!online.canOpen && !online.isOffline && !online.canLocate)
    }
}

@Suite @MainActor struct AskViewTests {
    @Test func theTitleAndTheUnverifiedNoteFollowTheScope() {
        #expect(AskView.headerTitle(scope: .everywhere, hasDocumentSources: false) == "Ask about your meetings")
        #expect(AskView.headerTitle(scope: .documents, hasDocumentSources: false) == "Ask about your meetings", "without sources nothing changes")
        #expect(AskView.headerTitle(scope: .documents, hasDocumentSources: true) == "Ask about your documents")
        #expect(AskView.headerTitle(scope: .everywhere, hasDocumentSources: true) == "Ask about your meetings and documents")
        #expect(AskView.headerTitle(scope: .meetings, hasDocumentSources: true) == "Ask about your meetings")
        #expect(AskModel.unverifiedNote(for: .meetings).contains("transcript") && !AskModel.unverifiedNote(for: .meetings).contains("document"))
        #expect(AskModel.unverifiedNote(for: .documents).contains("document") && !AskModel.unverifiedNote(for: .documents).contains("transcript"))
        #expect(AskModel.unverifiedNote(for: .everywhere).contains("transcript") && AskModel.unverifiedNote(for: .everywhere).contains("document"))
    }

    @Test func aDocumentChipIsNamedForVoiceOverByFileAndPlace() {
        func chip(_ name: String, _ locator: DocumentLocator) -> DocumentCitation {
            DocumentCitation(DocumentPassage(id: 1, key: "k", fileID: 1, sourceID: 1, relPath: name, fileName: name, format: .pdf, locator: locator, text: "T\nbody"))
        }
        let page = chip("Onboarding.pdf", .page(4))
        #expect(page.spokenLabel == "Open Onboarding, page 4")
        #expect(page.label == "Onboarding.pdf · p. 4")
        #expect(chip("Budget.xlsx", .sheet(name: "Q3", firstRow: 12, lastRow: 40)).spokenLabel == "Open Budget, sheet Q3, rows 12 to 40")
        #expect(chip("Pitch.pptx", .slide(7)).spokenLabel == "Open Pitch, slide 7")
        #expect(chip("Whiteboard.png", .image).spokenLabel == "Open Whiteboard")
        // A path never appears in what a chip says.
        #expect(!chip("Contract.pdf", .page(1)).label.contains("/"))
    }
}

@Suite @MainActor struct PanelRowStopTests {
    private func note(_ top: CGFloat, _ bottom: CGFloat) -> PanelGeometryProbe.Item { .init(kind: .note, frame: CGRect(x: 0, y: top, width: 200, height: bottom - top)) }
    private func viewport(_ kind: PanelGeometryProbe.Item.Kind, _ top: CGFloat, _ bottom: CGFloat) -> PanelGeometryProbe.Item {
        .init(kind: kind, frame: CGRect(x: 0, y: top, width: 200, height: bottom - top))
    }

    @Test func rowStopsFromSeveralRowsAreCollected() {
        var value: [CGFloat] = [10]
        PanelRowStop.Key.reduce(value: &value) { [20, 30] }
        #expect(value == [10, 20, 30])
        #expect(PanelRowStop.Key.defaultValue.isEmpty)
    }

    @Test func aViewportThatEndsBetweenTwoNotesPasses() {
        PanelGeometryProbe.items = [note(100, 130), note(136, 170), note(176, 210),
                                    viewport(.notesViewport, 90, 215), viewport(.panelViewport, 0, 174)]
        #expect(PanelGeometryProbe.problem() == nil)
    }

    @Test func aViewportThatEndsThroughANoteIsReported() {
        PanelGeometryProbe.items = [note(100, 130), note(136, 170), note(176, 210),
                                    viewport(.notesViewport, 90, 215), viewport(.panelViewport, 0, 150)]
        #expect(PanelGeometryProbe.problem()?.contains("panel's viewport") == true)
        // The notes' own viewport cutting a note is reported as well.
        PanelGeometryProbe.items = [note(100, 130), note(136, 170), viewport(.notesViewport, 90, 160), viewport(.panelViewport, 0, 300)]
        #expect(PanelGeometryProbe.problem()?.contains("notes' viewport") == true)
        // A note hidden by the notes' viewport does not count against the panel's.
        PanelGeometryProbe.items = [note(100, 130), note(136, 170), viewport(.notesViewport, 90, 133), viewport(.panelViewport, 0, 150)]
        #expect(PanelGeometryProbe.problem() == nil)
        PanelGeometryProbe.items = []
        #expect(PanelGeometryProbe.problem() != nil, "a scene that reports nothing is not a pass")
    }

    @Test func aSceneWhoseNotesAreBelowTheFoldIsReported() {
        PanelGeometryProbe.items = [note(500, 530), note(536, 570), viewport(.notesViewport, 490, 600), viewport(.panelViewport, 0, 400)]
        #expect(PanelGeometryProbe.problem(requiringNotesOnScreen: true)?.contains("not on screen") == true)
        #expect(PanelGeometryProbe.problem() == nil, "the scenes that do not need the notes in view only check the cuts")
    }
}
