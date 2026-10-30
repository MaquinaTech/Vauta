// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Lists shaped like what macOS 27 reports (a subset).
private let speech = ["en-US", "en-GB", "en-AU", "es-ES", "es-MX", "es-US", "fr-FR", "fr-CA", "de-DE", "it-IT",
                      "pt-BR", "pt-PT", "ja-JP", "ko-KR", "zh-CN", "zh-TW", "zh-HK", "yue-CN", "hi-IN"].map(Locale.init(identifier:))
private let dictation = speech + ["nl-NL", "ru-RU", "pl-PL", "sv-SE", "tr-TR", "ar-SA", "he-IL", "ca-ES"].map(Locale.init(identifier:))

private func catalog(installedSpeech: [String] = [], installedDictation: [String] = []) -> SpeechLanguageCatalog {
    SpeechLanguageCatalog(speech: speech, dictation: dictation,
                          installedSpeech: installedSpeech.map(Locale.init(identifier:)),
                          installedDictation: installedDictation.map(Locale.init(identifier:)))
}

@Suite("Capture: speech languages")
struct CaptureLanguageTests {
    @Test func mergesEnginesPerLanguage() throws {
        let c = catalog(installedSpeech: ["es-ES"], installedDictation: ["nl-NL"])
        let spanish = try #require(c.languages.first { $0.id == "es-ES" })
        #expect(spanish.engines == [.speech, .dictation])
        #expect(spanish.preferredEngine == .speech)
        #expect(spanish.isInstalled)
        let dutch = try #require(c.languages.first { $0.id == "nl-NL" })
        #expect(dutch.engines == [.dictation])
        #expect(dutch.preferredEngine == .dictation)
        #expect(dutch.isInstalled)
        #expect(c.languages.map(\.id) == c.languages.map(\.id).sorted())
        #expect(Set(c.languages.map(\.id)).count == c.languages.count)
    }

    /// The system lists the Spanish model as installed, but this app can't use it (an ad-hoc build signed again by an update): it
    /// counts as not installed, so Settings offers the download that the recording needs, instead of a recording that doesn't start.
    @Test func aModelThisAppCannotUseIsNotInstalled() async throws {
        let listed = ["es-ES", "en-US"].map(Locale.init(identifier:))
        let usable = await SpeechLanguages.usable(listed, .speech) { locale, engine in engine == .speech && locale.identifier(.bcp47) == "en-US" }
        #expect(usable.map { $0.identifier(.bcp47) } == ["en-US"])
        let c = SpeechLanguageCatalog(speech: speech, dictation: dictation, installedSpeech: usable)
        #expect(try #require(c.language(matching: "es-ES")).isInstalled == false)
        #expect(try #require(c.language(matching: "en-US")).isInstalled)
    }

    @Test(arguments: [
        ("es-ES", "es-ES"), ("es_ES", "es-ES"), ("es", "es-ES"), ("es-AR", "es-ES"), ("es-MX", "es-MX"),
        ("en", "en-US"), ("en-IE", "en-US"), ("en-GB", "en-GB"), ("pt", "pt-BR"), ("pt-PT", "pt-PT"),
        ("fr-BE", "fr-FR"), ("fr-CA", "fr-CA"), ("zh-Hans-CN", "zh-CN"), ("zh-Hant", "zh-TW"), ("zh-HK", "zh-HK"),
        ("zh-SG", "zh-CN"), ("ja", "ja-JP"), ("nl-BE", "nl-NL"), ("ca", "ca-ES"),
    ])
    func matchesRequestedLanguages(requested: String, expected: String) {
        #expect(catalog().language(matching: requested)?.id == expected)
    }

    @Test(arguments: ["fi-FI", "xx", "", "sw-KE"])
    func unsupportedLanguagesDontMatch(requested: String) {
        #expect(catalog().language(matching: requested) == nil)
    }

    @Test func defaultIsTheFirstSupportedPreferredLanguage() {
        let c = catalog()
        #expect(c.defaultLanguage(preferredLanguages: ["es-ES", "en-US"])?.id == "es-ES")
        #expect(c.defaultLanguage(preferredLanguages: ["fi-FI", "de-AT", "en-US"])?.id == "de-DE")
        // A language only DictationTranscriber supports still counts.
        #expect(c.defaultLanguage(preferredLanguages: ["nl-NL"])?.id == "nl-NL")
        #expect(c.defaultLanguage(preferredLanguages: ["zh-Hant-TW"])?.id == "zh-TW")
    }

    @Test func defaultFallsBackToEnglish() {
        #expect(catalog().defaultLanguage(preferredLanguages: ["fi-FI", "et-EE"])?.id == "en-US")
        #expect(catalog().defaultLanguage(preferredLanguages: [])?.id == "en-US")
        let noEnglish = SpeechLanguageCatalog(speech: [Locale(identifier: "it-IT")], dictation: [])
        #expect(noEnglish.defaultLanguage(preferredLanguages: ["fi-FI"])?.id == "it-IT")
        #expect(SpeechLanguageCatalog(speech: [], dictation: []).defaultLanguage(preferredLanguages: ["es-ES"]) == nil)
    }

