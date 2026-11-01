// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Knowledge · text keys")
struct KnowledgeTextKeysTests {
    @Test func normFoldsCaseAccentsAndPunctuation() {
        #expect(TextKeys.norm("  Telefónica,  S.A. ") == "telefonica s a")
        #expect(TextKeys.norm("Jean-Luc") == "jean luc")
        #expect(TextKeys.norm("ＡＢＣ　１２") == "abc 12")
    }

    /// Persisted keys of existing stores must not change for plain Latin text.
    @Test(arguments: ["Juan García", "Kobaltix", "Telefónica", "José María", "Ñandú", "Zoë", "François", "Müller", "1:1 sync"])
    func normIsStableForLegacyLatinNames(_ name: String) {
        let legacy = Self.legacyNorm(name)
        #expect(TextKeys.norm(name) == legacy)
    }

    @Test(arguments: [("Łukasz", "Lukasz"), ("Søren", "Soren"), ("Æsa", "Aesa"), ("Đorđe", "Dorde"), ("Straße", "Strasse"),
                      ("STRAẞE", "strasse"), ("Işık", "Isik"), ("Œuvre", "Oeuvre")])
    func normFoldsLettersWithoutDecomposition(_ a: String, _ b: String) {
        #expect(TextKeys.norm(a) == TextKeys.norm(b))
    }

    @Test func normDropsArabicVocalizationAndTatweel() {
        #expect(TextKeys.norm("مُحَمَّد") == TextKeys.norm("محمد"))
        #expect(TextKeys.norm("مـحـمد") == TextKeys.norm("محمد"))
    }

    @Test func normDropsHebrewPoints() {
        #expect(TextKeys.norm("שָׁלוֹם") == TextKeys.norm("שלום"))
    }

    @Test func normIsLocaleIndependent() {
        // Turkish dotted/dotless i fold the same regardless of the Mac's locale.
        #expect(TextKeys.norm("İstanbul") == "istanbul")
        #expect(TextKeys.norm("ISTANBUL") == "istanbul")
    }

    @Test func matchKeyJoinsNoSpaceScripts() {
        #expect(TextKeys.matchKey("王 伟") == "王伟")
        #expect(TextKeys.matchKey("juan garcia") == "juan garcia")
        #expect(TextKeys.matchKey("api 王 伟 team") == "api 王伟 team")
    }

    @Test func spanishPhoneticKey() {
        #expect(TextKeys.phonetic("Vallejo") == TextKeys.phonetic("Ballejo"))
        #expect(TextKeys.phonetic("Quique") == TextKeys.phonetic("Kike"))
    }

    @Test func boundedEditDistance() {
        #expect(TextKeys.editDistance("kobaltix", "cobaltis", limit: 2) == 2)
        #expect(TextKeys.editDistance("kobaltix", "nada", limit: 2) == 3)
    }

    @Test func onlyMidSentenceCapitalsAreFlagged() {
        let tokens = TextKeys.tokens("Hola. Juan dijo que Kobaltix va bien")
        #expect(tokens.map(\.capitalizedMidSentence) == [false, false, false, false, true, false, false])
    }

    @Test func spanishOpeningMarksStartSentences() {
        let tokens = TextKeys.tokens("vale ¿Marta viene?")
        #expect(tokens.first { $0.original == "Marta" }?.capitalizedMidSentence == false)
    }

    @Test func tokensKeepOriginalRanges() {
        let text = "Hablé con Jean-Luc ayer"
        let tokens = TextKeys.tokens(text, profile: LanguageProfile(identifier: "fr-FR"))
        let jean = tokens.first { $0.norm == "jean" }!
        let luc = tokens.first { $0.norm == "luc" }!
        #expect(text[jean.range.lowerBound..<luc.range.upperBound] == "Jean-Luc")
    }

    @Test func chineseTextIsSegmented() {
        let tokens = TextKeys.tokens("我们今天和王伟讨论了项目", profile: LanguageProfile(identifier: "zh-Hans"))
        #expect(tokens.count > 3)
        #expect(tokens.allSatisfy { $0.capitalizedMidSentence == false })
    }

    /// NLTokenizer returns overlapping ranges for a decimal followed by kana;
    /// segmenting such text used to trap and crash the indexer.
    @Test(arguments: ["6.4に", "3.5mm弾は", "6.4 に", "仕様は6.8×43mm SPCです"])
    func overlappingTokenizerRangesDoNotTrap(_ text: String) {
        _ = TextKeys.tokens(text, profile: LanguageProfile.detecting(text))
        #expect(!TextKeys.tokens(text, profile: LanguageProfile(identifier: "ja")).isEmpty)
    }

    /// The pre-release `norm` (es_ES folding, no extra letter folding).
    private static func legacyNorm(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "es_ES"))
        var out = "", pendingSpace = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            } else {
                pendingSpace = true
            }
        }
        return out
    }
}

@Suite("Knowledge · clean")
struct KnowledgeCleanTests {
    @Test func keepsJoinersAndDirectionMarks() {
        let persian = "می\u{200C}خواهم"
        let family = "👩\u{200D}👩\u{200D}👧"
        let rlm = "abc\u{200F}"
        #expect(MeetingStore.clean(persian, max: 100) == persian)
        #expect(MeetingStore.clean(family, max: 100) == family)
        #expect(MeetingStore.clean(rlm, max: 100) == rlm)
    }

    @Test func removesControlsAndBidiOverrides() {
        #expect(MeetingStore.clean("a\u{0007}b\u{202E}c\u{2066}d\u{0000}", max: 100) == "abcd")
        #expect(MeetingStore.clean("line1\nline2\tx", max: 100) == "line1\nline2\tx")
        #expect(MeetingStore.clean("  padded  ", max: 3) == "pad")
    }
}

