// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A name or term the person put in a transcript correction, offered for the glossary (`addCorrectedTerm`) so the custom
/// vocabulary has it and later meetings get suggestions for it.
@Suite("Storage: names and terms from transcript corrections")
struct CorrectedTermTests {
    private let english = LanguageProfile(locale: Locale(identifier: "en-US"))

    private func terms(_ old: String, _ new: String) -> [String] {
        TranscriptCorrection(from: old, to: new, profile: english).newTerms()
    }

    private func meeting(_ store: MeetingStore, _ texts: [String]) async throws -> (id: Int64, lines: [Int64]) {
        let id = try await store.startMeeting(at: .now, locale: Locale(identifier: "en-US"))
        var lines: [Int64] = []
        for (i, text) in texts.enumerated() {
            let start = Double(i * 10)
            lines.append(try await store.append(Segment(channel: .others, start: start, end: start + 8, text: text, isFinal: true), to: id))
        }
        _ = try await store.endMeeting(id, at: .now + 120)
        return (id, lines)
    }

    @Test func aNewTermIsANameOrATermPutInPlaceOfOtherWords() {
        #expect(terms("we deploy on cubernetes today", "we deploy on Kubernetes today") == ["Kubernetes"], "capitalized inside the sentence")
        #expect(terms("ask the happy team", "ask the API team") == ["API"], "an acronym")
        #expect(terms("the case runs on kates", "the cluster runs on K8s") == ["K8s"], "a digit inside; a common word is no term")
        #expect(terms("the beach is ready", "the speech is ready").isEmpty, "a common word for another")
        #expect(terms("we ship the beta", "we ship a beta").isEmpty, "a function word")
        #expect(terms("we ship it", "we ship it to Kubernetes").isEmpty, "only added, it replaces nothing")
        #expect(terms("send it to bob", "send it to Ana María López").isEmpty, "longer than the vocabulary takes")
    }

    @Test func theOfferHasTheTermsVautaDoesNotKnow() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store, ["we deploy on cubernetes with ana", "The budget is set"])
        try await store.saveGlossary(GlossaryTerm(term: "Grafana"))
        try await store.saveEntity(EntityDraft(kind: .person, name: "Anna"))

        let c = try #require(try await store.correctSegment(m.lines[0], text: "we deploy on Kubernetes with Anna"))
        let offer = try #require(try await store.correctEverywhereOffer(after: c), "no other line has the words, but a term is new")
        #expect(!offer.isElsewhere)
        #expect(offer.newTerms == ["Kubernetes"], "Anna is a person in Context already")
        #expect(offer.adding("Kubernetes") == nil, "nothing left once it is added")

        let known = try #require(try await store.correctSegment(m.lines[1], text: "The Grafana is set"))
        #expect(try await store.correctEverywhereOffer(after: known) == nil, "the glossary has it")
    }

    @Test func correctingEverywhereLeavesTheTermsOffered() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await meeting(store, ["we run cubernetes", "cubernetes is down"])
        let c = try #require(try await store.correctSegment(m.lines[0], text: "we run Kubernetes"))
        let offer = try #require(try await store.correctEverywhereOffer(after: c))
        #expect(offer.isElsewhere && offer.newTerms == ["Kubernetes"])
        let left = try #require(offer.corrected())
        #expect(!left.isElsewhere && left.newTerms == ["Kubernetes"])
        #expect(left.adding("Kubernetes") == nil)
        #expect(offer.adding("Kubernetes")?.isElsewhere == true, "Correct Everywhere stays offered")
    }

    @Test func anAddedTermIsPinnedInTheVocabularyAndUndone() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let added = try #require(try await store.addCorrectedTerm(" Kubernetes "))
        let term = try #require(try await store.glossary().first)
        #expect(term.term == "Kubernetes" && term.pinned)
        #expect(try await store.recognitionVocabulary(attendees: []).contains("Kubernetes"))
        #expect(try await store.addCorrectedTerm("kubernetes") == nil, "the glossary has it already")

        try await store.undoAddCorrectedTerm(added)
        #expect(try await store.glossary().isEmpty)

        let again = try #require(try await store.addCorrectedTerm("Kubernetes"))
        var renamed = try #require(try await store.glossary().first)
        renamed.term = "Kubernetes (K8s)"
        try await store.saveGlossary(renamed)
        try await store.undoAddCorrectedTerm(again)
        #expect(try await store.glossary().map(\.term) == ["Kubernetes (K8s)"], "a term the person changed since stays")
    }
}