    @Test func spanishKeepsWorking() throws {
        // 0.1.0 always used es-ES; it must stay selectable and prefer SpeechTranscriber.
        let spanish = try #require(catalog().language(matching: MeetingStore.Meeting.legacyLocaleIdentifier))
        #expect(spanish.id == "es-ES")
        #expect(spanish.preferredEngine == .speech)
    }

    @Test func picksTheEnginePerLanguage() throws {
        let c = catalog()
        let spanish = try #require(c.language(matching: "es-ES"))
        let dutch = try #require(c.language(matching: "nl-NL"))
        #expect(SpeechLanguages.engine(for: spanish) == .speech)
        #expect(SpeechLanguages.engine(for: spanish, vocabulary: ["Vauta"]) == .dictation(vocabulary: ["Vauta"]))
        #expect(SpeechLanguages.engine(for: dutch) == .dictation(vocabulary: []))
        let speechOnly = try #require(SpeechLanguageCatalog(speech: [Locale(identifier: "yue-CN")], dictation: []).languages.first)
        #expect(SpeechLanguages.engine(for: speechOnly, vocabulary: ["Vauta"]) == .speech)
    }

    @Test func engineKindOfTranscriptionEngines() {
        #expect(TranscriptionEngine.speech.kind == .speech)
        #expect(TranscriptionEngine.dictation(vocabulary: ["Vauta"]).kind == .dictation)
    }

    @Test func channelLocales() {
        let es = Locale(identifier: "es-ES"), en = Locale(identifier: "en-US")
        let both = ChannelLocales(es)
        #expect(both[.me] == es && both[.others] == es)
        let mixed = ChannelLocales(me: es, others: en)
        #expect(mixed[.me] == es)
        #expect(mixed[.others] == en)
    }
}

@Suite("Capture: speech model reservations")
struct CaptureReservationTests {
    private let day: TimeInterval = 86_400

    @Test func alreadyReservedIsANoOp() throws {
        let plan = try ReservationPlanner.plan(reserving: "es-ES", reserved: ["es-ES"], maximum: 5, active: [], lastUsed: [:])
        #expect(plan == .init(release: [], reserve: false))
    }

    @Test func reservesWhileThereIsRoom() throws {
        let plan = try ReservationPlanner.plan(reserving: "fr-FR", reserved: ["es-ES", "en-US"], maximum: 5, active: [], lastUsed: [:])
        #expect(plan == .init(release: [], reserve: true))
    }

    @Test func releasesTheLeastRecentlyUsedWhenFull() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reserved = ["es-ES", "en-US", "de-DE", "it-IT", "ja-JP"]
        let lastUsed = ["es-ES": now, "en-US": now - day, "de-DE": now - 30 * day, "it-IT": now - 2 * day, "ja-JP": now - 3 * day]
        let plan = try ReservationPlanner.plan(reserving: "fr-FR", reserved: reserved, maximum: 5, active: [], lastUsed: lastUsed)
        #expect(plan == .init(release: ["de-DE"], reserve: true))
    }

    @Test func neverUsedGoesFirstAndActiveIsKept() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reserved = ["es-ES", "en-US", "de-DE"]
        let plan = try ReservationPlanner.plan(reserving: "fr-FR", reserved: reserved, maximum: 3, active: ["en-US"],
                                               lastUsed: ["es-ES": now - 90 * day, "de-DE": now])
        // en-US was never used but is active; es-ES is the oldest of the rest.
        #expect(plan == .init(release: ["es-ES"], reserve: true))
    }

    @Test func releasesSeveralWhenOverTheLimit() throws {
        let plan = try ReservationPlanner.plan(reserving: "fr-FR", reserved: ["a-A", "b-B", "c-C"], maximum: 2, active: [], lastUsed: [:])
        #expect(plan == .init(release: ["a-A", "b-B"], reserve: true))
    }

    @Test func failsWhenEveryReservationIsActive() {
        #expect(throws: CaptureError.self) {
            try ReservationPlanner.plan(reserving: "fr-FR", reserved: ["es-ES", "en-US"], maximum: 2,
                                        active: ["es-ES", "en-US"], lastUsed: [:])
        }
    }

    @Test func usageIsRecordedPerLanguage() {
        let temp = CaptureTestDefaults()
        let usage = SpeechLanguageUsage(defaults: temp.defaults)
        #expect(usage.lastUsed().isEmpty)
        let t1 = Date(timeIntervalSince1970: 1_800_000_000)
        usage.noteUsed(["es-ES", "en-US"], at: t1)
        usage.noteUsed(["es-ES"], at: t1 + day)
        #expect(usage.lastUsed() == ["es-ES": t1 + day, "en-US": t1])
    }
}
