// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Where a quote really is: filler words, the nearest occurrence, the visible window, other languages and short phrases.
@Suite("Quote anchor: fillers, nearest occurrence, language")
struct QuoteAnchorTests {
    static func seg(_ id: Int64, _ start: Double, _ text: String) -> CitableSegment {
        CitableSegment(id: id, channel: .others, start: start, text: text)
    }

    @Test func fillersAreIgnoredOnBothSides() {
        let a = Self.seg(1, 0, "uh we should um ship it on Friday")
        #expect(QuoteAnchor.resolve(quote: "we should ship it on Friday", cited: 1, citedText: a.text, pool: nil, language: "en")?.how == .modulo)
        let b = Self.seg(2, 0, "we should ship it on Friday")
        #expect(QuoteAnchor.resolve(quote: "uh we should um ship it on Friday", cited: 2, citedText: b.text, pool: nil, language: "en")?.how == .modulo)
        #expect(QuoteAnchor.resolve(quote: "we should ummm ship it on Friday", cited: 2, citedText: b.text, pool: nil, language: "en")?.how == .modulo)
    }

    @Test func oneFillerCasePerLanguage() {
        let cases: [(String, String, String)] = [
            ("es", "eh vamos a aprobar el presupuesto hoy", "vamos a aprobar el presupuesto hoy"),
            ("fr", "euh on va approuver le budget aujourd'hui", "on va approuver le budget aujourd'hui"),
            ("de", "äh wir genehmigen das Budget heute noch", "wir genehmigen das Budget heute noch"),
            ("it", "ehm approviamo il budget oggi stesso", "approviamo il budget oggi stesso"),
            ("pt", "ahn vamos aprovar o orçamento hoje mesmo", "vamos aprovar o orçamento hoje mesmo"),
            ("ja", "えーと 予算を今日承認します", "予算を今日承認します"),
            ("ko", "음 오늘 예산을 승인하겠습니다 여러분", "오늘 예산을 승인하겠습니다 여러분"),
            ("zh", "嗯 我们今天批准预算吧", "我们今天批准预算吧"),
        ]
        for (lang, text, quote) in cases {
            let m = QuoteAnchor.resolve(quote: quote, cited: 1, citedText: text, pool: nil, language: lang)
            #expect(m?.segment == 1, "\(lang): \(String(describing: m))")
            let reverse = QuoteAnchor.resolve(quote: text, cited: 1, citedText: quote, pool: nil, language: lang)
            #expect(reverse?.segment == 1, "\(lang) reverse")
        }
    }

    @Test func wordsThatAreNotUnambiguousFillersAreKept() {
        // "este" (es), "é" (pt), "那个" (zh), "그" (ko) are words; "um" is Portuguese for "a"; "er" is German for "he".
        #expect(QuoteKey.make("este es el plan de este año", language: "es") == ["este", "es", "el", "plan", "de", "este", "ano"])
        #expect(QuoteKey.make("ele é um bom plano", language: "pt").contains("é".folding(options: .diacriticInsensitive, locale: nil)))
        #expect(QuoteKey.make("ele é um bom plano", language: "pt").contains("um"))
        #expect(QuoteKey.make("er sagte ja", language: "de").contains("er"))
        #expect(QuoteKey.make("那个计划很好", language: "zh").contains("那"))
        #expect(QuoteKey.make("그 계획은 좋습니다", language: "ko").contains("그"))
        #expect(!QuoteKey.make("um we ship", language: "en").contains("um"))
    }

    @Test func theNearestOccurrenceWinsAndTiesGoToTheEarlier() {
        let pool = QuoteAnchor.Pool([
            Self.seg(10, 1, "intro words here"), Self.seg(12, 2, "we agreed to ship the beta on Friday morning"),
            Self.seg(40, 3, "other filler talk goes on"), Self.seg(75, 4, "we agreed to ship the beta on Friday morning"),
            Self.seg(80, 5, "we agreed to ship the beta on Friday morning"), Self.seg(90, 6, "closing remarks"),
        ])
        let q = "we agreed to ship the beta on Friday"
        #expect(QuoteAnchor.resolve(quote: q, cited: 90, citedText: "closing remarks", pool: pool)?.segment == 80)
        // 75 and 80 are both one step from 40's neighbours? cited 40: 12 is one step before, 75 is one step after: the earlier wins.
        let tie = QuoteAnchor.resolve(quote: q, cited: 40, citedText: "other filler talk goes on", pool: pool)
        #expect(tie?.segment == 12 && tie?.how == .reanchored(from: 40))
    }

