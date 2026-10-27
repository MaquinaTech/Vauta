// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import PDFKit
import QuickLookUI
import SwiftUI

/// What a citation opens: the passage and, when the answer quoted it, the quote.
struct PassageViewerRequest: Identifiable {
    let id = UUID()
    let citation: DocumentCitation
}

/// The state of the passage viewer. The file is only touched by the person's own action in this sheet (Open, Quick Look): the
/// text shown is the one stored in the index.
@MainActor
@Observable
final class PassageViewerModel: Identifiable {
    let id: UUID
    enum Availability: Equatable {
        case loading
        /// The file is there and is shown as it is (a PDF at its page).
        case available
        /// The source can't be reached (a drive is unplugged, the folder moved): the stored passage is shown with its status.
        case unavailable(DocumentSourceStatus.State?)
        /// The file no longer has the quote at that place.
        case changed
        /// The file is a placeholder of a cloud service: Vauta does not download it, the stored passage is shown.
        case notOnThisMac
    }

    private(set) var passage: DocumentPassage?
    private(set) var availability = Availability.loading
    private(set) var pdf: PDFDocument?
    private(set) var image: NSImage?
    private(set) var openedFile: DocumentIndexer.ViewedFile?
    private(set) var appName: String?
    /// Why the last Locate… failed, shown in the sheet.
    private(set) var locateNote: DocumentsModel.Note?
    /// A rendering shows the buttons that open the file (the file itself is never touched there).
    /// The sheet went away: a load that is still waiting must not keep the file's access open.
    @ObservationIgnored private var closed = false
    @ObservationIgnored private var previewOpened = false
    @ObservationIgnored private var previewCanLocate = false
    let request: PassageViewerRequest
    @ObservationIgnored private let documents: DocumentsModel?
    /// A model for a rendering: a fixed passage and state.
    @ObservationIgnored private let preview: (DocumentPassage, Availability)?

    init(request: PassageViewerRequest, documents: DocumentsModel?) {
        self.request = request
        id = request.id
        self.documents = documents
        preview = nil
    }

    init(preview passage: DocumentPassage, availability: Availability, request: PassageViewerRequest, pdf: PDFDocument? = nil, image: NSImage? = nil, appName: String? = nil,
         opened: Bool = false, canLocate: Bool = false) {
        previewOpened = opened
        previewCanLocate = canLocate
        self.request = request
        id = request.id
        documents = nil
        self.preview = (passage, availability)
        self.passage = passage
        self.availability = availability
        self.pdf = pdf
        self.image = image
        self.appName = appName
    }

    func load() async {
        guard preview == nil, let documents, let index = documents.index, let indexer = documents.indexer else { return }
        let c = request.citation
        // By row first; a row that was replaced by a re-index is found again by its stable key.
        var found = try? await index.passage(id: c.passageID)
        if found == nil || found?.key != c.key { found = try? await index.passage(source: c.sourceID, relPath: c.relPath, key: c.key) }
        // The passage's key changed (the file was edited and indexed again): the quote is looked for in the same file's passages.
        if found == nil, let quote = quoteIfAny, let record = try? await index.file(source: c.sourceID, relPath: c.relPath),
           let passages = try? await index.passages(file: record.id) {
            found = QuoteLocator.passage(quoting: quote, in: passages)
        }
        guard !closed else { return }
        guard let found else {
            availability = .changed
            return
        }
        passage = found
        guard let file = await indexer.openForViewing(source: c.sourceID, relPath: c.relPath) else {
            let state = documents.snapshot.sources.first { $0.id == c.sourceID }?.state
            availability = .unavailable(state)
            return
        }
        // The sheet was closed while the file was being opened: its access is given back at once, not kept for the session.
        guard !closed else {
            await indexer.closeViewing(file)
            return
        }
        openedFile = file
        // A file that a cloud service keeps online only is not opened here (that would download it): the stored passage is shown.
        if await indexer.isNotOnThisMac(file) {
            guard !closed else { return }
            appName = NSWorkspace.shared.urlForApplication(toOpen: file.url).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            availability = .notOnThisMac
            return
        }
        // A file that changed since it was indexed no longer has this passage where it was: the stored one is shown, with a note.
        let current = await indexer.fileIsCurrent(source: c.sourceID, relPath: c.relPath)
        guard !closed else { return }
        appName = NSWorkspace.shared.urlForApplication(toOpen: file.url).map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
        guard current else {
            availability = .changed
            return
        }
        switch found.format {
        case .pdf:
            // Parsed off the main actor and within a limit (a large or crafted PDF must not freeze the window): if it takes too long
            // the stored passage is shown, with the buttons that open the file in its app.
            let url = file.url
            do {
                let opened = try await runWithDeadline(seconds: 8) { OpenedPDF(url: url) }
                guard !closed else { return }
                if let document = opened.document {
                    pdf = document
                    availability = .available
                } else {
                    // Not opened: either the file became a placeholder just now or it changed.
                    availability = await indexer.isNotOnThisMac(file) ? .notOnThisMac : .changed
                }
            } catch {
                availability = .available
            }
        case .image:
            let url = file.url
            let thumbnail = await DocumentImage.loadThumbnail(of: url)
            guard !closed else { return }
            image = thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            availability = .available
        default:
            availability = .available
        }
    }

