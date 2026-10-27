// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// What Settings → Models and Ask say about the search model: the label under the question, when the card shows, the texts of the
/// failures. The model itself is never downloaded here.
@Suite("App: search model card")
@MainActor
struct SearchModelCardTests {
    private func model(_ state: SearchModelStatus.State, index: LLMService.SearchIndexStatus? = nil,
                       choice: ModelProviderSettings.Embeddings = .onDeviceModel) -> SearchModelModel {
        let suite = "vauta.tests.searchcard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SearchModelModel(defaults: defaults)
        var status = SearchModelStatus()
        status.state = state
        model.installSnapshotState(status, index: index, choice: choice)
        return model
    }

    private func index(covered: Int, total: Int, ranking: Bool) -> LLMService.SearchIndexStatus {
        var index = LLMService.SearchIndexStatus()
        index.documents = SemanticRanker.Coverage(covered: covered, total: total)
        index.ranking = ranking
        return index
    }

    @Test func askSaysHowItFindsPassages() {
        #expect(model(.ready, index: index(covered: 10, total: 10, ranking: true)).askMode == .meaning)
        #expect(model(.ready, index: index(covered: 42, total: 100, ranking: false)).askMode == .indexing(percent: 42))
        // Never 100% while something is missing.
        #expect(model(.ready, index: index(covered: 999, total: 1_000, ranking: false)).askMode == .indexing(percent: 99))
        #expect(model(.notInstalled, choice: .none).askMode == .keyword)
        #expect(model(.downloading(received: 1, total: 2, phase: .weights)).askMode == .keyword)
        // A model server's embeddings are not this label's business.
        #expect(model(.ready, choice: .server).askMode == nil)
    }

    @Test func theCardShowsWhenTheModelIsChosenOrSomethingHappensToIt() {
        // Keyword search chosen, the model not installed: the card (and its Download button) is still there, the Mac can run it.
        #expect(model(.notInstalled, choice: .none).showsCard(choice: .none))
        // A Mac that cannot run it only shows the card to someone who chose it.
        #expect(model(.unsupported(.unsupportedHardware), choice: .none).showsCard(choice: .none) == false)
        #expect(model(.unsupported(.unsupportedHardware)).showsCard(choice: .onDeviceModel))
        #expect(model(.notInstalled).showsCard(choice: .onDeviceModel))
        #expect(model(.downloading(received: 1, total: 2, phase: .weights), choice: .none).showsCard(choice: .none))
        #expect(model(.ready, choice: .server).showsCard(choice: .server))
    }

    @Test func theAskLabelFollowsEachCorpusOnItsOwn() {
        var idx = LLMService.SearchIndexStatus()
        idx.meetings = SemanticRanker.Coverage(covered: 60, total: 60)
        idx.documents = SemanticRanker.Coverage(covered: 1_200, total: 5_740)
        idx.meetingsRanking = true
        #expect(model(.ready, index: idx).askMode == .meaningIndexing(.documents, percent: 20))
        idx.meetingsRanking = false
        idx.documentsRanking = true
        idx.meetings = SemanticRanker.Coverage(covered: 40, total: 60)
        idx.documents = SemanticRanker.Coverage(covered: 5_740, total: 5_740)
        #expect(model(.ready, index: idx).askMode == .meaningIndexing(.meetings, percent: 66))
        idx.documentsRanking = false
        idx.documents = SemanticRanker.Coverage(covered: 1_200, total: 5_740)
        #expect(model(.ready, index: idx).askMode == .indexing(percent: 20), "the corpus that is furthest behind")
        // The card says each corpus apart, so meetings are not lost in the count of passages.
        let text = SearchModelText.indexingParts(idx)
        #expect(text.contains("40") && text.contains("60") && text.contains("5,740") || text.contains("5\u{202F}740") || text.contains("5.740") || text.contains("5740"))
    }

    @Test func theOfferIsMadeOnlyBeforeInstallingAndNotToModelServerUsers() {
        #expect(model(.notInstalled, choice: .none).offersDownload)
        #expect(!model(.ready).offersDownload)
        #expect(!model(.notInstalled, choice: .server).offersDownload)
    }

    @Test func documentsShowTheirProgressOnlyWhileIndexing() {
        #expect(model(.ready, index: index(covered: 3, total: 9, ranking: false)).documentsBackfill == SemanticRanker.Coverage(covered: 3, total: 9))
        #expect(model(.ready, index: index(covered: 9, total: 9, ranking: true)).documentsBackfill == nil)
        #expect(model(.notInstalled, index: index(covered: 3, total: 9, ranking: false)).documentsBackfill == nil)
    }

