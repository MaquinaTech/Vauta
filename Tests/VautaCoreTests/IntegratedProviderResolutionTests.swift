// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// What "the integrated model" resolves to: the model when it is installed, Apple's with the reason when it is not, and the choices
/// that go with it.
@Suite("Providers: the integrated model")
struct IntegratedProviderResolutionTests {
    static func defaults(chat: String? = "integrated", live: String? = nil) -> UserDefaults {
        let d = UserDefaults(suiteName: "provider-test-\(UUID().uuidString)")!
        if let chat { d.set(chat, forKey: ModelProviderSettings.chatKey) }
        if let live { d.set(live, forKey: ModelProviderSettings.liveTasksKey) }
        return d
    }

    static func providers(_ defaults: UserDefaults, access: LanguageModelAccess) -> SystemModelProviders {
        SystemModelProviders(client: LLMClient(), defaults: defaults, languageModel: access, loadConfig: { nil })
    }

    static func installed(_ access: LanguageModelAccess) {
        let store = LanguageModelStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("provider-test-\(UUID().uuidString)"))
        access.adopt(IntegratedChatModel(engine: LanguageModelEngine(store: store)))
    }

    @Test func notInstalledFallsBackToAppleWithTheReasonOrFailsWithIt() {
        let access = LanguageModelAccess()
        switch Self.providers(Self.defaults(), access: access).chat() {
        case .success(let chat): #expect(chat.fallbackReason == .notReady && !chat.integrated)
        case .failure(let u): #expect(u.issue == .integratedModel(.notReady), "Apple is not available on this Mac: the issue names the integrated model")
        }
    }

    @Test func damagedFilesAreAnotherReason() {
        let access = LanguageModelAccess()
        access.markDamaged()
        switch Self.providers(Self.defaults(), access: access).chat() {
        case .success(let chat): #expect(chat.fallbackReason == .damaged)
        case .failure(let u): #expect(u.issue == .integratedModel(.damaged))
        }
    }

    @Test func installedIsTheIntegratedModelWithItsWindow() throws {
        let access = LanguageModelAccess()
        Self.installed(access)
        let chat = try Self.providers(Self.defaults(), access: access).chat().get()
        #expect(chat.integrated && chat.onDevice && chat.fallbackReason == nil && chat.contextTokens == IntegratedChatModel.contextWindow)
    }

    @Test func whileRecordingTheLiveWorkGoesToAppleOnlyWhenThePersonSaidSo() throws {
        let access = LanguageModelAccess()
        Self.installed(access)
        let both = Self.providers(Self.defaults(live: "integrated"), access: access)
        #expect(try both.chat(for: .live).get().integrated && both.chat(for: .main).isIntegrated)
        let apple = Self.providers(Self.defaults(live: "apple"), access: access)
        #expect(apple.chat(for: .main).isIntegrated, "minutes and answers after the meeting always use the integrated model")
        if case .success(let live) = apple.chat(for: .live) {
            // Apple's model when this Mac has it; otherwise (a CI runner without Apple Intelligence) the integrated one.
            let appleAvailable = AppleChatModel().availability == .available
            #expect(live.integrated == !appleAvailable, "live notes and answers use Apple's model when it is available")
        } else {
            Issue.record("the live work has a model: Apple's, or the integrated one when Apple is not available")
        }
    }

    @Test func theChoiceRoundTripsAndOlderBuildsReadItAsUnknown() {
        let d = Self.defaults(chat: nil)
        let saved = ModelProviderSettings(chat: .integrated, embeddings: .onDeviceModel)
        saved.save(defaults: d)
        #expect(ModelProviderSettings.load(defaults: d, hasServerConfig: false) == saved)
        #expect(d.string(forKey: ModelProviderSettings.chatKey) == "integrated")
        #expect(ModelProviderSettings.Chat(rawValue: "future-choice") == nil)
        #expect(ModelProviderSettings.liveTasks(defaults: d) == .integrated, "the default is the integrated model")
        ModelProviderSettings.saveLiveTasks(.apple, defaults: d)
        #expect(ModelProviderSettings.liveTasks(defaults: d) == .apple)
    }

    @Test func theHiddenFlagOfTheEarlierWaveBecomesTheChoiceOnce() {
        let d = Self.defaults(chat: nil)
        d.set(true, forKey: "integratedLanguageModel")
        #expect(ModelProviderSettings.load(defaults: d, hasServerConfig: false).chat == .integrated)
        #expect(d.object(forKey: "integratedLanguageModel") == nil && d.string(forKey: ModelProviderSettings.chatKey) == "integrated")
        // A person who chose a server keeps it.
        let server = Self.defaults(chat: "server")
        server.set(true, forKey: "integratedLanguageModel")
        #expect(ModelProviderSettings.load(defaults: server, hasServerConfig: true).chat == .server)
        // Apple's choice moves to the model, since the flag only ever meant that.
        let apple = Self.defaults(chat: "onDevice")
        apple.set(true, forKey: "integratedLanguageModel")
        #expect(ModelProviderSettings.load(defaults: apple, hasServerConfig: false).chat == .integrated)
    }

    @Test func theChoiceInSettingsRoundTripsAndSharesTheEmbeddingOptionsOfApple() {
        let choice = ModelProviderChoice(settings: ModelProviderSettings(chat: .integrated, embeddings: .none), serverMode: nil)
        #expect(choice == .integrated && choice.chat == .integrated && choice.serverMode == nil)
        #expect(choice.embeddingOptions == ModelProviderChoice.onDevice.embeddingOptions && choice.embeddingOptions == [.onDeviceModel, .none])
        #expect(choice.embeddings(keeping: .server) == .none && choice.settings(embeddings: .onDeviceModel) == ModelProviderSettings(chat: .integrated, embeddings: .onDeviceModel))
        #expect(ModelProviderChoice.allCases.count == 4)
    }
}

private extension Result where Success == ChatProvider, Failure == ProviderUnavailable {
    var isIntegrated: Bool { if case .success(let chat) = self { chat.integrated } else { false } }
}
