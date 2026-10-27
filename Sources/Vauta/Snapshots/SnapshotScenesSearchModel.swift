// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

// The optional search model (EmbeddingGemma 2): every state of its Settings card, the About sheet, the Ask label, the sidebar's
// "By meaning" group, the related meetings and documents, and the documents pane's progress line.

extension SnapshotScenes {
    static let searchModelSize = CGSize(width: 1020, height: 980)
    private static let total = SearchModelSpec.pinned.downloadSize

    static func modelStatus(_ state: SearchModelStatus.State, rate: Double? = nil, remaining: Int? = nil, installed: Int = 0,
                                    error: SearchModelError? = nil, cancellable: Bool = false) -> SearchModelStatus {
        var status = SearchModelStatus()
        status.lastError = error
        status.cancellable = cancellable
        status.state = state
        status.bytesPerSecond = rate
        status.secondsRemaining = remaining
        status.installedBytes = installed
        return status
    }

    static var installedBytes: Int { SearchModelSpec.pinned.installedSize }

    /// 1,240 of 5,800 passages (40 of 60 in meetings, 1,200 of 5,740 in documents).
    private static func partialIndex(onBattery: Bool = false, pause: IndexerPolicy.PauseReason? = nil) -> LLMService.SearchIndexStatus {
        var index = LLMService.SearchIndexStatus()
        index.meetings = SemanticRanker.Coverage(covered: 40, total: 60)
        index.documents = SemanticRanker.Coverage(covered: 1_200, total: 5_740)
        index.onBattery = onBattery
        index.pause = pause
        return index
    }

    static func doneIndex() -> LLMService.SearchIndexStatus {
        var index = LLMService.SearchIndexStatus()
        index.meetings = SemanticRanker.Coverage(covered: 60, total: 60)
        index.documents = SemanticRanker.Coverage(covered: 5_740, total: 5_740)
        index.ranking = true
        index.meetingsRanking = true
        index.documentsRanking = true
        return index
    }

    /// Meetings already rank by meaning; the documents still index.
    private static func meetingsFirstIndex() -> LLMService.SearchIndexStatus {
        var index = partialIndex()
        index.meetings = SemanticRanker.Coverage(covered: 60, total: 60)
        index.meetingsRanking = true
        return index
    }

    /// Everything is indexed except three passages the model could not read.
    private static func skippedIndex() -> LLMService.SearchIndexStatus {
        var index = doneIndex()
        index.documents = SemanticRanker.Coverage(covered: 5_740, total: 5_740, skipped: 3)
        return index
    }

    /// Settings → Models on the Apple on-device provider, with the search model in `status`.
    private static func searchModelPane(_ name: String, _ status: SearchModelStatus, index: LLMService.SearchIndexStatus? = nil,
                                        chat: ModelProviderSettings.Chat = .onDevice, choice: ModelProviderSettings.Embeddings = .onDeviceModel,
                                        retired: Bool = false) -> SnapshotScene {
        settingsScene("models-search-\(name)", .models, size: searchModelSize) { recorder, fixture in
            fixture.settings.models.installSnapshotState(recorder, discovered: [], saved: ModelProviderSettings(chat: chat, embeddings: choice))
            fixture.settings.models.physicalMemory = 16 * ModelRecommendation.gibibyte
            recorder.searchModel.installSnapshotState(status, index: index, choice: choice, retiredNotice: retired)
        }
    }