    /// The file is open here: the buttons that hand it to its app and to Quick Look show. Never for a placeholder of a cloud service:
    /// its app or Quick Look would make the cloud service download it, and Vauta never starts a download (Show in Finder stays).
    var canOpen: Bool { availability != .notOnThisMac && (openedFile != nil || previewOpened) }

    /// The source can't be found or read, and the person can point Vauta to it (a drive that isn't connected comes back by itself).
    var canLocate: Bool {
        if preview != nil { return previewCanLocate }
        guard case .unavailable(let state) = availability, state != .disconnected, let status = sourceStatus else { return false }
        return status.needsLocate
    }

    private var sourceStatus: DocumentSourceStatus? {
        documents?.snapshot.sources.first { $0.id == request.citation.sourceID }
    }

    func locate() {
        locateNote = nil
        if let status = sourceStatus { documents?.locate(status) { [weak self] note in self?.locateNote = note } }
    }

    func close() {
        closed = true
        guard let file = openedFile, let indexer = documents?.indexer else { return }
        openedFile = nil
        Task { await indexer.closeViewing(file) }
    }

    func openInDefaultApp() {
        guard let url = openedFile?.url else { return }
        NSWorkspace.shared.open(url)
    }

    func showInFinder() {
        if let url = openedFile?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else if let c = passage { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: documents?.snapshot.sources.first { $0.id == c.sourceID }?.source.path ?? "/")]) }
    }

    func quickLook() {
        guard let url = openedFile?.url else { return }
        QuickLookController.shared.show(url)
    }

    /// The source can't be reached: there is no file to show in the Finder.
    var isOffline: Bool {
        if case .unavailable = availability { return true }
        return false
    }

    /// The quote to highlight: what the answer quoted, else the start of the passage's own text.
    var quote: String? { quoteIfAny }

    private var quoteIfAny: String? {
        if let q = request.citation.quote, !q.trimmingCharacters(in: .whitespaces).isEmpty { return q }
        return nil
    }
}

/// A PDF opened on a background thread; the document is handed to the main actor once and not used from the thread again.
private struct OpenedPDF: @unchecked Sendable {
    let document: PDFDocument?

    init(url: URL) {
        guard let document = PDFDocument(url: url) else {
            self.document = nil
            return
        }
        // A file with only an owner password opens with the empty user password.
        if document.isLocked { _ = document.unlock(withPassword: "") }
        self.document = document
    }
}

/// QLPreviewPanel for one file.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookController()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}

