// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite struct KnowledgeRetrievalTests {
    private func search(_ fx: IndexFixture, _ question: String, locale: String? = nil, limit: Int = 5) async throws -> [DocumentPassage] {
        try await fx.index.search(question, limit: limit, locale: locale.map(Locale.init(identifier:)))
    }

    @Test func japaneseChineseAndKoreanPassagesAreFoundByTheWordsOfAQuestion() async throws {
        let fx = try IndexFixture()
        try await fx.add("ja.txt", text: "議事録\n第三四半期の予算が承認されました。合計は千二百万円です。担当者は田中さんです。")
        try await fx.add("zh.txt", text: "会议纪要\n第三季度预算已获批准,总额为一百二十万元。负责人是王伟。")
        try await fx.add("ko.txt", text: "회의록\n3분기 예산이 승인되었습니다. 총액은 천이백만 원입니다. 담당자는 김민수입니다.")
        try await fx.add("en.txt", text: "Minutes\nThe quarterly hiring plan was approved by the board of directors.")
        #expect(try await search(fx, "予算はいつ承認されましたか", locale: "ja").first?.fileName == "ja.txt")
        #expect(try await search(fx, "担当者は誰ですか", locale: "ja").first?.fileName == "ja.txt")
        #expect(try await search(fx, "预算什么时候获批准", locale: "zh").first?.fileName == "zh.txt")
        #expect(try await search(fx, "负责人是谁", locale: "zh").first?.fileName == "zh.txt")
        #expect(try await search(fx, "예산은 언제 승인되었나요", locale: "ko").first?.fileName == "ko.txt")
        #expect(try await search(fx, "담당자가 누구예요", locale: "ko").first?.fileName == "ko.txt")
        #expect(try await search(fx, "hiring plan approved", locale: "en").first?.fileName == "en.txt")
    }

    @Test func aPassageThatNamesAnEntityOfTheQuestionRanksHigher() async throws {
        let fx = try IndexFixture()
        try await fx.add("General.txt", text: "Budget review\nThe budget review budget review covers budget lines and budget owners every quarter.")
        try await fx.add("Ana.txt", text: "Notes\nAna wrote that the review of the budget is late.")
        let plain = try await fx.index.search("budget review", limit: 2, locale: Locale(identifier: "en"))
        #expect(plain.first?.fileName == "General.txt", "without the boost the denser passage comes first")
        let boosted = try await fx.index.search("budget review Ana", limit: 2, locale: Locale(identifier: "en"), entities: [["ana", "ana lopez"]])
        #expect(boosted.first?.fileName == "Ana.txt")
        #expect(boosted.count == 2, "the other passage stays")
    }

    @Test func accentsAndCaseDoNotMatter() async throws {
        let fx = try IndexFixture()
        try await fx.add("es.txt", text: "Acta\nLa reunión de presupuesto aprobó la inversión en formación del equipo.")
        #expect(try await search(fx, "REUNION presupuesto", locale: "es").first?.fileName == "es.txt")
        #expect(try await search(fx, "inversión formación", locale: "es").count == 1)
    }

    @Test func keywordsAloneWorkWithoutAnyEmbeddings() async throws {
        let fx = try IndexFixture()
        try await fx.add("a.txt", text: "Procurement policy\nPurchases above five thousand euros need two approvals from the finance team.")
        try await fx.add("b.txt", text: "Travel policy\nFlights are booked through the travel desk and reimbursed monthly.")
        let hits = try await search(fx, "how many approvals for purchases", locale: "en")
        #expect(hits.map(\.fileName) == ["a.txt"])
        #expect(try await search(fx, "zzzzzz qqqqqq", locale: "en").isEmpty)
    }

    @Test func vectorsFindMeaningWhereNoWordMatches() async throws {
        let fx = try IndexFixture()
        try await fx.add("cats.txt", text: "Felines\nDomestic cats sleep for most of the day.")
        try await fx.add("cars.txt", text: "Engines\nElectric motors deliver torque instantly.")
        let space = EmbeddingSpace(model: "test-embed", dimensions: 4)
        let todo = try await fx.index.passagesNeedingVectors(space: space, limit: 10)
        #expect(todo.count == 2)
        func vector(for text: String) -> [Float] { text.contains("cats") ? [1, 0.1, 0, 0] : [0, 0, 1, 0.1] }
        var items: [(id: Int64, q: Data, scale: Float)] = []
        for (id, text) in todo { let (q, scale) = try #require(VectorIndex.quantize(vector(for: text))); items.append((id, q, scale)) }
        try await fx.index.storeVectors(items, space: space)
        #expect(try await fx.index.passagesNeedingVectors(space: space, limit: 10).isEmpty)
        // "kitten" matches no word, but the question's vector points at the cat passage.
        let hits = try await fx.index.search("kitten", queryVector: [1, 0.05, 0, 0], space: space, limit: 2, locale: Locale(identifier: "en"))
        #expect(hits.first?.fileName == "cats.txt")
        // A vector of another space is never compared.
        let other = EmbeddingSpace(model: "other-model", dimensions: 4)
        #expect(try await fx.index.search("kitten", queryVector: [1, 0.05, 0, 0], space: other, limit: 2, locale: Locale(identifier: "en")).isEmpty)
        // The old space's vectors are dropped when the model changes.
        try await fx.index.dropVectors(notIn: other)
        #expect(try await fx.index.vectorCount() == 0)
        #expect(try await fx.index.passagesNeedingVectors(space: other, limit: 10).count == 2)
    }

    @Test func aPassageKeepsItsVectorWhenAnotherPassageOfTheFileChanges() async throws {
        let fx = try IndexFixture()
        let long = (1...40).map { "Sentence \($0) explains part \($0) of the migration plan in some detail for readers." }.joined(separator: " ")
        let id = try await fx.add("plan.txt", text: long)
        let space = EmbeddingSpace(model: "m", dimensions: 4)
        let first = try await fx.index.passagesNeedingVectors(space: space, limit: 100)
        try await fx.index.storeVectors(first.map { ($0.id, VectorIndex.quantize([1, 0, 0, 0])!.q, VectorIndex.quantize([1, 0, 0, 0])!.scale) }, space: space)
        // Edit the last sentence only: the other passages keep their rows and vectors.
        let edited = long.replacingOccurrences(of: "Sentence 40 explains part 40", with: "Sentence 40 now says something else")
        let drafts = PassageChunker.chunk(ExtractedDocument(units: [DocumentUnit(locator: .section(path: [], block: 1), text: edited)]), fileName: "plan.txt")
        let diff = try await fx.index.replacePassages(fileID: id, with: drafts.map { IndexedPassage(draft: $0, terms: DocumentTerms.terms(for: $0.text)) })
        #expect(diff.kept >= first.count - 2 && diff.added >= 1 && diff.removed >= 1)
        #expect(try await fx.index.passagesNeedingVectors(space: space, limit: 100).count == diff.added)
    }

    @Test func aCitationThatOutlivesARequestResolvesByFileAndKey() async throws {
        let fx = try IndexFixture()
        try await fx.add("a.txt", text: "Title\nThe vendor must provide a security questionnaire.", source: 3)
        let found = try #require(try await search(fx, "security questionnaire").first)
        let again = try await fx.index.passage(source: 3, relPath: "a.txt", key: found.key)
        #expect(again?.id == found.id && again?.text == found.text)
        #expect(try await fx.index.passage(source: 3, relPath: "a.txt", key: "nope") == nil)
    }

    @Test func theSidebarSearchFindsPassagesWithoutAModel() async throws {
        let fx = try IndexFixture()
        try await fx.add("a.txt", text: "Notes\nThe offsite is planned in Lisbon for early June.")
        let hits = try await fx.index.keywordHits("offsite Lisbon")
        #expect(hits.count == 1 && hits[0].text.contains("Lisbon"))
    }
}

