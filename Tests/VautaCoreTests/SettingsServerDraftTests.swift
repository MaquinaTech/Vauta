// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Settings: server draft")
struct SettingsServerDraftTests {
    static let pin = "W7ECLfQGJbixIYA8w2zmASwh+wP1lM07gbAxCyYfVpo="

    static func encode(_ config: LLMServerConfig) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(config), as: UTF8.self)
    }

    @Test func legacyConfigRoundTripsByteForByte() throws {
        // What Acta 0.1.x stored: no profile, so requests keep the 0.1 dialect.
        let stored = #"{"baseURL":"https:\/\/192.168.1.50:8443\/v1","contextTokens":65536,"deepModel":"b","embeddingModel":"c","fastModel":"a","mode":"remote","pins":["\#(Self.pin.replacingOccurrences(of: "/", with: "\\/"))"]}"#
        let config = try JSONDecoder().decode(LLMServerConfig.self, from: Data(stored.utf8))
        let draft = ServerDraft(config: config)
        #expect(draft.profile == nil)
        #expect(draft.config == config)
        #expect(try Self.encode(draft.config) == stored)
        #expect(!draft.differs(from: config))
    }

    @Test func profileRoleURLsAndEmbeddingSurviveSaving() {
        var config = LLMServerConfig(mode: .local, baseURL: "http://127.0.0.1:8000/v1", fastModel: "small", deepModel: "large",
                                     embeddingModel: "embed", contextTokens: 65_536,
                                     profile: ServerProfile(kind: .vllm, thinking: .chatTemplateKwargs,
                                                            sampling: .custom(SamplingParameters(temperature: 0.2, topK: 40)),
                                                            structuredOutput: .jsonSchema),
                                     embedding: EmbeddingSettings(dimensions: 512, matryoshka: true, family: .nomic))
        config.roleBaseURLs = RoleBaseURLs(embedding: "http://127.0.0.1:8001/v1")
        var draft = ServerDraft(config: config)
        #expect(draft.config == config)
        // Editing a visible field keeps everything the form does not show.
        draft.deepModel = "  larger  "
        let saved = draft.config
        #expect(saved.deepModel == "larger")
        #expect(saved.profile == config.profile && saved.roleBaseURLs == config.roleBaseURLs && saved.embedding == config.embedding)
        #expect(draft.sampling == .custom)
        #expect(draft.differs(from: config))
    }

    @Test func remoteTrustFieldsAreIgnoredForLocal() {
        var draft = ServerDraft(config: nil)
        draft.baseURL = " http://127.0.0.1:1234/v1 "
        draft.caPEM = "-----BEGIN CERTIFICATE-----"
        draft.pins = "\(Self.pin), other"
        #expect(draft.config.caPEM == nil && draft.config.pins.isEmpty)
        #expect(draft.config.baseURL == "http://127.0.0.1:1234/v1")
        draft.mode = .remote
        #expect(draft.config.pins == [Self.pin, "other"])
        draft.caPEM = "   \n"
        #expect(draft.config.caPEM == nil)
    }

    @Test func savedKeyOnlyGoesToTheSavedDestination() {
        let saved = LLMServerConfig(mode: .remote, baseURL: "https://192.168.1.50:8443/v1", caPEM: "CA", pins: [Self.pin],
                                    fastModel: "a", deepModel: "b", embeddingModel: "c")
        var draft = ServerDraft(config: saved)
        #expect(draft.sharesDestination(with: saved))
        draft.baseURL = "https://192.168.1.50:8443/v1/ "
        draft.fastModel = "other"   // models don't change where requests go
        #expect(draft.sharesDestination(with: saved))
        draft.caPEM = "another CA"
        #expect(!draft.sharesDestination(with: saved))
        draft = ServerDraft(config: saved)
        draft.pins = ""
        #expect(!draft.sharesDestination(with: saved))
        draft = ServerDraft(config: saved)
        draft.baseURL = "https://192.168.1.51:8443/v1"
        #expect(!draft.sharesDestination(with: saved))
        #expect(!ServerDraft(config: saved).sharesDestination(with: nil))
    }

    @Test func pinParsingAcceptsCommasSpacesAndLines() {
        #expect(ServerDraft.parsePins("a, b\nc  d,,") == ["a", "b", "c", "d"])
        #expect(ServerDraft.parsePins("  ").isEmpty)
    }

    @Test func validationMessages() {
        var draft = ServerDraft(config: nil)
        draft.baseURL = "http://127.0.0.1:1234/v1"
        #expect(draft.validationError == .missingModel(.fast))
        #expect(draft.destinationError == nil)
        #expect(draft.validationError?.localizedDescription.contains("fast model") == true)
        draft.fastModel = "a"; draft.deepModel = "b"; draft.embeddingModel = "c"
        #expect(draft.validationError == nil)
        draft.baseURL = "http://192.168.1.5:1234/v1"
        #expect(draft.validationError == .localRequiresLoopback)
        #expect(draft.destinationError == .localRequiresLoopback)
        draft.mode = .remote
        #expect(draft.validationError == .remoteRequiresHTTPS)
        draft.baseURL = "https://gpu.local/v1"
        draft.setKind(.vllm)
        // New-format configs that name a host need a CA or a pin.
        #expect(draft.validationError == .hostNameRequiresTrust("gpu.local"))
        draft.pins = Self.pin
        #expect(draft.validationError == nil)
    }

    @Test func probeConfigTestsTheDestinationBeforeModelsAreChosen() throws {
        var draft = ServerDraft(config: nil)
        draft.baseURL = "http://127.0.0.1:11434/v1"
        #expect(draft.validationError != nil)
        _ = try draft.probeConfig.validatedEndpoints()
        draft.fastModel = "chosen"
        #expect(draft.probeConfig.fastModel == "chosen")
    }

    @Test func adoptingADetectedServer() {
        let server = DiscoveredServer(kind: .ollama, baseURL: URL(string: "http://127.0.0.1:11434/v1/")!, version: "0.9",
                                      models: [DiscoveredModel(id: "qwen3:4b", kind: .chat, contextLength: 40_960),
                                               DiscoveredModel(id: "qwen3:30b", kind: .chat, contextLength: 16_384),
                                               DiscoveredModel(id: "qwen3-embedding:0.6b", kind: .embedding)])
        var draft = ServerDraft(config: nil)
        draft.adopt(server)
        #expect(draft.baseURL == "http://127.0.0.1:11434/v1")
        #expect(draft.profile == .defaults(for: .ollama))
        #expect(draft.fastModel == "qwen3:4b" && draft.deepModel == "qwen3:30b" && draft.embeddingModel == "qwen3-embedding:0.6b")
        #expect(draft.contextTokens == 16_384)
        #expect(draft.validationError == nil)

        // Models the user already chose and the server has are kept.
        var chosen = ServerDraft(config: nil)
        chosen.deepModel = "qwen3:4b"
        chosen.embeddingModel = "missing"
        chosen.adopt(server)
        #expect(chosen.deepModel == "qwen3:4b" && chosen.embeddingModel == "qwen3-embedding:0.6b")
        #expect(chosen.contextTokens == 40_960)
    }

    @Test func detectedContextIsClamped() {
        let server = DiscoveredServer(kind: .llamaCpp, baseURL: URL(string: "http://127.0.0.1:8080/v1/")!, version: nil,
                                      models: [DiscoveredModel(id: "m", kind: .chat, contextLength: 4_096)])
        #expect(ServerDraft.detectedContext(server, fast: "m", deep: "m") == LLMServerConfig.contextRange.lowerBound)
        #expect(ServerDraft.detectedContext(server, fast: "x", deep: "y") == nil)
    }

    @Test func switchingModeClearsAnAddressThatCannotWork() {
        var draft = ServerDraft(config: nil)
        draft.baseURL = "http://127.0.0.1:1234/v1"
        draft.switchMode(to: .remote)
        #expect(draft.mode == .remote && draft.baseURL.isEmpty)
        draft.baseURL = "https://192.168.1.9/v1"
        draft.switchMode(to: .remote)
        #expect(draft.baseURL == "https://192.168.1.9/v1")
        draft.switchMode(to: .local)
        #expect(draft.baseURL.isEmpty)
    }

    @Test func serverKindAndSampling() {
        var draft = ServerDraft(config: nil)
        #expect(draft.sampling == .qwenRecommended)   // the implicit 0.1 preset
        draft.sampling = .serverDefault                // no profile: unchanged
        #expect(draft.profile == nil)
        draft.setKind(.lmStudio)
        #expect(draft.profile == .defaults(for: .lmStudio))
        draft.sampling = .qwenRecommended
        #expect(draft.profile?.sampling == .qwenNonThinking)
        draft.setKind(.lmStudio)                       // same kind keeps edits
        #expect(draft.profile?.sampling == .qwenNonThinking)
        draft.setKind(nil)
        #expect(draft.profile == nil)
    }

    @Test func contextChoicesIncludeTheCurrentValue() {
        var draft = ServerDraft(config: nil)
        draft.contextTokens = 40_960
        #expect(draft.contextChoices.contains(40_960))
        #expect(draft.contextChoices.last == 262_144)
        #expect(draft.contextChoices == draft.contextChoices.sorted())
    }
}