/// The sheet a citation opens.
struct PassageViewer: View {
    let model: PassageViewerModel
    let done: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch model.availability {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
            case .available:
                content
            case .unavailable(let state):
                notice(unavailableText(state), symbol: unavailableSymbol(state))
                storedText
            case .notOnThisMac:
                notice(String(localized: "This file isn’t on this Mac, so Vauta shows the saved passage", comment: "Passage viewer: the file is only a placeholder of a cloud service (Google Drive, Dropbox, iCloud Drive…); Vauta does not download it and the stored passage is shown instead"), symbol: "icloud.slash")
                storedText
            case .changed:
                notice(String(localized: "This passage has changed in the file", comment: "Passage viewer: the file no longer has the quoted words at that place; the stored passage is shown instead"), symbol: "exclamationmark.triangle")
                storedText
            }
            if let note = model.locateNote { notice(note.text, symbol: "exclamationmark.triangle") }
            buttons
        }
        .padding(20)
        // A PDF gets a tall page view; any other passage is as tall as its text (up to a limit, then it scrolls).
        .frame(width: 720, height: showsPDF ? 560 : nil)
        .task { await model.load() }
        .onDisappear { model.close() }
        .onExitCommand(perform: done)
    }

    /// The sheet is tall for a PDF that is shown (or being opened), short for everything else.
    private var showsPDF: Bool {
        guard model.request.citation.format == .pdf else { return false }
        switch model.availability {
        case .loading, .available: return true
        default: return false
        }
    }

    private var header: some View {
        let citation = model.request.citation
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: icon).foregroundStyle(.secondary).accessibilityHidden(true)
                Text(verbatim: citation.fileName).font(.headline).lineLimit(1).truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
            }
            let place = citation.locator.shortLabel
            if !place.isEmpty {
                Text(verbatim: place).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String { model.request.citation.format.symbol }

    @ViewBuilder private var content: some View {
        if let pdf = model.pdf, let passage = model.passage {
            PDFPassageView(document: pdf, locator: passage.locator, quote: model.quote ?? firstWords(of: passage), ocr: passage.ocr)
                .frame(maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .accessibilityLabel(Text("Page \(passage.locator.pageNumber ?? 1) of the document", comment: "VoiceOver: the PDF view of the passage viewer"))
        } else {
            if let image = model.image {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                    .accessibilityLabel(Text("The image", comment: "VoiceOver: the picture shown in the passage viewer"))
            }
            storedText
        }
    }

    /// The passage as it is stored, with the quote marked.
    private var storedText: some View {
        // As tall as the passage: a short one does not sit above a field of empty grey. A long one scrolls at the limit.
        ViewThatFits(in: .vertical) {
            storedTextBody
            ScrollView { storedTextBody }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
        .frame(maxHeight: showsPDF ? .infinity : Self.maxTextHeight)
    }

    private static let maxTextHeight: CGFloat = 300

    @ViewBuilder private var storedTextBody: some View {
        if let passage = model.passage {
            ProtectedText(Text(highlighted(VautaPrompts.body(of: passage))))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text("Quote: \(model.quote ?? "")", comment: "VoiceOver: the highlighted quote of the passage viewer; the argument is the quoted words"))
                .accessibilityRepresentation { Text(verbatim: VautaPrompts.body(of: passage)) }
        }
    }

    private func notice(_ text: String, symbol: String) -> some View {
        NoticeLabel(Text(verbatim: text), symbol: symbol, tint: .orange)
    }

    private func unavailableText(_ state: DocumentSourceStatus.State?) -> String {
        switch state {
        case .disconnected?: String(localized: "Drive not connected", comment: "Documents pane: the source is on a drive that is not connected; its index is kept")
        case .noPermission?: String(localized: "Vauta no longer has access", comment: "Documents pane: macOS no longer lets Vauta read this source")
        default: String(localized: "Can’t find this file", comment: "Documents pane: the file was moved or deleted")
        }
    }

    private func unavailableSymbol(_ state: DocumentSourceStatus.State?) -> String {
        switch state {
        case .disconnected?: "externaldrive"
        case .noPermission?: "lock"
        default: "questionmark.circle"
        }
    }

    private func firstWords(of passage: DocumentPassage) -> String {
        let body = VautaPrompts.body(of: passage)
        return String(body.prefix(40))
    }

    /// The text with the quote marked like a search match. The quote is found the way verification finds it: letters and digits only,
    /// so a comma the model dropped or a line break inside the quote does not lose the highlight.
    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard let quote = model.quote, let range = QuoteLocator.swiftRange(of: quote, in: text),
              let lower = AttributedString.Index(range.lowerBound, within: out), let upper = AttributedString.Index(range.upperBound, within: out) else { return out }
        out.markMatch(lower..<upper, dark: colorScheme == .dark)
        return out
    }

    private var buttons: some View {
        HStack {
            if model.canOpen {
                Button(model.appName.map { String(localized: "Open in \($0)", comment: "Passage viewer: opens the file in its default app; the argument is the app's name") } ?? String(localized: "Open File", comment: "Passage viewer: opens the file in its default app")) { model.openInDefaultApp() }
                Button("Quick Look") { model.quickLook() }
            }
            if model.canLocate {
                Button("Locate…") { model.locate() }
            } else if !model.isOffline {
                Button("Show in Finder") { model.showInFinder() }
            }
            Spacer()
            Button("Close", action: done).keyboardShortcut(.defaultAction)
        }
    }
}

