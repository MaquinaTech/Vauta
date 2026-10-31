// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `TranscriptCorrection`: what a correction of a line changed, word by word, and which items written from the old line it reaches.
@Suite("Transcript correction: words, items and quotes")
struct TranscriptCorrectionTests {
    private let english = LanguageProfile(locale: Locale(identifier: "en-US"))
    private let spanish = LanguageProfile(locale: Locale(identifier: "es-ES"))

    private func correction(_ old: String, _ new: String, _ profile: LanguageProfile? = nil) -> TranscriptCorrection {
        TranscriptCorrection(from: old, to: new, profile: profile ?? english)
    }

    @Test func caseAccentsAndPunctuationAreNotAChangeOfWords() {
        #expect(!correction("ana said we ship friday", "Ana said: we ship Friday.").changesWords)
        #expect(!correction("Jose dijo que si", "José dijo que sí", spanish).changesWords)
        #expect(correction("Ana said we ship Friday", "Anna said we ship Friday").changesWords)
    }

    @Test func aCorrectedNameReachesTheItemsThatUseIt() {
        let c = correction("Ana will send the report to the client tomorrow", "Anna will send the report to the client tomorrow")
        #expect(c.touches("Ana sends the report to the client"))
        #expect(!c.touches("The client gets the report tomorrow"), "the words it relies on did not change, and the name is far from them")
    }

    @Test func aCorrectedFigureReachesTheItemThatGivesIt() {
        let c = correction("We need 15 laptops for the new team", "We need 50 laptops for the new team")
        #expect(c.touches("Buy 15 laptops"))
        #expect(!correction("We need 15 laptops for the new team, said Ana", "We need 15 laptops for the new team, said Anna").touches("Buy 15 laptops"),
                "a change far from what it says")
    }

    @Test func aWordAddedNextToWhatTheItemSaysReachesIt() {
        #expect(correction("we will ship on Friday", "we will not ship on Friday").touches("Ship on Friday"))
    }

    @Test func hesitationsAloneReachNothing() {
        let c = correction("we will um ship on Friday", "we will ship on Friday")
        #expect(c.changesWords)
        #expect(!c.touches("Ship on Friday"))
    }

    @Test func anItemInOtherWordsIsReachedByAnyChangeThatCarriesMeaning() {
        let c = correction("vamos a lanzar Kobaltix en marzo", "vamos a lanzar Cobaltix en marzo", spanish)
        #expect(c.touches("Launch the product in March"), "the minutes are in another language: no shared word to go by")
        #expect(!correction("vamos a lanzar Kobaltix en marzo", "eh vamos a lanzar Kobaltix en marzo", spanish).touches("Launch the product in March"),
                "a hesitation added changes no meaning")
    }

    @Test func aQuoteFollowsTheCorrection() {
        let c = correction("I'll send it to Ana tomorrow, okay?", "I'll send it to Anna tomorrow, okay?")
        #expect(c.corrected(quote: "send it to Ana tomorrow") == "send it to Anna tomorrow")
        #expect(c.corrected(quote: "send it to Ana tomorrow, okay?") == "send it to Anna tomorrow, okay?", "with its punctuation")
        #expect(c.corrected(quote: "SEND IT TO ANA") == "send it to Anna", "found word by word")
        #expect(c.corrected(quote: "the budget") == nil, "not in the line")
        #expect(correction("Ana tomorrow", "tomorrow").corrected(quote: "Ana") == nil, "the correction removed it")
    }

    @Test func aSplitCutsTheTranscribedTextAtTheSameWord() throws {
        let original = "so the cubernetes cluster is ready and Ana will deploy"
        let corrected = "so the Kubernetes cluster is ready and Anna will deploy"
        let c = correction(original, corrected)
        let cut = c.oldCut(atNew: try #require(corrected.range(of: " and")).lowerBound)
        #expect(original[..<cut].trimmingCharacters(in: .whitespaces) == "so the cubernetes cluster is ready")
        #expect(original[cut...] == "and Ana will deploy")
        // Cut right after a replaced word: the word it replaced stays on the left.
        let afterName = c.oldCut(atNew: try #require(corrected.range(of: "Anna")).upperBound)
        #expect(original[afterName...] == "will deploy")
    }

    @Test func aVeryLongLineIsStillCompared() {
        let words = (0..<3_000).map { "w\($0)" }
        let old = words.joined(separator: " ")
        var changed = words
        changed[1_500] = "Kobaltix"
        let c = correction(old, changed.joined(separator: " "))
        #expect(c.changesWords)
        #expect(c.oldToNew.compactMap { $0 }.count == 2_999, "the same words at both ends are kept without a table")
    }
}
