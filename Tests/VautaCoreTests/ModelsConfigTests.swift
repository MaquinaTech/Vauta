// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Models: server config")
struct ModelsConfigTests {
    typealias F = ModelsFixtures

    @Test(arguments: [
        (LLMServerConfig.Mode.local, "http://127.0.0.1:1234/v1"), (.local, "http://localhost:11434/v1/"), (.local, "http://[::1]:8080/v1"),
        (.local, "http://[0:0:0:0:0:0:0:1]:8080/v1"),
        (.remote, "https://192.168.1.50:8443/v1"), (.remote, "https://10.0.0.7/v1"), (.remote, "https://100.101.102.103:8443/v1"),
        (.remote, "https://[fd12:3456::1]:8443/v1"), (.remote, "https://[fe80::1%25en0]:8443/v1"), (.remote, "https://[fc00::5]/v1"),
        (.remote, "https://[::ffff:192.168.1.9]/v1"),
        // Saved legacy (no profile) configs with names keep working.
        (.remote, "https://servidor.local:8443/v1"), (.remote, "https://gpu.tail1234.ts.net/v1"),
    ])
    func acceptedDestinations(mode: LLMServerConfig.Mode, url: String) {
        #expect((try? F.config(mode, url).validated(keepingLegacyNames: true)) != nil)
    }

    @Test(arguments: [
        (LLMServerConfig.Mode.local, "http://192.168.1.50:1234/v1"), (.remote, "http://192.168.1.50:8443/v1"),
        (.remote, "https://api.example.com/v1"), (.remote, "https://8.8.8.8/v1"), (.remote, "https://127.0.0.1:8443/v1"),
        (.remote, "https://user:pw@192.168.1.50/v1"), (.remote, "https://192.168.1.50/v1?x=1"), (.local, "ftp://127.0.0.1/v1"),
        (.remote, "https://172.32.0.1/v1"),
        // Text-prefix tricks that the 0.1.x check let through.
        (.remote, "https://[fc::1]/v1"), (.remote, "https://[fe8::1]/v1"), (.remote, "https://[fd::1]/v1"),
        (.remote, "https://[2001:db8::1]/v1"), (.remote, "https://[::ffff:8.8.8.8]/v1"),
        // Leading zeros could be read as octal by a resolver.
        (.remote, "https://010.0.0.1/v1"), (.local, "http://127.0.0.01:1234/v1"),
        (.remote, "https://evil.local.example.com/v1"),
    ])
    func rejectedDestinations(mode: LLMServerConfig.Mode, url: String) {
        #expect((try? F.config(mode, url).validated()) == nil)
    }

