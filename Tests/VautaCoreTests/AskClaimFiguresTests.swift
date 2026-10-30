// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A claim of Ask is verified when its quote is in the cited segment and its figures are in what holds the quote too, written
/// with digits or in words.
@Suite("Ask: the figures of a claim")
struct AskClaimFiguresTests {
    private func seg(_ id: Int64, _ text: String) -> CitableSegment { CitableSegment(id: id, channel: .others, start: Double(id) * 10, text: text) }

    private func claim(_ text: String, cites: Int64, quote: String) -> String {
        #"{"found": true, "answer": "x", "claims": [{"text": "\#(text)", "citations": [\#(cites)], "quote": "\#(quote)"}]}"#
    }

    @Test func aFigureTheQuotedSegmentDoesNotHoldIsNotVerified() throws {
        let sent = [Int64(1): seg(1, "The budget for the launch is 5.000 euros this quarter")]
        let wrong = try VautaPrompts.verifyAnswer(claim("The launch budget is 50.000 euros", cites: 1, quote: "The budget for the launch is"), sent: sent)
        #expect(!wrong.claims[0].verified && wrong.claims[0].figureMissing && wrong.claims[0].citations == [1], "the quote is there, the figure is not")
        #expect(wrong.isUnverified)
        let right = try VautaPrompts.verifyAnswer(claim("The launch budget is 5,000 euros", cites: 1, quote: "The budget for the launch is"), sent: sent)
        #expect(right.claims[0].verified && !right.claims[0].figureMissing)
    }

    @Test func aFigureSaidInWordsIsInTheSegment() throws {
        let en = [Int64(1): seg(1, "ninety one percent of the youngest age groups said they would do it")]
        let a = try VautaPrompts.verifyAnswer(claim("91 percent of the youngest said they would", cites: 1, quote: "of the youngest age groups said"), sent: en, language: "en")
        #expect(a.claims[0].verified)
        let es = [Int64(2): seg(2, "Que cambie de las 8 de la mañana a las seis para que puedan abrir")]
        let b = try VautaPrompts.verifyAnswer(claim("El horario pasa de las 8 a las 6", cites: 2, quote: "de las 8 de la mañana a las seis"), sent: es, language: "es")
        #expect(b.claims[0].verified)
        // Words count only in the segment's language.
        let c = try VautaPrompts.verifyAnswer(claim("El horario pasa de las 8 a las 6", cites: 2, quote: "de las 8 de la mañana a las seis"), sent: es, language: "en")
        #expect(!c.claims[0].verified && c.claims[0].figureMissing)
        // A segment's own language wins over the answer's.
        let d = try VautaPrompts.verifyAnswer(claim("El horario pasa de las 8 a las 6", cites: 2, quote: "de las 8 de la mañana a las seis"), sent: es,
                                              language: "en", languages: [2: "es"])
        #expect(d.claims[0].verified)
    }

    @Test func citationCodesAndSpeakerLabelsAreNotFigures() throws {
        let sent = [Int64(73): seg(73, "we can make this for twelve Euro and fifty cents")]
        let a = try VautaPrompts.verifyAnswer(claim("Speaker 2 said it in segment S73", cites: 73, quote: "we can make this for twelve Euro"), sent: sent, language: "en")
        #expect(a.claims[0].verified)
        let b = try VautaPrompts.verifyAnswer(claim("It costs 12.50 euros", cites: 73, quote: "we can make this for twelve Euro"), sent: sent, language: "en")
        #expect(!b.claims[0].verified, "12.50 is not looked for in words")
    }

    @Test func aDocumentWithTheFigureStillBacksAClaimItQuotes() throws {
        let doc = DocumentPassage(id: 1, key: "k1", fileID: 1, sourceID: 1, relPath: "a.pdf", fileName: "a.pdf", title: nil, format: .pdf, locator: .page(1),
                                  text: "Plan\nThe budget for the launch is 50.000 euros", ocr: false, score: 1)
        let sent = [Int64(1): seg(1, "The budget for the launch is 5.000 euros this quarter")]
        let reply = #"{"found": true, "answer": "x", "claims": [{"text": "The launch budget is 50.000 euros", "citations": [1, "D1"], "quote": "The budget for the launch is"}]}"#
        let a = try VautaPrompts.verifyAnswer(reply, sent: sent, documents: ["D1": doc])
        #expect(a.claims[0].verified && !a.claims[0].figureMissing, "the document holds the quote and the figure")
        let onlyDoc = #"{"found": true, "answer": "x", "claims": [{"text": "The launch budget is 60.000 euros", "citations": ["D1"], "quote": "The budget for the launch is"}]}"#
        let b = try VautaPrompts.verifyAnswer(onlyDoc, sent: [:], documents: ["D1": doc])
        #expect(!b.claims[0].verified && b.claims[0].figureMissing)
    }
}