@Suite("Settings: model provider choice")
struct SettingsProviderChoiceTests {
    @Test func choiceFromSavedSettings() {
        #expect(ModelProviderChoice(settings: .init(chat: .onDevice, embeddings: .server), serverMode: .remote) == .onDevice)
        #expect(ModelProviderChoice(settings: .init(chat: .server, embeddings: .server), serverMode: .remote) == .networkServer)
        #expect(ModelProviderChoice(settings: .init(chat: .server, embeddings: .server), serverMode: .local) == .localServer)
        #expect(ModelProviderChoice(settings: .init(chat: .server, embeddings: .server), serverMode: nil) == .localServer)
    }

    @Test func newInstallsUseKeywordSearchOnly() {
        let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        #expect(ModelProviderSettings.load(defaults: defaults, hasServerConfig: false) == .init(chat: .onDevice, embeddings: .none))
        // Upgrades with a server configuration keep using it.
        #expect(ModelProviderSettings.load(defaults: defaults, hasServerConfig: true) == .init(chat: .server, embeddings: .server))
        // An explicit saved choice always wins, including the search model on this Mac.
        ModelProviderSettings(chat: .onDevice, embeddings: .onDeviceModel).save(defaults: defaults)
        #expect(ModelProviderSettings.load(defaults: defaults, hasServerConfig: false) == .init(chat: .onDevice, embeddings: .onDeviceModel))
        #expect(ModelProviderSettings.load(defaults: defaults, hasServerConfig: true) == .init(chat: .onDevice, embeddings: .onDeviceModel))
    }