    static var searchModelScenes: [SnapshotScene] {
        let total = total
        return [
            // The card in each state.
            searchModelPane("not-installed", modelStatus(.notInstalled)),
            // Keyword search chosen (the default): the card and its Download button are still there.
            searchModelPane("not-installed-keyword", modelStatus(.notInstalled), choice: .none),
            searchModelPane("downloading", modelStatus(.downloading(received: 312_000_000, total: total, phase: .weights), rate: 9_800_000, remaining: 27)),
            searchModelPane("downloading-start", modelStatus(.downloading(received: 4_000_000, total: total, phase: .tokenizer))),
            searchModelPane("paused-recording", modelStatus(.pausedForRecording(received: 312_000_000, total: total))),
            searchModelPane("partial", modelStatus(.partial(verified: 312_000_000, total: total))),
            searchModelPane("partial-offline", modelStatus(.partial(verified: 312_000_000, total: total), error: .offline)),
            // One of the two files was imported from a file: the card says which one is still needed.
            searchModelPane("imported-weights", modelStatus(.needsFile(missing: .tokenizer), installed: total - SearchModelSpec.pinned.tokenizerSize)),
            searchModelPane("imported-weights-offline", modelStatus(.needsFile(missing: .tokenizer), installed: total - SearchModelSpec.pinned.tokenizerSize, error: .offline)),
            searchModelPane("imported-tokenizer", modelStatus(.needsFile(missing: .weights), installed: SearchModelSpec.pinned.tokenizerSize)),
            searchModelPane("verifying", modelStatus(.verifying)),
            searchModelPane("verifying-import", modelStatus(.verifying, cancellable: true)),
            searchModelPane("preparing", modelStatus(.preparing)),
            searchModelPane("indexing", modelStatus(.ready, installed: installedBytes), index: partialIndex()),
            searchModelPane("indexing-meetings-first", modelStatus(.ready, installed: installedBytes), index: meetingsFirstIndex()),
            searchModelPane("ready-skipped", modelStatus(.ready, installed: installedBytes), index: skippedIndex()),
            searchModelPane("indexing-paused-power", modelStatus(.ready, installed: installedBytes), index: partialIndex(onBattery: true)),
            searchModelPane("indexing-paused-recording", modelStatus(.ready, installed: installedBytes), index: partialIndex(pause: .recording)),
            searchModelPane("ready", modelStatus(.ready, installed: installedBytes), index: doneIndex()),
            searchModelPane("ready-keyword", modelStatus(.ready, installed: installedBytes), index: nil, choice: .none),
            searchModelPane("ready-server-chosen", modelStatus(.ready, installed: installedBytes), index: nil, chat: .server, choice: .server),
            searchModelPane("unsupported", modelStatus(.unsupported(.unsupportedHardware))),
            searchModelPane("unsupported-self-test", modelStatus(.unsupported(.selfTestFailed))),
            searchModelPane("damaged", modelStatus(.damaged, installed: installedBytes)),
            searchModelPane("error-tokenizer", modelStatus(.failed(.tokenizerUnreadable), installed: installedBytes)),
            searchModelPane("error-encoder", modelStatus(.failed(.encoderFailed), installed: installedBytes)),
            searchModelPane("error-io", modelStatus(.failed(.ioError))),
            searchModelPane("migrated-notice", modelStatus(.notInstalled), choice: .none, retired: true),
            searchModelPane("error-mismatch", modelStatus(.failed(.mismatch))),
            searchModelPane("error-host", modelStatus(.failed(.hostNotAllowed))),
            searchModelPane("error-offline", modelStatus(.failed(.offline))),
            searchModelPane("error-disk", modelStatus(.failed(.diskFull(needed: SearchModelSpec.pinned.downloadSize + (256 << 20))))),
            searchModelPane("error-revision-gone", modelStatus(.failed(.revisionGone))),
            searchModelPane("error-import-wrong-file", modelStatus(.failed(.importWrongFile))),

            // The About sheet.
            SnapshotScene(name: "sheet-search-model-about", size: CGSize(width: 440, height: 420), fitHeight: true, isSheet: true) { _ in
                .init(view: AnyView(SearchModelAboutSheet(close: {}).background(Color(nsColor: .windowBackgroundColor))))
            },

            // Ask: how it finds passages.
            askModeScene("ask-mode-meaning", status: modelStatus(.ready, installed: installedBytes), index: doneIndex()),
            askModeScene("ask-mode-indexing", status: modelStatus(.ready, installed: installedBytes), index: partialIndex()),
            askModeScene("ask-mode-meaning-indexing", status: modelStatus(.ready, installed: installedBytes), index: meetingsFirstIndex()),
            askModeScene("ask-mode-keyword", status: modelStatus(.notInstalled), index: nil, choice: .none),
            // Not installed, never offered before: Ask's empty state says the model exists.
            askModeScene("ask-offer", status: modelStatus(.notInstalled), index: nil, choice: .none, empty: true),

            // The sidebar search: keyword results first, then "By meaning".
            meetingsDocumentsScene("sidebar-search-by-meaning", size: CGSize(width: meetingsSize.width, height: 1500), documents: { DocumentsModel(preview: upToDate, defaults: $0.appDefaults) }) { history, fixture in
                history.documentsModel = DocumentsModel(preview: upToDate, defaults: fixture.appDefaults)
                history.query = fixture.content.searchQuery
                try? await Task.sleep(for: .milliseconds(900))
                let passages = samplePassages(fixture.language)
                history.documentHits = [passages[2]]
                // Meeting passages that mean the same but do not contain the word: the best passage of each of the other meetings, the
                // same filter as the app (what the keyword results already show is left out).
                let shown = Set(history.hits.map(\.segment.id))
                var found: [RetrievedPassage] = []
                let word = fixture.content.searchQuery.lowercased()
                for meeting in history.meetings where found.count < 2 {
                    // One segment that does not contain the query word and is not shown above: what a search by meaning adds.
                    let segments = (try? await fixture.world.store.citableSegments(meeting.id)) ?? []
                    if let segment = segments.first(where: { !shown.contains($0.id) && !$0.text.lowercased().contains(word) }) {
                        found.append(RetrievedPassage(meeting: meeting, start: segment.start, end: segment.start, segments: [segment], score: 0.8))
                    }
                }
                history.meaningMeetingHits = found
                // Document passages that do not contain the query word either (the one that does is under Documents).
                history.meaningDocumentHits = [passages[0], passages[1]]
            },

            // A meeting's Summary: related documents found by meaning, and related meetings.
            meetingsDocumentsScene("summary-related-documents-meaning", size: tallMeetingsSize, documents: { DocumentsModel(preview: upToDate, defaults: $0.appDefaults) }, prepare: featured) { history, fixture in
                history.documentsModel = DocumentsModel(preview: upToDate, defaults: fixture.appDefaults)
                history.relatedDocuments = Array(samplePassages(fixture.language).prefix(3))
                history.relatedDocumentsByMeaning = true
                try? await Task.sleep(for: .milliseconds(300))
            },
            meetingsDocumentsScene("summary-related-meetings", size: tallMeetingsSize, documents: { DocumentsModel(preview: upToDate, defaults: $0.appDefaults) }, prepare: featured) { history, fixture in
                history.documentsModel = DocumentsModel(preview: upToDate, defaults: fixture.appDefaults)
                history.relatedMeetings = Array(history.meetings.filter { $0.id != fixture.world.featuredMeetingID }.prefix(3))
                try? await Task.sleep(for: .milliseconds(300))
            },

            // Settings → Documents while the search model still indexes the passages.
            settingsScene("documents-meaning-progress", .documents, size: CGSize(width: 1020, height: 700)) { recorder, fixture in
                recorder.documents = DocumentsModel(preview: upToDate, defaults: fixture.appDefaults)
                recorder.searchModel.installSnapshotState(modelStatus(.ready, installed: installedBytes), index: partialIndex())
            },
        ]
    }

    /// Ask with the answer of the sample question (or the empty state), and the search model in `status`.
    private static func askModeScene(_ name: String, status: SearchModelStatus, index: LLMService.SearchIndexStatus?,
                                     choice: ModelProviderSettings.Embeddings = .onDeviceModel, empty: Bool = false) -> SnapshotScene {
        SnapshotScene(name: name, size: meetingsSize) { fixture in
            let recorder = await fixture.makeRecorder()
            recorder.searchModel.installSnapshotState(status, index: index, choice: choice)
            guard let history = recorder.history else { return .init(view: AnyView(EmptyView())) }
            history.llm = nil
            try? await fixture.world.restoreTranscript()
            await history.reload()
            history.mode = .ask
            if !empty { await prepareAsk(history.ask, fixture) }
            let view = MeetingsWindow(model: history, recorder: recorder, preferences: fixture.preferences, settings: fixture.settings)
            return .init(view: AnyView(view), title: String(localized: "Meetings", comment: "Window title"))
        }
    }
}
#endif
