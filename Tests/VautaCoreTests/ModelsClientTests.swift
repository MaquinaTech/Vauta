// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// End-to-end client behaviour against an in-process stub server.
@Suite("Models: client")
struct ModelsClientTests {
    typealias F = ModelsFixtures
    typealias Reply = StubServer.Reply

    @discardableResult
    private func withServer<T>(_ handler: @escaping StubServer.Handler, _ body: (Int) async throws -> T) async throws -> T {
        let port = StubServer.register(handler)
        defer { StubServer.unregister(port) }
        return try await body(port)
    }

    @Test func modelsList() async throws {
        let ids = try await withServer({ r in
            r.url.path() == "/v1/models" ? .json(["object": "list", "data": [["id": "a"], ["id": "b"]]]) : nil
        }) { port in try await F.client(port: port).models() }
        #expect(ids == ["a", "b"])
    }

    @Test func modelsListIncludesEveryRoleURL() async throws {
        let main = StubServer.register { _ in .json(["object": "list", "data": [["id": "chat-a"], ["id": "shared"]]]) }
        let other = StubServer.register { _ in .json(["object": "list", "data": [["id": "embed-b"], ["id": "shared"]]]) }
        defer { StubServer.unregister(main); StubServer.unregister(other) }
        var config = F.config(.local, "http://127.0.0.1:\(main)/v1")
        config.roleBaseURLs = RoleBaseURLs(embedding: "http://127.0.0.1:\(other)/v1")
        let client = LLMClient(config: config, bearer: { nil }, protocolClasses: [StubServer.self])
        #expect(try await client.allModels() == ["chat-a", "shared", "embed-b"])
        #expect(try await client.models() == ["chat-a", "shared"])
    }

    @Test func emptyEmbeddingModelOnlyFailsEmbeddingCalls() async throws {
        let config = F.config(.local, "http://127.0.0.1:1234/v1", embeddingModel: "")
        let client = LLMClient(config: config, bearer: { nil }, protocolClasses: [StubServer.self])
        #expect(client.isConfigured)
        await #expect(throws: LLMError.notConfigured) { try await client.embed(["x"]) }
    }

    @Test func streamingChat() async throws {
        let progress = Counter()
        let result = try await withServer({ _ in
            // Leading reasoning in the content is not part of the answer.
            .text(F.sse([F.delta("<think>no</think>")] + (0..<39).map { _ in F.delta("x") } + [F.delta("x", finish: "stop"), F.usage]))
        }) { port in
            try await F.client(port: port).chat([.user("q")], ChatOptions(model: .deep, maxTokens: 50)) { n in progress.set(n) }
        }
        #expect(result.content == String(repeating: "x", count: 40))
        #expect(result.finishReason == .stop && !result.isTruncated)
        #expect(result.promptTokens == 120 && result.cachedTokens == 100 && result.completionTokens == 7)
        #expect(progress.value == 32)
    }