    // MARK: Apple's on-device embeddings were removed

    @Test func theRetiredAppleChoiceBecomesKeywordSearchOnceWithANotice() {
        let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        defaults.set("onDevice", forKey: "modelProviderChat")
        defaults.set("onDevice", forKey: "modelProviderEmbeddings")
        #expect(ModelProviderSettings.load(defaults: defaults, hasServerConfig: false) == .init(chat: .onDevice, embeddings: .none))
        #expect(defaults.string(forKey: "modelProviderEmbeddings") == "none", "rewritten once")
        #expect(defaults.bool(forKey: ModelProviderSettings.retiredAppleNLKey))
        // The notice flag is set only by the migration; a second load does not set it again after Settings cleared it.
        defaults.removeObject(forKey: ModelProviderSettings.retiredAppleNLKey)
        _ = ModelProviderSettings.load(defaults: defaults, hasServerConfig: false)
        #expect(!defaults.bool(forKey: ModelProviderSettings.retiredAppleNLKey))
    }

    @Test func theRetiredRawValueIsNeverReusedAndTheNewOneRoundTrips() {
        #expect(ModelProviderSettings.Embeddings(rawValue: "onDevice") == nil)
        #expect(ModelProviderSettings.Embeddings.onDeviceModel.rawValue == "searchModel")
        let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        ModelProviderSettings(chat: .server, embeddings: .onDeviceModel).save(defaults: defaults)
        #expect(defaults.string(forKey: "modelProviderEmbeddings") == "searchModel")
        #expect(ModelProviderSettings.load(defaults: defaults, hasServerConfig: false).embeddings == .onDeviceModel)
        #expect(!defaults.bool(forKey: ModelProviderSettings.retiredAppleNLKey))
    }

    @Test func aModelServerChoiceIsUntouchedByTheMigration() {
        let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        ModelProviderSettings(chat: .server, embeddings: .server).save(defaults: defaults)
        #expect(ModelProviderSettings.load(defaults: defaults, hasServerConfig: true) == .init(chat: .server, embeddings: .server))
        #expect(defaults.object(forKey: ModelProviderSettings.retiredAppleNLKey) == nil)
    }

    @Test func installingTheModelAdoptsItOnlyFromKeywordSearch() {
        let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        ModelProviderSettings(chat: .onDevice, embeddings: .none).save(defaults: defaults)
        #expect(ModelProviderSettings.adoptSearchModel(defaults: defaults))
        #expect(ModelProviderSettings.load(defaults: defaults, hasServerConfig: false).embeddings == .onDeviceModel)
        ModelProviderSettings(chat: .server, embeddings: .server).save(defaults: defaults)
        #expect(!ModelProviderSettings.adoptSearchModel(defaults: defaults), "a person who chose a model server keeps it")
        #expect(ModelProviderSettings.load(defaults: defaults, hasServerConfig: true).embeddings == .server)
        // Deleting the model goes back to keyword search, only if it was in use.
        ModelProviderSettings(chat: .server, embeddings: .onDeviceModel).save(defaults: defaults)
        #expect(ModelProviderSettings.dropSearchModel(defaults: defaults))
        #expect(ModelProviderSettings.load(defaults: defaults, hasServerConfig: true).embeddings == .none)
        #expect(!ModelProviderSettings.dropSearchModel(defaults: defaults))
    }