    @Test func aCitedIdOutsideThePoolUsesTheNumericDistance() {
        let pool = QuoteAnchor.Pool([Self.seg(10, 1, "we agreed to ship the beta on Friday"), Self.seg(100, 2, "we agreed to ship the beta on Friday")])
        #expect(QuoteAnchor.resolve(quote: "we agreed to ship the beta", cited: 95, citedText: nil, pool: pool)?.segment == 100)
        #expect(QuoteAnchor.resolve(quote: "we agreed to ship the beta", cited: 15, citedText: nil, pool: pool)?.segment == 10)
    }

    @Test func aQuoteInAnotherLanguageNeverMatches() {
        let pool = QuoteAnchor.Pool([Self.seg(1, 0, "vamos a aprobar el presupuesto de este trimestre")], language: "es")
        #expect(QuoteAnchor.resolve(quote: "we are going to approve the budget of this quarter", cited: 1, citedText: pool.segment(1)?.text, pool: pool, language: "es") == nil)
        #expect(QuoteAnchor.resolve(quote: "vamos a aprobar el presupuesto", cited: 1, citedText: pool.segment(1)?.text, pool: pool, language: "es")?.segment == 1)
    }

    @Test func spelledOutLettersAreNotJoinedUntilTheOwnerDecides() {
        #expect(!QuoteKey.joinsSpelledInitials)
        #expect(QuoteKey.make("T_V_", language: "en") == ["t", "v"], "the approved rule ignores only case, punctuation, whitespace and fillers")
        #expect(QuoteAnchor.resolve(quote: "the T V show tonight", cited: 1, citedText: "the TV show tonight at nine", pool: nil, language: "en") == nil)
    }

    @Test func theJoiningOfSpelledOutLettersWorksWhenTurnedOn() {
        let join = true
        #expect(QuoteKey.make("T_V_", language: "en", joinInitials: join) == ["tv"])
        #expect(QuoteKey.make("a b plan", language: "en", joinInitials: join) == ["a", "b", "plan"], "two letters, one of them a word")
        #expect(QuoteKey.make("plan a b", language: "en", joinInitials: join) == ["plan", "a", "b"])
        #expect(QuoteKey.make("a b c plan", language: "en", joinInitials: join) == ["a", "b", "c", "plan"], "a run never merges real words, whatever its length")
        #expect(QuoteKey.make("the N B C team", language: "en", joinInitials: join) == ["the", "nbc", "team"])
    }

    @Test func fillersAreRemovedAndWordsThatLookLikeThemStay() {
        #expect(QuoteKey.make("err on the side", language: "en") == ["err", "on", "the", "side"], "a word that squeezes to a filler is not one")
        #expect(QuoteKey.make("ummm we agree hmmm", language: "en") == ["we", "agree"], "stretched fillers go")
        #expect(QuoteKey.make("ohh ja", language: "de") == ["ohh", "ja"], "oh is not in the owner's list for German")
    }

    @Test func shortCommonPhrasesAreNeverReanchored() {
        let pool = QuoteAnchor.Pool([Self.seg(1, 0, "you know how it goes"), Self.seg(2, 1, "well I think we should wait for more data")])
        #expect(QuoteAnchor.resolve(quote: "you know", cited: 2, citedText: "well I think we should wait", pool: pool) == nil, "two words")
        #expect(QuoteAnchor.resolve(quote: "I think", cited: 1, citedText: "something else entirely", pool: pool) == nil, "under 8 characters")
    }

    @Test func aQuoteAcrossTwoSegmentsIsStillNotFound() {
        let pool = QuoteAnchor.Pool([Self.seg(1, 0, "we will ship the beta"), Self.seg(2, 1, "on Friday morning for everyone")])
        #expect(QuoteAnchor.resolve(quote: "ship the beta on Friday morning", cited: 1, citedText: "we will ship the beta", pool: pool) == nil)
    }

    @Test func exactMatchesAreUnchanged() {
        let m = QuoteAnchor.resolve(quote: "ship the beta", cited: 1, citedText: "we will ship the beta", pool: nil)
        #expect(m == QuoteAnchor.Match(segment: 1, how: .exact))
    }
}