    @Test func truncationIsReportedOrThrown() async throws {
        let handler: StubServer.Handler = { _ in .text(F.sse([F.delta("{\"a\":", finish: "length")])) }
        try await withServer(handler) { port in
            let client = F.client(port: port)
            let result = try await client.chat([.user("q")], ChatOptions(model: .fast, maxTokens: 5))
            #expect(result.isTruncated && result.content == "{\"a\":")
            await #expect(throws: LLMError.outputTruncated) {
                try await client.chat([.user("q")], ChatOptions(model: .fast, maxTokens: 5, failOnTruncation: true))
            }
        }
    }

    @Test func serverIgnoringStreamTrue() async throws {
        let result = try await withServer({ _ in
            .json(["object": "chat.completion", "choices": [["message": ["role": "assistant", "content": "plain"], "finish_reason": "stop"]],
                   "usage": ["prompt_tokens": 3, "completion_tokens": 1]])
        }) { port in try await F.client(port: port).chat([.user("q")], ChatOptions(model: .fast, maxTokens: 5)) }
        #expect(result.content == "plain" && result.promptTokens == 3 && result.finishReason == .stop)
    }

    @Test func errorStatusesCarryTheServerMessage() async throws {
        let cases: [(Reply, LLMError)] = [
            (.json(["error": ["message": "prompt is too long for n_ctx 4096"]], status: 400), .contextLengthExceeded(message: "prompt is too long for n_ctx 4096")),
            (.json(["error": ["message": "model 'x' not found", "code": "model_not_found"]], status: 404), .modelNotFound(message: "model 'x' not found")),
            (.json(["detail": "Invalid request"], status: 400), .http(400, message: "Invalid request")),
            (Reply(status: 503, headers: ["Retry-After": "42"], body: Data()), .busy(retryAfter: 42)),
            (Reply(status: 401), .unauthorized),
        ]
        for (reply, expected) in cases {
            try await withServer({ _ in reply }) { port in
                await #expect(throws: expected) { try await F.client(port: port).chat([.user("q")], ChatOptions(model: .fast, maxTokens: 5)) }
            }
        }
    }

    @Test func midStreamErrorEvent() async throws {
        try await withServer({ _ in .text(F.sse([F.delta("a")], done: false) + "event: error\ndata: {\"error\":{\"message\":\"engine died\"}}\n\n") }) { port in
            await #expect(throws: LLMError.server(message: "engine died")) {
                try await F.client(port: port).chat([.user("q")], ChatOptions(model: .fast, maxTokens: 5))
            }
        }
    }

    @Test func authorizationHeaderReachesTheServer() async throws {
        try await withServer({ _ in .json(["data": []]) }) { port in
            _ = try await F.client(port: port, bearer: { "sk-123" }).models()
            #expect(StubServer.requests(port).first?.headers["Authorization"] == "Bearer sk-123")
        }
    }

    // MARK: Embeddings

    private static func embeddings(dims: Int, count: Int = 2, base64: Bool = false) -> StubServer.Handler {
        { request in
            let inputs = request.json?["input"] as? [String] ?? []
            let data = inputs.prefix(count).enumerated().reversed().map { i, _ -> [String: Any] in
                let v = (0..<dims).map { Float($0 + i) }
                if base64 {
                    let bytes = v.withUnsafeBufferPointer { Data(buffer: $0) }
                    return ["index": i, "embedding": bytes.base64EncodedString()]
                }
                return ["index": i, "embedding": v]
            }
            return .json(["object": "list", "data": data])
        }
    }

    @Test func legacyEmbeddingsTruncateTo1024() async throws {
        try await withServer(Self.embeddings(dims: 2560)) { port in
            let vectors = try await F.client(port: port).embed(["a", "b"])
            #expect(vectors.count == 2 && vectors.allSatisfy { $0.count == 1024 } && vectors[1][0] == 1)
            #expect(StubServer.requests(port).first?.json?["encoding_format"] == nil)
        }
    }

    @Test func profiledEmbeddingsKeepNativeDimsForNonMatryoshka() async throws {
        try await withServer(Self.embeddings(dims: 768)) { port in
            let client = F.client(port: port, profile: .defaults(for: .ollama), embeddingModel: "bge-m3")
            let batch = try await client.embed(["a", "b"], purpose: .document)
            #expect(batch.space == EmbeddingSpace(model: "bge-m3", dimensions: 768))
            #expect(StubServer.requests(port).first?.json?["encoding_format"] as? String == "float")
        }
        try await withServer(Self.embeddings(dims: 4096)) { port in
            let client = F.client(port: port, profile: .defaults(for: .vllm), embeddingModel: "intfloat/e5-mistral-7b")
            let batch = try await client.embed(["a", "b"], purpose: .document)
            #expect(batch.space.dimensions == 4096)
        }
    }

    @Test func matryoshkaModelsAreTruncatedToTheSetting() async throws {
        try await withServer(Self.embeddings(dims: 2560)) { port in
            let qwen = F.client(port: port, profile: .defaults(for: .lmStudio), embeddingModel: "text-embedding-qwen3-embedding-4b")
            let full = try await qwen.embed(["a", "b"], purpose: .document)
            #expect(full.space.dimensions == 1024)
            let custom = F.client(port: port, profile: .defaults(for: .lmStudio), embedding: EmbeddingSettings(dimensions: 512),
                                  embeddingModel: "text-embedding-qwen3-embedding-4b")
            let short = try await custom.embed(["a", "b"], purpose: .document)
            #expect(short.space.dimensions == 512)
        }
    }

    @Test func queryPrefixesAreApplied() async throws {
        try await withServer(Self.embeddings(dims: 768, count: 1)) { port in
            let client = F.client(port: port, profile: .defaults(for: .ollama), embeddingModel: "nomic-embed-text")
            _ = try await client.embed(["what was decided?"], purpose: .query)
            #expect(StubServer.requests(port).first?.json?["input"] as? [String] == ["search_query: what was decided?"])
        }
    }

    @Test func base64EmbeddingsAndTooSmallVectors() async throws {
        try await withServer(Self.embeddings(dims: 300, base64: true)) { port in
            let batch = try await F.client(port: port, profile: .defaults(for: .vllm), embeddingModel: "bge-m3").embed(["a", "b"], purpose: .document)
            #expect(batch.vectors[0][299] == 299 && batch.vectors[1][0] == 1)
        }
        try await withServer(Self.embeddings(dims: 128)) { port in
            await #expect(throws: LLMError.embeddingDimensions(128, minimum: 1024)) { try await F.client(port: port).embed(["a", "b"]) }
        }
        try await withServer(Self.embeddings(dims: 512, count: 1)) { port in
            await #expect(throws: LLMError.invalidResponse("embeddings")) { try await F.client(port: port).embed(["a", "b"]) }
        }
    }

    @Test func reembeddingDecision() {
        let space = EmbeddingSpace(model: "bge-m3", dimensions: 1024)
        #expect(!space.requiresReembedding(storedModel: "bge-m3", storedDimensions: 1024))
        #expect(space.requiresReembedding(storedModel: "bge-m3", storedDimensions: 768))
        #expect(space.requiresReembedding(storedModel: "mxbai-embed-large", storedDimensions: 1024))
    }

    // MARK: Inspection of the configured server

    @Test func inspectConfiguredOllama() async throws {
        try await withServer({ r in
            switch r.url.path() {
            case "/v1/models": .json(["data": [["id": "qwen3:8b"], ["id": "bge-m3"]]])
            case "/api/version": .json(["version": "0.12.3"])
            case "/api/tags": .json(["models": [["name": "qwen3:8b", "details": ["parameter_size": "8.2B"]], ["name": "bge-m3"]]])
            case "/api/show":
                (r.json?["model"] as? String) == "bge-m3"
                    ? .json(["capabilities": ["embedding"], "model_info": ["bert.context_length": 8192]])
                    : .json(["capabilities": ["completion", "thinking"], "model_info": ["qwen3.context_length": 40960],
                             "parameters": "num_ctx 16384\ntemperature 0.6"])
            default: nil
            }
        }) { port in
            let server = try await F.client(port: port, profile: .defaults(for: .ollama)).inspect()
            #expect(server.kind == .ollama && server.version == "0.12.3")
            let qwen = try #require(server.models.first { $0.id == "qwen3:8b" })
            #expect(qwen.kind == .chat && qwen.contextLength == 16384 && qwen.maxContextLength == 40960 && qwen.parameterBillions == 8.2)
            #expect(server.models.first { $0.id == "bge-m3" }?.kind == .embedding)
            #expect(server.suggestedRoles == SuggestedRoles(fast: "qwen3:8b", deep: "qwen3:8b", embedding: "bge-m3"))
            #expect(StubServer.requests(port).allSatisfy { $0.url.host() == "127.0.0.1" && $0.url.port == port })
        }
    }

    @Test func inspectDoesNotProbeOtherPathsForAKnownKind() async throws {
        try await withServer({ r in r.url.path() == "/v1/models" ? .json(["data": [["id": "mlx-community/Qwen3-4B-4bit"]]]) : nil }) { port in
            let server = try await F.client(port: port, profile: .defaults(for: .mlx)).inspect()
            #expect(server.kind == .mlx)
            #expect(StubServer.requests(port).allSatisfy { $0.url.path().hasPrefix("/v1/") })
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func set(_ v: Int) { lock.withLock { _value = max(_value, v) } }
}
