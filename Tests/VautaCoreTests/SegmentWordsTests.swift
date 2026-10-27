// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Segment numbers, ranges and TeX markup written into prose are taken out; the sentences around them stay.
@Suite("Minutes and answers: segment words, ranges and markup")
struct SegmentWordsTests {
    @Test func segmentNumbersWrittenAsWordsGoInEveryLanguage() {
        let cases: [(String, String, String)] = [
            ("en", "The board agreed in segment 5143 to keep it.", "The board agreed to keep it."),
            ("en", "It was approved (segments 12 and 14) by everyone.", "It was approved by everyone."),
            ("es", "La junta lo aprobó en el segmento 5143 sin cambios.", "La junta lo aprobó sin cambios."),
            ("es", "Se acordó en los segmentos 12 y 14 mantenerlo.", "Se acordó mantenerlo."),
            ("fr", "Le conseil l’a approuvé dans le segment 40 sans changement.", "Le conseil l’a approuvé sans changement."),
            ("de", "Der Vorstand stimmte im Segment 12 zu.", "Der Vorstand stimmte zu."),
            ("it", "Il consiglio l’ha approvato nel segmento 7 senza modifiche.", "Il consiglio l’ha approvato senza modifiche."),
            ("pt", "A diretoria aprovou no segmento nº 7 sem mudanças.", "A diretoria aprovou sem mudanças."),
            ("ja", "取締役会はセグメント12で承認した。", "取締役会は承認した。"),
            ("ko", "이사회는 세그먼트 12에서 승인했습니다.", "이사회는 승인했습니다."),
            ("zh", "董事会在片段12批准了。", "董事会在批准了。"),
        ]
        for (language, input, expected) in cases {
            let out = AnswerText.dropSegmentWords(input, language: language)
            #expect(out.replacingOccurrences(of: " ", with: "") == expected.replacingOccurrences(of: " ", with: ""), "\(language): \(out)")
        }
    }

    @Test func spelledOutNumbersAreRecognised() {
        #expect(AnswerText.dropSegmentWords("Agreed in segment forty-two today.", language: "en") == "Agreed today.")
        let es = AnswerText.dropSegmentWords("Lo aprobaron en el segmento cinco mil ciento cuarenta y tres ayer.", language: "es")
        #expect(es == "Lo aprobaron ayer.", Comment(rawValue: es))
    }

    @Test func aSegmentWordWithNoNumberStays() {
        for text in ["The segment of customers grew.", "El segmento de clientes creció.", "Wir beobachten das Segment Privatkunden."] {
            #expect(AnswerText.dropSegmentWords(text, language: "en") == text, Comment(rawValue: text))
        }
    }

    @Test func rangesAreTakenOut() {
        let codes: Set<String> = ["S3", "S43", "S5"]
        for text in ["Budget kept (S3 to S43) for now.", "Budget kept (S3–S43) for now.", "Budget kept S3-S43 for now.", "Budget kept (segments 3 to 43) for now.",
                     "Budget kept [S3 - S43] for now."] {
            #expect(AnswerText.clean(text, codes: codes) == "Budget kept for now.", "\(text) → \(AnswerText.clean(text, codes: codes))")
        }
        #expect(AnswerText.clean("Audi (S3 to S9) is fast", codes: ["S5"]) == "Audi (S3 to S9) is fast", "codes that were not sent stay")
    }