    @Test func everyFailureHasAMessageAndTheRightWayOut() {
        let errors: [SearchModelError] = [.mismatch, .hostNotAllowed, .revisionGone, .offline, .diskFull(needed: 830_000_000), .importWrongFile,
                                          .unexpectedResponse, .ioError, .unsupported, .selfTestFailed, .tokenizerUnreadable, .encoderFailed]
        for error in errors { #expect(!SearchModelText.failure(error).isEmpty) }
        #expect(SearchModelText.offersImport(.revisionGone) && SearchModelText.offersImport(.importWrongFile))
        #expect(!SearchModelText.offersImport(.diskFull(needed: 1)) && SearchModelText.isDiskFull(.diskFull(needed: 1)))
        // The message never carries a file's content: a category and fixed words only.
        #expect(SearchModelText.failure(.importWrongFile).contains(SearchModelText.shortRevision))
    }

    @Test func progressTextNamesSizesAndWaitsForTheTimeLeft() {
        let early = SearchModelText.progress(received: 100_000_000, total: 574_175_806, secondsRemaining: nil)
        let later = SearchModelText.progress(received: 100_000_000, total: 574_175_806, secondsRemaining: 90)
        #expect(later.hasPrefix(early) && later.count > early.count)
        #expect(SearchModelText.downloadSize.hasPrefix("574"))
    }

    @Test func indexingNamesTheReasonItWaits() {
        var waiting = LLMService.SearchIndexStatus()
        #expect(SearchModelText.pauseReason(waiting) == nil)
        waiting.onBattery = true
        #expect(SearchModelText.pauseReason(waiting) != nil)
        waiting.pause = .recording
        #expect(SearchModelText.pauseReason(waiting) != SearchModelText.pauseReason(LLMService.SearchIndexStatus()))
    }

    @Test func aHalfImportedModelNamesTheFileThatIsStillNeeded() {
        let weights = SearchModelText.importedPart(missing: .tokenizer)
        let tokenizer = SearchModelText.importedPart(missing: .weights)
        #expect(weights.contains("tokenizer.json") && weights.contains(SearchModelText.tokenizerSize), "asks for the tokenizer, with the size of downloading just it")
        #expect(tokenizer.contains("model.safetensors") && tokenizer.contains(SearchModelText.weightsSize))
        #expect(SearchModelText.tokenizerSize.hasPrefix("3") && SearchModelText.weightsSize.hasPrefix("54"))
        // Never the words of a download that stopped: nothing was downloaded.
        #expect(!weights.contains("stopped") && !tokenizer.contains("stopped"))
        var status = SearchModelStatus()
        status.state = .needsFile(missing: .tokenizer)
        #expect(status.fraction == nil && !status.isReady)
    }

    @Test func theSidebarLooksByMeaningForTwoWordsOrFourCharacters() {
        #expect(MeetingsModel.isMeaningful("budget") && MeetingsModel.isMeaningful("contrato"))
        #expect(MeetingsModel.isMeaningful("a b") && MeetingsModel.isMeaningful("  presupuesto trimestral "))
        #expect(MeetingsModel.isMeaningful("予算会議"))
        #expect(!MeetingsModel.isMeaningful("bud") && !MeetingsModel.isMeaningful("  ") && !MeetingsModel.isMeaningful(""))
    }

    @Test func indexingIsTwoShortLinesWithoutNestedColons() {
        var idx = LLMService.SearchIndexStatus()
        idx.meetings = SemanticRanker.Coverage(covered: 40, total: 60)
        idx.documents = SemanticRanker.Coverage(covered: 1_200, total: 5_740)
        let title = SearchModelText.indexingTitle, detail = SearchModelText.indexing(idx)
        #expect(!title.contains(":") && title.count < 60)
        #expect(detail.contains("40") && detail.contains("60") && detail.contains("5") && detail.contains("meetings and documents"))
        #expect(detail.filter { $0 == ":" }.count <= 2, "the counts keep their own labels, but there is no “…: Meetings: …” chain")
    }

    @Test func deletingNamesDocumentsToo() {
        #expect(SearchModelText.deleteMessage(choice: .onDeviceModel, freed: 574_000_000).contains("documents"))
    }
}
