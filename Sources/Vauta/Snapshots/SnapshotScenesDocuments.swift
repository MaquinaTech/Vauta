// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import AppKit
import CoreText
import PDFKit
import SwiftUI

/// Sample documents in the language being rendered, so every scene of the Documents feature reads as a real answer would.
struct DocumentSample {
    let passage: String
    let quote: String
    let question: String
    let answer: String
    let claim: String

    static func forLanguage(_ language: String) -> DocumentSample {
        switch language {
        case "es":
            DocumentSample(passage: "Los nuevos empleados reciben el portátil el primer día y la tarjeta de acceso el segundo.", quote: "reciben el portátil el primer día",
                           question: "¿Cuándo reciben el portátil los nuevos empleados?", answer: "El primer día.", claim: "Reciben el portátil el primer día.")
        case "fr":
            DocumentSample(passage: "Les nouveaux arrivants reçoivent leur ordinateur le premier jour et leur badge le deuxième.", quote: "reçoivent leur ordinateur le premier jour",
                           question: "Quand les nouveaux arrivants reçoivent-ils leur ordinateur ?", answer: "Le premier jour.", claim: "Ils reçoivent leur ordinateur le premier jour.")
        case "de":
            DocumentSample(passage: "Neue Mitarbeitende erhalten am ersten Tag ihren Laptop und am zweiten Tag ihren Ausweis.", quote: "am ersten Tag ihren Laptop",
                           question: "Wann bekommen neue Mitarbeitende ihren Laptop?", answer: "Am ersten Tag.", claim: "Sie erhalten am ersten Tag ihren Laptop.")
        case "it":
            DocumentSample(passage: "I nuovi assunti ricevono il laptop il primo giorno e il badge il secondo.", quote: "ricevono il laptop il primo giorno",
                           question: "Quando i nuovi assunti ricevono il laptop?", answer: "Il primo giorno.", claim: "Ricevono il laptop il primo giorno.")
        case "pt-BR":
            DocumentSample(passage: "Os novos contratados recebem o notebook no primeiro dia e o crachá no segundo.", quote: "recebem o notebook no primeiro dia",
                           question: "Quando os novos contratados recebem o notebook?", answer: "No primeiro dia.", claim: "Recebem o notebook no primeiro dia.")
        case "ja":
            DocumentSample(passage: "新入社員は初日にノートパソコンを、2日目に入館証を受け取ります。", quote: "初日にノートパソコンを",
                           question: "新入社員はいつノートパソコンを受け取りますか？", answer: "初日です。", claim: "初日にノートパソコンを受け取る。")
        case "ko":
            DocumentSample(passage: "신규 입사자는 첫날 노트북을, 둘째 날 출입증을 받습니다.", quote: "첫날 노트북을",
                           question: "신규 입사자는 언제 노트북을 받나요?", answer: "첫날입니다.", claim: "첫날 노트북을 받는다.")
        case "zh-Hans":
            DocumentSample(passage: "新员工第一天领取笔记本电脑，第二天领取门禁卡。", quote: "第一天领取笔记本电脑",
                           question: "新员工什么时候领取笔记本电脑？", answer: "第一天。", claim: "第一天领取笔记本电脑。")
        default:
            DocumentSample(passage: "New hires get laptop access on day one and badge access on day two.", quote: "laptop access on day one",
                           question: "When do new hires get their laptop?", answer: "On their first day.", claim: "New hires get a laptop on day one.")
        }
    }
}

/// The sentences of the sample documents that mention the beta (the search query of the sample content) and a note about the release,
/// each with the words a citation quotes, in the language being rendered.
struct DocumentExtras {
    let hit: String
    let hitQuote: String
    let notes: String
    let notesQuote: String