    @Test func rejectedTrustMaterial() {
        #expect(throws: LLMServerConfig.Invalid.invalidPin("not-a-pin")) {
            try F.config(.remote, "https://192.168.1.50/v1", pins: ["not-a-pin"]).validated()
        }
        #expect(throws: LLMServerConfig.Invalid.caRequiresHTTPS) { try F.config(.local, "http://127.0.0.1:1234/v1", ca: F.testCA).validated() }
        #expect(throws: LLMServerConfig.Invalid.invalidCA) { try F.config(.remote, "https://192.168.1.50/v1", ca: "garbage").validated() }
        #expect(throws: LLMServerConfig.Invalid.pinsRequireHTTPS) {
            try F.config(.local, "http://127.0.0.1:1234/v1", pins: [F.serverPin]).validated()
        }
    }

    @Test func everyModelIsRequired() {
        var config = F.config(.local, "http://127.0.0.1:1234/v1")
        config.embeddingModel = " "
        #expect(throws: LLMServerConfig.Invalid.missingModel(.embedding)) { try config.validated() }
    }

    @Test func invalidErrorsAreLocalized() {
        let error = LLMServerConfig.Invalid.notPrivateHost("8.8.8.8")
        #expect(error.errorDescription?.contains("8.8.8.8") == true)
        #expect("\(error)" == error.errorDescription)
    }

    // MARK: Compatibility with 0.1.x configs

    static let legacyJSON = #"{"mode":"local","baseURL":"http://127.0.0.1:1234/v1","fastModel":"a","deepModel":"b","embeddingModel":"c"}"#

    @Test func legacyImportDefaults() throws {
        let decoded = try JSONDecoder().decode(LLMServerConfig.self, from: Data(Self.legacyJSON.utf8))
        #expect(decoded.contextTokens == LLMServerConfig.defaultContext && decoded.pins.isEmpty && decoded.caPEM == nil)
        #expect(decoded.profile == nil && decoded.roleBaseURLs == nil && decoded.embedding == nil)
        #expect(decoded.effectiveProfile == .legacy)
    }

    @Test func legacyKeychainJSONRoundTripsWithoutNewKeys() throws {
        // Exactly what 0.1.x wrote with JSONEncoder (caPEM omitted when nil).
        let stored = #"{"baseURL":"https:\/\/192.168.1.50:8443\/v1","contextTokens":65536,"deepModel":"b","embeddingModel":"c","fastModel":"a","mode":"remote","pins":["W7ECLfQGJbixIYA8w2zmASwh+wP1lM07gbAxCyYfVpo="]}"#
        let config = try JSONDecoder().decode(LLMServerConfig.self, from: Data(stored.utf8))
        #expect(try config.validated().pins == [F.serverPin])
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let again = String(decoding: try encoder.encode(config), as: UTF8.self)
        #expect(again == stored)
    }

    @Test func newFieldsRoundTrip() throws {
        var config = F.config(.local, "http://127.0.0.1:8000/v1", profile: ServerProfile(kind: .vllm, thinking: .chatTemplateKwargs,
                                                                                       sampling: .custom(SamplingParameters(temperature: 0.2, topK: 40)),
                                                                                       structuredOutput: .jsonSchema),
                              embedding: EmbeddingSettings(dimensions: 512, matryoshka: true, family: .nomic))
        config.roleBaseURLs = RoleBaseURLs(embedding: "http://127.0.0.1:8001/v1")
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(LLMServerConfig.self, from: data) == config)
    }

    @Test func profileDecodingIsTolerant() throws {
        let json = #"{"mode":"local","baseURL":"http://127.0.0.1:11434/v1","fastModel":"a","deepModel":"b","embeddingModel":"c","profile":{"kind":"ollama"},"futureField":1}"#
        let config = try JSONDecoder().decode(LLMServerConfig.self, from: Data(json.utf8))
        #expect(config.profile == .defaults(for: .ollama))
        let future = #"{"mode":"local","baseURL":"http://127.0.0.1:1/v1","fastModel":"a","deepModel":"b","embeddingModel":"c","profile":{"kind":"quantum","thinking":"telepathy","structuredOutput":"xml","sampling":{"preset":"new"}}}"#
        let unknown = try JSONDecoder().decode(LLMServerConfig.self, from: Data(future.utf8))
        #expect(unknown.profile == ServerProfile(kind: .openAICompatible, thinking: .none, sampling: .none, structuredOutput: .none))
    }

    @Test func samplingPresetEncoding() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(SamplingPreset.qwenNonThinking), as: UTF8.self) == #"{"preset":"qwen-nonthinking"}"#)
        let custom = SamplingPreset.custom(SamplingParameters(temperature: 0.5, minP: 0.05))
        #expect(String(decoding: try encoder.encode(custom), as: UTF8.self) == #"{"minP":0.05,"preset":"custom","temperature":0.5}"#)
        #expect(try JSONDecoder().decode(SamplingPreset.self, from: encoder.encode(custom)) == custom)
    }

    // MARK: Host names in remote mode

    @Test func newRemoteNamesNeedPrivateTrust() throws {
        let profile = ServerProfile.defaults(for: .vllm)
        #expect(throws: LLMServerConfig.Invalid.hostNameRequiresTrust("gpu.local")) {
            try F.config(.remote, "https://gpu.local/v1", profile: profile).validated()
        }
        #expect((try? F.config(.remote, "https://gpu.local/v1", pins: [F.serverPin], profile: profile).validated()) != nil)
        #expect((try? F.config(.remote, "https://gpu.local/v1", ca: F.testCA, profile: profile).validated()) != nil)
        #expect((try? F.config(.remote, "https://10.0.0.7/v1", profile: profile).validated()) != nil)
    }

    @Test func legacyRemoteNamesWarnInsteadOfFailing() {
        let legacy = F.config(.remote, "https://gpu.local:8443/v1")
        // Only an already saved config keeps working; pasting, editing or checking one without a profile needs the trust.
        #expect((try? legacy.validated(keepingLegacyNames: true)) != nil)
        #expect((try? legacy.validatedEndpoints(keepingLegacyNames: true)) != nil)
        #expect(throws: LLMServerConfig.Invalid.hostNameRequiresTrust("gpu.local")) { try legacy.validated() }
        #expect(throws: LLMServerConfig.Invalid.hostNameRequiresTrust("gpu.local")) { try LLMServerConfig.save(legacy, service: "unused") }
        #expect(legacy.securityWarnings == [.hostNameWithoutPinnedTrust("gpu.local")])
        #expect(F.config(.remote, "https://gpu.local/v1", pins: [F.serverPin]).securityWarnings.isEmpty)
        #expect(F.config(.remote, "https://10.0.0.7/v1").securityWarnings.isEmpty)
        #expect(F.config(.local, "http://localhost:1234/v1").securityWarnings.isEmpty)
    }

    // MARK: Endpoints

    @Test func caBundleKeepsEveryCertificate() throws {
        let bundle = F.testRSA + "\n" + F.testCA
        let endpoint = try F.config(.remote, "https://10.0.0.7/v1", ca: bundle).validated()
        #expect(endpoint.caDERs.count == 2)
        #expect(LLMServerConfig.ders(fromPEM: bundle).count == 2)
        #expect(LLMServerConfig.der(fromPEM: bundle) == LLMServerConfig.ders(fromPEM: F.testRSA).first)
        // A broken or unterminated certificate invalidates the bundle instead of being skipped.
        let broken = F.testCA + "\n-----BEGIN CERTIFICATE-----\n!!not base64!!\n-----END CERTIFICATE-----\n"
        #expect(LLMServerConfig.ders(fromPEM: broken).isEmpty)
        #expect(LLMServerConfig.ders(fromPEM: F.testCA + "\n-----BEGIN CERTIFICATE-----\nMIIB\n").isEmpty)
        #expect(throws: LLMServerConfig.Invalid.invalidCA) { try F.config(.remote, "https://10.0.0.7/v1", ca: broken).validated() }
    }

    @Test func roleBaseURLsFollowTheModeRules() throws {
        var config = F.config(.local, "http://127.0.0.1:8000/v1")
        config.roleBaseURLs = RoleBaseURLs(embedding: "http://127.0.0.1:8001/v1")
        let endpoints = try config.validatedEndpoints()
        #expect(endpoints[.fast]?.port == 8000 && endpoints[.deep]?.port == 8000 && endpoints[.embedding]?.port == 8001)
        config.roleBaseURLs = RoleBaseURLs(deep: "http://192.168.1.5:8000/v1")
        #expect(throws: LLMServerConfig.Invalid.localRequiresLoopback) { try config.validatedEndpoints() }
        config.roleBaseURLs = RoleBaseURLs(deep: "  ")
        #expect(try config.validatedEndpoints()[.deep]?.port == 8000)
    }

    @Test func nativeRootStripsV1() throws {
        let endpoint = try F.config(.local, "http://127.0.0.1:11434/v1", profile: .defaults(for: .ollama)).validated()
        #expect(endpoint.nativeRoot.absoluteString == "http://127.0.0.1:11434/")
        #expect(endpoint.nativePaths.contains("api/show"))
        let proxied = try F.config(.local, "http://127.0.0.1:9000/llm/v1", profile: .defaults(for: .llamaCpp)).validated()
        #expect(proxied.nativeRoot.absoluteString == "http://127.0.0.1:9000/llm/")
        #expect(proxied.nativePaths == ["props"])
    }

    @Test func embeddingDimensionsAreBounded() {
        let config = F.config(.local, "http://127.0.0.1:1234/v1", embedding: EmbeddingSettings(dimensions: 128))
        #expect(throws: LLMServerConfig.Invalid.invalidEmbeddingDimensions) { try config.validated() }
    }

    // MARK: Address parsing

    @Test func addressClassification() {
        #expect(ServerAddress.isLoopback("127.1.2.3") && ServerAddress.isLoopback("::1") && ServerAddress.isLoopback("::ffff:127.0.0.1"))
        #expect(!ServerAddress.isLoopback("127.0.0") && !ServerAddress.isLoopback("localhost.evil.com") && !ServerAddress.isLoopback("::2"))
        #expect(ServerAddress.isPrivateNetworkHost("fe80::1%en0") && ServerAddress.isPrivateNetworkHost("febf::1"))
        #expect(!ServerAddress.isPrivateNetworkHost("fec0::1") && !ServerAddress.isPrivateNetworkHost("fe00::1"))
        #expect(ServerAddress.isPrivateNetworkHost("169.254.1.1") && !ServerAddress.isPrivateNetworkHost("100.128.0.1"))
        #expect(ServerAddress.ip("1.2.3.4.5") == nil && ServerAddress.ip("256.0.0.1") == nil && ServerAddress.ip("1.2.3") == nil)
        #expect(ServerAddress.isPrivateOrLoopbackPeer("192.168.1.4") && !ServerAddress.isPrivateOrLoopbackPeer("93.184.216.34"))
        #expect(LLMClient.peerAllowed("127.0.0.1", mode: .local) && !LLMClient.peerAllowed("192.168.1.4", mode: .local))
        #expect(LLMClient.peerAllowed("10.0.0.7", mode: .remote) && !LLMClient.peerAllowed("8.8.8.8", mode: .remote))
    }

    @Test func onLinkPeers() throws {
        let v6 = try #require(ServerAddress.ip("2a01:db8:1:2::1"))
        let peer6 = try #require(ServerAddress.ip("2a01:db8:1:2:aaaa::7"))
        let other6 = try #require(ServerAddress.ip("2a01:db8:1:3::7"))
        let mask64 = try #require(ServerAddress.ip("ffff:ffff:ffff:ffff::"))
        #expect(ServerAddress.inSubnet(peer6, v6, mask: mask64) && !ServerAddress.inSubnet(other6, v6, mask: mask64))
        let v4 = try #require(ServerAddress.ip("203.0.113.10"))
        let mask24 = try #require(ServerAddress.ip("255.255.255.0"))
        #expect(ServerAddress.inSubnet(.v4([203, 0, 113, 99]), v4, mask: mask24))
        #expect(!ServerAddress.inSubnet(.v4([203, 0, 114, 99]), v4, mask: mask24))
        // A zero or very short mask never matches, and families never mix.
        #expect(!ServerAddress.inSubnet(.v4([8, 8, 8, 8]), v4, mask: .v4([0, 0, 0, 0])))
        #expect(!ServerAddress.inSubnet(peer6, v4, mask: mask24))
        // Remote mode accepts an on-link global peer, never loopback or a non-literal.
        #expect(LLMClient.peerAllowed("2a01:db8:1:2::7", mode: .remote, onLink: { _ in true }))
        #expect(!LLMClient.peerAllowed("2a01:db8:1:2::7", mode: .remote, onLink: { _ in false }))
        #expect(!LLMClient.peerAllowed("127.0.0.1", mode: .remote, onLink: { _ in true }))
        #expect(!LLMClient.peerAllowed("gpu.local", mode: .remote, onLink: { _ in true }))
        #expect(!LLMClient.peerAllowed("2a01:db8:1:2::7", mode: .local, onLink: { _ in true }))
        // The real interface table never makes a well-known public resolver on-link.
        #expect(!ServerAddress.isOnLink("8.8.8.8") && !ServerAddress.isOnLink("not-an-ip"))
    }

    @Test func onLinkAcceptanceIsIPv6Only() throws {
        // A Mac on a public IPv4 subnet (here a /8) does not make its neighbours acceptable peers.
        let subnets: [(address: ServerAddress.IP, mask: ServerAddress.IP)] = [
            (.v4([203, 0, 113, 10]), .v4([255, 0, 0, 0])),
            (try #require(ServerAddress.ip("2a01:db8:1:2::1")), try #require(ServerAddress.ip("ffff:ffff:ffff:ffff::"))),
        ]
        #expect(!ServerAddress.isOnLink("203.7.7.7", subnets: subnets))
        #expect(!ServerAddress.isOnLink("::ffff:203.7.7.7", subnets: subnets))
        #expect(ServerAddress.isOnLink("2a01:db8:1:2::7", subnets: subnets))
        #expect(!ServerAddress.isOnLink("2a01:db8:1:3::7", subnets: subnets))
        // Even when the interface check says yes, a public IPv4 peer (plain or mapped) is refused.
        #expect(!LLMClient.peerAllowed("203.7.7.7", mode: .remote, onLink: { _ in true }))
        #expect(!LLMClient.peerAllowed("::ffff:203.7.7.7", mode: .remote, onLink: { _ in true }))
        #expect(LLMClient.peerAllowed("::ffff:192.168.1.4", mode: .remote, onLink: { _ in false }))
        #expect(ServerAddress.isIPv6("2a01:db8::1") && !ServerAddress.isIPv6("::ffff:10.0.0.1") && !ServerAddress.isIPv6("10.0.0.1"))
    }
}