    @Test func installingNeverMovesSomeoneWithAServerAndNoSavedChoice() {
        let defaults = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        // The 0.1 fallback: no saved keys, a server configured, so search is on the server.
        #expect(!ModelProviderSettings.adoptSearchModel(defaults: defaults, hasServerConfig: true))
        #expect(defaults.string(forKey: "modelProviderChat") == nil && defaults.string(forKey: "modelProviderEmbeddings") == nil)
        // Without a server and without a choice, the install adopts the model and writes only the embeddings key.
        #expect(ModelProviderSettings.adoptSearchModel(defaults: defaults, hasServerConfig: false))
        #expect(defaults.string(forKey: "modelProviderEmbeddings") == "searchModel" && defaults.string(forKey: "modelProviderChat") == nil)
        // A saved chat choice is never rewritten.
        let other = UserDefaults(suiteName: "vauta.tests.\(UUID().uuidString)")!
        other.set("server", forKey: "modelProviderChat")
        other.set("none", forKey: "modelProviderEmbeddings")
        #expect(ModelProviderSettings.adoptSearchModel(defaults: other))
        #expect(other.string(forKey: "modelProviderChat") == "server")
        ModelProviderSettings.saveEmbeddings(.none, defaults: other)
        #expect(other.string(forKey: "modelProviderChat") == "server" && other.string(forKey: "modelProviderEmbeddings") == "none")
    }

    @Test func embeddingsFollowTheChoice() {
        #expect(ModelProviderChoice.onDevice.embeddings(keeping: .server) == .none)
        #expect(ModelProviderChoice.onDevice.embeddings(keeping: .none) == .none)
        #expect(ModelProviderChoice.localServer.embeddings(keeping: .onDeviceModel) == .onDeviceModel)
        #expect(ModelProviderChoice.onDevice.embeddingOptions == [.onDeviceModel, .none])
        #expect(ModelProviderChoice.localServer.embeddingOptions == [.server, .onDeviceModel, .none])
        #expect(ModelProviderChoice.networkServer.settings(embeddings: .server) == ModelProviderSettings(chat: .server, embeddings: .server))
        #expect(ModelProviderChoice.onDevice.settings(embeddings: .server) == ModelProviderSettings(chat: .onDevice, embeddings: .none))
        #expect(ModelProviderChoice.onDevice.serverMode == nil && ModelProviderChoice.networkServer.serverMode == .remote)
    }

    @Test func pinIsComputedFromAServerCertificate() {
        typealias F = ModelsFixtures
        var draft = ServerDraft(config: nil)
        #expect(draft.addPin(fromCertificatePEM: F.testServer) == F.serverPin)
        #expect(draft.pins == F.serverPin)
        // Adding the same certificate again keeps one pin.
        draft.addPin(fromCertificatePEM: F.testServer)
        #expect(draft.pins == F.serverPin)
        draft.addPin(fromCertificatePEM: F.testCA)
        #expect(ServerDraft.parsePins(draft.pins) == [F.serverPin, F.caPin])
        #expect(draft.addPin(fromCertificatePEM: "not a certificate") == nil)
    }

    @Test func embeddingModelIsRequiredOnlyWhenEmbeddingsRunOnTheServer() {
        var draft = ServerDraft(config: nil)
        draft.baseURL = "http://127.0.0.1:1234/v1"
        draft.fastModel = "a"
        draft.deepModel = "b"
        #expect(draft.validationError == .missingModel(.embedding))
        #expect(draft.validationError(embeddingsOnServer: true) == .missingModel(.embedding))
        #expect(draft.validationError(embeddingsOnServer: false) == nil)
        draft.embeddingModel = "c"
        #expect(draft.validationError == nil)
    }

    @Test func roleURLsCountAsPartOfTheDestination() {
        var config = LLMServerConfig(mode: .local, baseURL: "http://127.0.0.1:1234/v1", fastModel: "a", deepModel: "b", embeddingModel: "c")
        var draft = ServerDraft(config: config)
        #expect(draft.sharesDestination(with: config))
        draft.roleBaseURLs = RoleBaseURLs(embedding: "http://127.0.0.1:9/v1")
        #expect(!draft.sharesDestination(with: config))
        config.roleBaseURLs = draft.roleBaseURLs
        #expect(draft.sharesDestination(with: config))
    }
}