    static func forLanguage(_ language: String) -> DocumentExtras {
        switch language {
        case "es":
            DocumentExtras(hit: "La versión beta sale la primera semana de marzo.", hitQuote: "la primera semana de marzo",
                           notes: "La versión beta necesita dos semanas más de pruebas antes del lanzamiento.", notesQuote: "dos semanas más de pruebas")
        case "fr":
            DocumentExtras(hit: "La version bêta sort la première semaine de mars.", hitQuote: "la première semaine de mars",
                           notes: "La version bêta a besoin de deux semaines de tests avant le lancement.", notesQuote: "deux semaines de tests")
        case "de":
            DocumentExtras(hit: "Die Beta erscheint in der ersten Märzwoche.", hitQuote: "in der ersten Märzwoche",
                           notes: "Die Beta braucht vor dem Start noch zwei Wochen Tests.", notesQuote: "noch zwei Wochen Tests")
        case "it":
            DocumentExtras(hit: "La beta esce nella prima settimana di marzo.", hitQuote: "nella prima settimana di marzo",
                           notes: "La beta richiede altre due settimane di test prima del lancio.", notesQuote: "altre due settimane di test")
        case "pt-BR":
            DocumentExtras(hit: "A versão beta sai na primeira semana de março.", hitQuote: "na primeira semana de março",
                           notes: "A versão beta precisa de mais duas semanas de testes antes do lançamento.", notesQuote: "mais duas semanas de testes")
        case "ja":
            DocumentExtras(hit: "ベータ版は3月の第1週にリリース予定です。", hitQuote: "3月の第1週にリリース予定",
                           notes: "ベータ版は公開前にあと2週間のテストが必要です。", notesQuote: "あと2週間のテスト")
        case "ko":
            DocumentExtras(hit: "베타 버전은 3월 첫째 주에 출시됩니다.", hitQuote: "3월 첫째 주에 출시됩니다",
                           notes: "베타 버전은 출시 전에 2주 더 테스트가 필요합니다.", notesQuote: "2주 더 테스트")
        case "zh-Hans":
            DocumentExtras(hit: "测试版计划在三月第一周发布。", hitQuote: "三月第一周发布",
                           notes: "测试版在发布前还需要两周的测试。", notesQuote: "还需要两周的测试")
        default:
            DocumentExtras(hit: "The beta release is planned for the first week of March.", hitQuote: "planned for the first week of March",
                           notes: "The beta needs two more weeks of testing before launch.", notesQuote: "two more weeks of testing")
        }
    }
}

/// Documents: Settings → Documents, Ask over documents, the passage viewer, a meeting's materials, and the dialogs.
@MainActor
extension SnapshotScenes {
    // MARK: Sample state