@Suite("Knowledge · language profiles")
struct KnowledgeLanguageProfileTests {
    @Test func legacyProfileIsSpanish() {
        #expect(LanguageProfile.legacy.languageCode == "es")
        #expect(LanguageProfile(identifier: nil) == LanguageProfile.legacy)
        #expect(LanguageProfile.legacy.capitalizationMarksNames)
    }

    @Test(arguments: [("en-US", LanguageProfile.Casing.properNounsCapitalized), ("es-ES", .properNounsCapitalized),
                      ("ru-RU", .properNounsCapitalized), ("de-DE", .nounsCapitalized), ("zh-Hans", .caseless),
                      ("ja-JP", .caseless), ("ko-KR", .caseless), ("ar-SA", .caseless), ("he-IL", .caseless), ("hi-IN", .caseless),
                      ("th-TH", .caseless)])
    func casingFollowsScriptAndLanguage(_ identifier: String, _ casing: LanguageProfile.Casing) {
        #expect(LanguageProfile(identifier: identifier).casing == casing)
    }

    @Test func spacesByLanguage() {
        #expect(!LanguageProfile(identifier: "ja-JP").usesSpaces)
        #expect(!LanguageProfile(identifier: "th-TH").usesSpaces)
        #expect(LanguageProfile(identifier: "ko-KR").usesSpaces)
    }

    @Test(arguments: ["en", "es", "fr", "de", "it", "pt", "nl", "ja", "ko", "zh", "ca"])
    func everyMainLanguageHasStopwords(_ code: String) {
        #expect(LanguageProfile(identifier: code).stopwords.count >= 20)
    }

    @Test func unknownLanguagesFallBackToGenericStopwords() {
        #expect(LanguageProfile(identifier: "pl-PL").stopwords.contains("the"))
    }

    @Test func calendarWordsComeFromTheLocale() {
        #expect(LanguageProfile(identifier: "en-US").noiseWords.isSuperset(of: ["monday", "september"]))
        #expect(LanguageProfile(identifier: "es-ES").noiseWords.isSuperset(of: ["miercoles", "septiembre", "yo", "vale"]))
        #expect(LanguageProfile(identifier: "de-DE").noiseWords.contains("dienstag"))
        #expect(LanguageProfile(identifier: "fr-FR").noiseWords.contains("mercredi"))
    }

    @Test func phoneticKeyOnlyWhereTheRulesHold() {
        // The Spanish key makes "Hannah" sound like "Ana": right in Spanish, wrong in English, which has rules of its own.
        let es = LanguageProfile(identifier: "es-ES"), en = LanguageProfile(identifier: "en-US")
        #expect(es.phoneticKey("Hannah") == es.phoneticKey("Ana"))
        #expect(en.phoneticKey("Hannah") != nil && en.phoneticKey("Hannah") != en.phoneticKey("Ana"))
        #expect(LanguageProfile(identifier: "ca-ES").phoneticKey("Vallès") != nil)
        // German capitalizes every noun, so its corrector is off and it has no key.
        #expect(LanguageProfile(identifier: "de-DE").phoneticKey("Meyer") == nil)
    }

    @Test func sentenceTerminatorsPerScript() {
        #expect(LanguageProfile(identifier: "zh-Hans").isSentenceTerminator("。"))
        #expect(LanguageProfile(identifier: "ar").isSentenceTerminator("؟"))
        #expect(LanguageProfile(identifier: "hi").isSentenceTerminator("।"))
        #expect(LanguageProfile(identifier: "es").isSentenceTerminator("¿"))
        #expect(!LanguageProfile(identifier: "en").isSentenceTerminator("¿"))
    }

    @Test func detectsTheQuestionLanguage() {
        let profile = LanguageProfile.detecting("What did we decide about the budget for the new office?")
        #expect(profile.languageCode == "en")
        #expect(LanguageProfile.detecting("").languageCode == "es")
    }

    @Test func queryTermsKeepAcronymsNumbersAndShortNames() {
        let en = LanguageProfile(identifier: "en-US")
        let terms = MeetingStore.queryTerms("What did Li say about the API in Q3 and the 5G rollout?", profile: en)
        #expect(Set(terms).isSuperset(of: ["Li", "API", "Q3", "5G", "rollout"]))
        #expect(!terms.contains { ["What", "did", "the", "about", "and", "in"].contains($0) })
        let es = MeetingStore.queryTerms("¿Qué dijo Ana de la API en la reunión?", profile: .legacy)
        #expect(Set(es) == ["Ana", "API"])
    }

    @Test func chineseQueriesAreSegmented() {
        let terms = MeetingStore.queryTerms("我们关于预算决定了什么", profile: LanguageProfile(identifier: "zh-Hans"))
        #expect(terms.contains("预算"))
        #expect(!terms.contains("我们"))
    }

    @Test func sampleQuestionsMarkOnlyTheTopic() {
        func marked(_ question: String, _ text: String) -> [String] {
            MeetingStore.matchedRanges(of: question, in: text).map { String(text[$0]) }
        }
        #expect(marked("Cosa abbiamo deciso sulla beta?", "Ieri abbiamo chiuso la beta con Ana") == ["beta"])
        #expect(marked("ベータについて何を決めましたか？", "ありがとうございました。ベータは木曜日に配布し、4ステップになりました") == ["ベータ"])
        #expect(marked("베타에 대해 무엇을 결정했나요?", "베타는 목요일에 배포하고 베타 빌드는 두 번 나갑니다") == ["베타", "베타"])
        #expect(marked("我们对测试版做了什么决定？", "就这么做。Northwind做两次测试版") == ["测试版"])
    }
}
