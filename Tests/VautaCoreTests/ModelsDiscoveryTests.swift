// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Models: server discovery")
struct ModelsDiscoveryTests {
    typealias Path = ServerDiscovery.Path

    /// A fake server answering a fixed set of paths.
    private func fetcher(_ routes: [Path: Any]) -> ServerDiscovery.Fetch {
        let encoded = routes.mapValues { (try? JSONSerialization.data(withJSONObject: $0)) ?? Data() }
        return { path, _ in encoded[path] }
    }

    private func identify(_ routes: [Path: Any], hints: [ServerKind] = []) async -> DiscoveredServer? {
        await ServerDiscovery.identify(baseURL: URL(string: "http://127.0.0.1:1/v1/")!, hints: hints, fetch: fetcher(routes))
    }

    @Test func noModelListMeansNoServer() async {
        #expect(await identify([.native("api/version"): ["version": "1"]]) == nil)
    }

    @Test func lmStudio() async throws {
        let server = try #require(await identify([
            .openAI("models"): ["data": [["id": "qwen/qwen3-30b-a3b"], ["id": "text-embedding-nomic-embed-text-v1.5"]]],
            .native("api/v0/models"): ["data": [
                ["id": "qwen/qwen3-30b-a3b", "type": "llm", "state": "loaded", "max_context_length": 40960, "loaded_context_length": 32768],
                ["id": "google/gemma-3-4b", "type": "vlm", "state": "not-loaded", "max_context_length": 131072],
                ["id": "text-embedding-nomic-embed-text-v1.5", "type": "embeddings", "state": "not-loaded", "max_context_length": 2048],
            ]],
        ], hints: [.lmStudio]))
        #expect(server.kind == .lmStudio && server.models.count == 3)
        let qwen = try #require(server.models.first)
        #expect(qwen.kind == .chat && qwen.contextLength == 32768 && qwen.maxContextLength == 40960 && qwen.loaded == true)
        #expect(server.suggestedRoles == SuggestedRoles(fast: "google/gemma-3-4b", deep: "qwen/qwen3-30b-a3b",
                                                        embedding: "text-embedding-nomic-embed-text-v1.5"))
        let config = server.suggestedConfig()
        #expect(config.profile == .defaults(for: .lmStudio) && config.baseURL == "http://127.0.0.1:1/v1")
        #expect(config.contextTokens == 32768 && config.fastModel == "google/gemma-3-4b")
    }

    @Test func llamaCpp() async throws {
        let server = try #require(await identify([
            .openAI("models"): ["data": [["id": "gemma-3-12b-it-Q4_K_M.gguf", "owned_by": "llamacpp"]]],
            .native("props"): ["default_generation_settings": ["n_ctx": 16384], "model_path": "/models/gemma.gguf"],
        ], hints: [.llamaCpp, .localAI, .mlx]))
        #expect(server.kind == .llamaCpp && server.models.first?.contextLength == 16384 && server.models.first?.kind == .unknown)
        #expect(server.suggestedRoles.deep == "gemma-3-12b-it-Q4_K_M.gguf" && server.suggestedRoles.embedding == nil)
    }

    @Test func vllm() async throws {
        let server = try #require(await identify([
            .openAI("models"): ["data": [["id": "Qwen/Qwen3-32B-AWQ", "owned_by": "vllm", "max_model_len": 32768]]],
            .native("version"): ["version": "0.11.0"],
        ], hints: [.vllm]))
        #expect(server.kind == .vllm && server.version == "0.11.0" && server.models.first?.contextLength == 32768)
    }

    @Test func localAIAndMLXAndJanAndGeneric() async throws {
        let localAI = try #require(await identify([.openAI("models"): ["data": [["id": "phi-4"]]], .native("version"): ["version": "v2.29.0"]],
                                                  hints: [.llamaCpp, .localAI, .mlx]))
        #expect(localAI.kind == .localAI)
        let mlx = try #require(await identify([.openAI("models"): ["data": [["id": "mlx-community/Qwen3-8B-4bit"]]]],
                                              hints: [.llamaCpp, .localAI, .mlx]))
        #expect(mlx.kind == .mlx)
        let jan = try #require(await identify([.openAI("models"): ["data": [["id": "llama3.2-3b-instruct"]]]], hints: [.jan]))
        #expect(jan.kind == .jan)
        let generic = try #require(await identify([.openAI("models"): ["data": [["id": "x"]]]]))
        #expect(generic.kind == .openAICompatible)
    }

    @Test func ollamaWithLoadedContext() async throws {
        let server = try #require(await identify([
            .openAI("models"): ["data": [["id": "qwen3:30b-a3b"], ["id": "qwen3:4b"], ["id": "embeddinggemma"]]],
            .native("api/version"): ["version": "0.12.0"],
            .native("api/tags"): ["models": [["name": "qwen3:30b-a3b", "details": ["parameter_size": "30.5B"]],
                                             ["name": "qwen3:4b", "details": ["parameter_size": "4.0B"]],
                                             ["name": "embeddinggemma", "details": ["parameter_size": "307M"]]]],
            .native("api/ps"): ["models": [["name": "qwen3:4b", "context_length": 8192]]],
        ], hints: [.ollama]))
        #expect(server.kind == .ollama)
        #expect(server.models.first { $0.id == "qwen3:4b" }?.contextLength == 8192)
        #expect(server.models.first { $0.id == "qwen3:4b" }?.loaded == true)
        #expect(server.models.first { $0.id == "qwen3:30b-a3b" }?.loaded == false)
        // Without /api/show answers the kind comes from the name.
        #expect(server.suggestedRoles == SuggestedRoles(fast: "qwen3:4b", deep: "qwen3:30b-a3b", embedding: "embeddinggemma"))
    }

    @Test func embeddingPreference() {
        let models = ["mxbai-embed-large", "bge-m3", "text-embedding-qwen3-embedding-0.6b", "all-minilm"].map {
            DiscoveredModel(id: $0, kind: .embedding)
        }
        #expect(ServerDiscovery.suggestRoles(models).embedding == "text-embedding-qwen3-embedding-0.6b")
        #expect(ServerDiscovery.suggestRoles(Array(models.prefix(2))).embedding == "bge-m3")
        #expect(ServerDiscovery.suggestRoles(Array(models.prefix(2))).deep == nil)
    }

    @Test func nameHeuristics() {
        #expect(ServerDiscovery.parameterBillions(fromName: "qwen3:30b-a3b") == 30)
        #expect(ServerDiscovery.parameterBillions(fromName: "google/gemma-3-27b-it") == 27)
        #expect(ServerDiscovery.parameterBillions(fromName: "Qwen3-4B-MLX-4bit") == 4)
        #expect(ServerDiscovery.parameterBillions(fromName: "llama3.2:3b") == 3)
        #expect(ServerDiscovery.parameterBillions(fromName: "bge-m3") == nil)
        #expect(ServerDiscovery.parameterBillions(fromSize: "567M") == 0.567)
        #expect(ServerDiscovery.kindFromName("nomic-embed-text") == .embedding && ServerDiscovery.kindFromName("BAAI/bge-m3") == .embedding)
        #expect(ServerDiscovery.kindFromName("qwen3:8b") == .unknown)
    }

    @Test func loopbackScanFindsServersOnKnownPorts() async {
        // The stub intercepts every request: no socket is opened.
        StubServer.register(port: 11434) { r in
            switch r.url.path() {
            case "/v1/models": .json(["data": [["id": "qwen3:8b"]]])
            case "/api/version": .json(["version": "0.12.0"])
            case "/api/tags": .json(["models": [["name": "qwen3:8b"]]])
            default: nil
            }
        }
        StubServer.register(port: 1234) { r in r.url.path() == "/v1/models" ? .json(["data": [["id": "m"]]]) : nil }
        defer {
            StubServer.unregister(11434)
            StubServer.unregister(1234)
        }
        let session = ServerDiscovery.loopbackSession(timeout: 1, protocolClasses: [StubServer.self])
        let servers = await ServerDiscovery.scanLoopback(session: session, timeout: 1)
        #expect(servers.map(\.kind) == [.lmStudio, .ollama])
        #expect(servers.allSatisfy { $0.baseURL.host() == "127.0.0.1" })
    }

    @Test func userTypedURLsMustBeLoopback() async {
        #expect(await ServerDiscovery.inspectLoopback(baseURL: "http://192.168.1.10:1234/v1") == nil)
        #expect(await ServerDiscovery.inspectLoopback(baseURL: "https://127.0.0.1:1234/v1") == nil)
        #expect(await ServerDiscovery.inspectLoopback(baseURL: "http://example.com/v1") == nil)
    }

    @Test func answersPastTheCapAreDropped() async {
        let big = Data(repeating: UInt8(ascii: "a"), count: 4096)
        let port = StubServer.register { r in
            switch r.url.path() {
            case "/v1/models": StubServer.Reply(headers: ["Content-Type": "application/json"], body: big)   // no length: read until the cap
            case "/api/tags": StubServer.Reply(headers: ["Content-Type": "application/json", "Content-Length": "4096"], body: big)
            case "/api/version": StubServer.Reply(body: Data(#"{"version":"1"}"#.utf8))
            default: nil
            }
        }
        defer { StubServer.unregister(port) }
        let session = ServerDiscovery.loopbackSession(timeout: 5, protocolClasses: [StubServer.self])
        defer { session.invalidateAndCancel() }
        let fetch = ServerDiscovery.loopbackFetch(session: session, root: URL(string: "http://127.0.0.1:\(port)/")!, timeout: 5, maxBytes: 1024)
        #expect(await fetch(.openAI("models"), nil) == nil)
        #expect(await fetch(.native("api/tags"), nil) == nil)
        #expect(await fetch(.native("api/version"), nil) == Data(#"{"version":"1"}"#.utf8))
    }
}