/// A PDFView that tells when it is in a window with a size, which is when it can scroll to a page and select text.
final class PassagePDFView: PDFView {
    let markOverlay = QuoteMarkOverlay()
    var onReady: ((PassagePDFView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notify()
    }

    override func layout() {
        super.layout()
        notify()
    }

    private func notify() {
        guard window != nil, bounds.width > 1, bounds.height > 1, let ready = onReady else { return }
        onReady = nil
        // After this layout pass has finished.
        DispatchQueue.main.async { ready(self) }
    }
}

/// The quote's marks drawn above its page, as ordinary views: a view hosted in a sheet, or drawn into a bitmap, always shows them (PDFKit's
/// own highlight annotation is drawn by the page renderer, which a view captured offscreen may leave out).
final class QuoteMarkOverlay: NSObject, PDFPageOverlayViewProvider {
    private final class MarkView: NSView {
        var rects: [CGRect] = []
        override var isFlipped: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemYellow.withAlphaComponent(0.45).setFill()
            for rect in rects { rect.fill() }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// The marks of each page, in the page's own coordinates.
    private var marks: [ObjectIdentifier: [CGRect]] = [:]

    func mark(_ rects: [CGRect], on page: PDFPage) { marks[ObjectIdentifier(page)] = rects }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        guard let rects = marks[ObjectIdentifier(page)], !rects.isEmpty else { return nil }
        let overlay = MarkView()
        overlay.rects = rects
        return overlay
    }
}

/// A PDF at the page of a passage, with the quote selected. Done once, after the first layout, and only on that page.
struct PDFPassageView: NSViewRepresentable {
    let document: PDFDocument
    let locator: DocumentLocator
    let quote: String
    /// The passage was read with OCR: the page has no text layer to select in, so it is shown without a selection.
    let ocr: Bool

    func makeNSView(context: Context) -> PassagePDFView {
        let view = PassagePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        let (document, number, quote, ocr) = (document, locator.pageNumber, quote, ocr)
        // The marks are in place before the view first draws; the scroll and the selection wait for the layout.
        let located = number.flatMap { Self.locate(document: document, page: $0, quote: quote, ocr: ocr) }
        if let number, let located, let page = document.page(at: number - 1) {
            view.markOverlay.mark(located.rects, on: page)
            view.pageOverlayViewProvider = view.markOverlay
        }
        view.document = document
        view.onReady = { view in
            guard let number, let page = document.page(at: number - 1) else { return }
            view.go(to: page)
            guard let located else { return }
            view.setCurrentSelection(located.selection, animate: false)
            view.go(to: located.selection.bounds(for: page).insetBy(dx: -40, dy: -90), on: page)
        }
        return view
    }

    /// Goes to the page and marks the quote on it. Only that page's text is searched, once; an OCR page has no text layer, so it is
    /// shown as it is. A quote that is not found leaves the page shown without a selection (the file is checked for changes elsewhere).
    @discardableResult
    static func showPassage(in view: PDFView, document: PDFDocument, page number: Int?, quote: String, ocr: Bool) -> Bool {
        guard let number, let page = document.page(at: number - 1) else { return false }
        view.go(to: page)
        guard let located = locate(document: document, page: number, quote: quote, ocr: ocr) else { return false }
        if let view = view as? PassagePDFView {
            view.markOverlay.mark(located.rects, on: page)
            view.pageOverlayViewProvider = view.markOverlay
            // The page's overlay is made again with the new marks.
            let current = view.document
            view.document = nil
            view.document = current
            view.go(to: page)
        }
        view.setCurrentSelection(located.selection, animate: false)
        // The quote with room around it, so what comes before it is on screen too.
        view.go(to: located.selection.bounds(for: page).insetBy(dx: -40, dy: -90), on: page)
        return true
    }

    /// The lines of the quote on its page, in page coordinates, and the quote's selection; nil for an OCR page (no text layer) or a
    /// quote that is not on the page.
    static func locate(document: PDFDocument, page number: Int, quote: String, ocr: Bool) -> (selection: PDFSelection, rects: [CGRect])? {
        guard !ocr, let page = document.page(at: number - 1), let range = QuoteLocator.range(of: quote, in: page.string ?? ""),
              let selection = page.selection(for: range) else { return nil }
        let rects = selection.selectionsByLine().map { $0.bounds(for: page) }.filter { $0.width > 0 && $0.height > 0 }
        return (selection, rects)
    }

    func updateNSView(_ view: PassagePDFView, context: Context) {}
}
