// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("App: recording setup")
struct AppRecordingSetupTests {
    private func catalog(installedSpeech: [String] = [], installedDictation: [String] = []) -> SpeechLanguageCatalog {
        SpeechLanguageCatalog(speech: ["en-US", "es-ES", "fr-FR"].map(Locale.init(identifier:)),
                              dictation: ["en-US", "es-ES", "fr-FR", "nl-NL"].map(Locale.init(identifier:)),
                              installedSpeech: installedSpeech.map(Locale.init(identifier:)),
                              installedDictation: installedDictation.map(Locale.init(identifier:)))
    }

    private func plan(_ preferred: String?, _ catalog: SpeechLanguageCatalog, me: Bool = false, others: Bool = false,
                      system: [String] = ["en-US"]) throws -> RecordingLanguagePlan {
        try RecordingLanguagePlan.make(preferred: preferred, catalog: catalog, preferredLanguages: system,
                                       dictationMe: me, dictationOthers: others).get()
    }

    // MARK: Language

    @Test func automaticFollowsThePreferredLanguages() throws {
        let p = try plan(nil, catalog(installedSpeech: ["fr-FR"]), system: ["fr-CA", "en-US"])
        #expect(p.language.id == "fr-FR")
        #expect(p.engines == [.me: .speech, .others: .speech])
        #expect(p.missingEngines.isEmpty)
    }

    @Test func theChosenLanguageWins() throws {
        #expect(try plan("es", catalog()).language.id == "es-ES")
    }

    @Test func aMissingModelIsReported() throws {
        let p = try plan("es-ES", catalog(installedSpeech: ["en-US"]))
        #expect(p.missingEngines == [.speech])
    }

    @Test func dictationOnlyLanguagesUseDictationOnBothChannels() throws {
        let p = try plan("nl-NL", catalog(installedDictation: ["nl-NL"]))
        #expect(p.engines == [.me: .dictation, .others: .dictation])
        #expect(p.missingEngines.isEmpty)
    }

    @Test func dictationPerChannelNeedsItsModelToo() throws {
        let p = try plan("en-US", catalog(installedSpeech: ["en-US"]), others: true)
        #expect(p.engines == [.me: .speech, .others: .dictation])
        #expect(p.missingEngines == [.dictation])
    }

    @Test func unsupportedLanguagesFail() {
        let result = RecordingLanguagePlan.make(preferred: "fi-FI", catalog: catalog(), preferredLanguages: ["en-US"],
                                                dictationMe: false, dictationOthers: false)
        #expect(throws: RecordingLanguagePlan.Failure.unsupported("fi-FI")) { try result.get() }
        let empty = SpeechLanguageCatalog(speech: [], dictation: [])
        #expect(throws: RecordingLanguagePlan.Failure.self) {
            try RecordingLanguagePlan.make(preferred: nil, catalog: empty, dictationMe: false, dictationOthers: false).get()
        }
    }

    // MARK: Audio source

    @Test func tickingFamiliesBuildsAnAppScope() {
        #expect(SystemAudioScope.auto.toggling(.zoom) == .apps([.zoom]))
        #expect(SystemAudioScope.allSystem.toggling(.zoom) == .apps([.zoom]))
        #expect(SystemAudioScope.apps([.zoom]).toggling(.chromium) == .apps([.zoom, .chromium]))
        #expect(SystemAudioScope.apps([.zoom, .chromium]).toggling(.zoom) == .apps([.chromium]))
        #expect(SystemAudioScope.apps([.zoom]).toggling(.zoom) == .auto)
        #expect(SystemAudioScope.apps([.zoom]).includes(.zoom))
        #expect(!SystemAudioScope.auto.includes(.zoom))
    }

    @Test func summaries() {
        #expect(SystemAudioScope.auto.summary == "Automatic")
        #expect(SystemAudioScope.allSystem.summary == "All system audio")
        #expect(SystemAudioScope.apps([.zoom]).summary == "Zoom")
        #expect(SystemAudioScope.legacyDefault.summary == "Safari")
        #expect(SystemAudioScope.apps([.zoom, .webkit]).summary.contains("Zoom"))
        #expect(SystemAudioScope.apps([.zoom, .webkit]).summary.contains("Safari"))
    }

    @Test func theMeetingsSourceAppIsTheCapturedCallApp() {
        #expect(SystemAudioScope.auto.sourceApp(callFamily: .teams) == .teams)
        #expect(SystemAudioScope.auto.sourceApp(callFamily: nil) == nil)
        #expect(SystemAudioScope.allSystem.sourceApp(callFamily: .zoom) == .zoom)
        #expect(SystemAudioScope.apps([.webkit]).sourceApp(callFamily: nil) == .webkit)
        #expect(SystemAudioScope.apps([.webkit]).sourceApp(callFamily: .zoom) == .webkit)
        #expect(SystemAudioScope.apps([.webkit, .zoom]).sourceApp(callFamily: .zoom) == .zoom)
        #expect(SystemAudioScope.apps([.webkit, .zoom]).sourceApp(callFamily: .teams) == nil)
    }
}