@Suite struct DocumentEmbeddingTests {
    private func service(embedder: (any EmbeddingModel)?, network: Bool = false) async throws -> (LLMService, IndexFixture, TestProviders) {
        let f = try KnowledgeFixture()
        let docs = try IndexFixture()
        try await docs.add("a.txt", text: "Felines\nDomestic cats sleep for most of the day and hunt at night.")
        try await docs.add("b.txt", text: "Engines\nElectric motors deliver torque instantly at any speed.")
        let providers = TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }, embedder: embedder)
        providers.onTheNetwork = network
        let service = LLMService(store: f.store, providers: providers)
        await service.setDocuments(docs.index)
        _ = f
        return (service, docs, providers)
    }

    @Test func passagesAreEmbeddedLocallyAndTheNetworkWaitsForTheOptIn() async throws {
        let embedder = FakeEmbedder(space: EmbeddingSpace(model: "e", dimensions: 8))
        let (local, docs, _) = try await service(embedder: embedder)
        #expect(await local.documentEmbeddingRoute() == .local)
        #expect(await local.embedDocumentPassages(allowNetwork: false) == 2)
        #expect(try await docs.index.vectorCount() == 2)
        // Nothing more to do.
        #expect(await local.embedDocumentPassages(allowNetwork: false) == 0)

        let (remote, remoteDocs, _) = try await service(embedder: embedder, network: true)
        #expect(await remote.documentEmbeddingRoute() == .network)
        #expect(await remote.embedDocumentPassages(allowNetwork: false) == 0, "every passage would leave the Mac: not without the person's choice")
        #expect(try await remoteDocs.index.vectorCount() == 0)
        #expect(await remote.embedDocumentPassages(allowNetwork: true) == 2)
        #expect(try await remoteDocs.index.vectorCount() == 2)
    }

    @Test func withoutEmbeddingsNothingIsDone() async throws {
        let (service, docs, _) = try await service(embedder: nil)
        #expect(await service.documentEmbeddingRoute() == .off)
        #expect(await service.embedDocumentPassages(allowNetwork: true) == 0)
        #expect(try await docs.index.vectorCount() == 0)
    }

    @Test func aFailingEmbeddingServerLeavesKeywordSearchWorking() async throws {
        let (service, docs, _) = try await service(embedder: FakeEmbedder(space: EmbeddingSpace(model: "e", dimensions: 8), fails: true))
        #expect(await service.embedDocumentPassages(allowNetwork: false) == 0)
        #expect(try await docs.index.search("cats hunt at night", limit: 3, locale: Locale(identifier: "en")).first?.fileName == "a.txt")
    }

    @Test func theNetworkPurposeIsLoggedAsIndexingYourDocuments() {
        #expect(NetworkPurpose.documents.rawValue == "documents")
        #expect(NetworkPurpose.allCases.contains(.documents))
    }
}