    private static func source(_ id: Int64, _ name: String, _ path: String, kind: DocumentSource.Kind = .folder, paused: Bool = false) -> DocumentSource {
        DocumentSource(id: id, kind: kind, displayName: name, path: path, paused: paused, addedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(id)))
    }

    private static func counts(files: Int, indexed: Int, skipped: Int = 0, pending: Int = 0, ocr: Int = 0, partial: Int = 0,
                               google: Int = 0, online: Int = 0, folders: Int = 0) -> DocumentSourceCounts {
        var c = DocumentSourceCounts()
        c.files = files; c.indexed = indexed; c.skipped = skipped; c.pending = pending; c.ocrPending = ocr; c.partial = partial
        c.googleShortcuts = google; c.onlineOnly = online; c.onlineOnlyFolders = folders
        return c
    }

    private static var checked: Date { SampleWorld.snapshotNow.addingTimeInterval(-10 * 60) }

    private static var projects: DocumentSource { source(1, "Projects", "/Users/maya/Documents/Projects") }
    private static var handbook: DocumentSource { source(2, "Handbook", "/Users/maya/Documents/Handbook") }
    private static var budget: DocumentSource { source(3, "Budget 2027.xlsx", "/Users/maya/Documents/Finance/Budget 2027.xlsx", kind: .file) }

    private static func snapshot(_ sources: [DocumentSourceStatus], ocr: Bool = true, full: Bool = false) -> DocumentsSnapshot {
        var s = DocumentsSnapshot()
        s.sources = sources
        s.ocrEnabled = ocr
        s.totalFiles = sources.reduce(0) { $0 + $1.counts.indexed }
        // About 38,000 characters (16 pages) of text per indexed file.
        s.totalCharacters = full ? DocumentLimits.maxTotalCharacters : s.totalFiles * 38_000
        s.totalPassages = s.totalFiles * 9
        s.pendingFiles = sources.reduce(0) { $0 + $1.counts.pending }
        s.readableFiles = sources.reduce(0) { $0 + $1.counts.files }
        return s
    }

    static var upToDate: DocumentsSnapshot {
        snapshot([
            DocumentSourceStatus(source: projects, state: .upToDate(checked: checked), counts: counts(files: 412, indexed: 400, skipped: 12)),
            DocumentSourceStatus(source: handbook, state: .upToDate(checked: checked), counts: counts(files: 96, indexed: 96)),
            DocumentSourceStatus(source: budget, state: .upToDate(checked: checked), counts: counts(files: 1, indexed: 1)),
        ])
    }

    private static func documentsSettings(_ name: String, size: CGSize = CGSize(width: 1020, height: 640), _ state: DocumentsSnapshot,
                                          configure: @escaping @MainActor (DocumentsModel, SampleNames) -> Void = { _, _ in }) -> SnapshotScene {
        settingsScene(name, .documents, size: size) { recorder, fixture in
            let model = DocumentsModel(preview: SampleNames.forLanguage(fixture.language).localized(state), defaults: fixture.appDefaults)
            configure(model, SampleNames.forLanguage(fixture.language))
            recorder.documents = model
        }
    }

    // MARK: Sample passages

    static func samplePassages(_ language: String) -> [DocumentPassage] {
        let sample = DocumentSample.forLanguage(language)
        let extras = DocumentExtras.forLanguage(language)
        return [
            DocumentPassage(id: 1, key: "a1", fileID: 1, sourceID: 2, relPath: "Onboarding.pdf", fileName: "Onboarding.pdf", format: .pdf, locator: .page(4),
                            text: "Onboarding\n" + sample.passage, score: 1),
            DocumentPassage(id: 2, key: "a2", fileID: 2, sourceID: 3, relPath: "Budget 2027.xlsx", fileName: "Budget 2027.xlsx", format: .xlsx,
                            locator: .sheet(name: "Q3", firstRow: 12, lastRow: 40),
                            text: "Budget 2027 — Sheet \"Q3\", rows 12–40 — columns: Region | Revenue | Owner\nRegion: North; Revenue: 1.2M; Owner: Ana", score: 0.9),
            DocumentPassage(id: 3, key: "a3", fileID: 3, sourceID: 2, relPath: "Pitch.pptx", fileName: "Pitch.pptx", format: .pptx, locator: .slide(7),
                            text: "Pitch (slide 7)\n" + extras.hit, score: 0.8),
            DocumentPassage(id: 4, key: "a4", fileID: 4, sourceID: 2, relPath: "Notes.md", fileName: "Notes.md", format: .markdown,
                            locator: .section(path: ["Release"], block: 3), text: "Notes › Release\n" + extras.notes, score: 0.7),
        ]
    }

    private static func prepareDocumentAsk(_ history: MeetingsModel, _ fixture: SnapshotFixture, status: DocumentsSnapshot, mixed: Bool, verified: Bool = true,
                                           documentsOnly: Bool = false) async {
        let sample = DocumentSample.forLanguage(fixture.language)
        history.mode = .ask
        history.documentsModel = DocumentsModel(preview: SampleNames.forLanguage(fixture.language).localized(status), defaults: fixture.appDefaults)
        let ask = history.ask
        await prepareAsk(ask, fixture)
        let passages = samplePassages(fixture.language)
        ask.scope = documentsOnly ? .documents : .everywhere
        ask.answeredScope = ask.scope
        // Mixed: the question about the beta that the meeting answers (prepareAsk); documents only: the one about laptops.
        if !mixed {
            ask.question = sample.question
            ask.answeredQuestion = sample.question
        }
        let citation = DocumentCitation(passages[0], quote: sample.quote)
        let extras = DocumentExtras.forLanguage(fixture.language)
        // Documents only: the laptop question and the Onboarding PDF. Meetings and documents: the question about the beta, answered by a
        // meeting and by the pitch deck.
        let documentClaim = mixed
            ? VerifiedAnswer.Claim(id: "claim-doc", text: extras.hit, citations: [], verified: verified, documents: [DocumentCitation(passages[2], quote: extras.hitQuote)])
            : VerifiedAnswer.Claim(id: "claim-doc", text: sample.claim, citations: [], verified: verified, documents: [citation])
        if documentsOnly {
            ask.passages = []
            ask.answer = VerifiedAnswer(answer: sample.answer, claims: [documentClaim])
        } else if mixed, let existing = ask.answer {
            ask.answer = VerifiedAnswer(answer: existing.answer, claims: Array(existing.claims.prefix(1)) + [documentClaim])
        }
        ask.documentPassages = documentsOnly ? passages : [passages[2], passages[3]]
    }

    // MARK: Viewer

    private static func samplePDF(_ sample: DocumentSample) -> PDFDocument? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for page in 1...4 {
            context.beginPDFPage(nil)
            let text = page == 4 ? "Onboarding\n\n" + sample.passage + "\n\n" + sample.passage : "Onboarding · \(page)"
            let attributed = NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 16, nil)])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0),
                                                 CGPath(rect: CGRect(x: 56, y: 56, width: 500, height: 680), transform: nil), nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)
    }

    private static func sampleImage(_ text: String) -> NSImage? {
        let size = CGSize(width: 900, height: 260)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 0.97, green: 0.96, blue: 0.9, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let attributed = NSAttributedString(string: text, attributes: [.font: CTFontCreateWithName("Helvetica-Bold" as CFString, 30, nil), .foregroundColor: NSColor.black])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed), CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 30, y: 30, width: size.width - 60, height: size.height - 60), transform: nil), nil)
        CTFrameDraw(frame, context)
        return context.makeImage().map { NSImage(cgImage: $0, size: size) }
    }

    private static func viewer(_ name: String, passage index: Int = 0, availability: PassageViewerModel.Availability = .available, quote: Bool = true,
                               pdf: Bool = false, image: Bool = false, appName: String? = nil, canLocate: Bool = false) -> SnapshotScene {
        SnapshotScene(name: name, size: CGSize(width: 720, height: 560), fitHeight: !pdf, isSheet: true) { fixture in
            let sample = DocumentSample.forLanguage(fixture.language)
            var passage = samplePassages(fixture.language)[index]
            if image {
                passage = DocumentPassage(id: 9, key: "i", fileID: 9, sourceID: 2, relPath: "Whiteboard.png", fileName: "Whiteboard.png", format: .image, locator: .image,
                                          text: "Whiteboard\n" + sample.passage, ocr: true)
            }
            let extras = DocumentExtras.forLanguage(fixture.language)
            let q = quote ? (index == 0 || image ? sample.quote : (index == 1 ? "Revenue: 1.2M" : (index == 2 ? extras.hitQuote : extras.notesQuote))) : nil
            let request = PassageViewerRequest(citation: DocumentCitation(passage, quote: q))
            let model = PassageViewerModel(preview: passage, availability: availability, request: request, pdf: pdf ? samplePDF(sample) : nil,
                                           image: image ? sampleImage(sample.passage) : nil, appName: appName,
                                           opened: (availability == .available || availability == .notOnThisMac) && appName != nil, canLocate: canLocate)
            return .init(view: AnyView(PassageViewer(model: model, done: {}).background(Color(nsColor: .windowBackgroundColor))))
        }
    }

    /// The Meetings window tall enough to show the whole Summary down to Materials (they sit under the minutes).
    static var tallMeetingsSize: CGSize { CGSize(width: meetingsSize.width, height: 1700) }

    // MARK: Scenes

    static var documentScenes: [SnapshotScene] {
        let everyReason: [DocumentSkipReason] = [.unsupported, .exportAsPDF, .passwordProtected, .tooLarge, .noText, .unreadable, .timedOut, .crashed,
                                                 .iCloudNotDownloaded, .cloudNotDownloaded, .googleDriveShortcut, .tooManyFiles, .partial]
        return [
            documentsSettings("documents-empty", snapshot([])),
            // A folder marked as holding notes exported from Notes: its passages are labelled "Note" in the brief.
            documentsSettings("documents-notes-export", snapshot([
                DocumentSourceStatus(source: projects, state: .upToDate(checked: checked), counts: counts(files: 412, indexed: 400, skipped: 12)),
                DocumentSourceStatus(source: DocumentSource(id: 4, kind: .folder, displayName: "Notes export", path: "/Users/maya/Documents/Notes export",
                                                            addedAt: Date(timeIntervalSince1970: 1_790_000_004), isNotesExport: true),
                                     state: .upToDate(checked: checked), counts: counts(files: 38, indexed: 38)),
            ])),
            documentsSettings("documents-drop-highlight", snapshot([]), configure: { model, _ in model.dropTargeted = true }),
            documentsSettings("documents-indexing", snapshot([
                DocumentSourceStatus(source: projects, state: .indexing(done: 120, total: 412), counts: counts(files: 412, indexed: 120, pending: 292)),
                DocumentSourceStatus(source: handbook, state: .waiting, counts: counts(files: 96, indexed: 0, pending: 96)),
            ])),
            documentsSettings("documents-ocr", snapshot([
                DocumentSourceStatus(source: projects, state: .readingImages(left: 14), counts: counts(files: 412, indexed: 398, skipped: 0, ocr: 14)),
            ])),
            documentsSettings("documents-up-to-date", upToDate),
            // Files the Mac does not hold: Google Drive shortcuts and files a cloud service keeps online only, with what to do.
            documentsSettings("documents-cloud-files", size: CGSize(width: 1020, height: 900), snapshot([
                DocumentSourceStatus(source: projects, state: .upToDate(checked: checked), counts: counts(files: 412, indexed: 387, skipped: 25, google: 6, online: 15)),
                DocumentSourceStatus(source: handbook, state: .upToDate(checked: checked), counts: counts(files: 96, indexed: 96)),
            ])),
            documentsSettings("documents-cloud-files-online-only", size: CGSize(width: 1020, height: 760), snapshot([
                DocumentSourceStatus(source: projects, state: .upToDate(checked: checked), counts: counts(files: 40, indexed: 28, skipped: 12, online: 12)),
            ])),
            // Whole folders that are placeholders, with files that are not downloaded and a Google Drive shortcut.
            documentsSettings("documents-cloud-files-folders", size: CGSize(width: 1020, height: 760), snapshot([
                DocumentSourceStatus(source: projects, state: .upToDate(checked: checked), counts: counts(files: 40, indexed: 28, skipped: 14, google: 1, online: 11, folders: 2)),
            ])),
            documentsSettings("documents-cloud-files-folders-only", size: CGSize(width: 1020, height: 760), snapshot([
                DocumentSourceStatus(source: projects, state: .upToDate(checked: checked), counts: counts(files: 40, indexed: 40, skipped: 2, folders: 2)),
            ])),
            documentsSettings("documents-cloud-files-google-only", size: CGSize(width: 1020, height: 760), snapshot([
                DocumentSourceStatus(source: projects, state: .upToDate(checked: checked), counts: counts(files: 40, indexed: 39, skipped: 1, google: 1)),
            ])),
            documentsSettings("documents-problems", size: CGSize(width: 1020, height: 1180), snapshot([
                DocumentSourceStatus(source: source(1, "Projects", "/Users/maya/Documents/Projects"), state: .notFound, counts: counts(files: 412, indexed: 400, skipped: 12)),
                DocumentSourceStatus(source: source(2, "Photos Archive", "/Volumes/Backup Drive/Photos Archive"), state: .disconnected, counts: counts(files: 2210, indexed: 2210)),
                DocumentSourceStatus(source: source(3, "Contract.pdf", "/Users/maya/Downloads/Contract.pdf", kind: .file), state: .noPermission, counts: counts(files: 1, indexed: 1)),
                DocumentSourceStatus(source: source(4, "Archive", "/Users/maya/Documents/Archive"), state: .indexFull, counts: counts(files: 5400, indexed: 4900, skipped: 500)),
                DocumentSourceStatus(source: source(5, "Notes", "/Users/maya/Documents/Notes"), state: .pausedForPower(.lowPower), counts: counts(files: 80, indexed: 30, pending: 50)),
                DocumentSourceStatus(source: source(6, "Reports", "/Users/maya/Documents/Reports", paused: true), state: .paused, counts: counts(files: 12, indexed: 12)),
            ], full: true)),
            // The row's menu with every item (a source that has skipped files and can't be found), beside its row: a menu that is open
            // can't be drawn offscreen, so its items are laid out as the menu shows them.
            SnapshotScene(name: "settings-documents-row-menu", size: CGSize(width: 640, height: 330), fitHeight: true, isSheet: true) { fixture in
                let named = SampleNames.forLanguage(fixture.language).localized(snapshot([DocumentSourceStatus(source: projects, state: .notFound, counts: counts(files: 412, indexed: 400, skipped: 12))]))
                let status = named.sources[0]
                let model = DocumentsModel(preview: named, defaults: fixture.appDefaults)
                return .init(view: AnyView(VStack(alignment: .leading, spacing: 8) {
                    DocumentSourceRow(status: status, model: model)
                    VStack(alignment: .leading, spacing: 2) {
                        DocumentSourceMenuItems(status: status, model: model)
                            .buttonStyle(.plain)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                    }
                    .padding(.vertical, 6)
                    .frame(width: 260, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                    .padding(.leading, 44)
                }
                .padding(20)
                .background(Color(nsColor: .windowBackgroundColor))))
            },
            // Several items added at once: every one says what became of it.
            documentsSettings("documents-add-results", size: CGSize(width: 1020, height: 760), upToDate, configure: { model, names in
                model.notes = [.added(names.name("Projects")), .alreadyIncluded(names.name("Handbook")), .ownData, .failed]
            }),
            documentsSettings("documents-network-embeddings", size: CGSize(width: 1020, height: 820), upToDate, configure: { model, _ in model.embeddingsOnNetwork = true }),
            documentsSettings("documents-long-names", size: CGSize(width: 1020, height: 520), snapshot([
                DocumentSourceStatus(source: source(1, "Long", "/Users/maya/Documents/Collaboration/Long"),
                                     state: .indexing(done: 31, total: 140), counts: counts(files: 140, indexed: 31, skipped: 2, pending: 107)),
            ])),
            // The Remove… confirmation, drawn by AppKit's own alert.
            SnapshotScene(name: "settings-documents-remove-confirm", size: CGSize(width: 260, height: 160), isSheet: true) { fixture in
                .init(view: AnyView(EmptyView()),
                      alert: SnapshotAlert(title: DocumentsModel.removeTitle(SampleNames.forLanguage(fixture.language).name("Projects")), message: DocumentsModel.removeMessage(.folder),
                                           buttons: [.init(title: DocumentsModel.removeLabel, destructive: true), .init(title: String(localized: "Cancel", comment: "Alert button"))],
                                           defaultIndex: 1))
            },
            // The help behind the "?" of the line under a source that has files the Mac does not hold.
            SnapshotScene(name: "settings-documents-cloud-help", size: CGSize(width: 520, height: 520), fitHeight: true, isSheet: true) { fixture in
                .init(view: AnyView(CloudFilesHelpSheet(googleShortcuts: 6, onlineOnly: 15, sourceName: SampleNames.forLanguage(fixture.language).name("Projects"), close: {}).background(Color(nsColor: .windowBackgroundColor))))
            },
            SnapshotScene(name: "settings-documents-cloud-help-folders", size: CGSize(width: 520, height: 600), fitHeight: true, isSheet: true) { fixture in
                .init(view: AnyView(CloudFilesHelpSheet(googleShortcuts: 1, onlineOnly: 11, folders: 2, sourceName: SampleNames.forLanguage(fixture.language).name("Projects"), close: {}).background(Color(nsColor: .windowBackgroundColor))))
            },
            SnapshotScene(name: "settings-documents-cloud-help-google-only", size: CGSize(width: 520, height: 400), fitHeight: true, isSheet: true) { fixture in
                .init(view: AnyView(CloudFilesHelpSheet(googleShortcuts: 1, onlineOnly: 0, sourceName: SampleNames.forLanguage(fixture.language).name("Projects"), close: {}).background(Color(nsColor: .windowBackgroundColor))))
            },
            SnapshotScene(name: "settings-documents-skipped-sheet", size: CGSize(width: 760, height: 1_600), fitHeight: true, isSheet: true) { fixture in
                let names = SampleNames.forLanguage(fixture.language)
                // Fifteen files skipped, as many as the sheet lists (the two folders kept online are counted apart).
                let status = names.localized(snapshot([DocumentSourceStatus(source: projects, state: .upToDate(checked: checked), counts: counts(files: 415, indexed: 400, skipped: 15, folders: 1))])).sources[0]
                let archive = names.name("Archive")
                var files = everyReason.enumerated().map { i, reason in
                    DocumentsModel.SkippedEntry(id: Int64(i), name: names.skipped(i),
                                                folder: i % 2 == 0 ? archive + "/2024" : "", reason: reason, size: reason == .tooLarge ? 214_000_000 : reason == .googleDriveShortcut ? 212 : Int64(120_000 * (i + 1) * (i + 1)),
                                                format: [.text, .text, .pdf, .pdf, .image, .docx, .xlsx, .pdf, .docx, .docx, .text, .text, .pdf][i])
                }
                // "Too large" names the limit of the kind of file: 50 MB for a Word file, 30 MB for a picture.
                files.append(DocumentsModel.SkippedEntry(id: 20, name: names.skipped(13), folder: archive, reason: .tooLarge, size: 61_000_000, format: .docx))
                // A folder that a cloud service keeps online only (stored as "Folder/"): a folder row with no size.
                files.insert(DocumentsModel.SkippedEntry(id: 22, name: names.skipped(14), folder: archive, reason: .cloudNotDownloaded, size: 0, format: .text, isFolder: true), at: 10)
                files.append(DocumentsModel.SkippedEntry(id: 21, name: names.skipped(15), folder: "", reason: .tooLarge, size: 38_000_000, format: .image))
                let list = DocumentsModel.SkippedList(source: status, files: files)
                // Tall enough for every row: the real list scrolls beyond 720 pt.
                return .init(view: AnyView(SkippedFilesSheet(list: list, close: {}, listMaxHeight: 1_400).background(Color(nsColor: .windowBackgroundColor))))
            },

            // Ask.
            meetingsAfterScene("ask-scope-everywhere-mixed", prefix: "") { history, fixture in
                await prepareDocumentAsk(history, fixture, status: upToDate, mixed: true)
            } apply: { _, _ in },
            meetingsAfterScene("ask-documents-only", prefix: "") { history, fixture in
                await prepareDocumentAsk(history, fixture, status: upToDate, mixed: false, documentsOnly: true)
            } apply: { _, _ in },
            // A meeting is selected while Ask looks only in the documents: no meeting picker (it would not apply), the scope control is under the field.
            meetingsAfterScene("ask-documents-meeting-selected", prefix: "") { history, fixture in
                await prepareDocumentAsk(history, fixture, status: upToDate, mixed: false, documentsOnly: true)
                history.selectedID = fixture.world.featuredMeetingID
            } apply: { _, _ in },
            // A meeting is selected and Ask looks everywhere: both controls show, each in its own row.
            meetingsAfterScene("ask-scope-meeting-selected", prefix: "") { history, fixture in
                await prepareDocumentAsk(history, fixture, status: upToDate, mixed: true)
                history.selectedID = fixture.world.featuredMeetingID
            } apply: { _, _ in },
            // The scope was changed after the answer: the title and footer still describe the answer on screen.
            meetingsAfterScene("ask-scope-changed-after-answer", prefix: "") { history, fixture in
                await prepareDocumentAsk(history, fixture, status: upToDate, mixed: true)
                history.ask.scope = .documents
            } apply: { _, _ in },
            meetingsAfterScene("ask-document-unverified", prefix: "") { history, fixture in
                await prepareDocumentAsk(history, fixture, status: upToDate, mixed: false, verified: false, documentsOnly: true)
            } apply: { _, _ in },
            meetingsAfterScene("ask-indexing-note", prefix: "") { history, fixture in
                let status = snapshot([DocumentSourceStatus(source: projects, state: .indexing(done: 120, total: 412), counts: counts(files: 412, indexed: 120, pending: 292))])
                history.mode = .ask
                history.documentsModel = DocumentsModel(preview: SampleNames.forLanguage(fixture.language).localized(status), defaults: fixture.appDefaults)
            } apply: { _, _ in },
            meetingsAfterScene("ask-no-sources-hint", prefix: "") { history, fixture in
                history.mode = .ask
                history.documentsModel = DocumentsModel(preview: snapshot([]), defaults: fixture.appDefaults)
            } apply: { _, _ in },
            meetingsAfterScene("ask-not-found-documents", prefix: "") { history, fixture in
                let sample = DocumentSample.forLanguage(fixture.language)
                history.mode = .ask
                history.documentsModel = DocumentsModel(preview: upToDate, defaults: fixture.appDefaults)
                history.ask.scope = .documents
                history.ask.answeredScope = .documents
                history.ask.question = sample.question
                history.ask.answeredQuestion = sample.question
                history.ask.answer = VerifiedAnswer(answer: String(localized: "I can’t find that in your documents.", comment: "Ask answer when no document passage matches"), claims: [])
            } apply: { _, _ in },
            meetingsAfterScene("ask-passages-list-documents", prefix: "") { history, fixture in
                let sample = DocumentSample.forLanguage(fixture.language)
                history.mode = .ask
                history.documentsModel = DocumentsModel(preview: upToDate, defaults: fixture.appDefaults)
                history.ask.scope = .documents
                history.ask.answeredScope = .documents
                history.ask.question = sample.question
                history.ask.answeredQuestion = sample.question
                history.ask.needsModel = true
                history.ask.documentPassages = samplePassages(fixture.language)
            } apply: { _, _ in },

            // The passage viewer.
            viewer("viewer-pdf-highlight", pdf: true, appName: "Preview"),
            viewer("viewer-text-passage", passage: 3, appName: "TextEdit"),
            viewer("viewer-spreadsheet-passage", passage: 1, appName: "Numbers"),
            viewer("viewer-image-ocr", image: true, appName: "Preview"),
            viewer("viewer-changed", availability: .changed),
            viewer("viewer-not-on-this-mac", passage: 3, availability: .notOnThisMac, appName: "TextEdit"),
            viewer("viewer-offline", availability: .unavailable(.disconnected)),
            viewer("viewer-not-found", availability: .unavailable(.notFound), canLocate: true),

            // A meeting's materials and related documents, and the search.
            meetingsDocumentsScene("summary-materials", size: tallMeetingsSize, documents: { DocumentsModel(preview: upToDate, defaults: $0.appDefaults) }, prepare: featured) { history, fixture in
                history.documentsModel = DocumentsModel(preview: upToDate, defaults: fixture.appDefaults)
                history.materials = [MeetingMaterial(origin: .attached(sourceID: 3), name: "Budget 2027.xlsx"), MeetingMaterial(origin: .linked(sourceID: 2, relPath: "Hiring/Onboarding.pdf"), name: "Onboarding.pdf")]
                history.materialStates = ["a3": .ready, "l2:Hiring/Onboarding.pdf": .ready]
                try? await Task.sleep(for: .milliseconds(300))
            },
            // Materials Ask cannot use (yet): each row says why, and a file that cannot be attached says so right there.
            meetingsDocumentsScene("summary-materials-problems", size: tallMeetingsSize, documents: { DocumentsModel(preview: upToDate, defaults: $0.appDefaults) }, prepare: featured) { history, fixture in
                history.documentsModel = DocumentsModel(preview: upToDate, defaults: fixture.appDefaults)
                history.materials = [
                    MeetingMaterial(origin: .attached(sourceID: 3), name: "Budget 2027.xlsx"),
                    MeetingMaterial(origin: .attached(sourceID: 4), name: "Contract.pdf"),
                    MeetingMaterial(origin: .attached(sourceID: 5), name: "Site survey.pdf"),
                    MeetingMaterial(origin: .attached(sourceID: 6), name: "Specs.docx"),
                    MeetingMaterial(origin: .attached(sourceID: 7), name: "Vendor quotes.xlsx"),
                    MeetingMaterial(origin: .attached(sourceID: 8), name: "Whiteboard.png"),
                    MeetingMaterial(origin: .linked(sourceID: 2, relPath: "Hiring/Onboarding.pdf"), name: "Onboarding.pdf"),
                ]
                history.materialStates = [
                    "a3": .ready, "a4": .skipped(.passwordProtected, .pdf), "a5": .skipped(.tooLarge, .pdf), "a6": .indexing,
                    "a7": .unavailable(.disconnected), "a8": .readingImages(left: 3), "l2:Hiring/Onboarding.pdf": .partial,
                ]
                history.materialsNotes = [.unsupported]
                try? await Task.sleep(for: .milliseconds(300))
            },
            meetingsDocumentsScene("summary-materials-waiting", size: tallMeetingsSize, documents: { DocumentsModel(preview: upToDate, defaults: $0.appDefaults) }, prepare: featured) { history, fixture in
                history.documentsModel = DocumentsModel(preview: upToDate, defaults: fixture.appDefaults)
                history.materials = [MeetingMaterial(origin: .attached(sourceID: 3), name: "Budget 2027.xlsx")]
                history.materialStates = ["a3": .waiting]
                history.materialsNotes = [.failed]
                try? await Task.sleep(for: .milliseconds(300))
            },
            meetingsDocumentsScene("summary-materials-drop", size: tallMeetingsSize, documents: { DocumentsModel(preview: upToDate, defaults: $0.appDefaults) }, prepare: featured) { history, fixture in
                history.documentsModel = DocumentsModel(preview: upToDate, defaults: fixture.appDefaults)
                history.materials = []
                history.materialsDropTargeted = true
                try? await Task.sleep(for: .milliseconds(300))
            },
            meetingsDocumentsScene("summary-related-documents", size: tallMeetingsSize, documents: { DocumentsModel(preview: upToDate, defaults: $0.appDefaults) }, prepare: featured) { history, fixture in
                history.documentsModel = DocumentsModel(preview: upToDate, defaults: fixture.appDefaults)
                history.relatedDocuments = Array(samplePassages(fixture.language).prefix(3))
                try? await Task.sleep(for: .milliseconds(300))
            },
            meetingsDocumentsScene("search-documents-group", documents: { DocumentsModel(preview: upToDate, defaults: $0.appDefaults) }) { history, fixture in
                history.documentsModel = DocumentsModel(preview: upToDate, defaults: fixture.appDefaults)
                history.query = fixture.content.searchQuery
                try? await Task.sleep(for: .milliseconds(900))
                // Passages that contain the query, so the rows show what matched (the group sits above the transcripts).
                let query = fixture.content.searchQuery
                // Only the passages that really contain the query (the sample sentences about the beta).
                let passages = samplePassages(fixture.language)
                history.documentHits = [passages[2], passages[3]]
            },

            // The two dialogs that mention documents.
            SnapshotScene(name: "erase-confirm-documents", size: CGSize(width: 440, height: 300), fitHeight: true, isSheet: true) { fixture in
                let recorder = await fixture.makeRecorder()
                fixture.settings.eraseMeetings = 12
                fixture.settings.eraseDocumentSources = 3
                return .init(view: AnyView(EraseEverythingSheet(recorder: recorder, model: fixture.settings, isPresented: .constant(true))
                    .background(Color(nsColor: .windowBackgroundColor))))
            },
            SnapshotScene(name: "restore-documents-note", size: CGSize(width: 440, height: 300), fitHeight: true, isSheet: true) { fixture in
                let recorder = await fixture.makeRecorder()
                let model = BackupModel()
                model.installSnapshotFile(restoring: URL(fileURLWithPath: "/Users/maya/Documents/" + BackupModel.defaultFileName(day: "2026-10-08")),
                                          date: Date(timeIntervalSince1970: 1_791_450_000))
                model.installSnapshotBackupDocumentSources(3)
                model.stage = .confirm(current: 12, backup: 48)
                return .init(view: AnyView(RestoreSheet(recorder: recorder, model: model).background(Color(nsColor: .windowBackgroundColor))))
            },
            // A backup without document sources, restored on a Mac that has some: they are removed, and the sheet says so first.
            SnapshotScene(name: "restore-documents-removed", size: CGSize(width: 440, height: 300), fitHeight: true, isSheet: true) { fixture in
                let recorder = await fixture.makeRecorder()
                let model = BackupModel()
                model.installSnapshotFile(restoring: URL(fileURLWithPath: "/Users/maya/Documents/" + BackupModel.defaultFileName(day: "2026-10-08")),
                                          date: Date(timeIntervalSince1970: 1_791_450_000))
                model.installSnapshotCurrentDocumentSources(3)
                model.stage = .confirm(current: 12, backup: 48)
                return .init(view: AnyView(RestoreSheet(recorder: recorder, model: model).background(Color(nsColor: .windowBackgroundColor))))
            },
        ]
    }
}
#endif