    @Test func yearsScalesAndAgeRangesInBracketsStayInTheProse() throws {
        for text in ["Budget for the period (2025-2026) approved", "Rate the demo (1 to 5) by Friday", "Ages (18-25) are the target", "La tarifa (10 a 20) se aprobó",
                     "Le plan (2024 à 2026) est validé", "Phase (3 bis 5) ist geplant"] {
            #expect(AnswerText.clean(text) == text, "\(text) → \(AnswerText.clean(text))")
            #expect(MinutesText.cleanProse(text) == text)
            #expect(AnswerText.clean(text, codes: ["S2025", "S10", "S1", "S18", "S3"]) == text, "even when a year is also a sent segment number")
        }
        let json = #"{"title":"T","summary":"Ages (18-25) are the target. Rate the demo (1 to 5) and the period (2025-2026) (segments 3 to 9).","topics":[],"decisions":[],"tasks":[],"entities":[],"open_questions":[]}"#
        let m = try VautaPrompts.validateMinutes(json, segments: [:], candidates: [], selfEntity: nil)
        #expect(m.summary == "Ages (18-25) are the target. Rate the demo (1 to 5) and the period (2025-2026).", Comment(rawValue: m.summary))
    }

    @Test func aSegmentWordWithoutSomethingThatSaysSoStays() {
        for text in ["Customer segment two grew", "We are targeting segment 18-25 this year.", "The premium segment 5 percent share rose."] {
            #expect(AnswerText.dropSegmentWords(text, language: "en") == text, Comment(rawValue: text))
        }
        #expect(AnswerText.dropSegmentWords("Customer segment 18 grew", language: "en", codes: ["S18"]) == "Customer grew", "a number that was sent is a citation")
        #expect(AnswerText.dropSegmentWords("Lo aprobaron en el segmento cinco ayer.", language: "es") == "Lo aprobaron ayer.")
        // Spelled-out numbers are read in the language of the text, not the transcript's.
        #expect(AnswerText.dropSegmentWords("Es wurde im Segment zwölf entschieden.", language: "de") == "Es wurde entschieden.")
    }

    @Test func marketSegmentPhrasingStaysWhenTheNumberWasNotSent() {
        let codes: Set<String> = ["S5143", "S12"]
        for (language, text) in [("en", "We saw growth in segment 3 of the market."), ("es", "Nos enfocaremos en el segmento dos del mercado."),
                                 ("de", "Wir konzentrieren uns im Segment drei auf Neukunden."), ("en", "Revenue from segment 7 doubled, per the plan."),
                                 ("es", "El crecimiento en el segmento 18 fue notable.")] {
            #expect(AnswerText.dropSegmentWords(text, language: language, codes: codes) == text, Comment(rawValue: text))
        }
        // The same words with a number that was sent are a citation.
        #expect(AnswerText.dropSegmentWords("The board agreed in segment 5143 to keep it.", language: "en", codes: codes) == "The board agreed to keep it.")
        #expect(AnswerText.dropSegmentWords("Se aprobó (segmento 12) ayer.", language: "es", codes: []) == "Se aprobó ayer.", "a bracket still says so")
    }

    @Test func texMarkupIsUnwrappedAndDollarsStay() {
        #expect(AnswerText.clean(#"The cost is $\text{25 Euro}$ per seat."#) == "The cost is 25 Euro per seat.")
        #expect(AnswerText.clean("The cost is $\u{9}ext{25 Euro}$ per seat.") == "The cost is 25 Euro per seat.", "the JSON tab artefact")
        #expect(AnswerText.clean(#"Use $\mathrm{x}$ here"#) == "Use x here")
        #expect(AnswerText.clean("It costs $25 or $5–$10 each.") == "It costs $25 or $5–$10 each.")
        #expect(AnswerText.clean("Between $5 and $10 per seat") == "Between $5 and $10 per seat")
    }

    @Test func theCutSummaryShapeIsCountedInTheTrace() throws {
        let json = #"{"title":"T","summary":"La reunión trató la presencia de términos como ","topics":[],"decisions":[],"tasks":[],"entities":[],"open_questions":[]}"#
        let m = try VautaPrompts.validateMinutes(json, segments: [:], candidates: [], selfEntity: nil)
        #expect(m.counts["summary.unfinished"] == 1)
        let ok = try VautaPrompts.validateMinutes(json.replacingOccurrences(of: "como ", with: "como x."), segments: [:], candidates: [], selfEntity: nil)
        #expect(ok.counts["summary.unfinished"] == nil)
    }
}
