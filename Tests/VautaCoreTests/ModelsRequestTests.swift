// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Models: requests")
struct ModelsRequestTests {
    typealias F = ModelsFixtures
    let messages = [ChatMessage.system("sys"), .user("hola")]

    private func body(_ profile: ServerProfile, _ options: ChatOptions) throws -> [String: Any] {
        let data = try ServerRequests.chatBody(model: "m", messages: messages, options: options, profile: profile)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The body Acta 0.1.x sent, field by field (its key order was random; numbers
    /// are serialised by JSONSerialization exactly as before).
    @Test func legacyBodyWithoutThinkingIsUnchanged() throws {
        let data = try ServerRequests.chatBody(model: "m", messages: messages, options: ChatOptions(model: .fast, maxTokens: 500),
                                               profile: .legacy)
        let expected = #"{"enable_thinking":false,"max_tokens":500,"messages":[{"content":"sys","role":"system"},{"content":"hola","role":"user"}],"model":"m","stream":true,"stream_options":{"include_usage":true},"temperature":0.69999999999999996,"top_k":20,"top_p":0.80000000000000004}"#
        #expect(String(decoding: data, as: UTF8.self) == expected)
        let legacy: NSDictionary = [
            "model": "m", "messages": [["role": "system", "content": "sys"], ["role": "user", "content": "hola"]],
            "max_tokens": 500, "stream": true, "stream_options": ["include_usage": true], "enable_thinking": false,
            "temperature": 0.7, "top_p": 0.8, "top_k": 20,
        ]
        #expect(NSDictionary(dictionary: try body(.legacy, ChatOptions(model: .fast, maxTokens: 500))) == legacy)
    }

    @Test func legacyBodyWithThinkingIsUnchanged() throws {
        let data = try ServerRequests.chatBody(model: "m", messages: messages,
                                               options: ChatOptions(model: .deep, maxTokens: 10_000, thinking: true, reasoningEffort: "low"),
                                               profile: .legacy)
        let expected = #"{"enable_thinking":true,"max_tokens":10000,"messages":[{"content":"sys","role":"system"},{"content":"hola","role":"user"}],"model":"m","reasoning_effort":"low","stream":true,"stream_options":{"include_usage":true}}"#
        #expect(String(decoding: data, as: UTF8.self) == expected)
    }

    @Test func legacyClientSendsTheLegacyBody() async throws {
        let port = StubServer.register { _ in .text(F.sse([F.delta("{}", finish: "stop")])) }
        defer { StubServer.unregister(port) }
        _ = try await F.client(port: port).chat(messages, ChatOptions(model: .fast, maxTokens: 500))
        let sent = try #require(StubServer.requests(port).first)
        #expect(sent.url.absoluteString == "http://127.0.0.1:\(port)/v1/chat/completions")
        let expected = #"{"enable_thinking":false,"max_tokens":500,"messages":[{"content":"sys","role":"system"},{"content":"hola","role":"user"}],"model":"fast-model","stream":true,"stream_options":{"include_usage":true},"temperature":0.69999999999999996,"top_k":20,"top_p":0.80000000000000004}"#
        #expect(sent.body.map { String(decoding: $0, as: UTF8.self) } == expected)
    }

    @Test func thinkingControls() throws {
        let off = ChatOptions(model: .fast, maxTokens: 10)
        let on = ChatOptions(model: .deep, maxTokens: 10, thinking: true, reasoningEffort: "high")
        func profile(_ t: ThinkingControl) -> ServerProfile { ServerProfile(kind: .openAICompatible, thinking: t, structuredOutput: .none) }

        let kwargsOff = try body(profile(.chatTemplateKwargs), off)
        #expect(kwargsOff["chat_template_kwargs"] as? [String: Bool] == ["enable_thinking": false] && kwargsOff["enable_thinking"] == nil)
        #expect(try body(profile(.chatTemplateKwargs), on)["reasoning_effort"] as? String == "high")

        #expect(try body(profile(.reasoningEffort), off)["reasoning_effort"] as? String == "low")
        #expect(try body(profile(.reasoningEffort), on)["reasoning_effort"] as? String == "high")

        let ollamaOff = try body(profile(.ollamaThink), off)
        #expect(ollamaOff["think"] as? Bool == false && ollamaOff["reasoning_effort"] as? String == "none")
        #expect(try body(profile(.ollamaThink), on)["think"] as? Bool == true)

        let none = try body(profile(.none), on)
        #expect(none["enable_thinking"] == nil && none["chat_template_kwargs"] == nil && none["reasoning_effort"] == nil && none["think"] == nil)
        #expect(none["temperature"] == nil && none["top_k"] == nil)
    }

    @Test func samplingPresets() throws {
        let off = ChatOptions(model: .fast, maxTokens: 10)
        let on = ChatOptions(model: .fast, maxTokens: 10, thinking: true)
        let qwen = ServerProfile(kind: .vllm, thinking: .chatTemplateKwargs, sampling: .qwenNonThinking, structuredOutput: .none)
        #expect(try body(qwen, off)["top_k"] as? Int == 20)
        #expect(try body(qwen, on)["temperature"] == nil)
        let custom = ServerProfile(kind: .vllm, thinking: .none, sampling: .custom(SamplingParameters(temperature: 0.3, minP: 0.1)),
                                   structuredOutput: .none)
        let b = try body(custom, on)
        #expect(b["temperature"] as? Double == 0.3 && b["min_p"] as? Double == 0.1 && b["top_p"] == nil)
    }

    @Test func aMessageThatIsTheSchemaMarkerIsNotTakenForTheSchema() throws {
        let schema = Data(#"{"type":"object","properties":{"found":{"type":"boolean"}}}"#.utf8)
        let options = ChatOptions(model: .deep, maxTokens: 10, responseFormat: .jsonSchema(name: "answer", schema: schema))
        let profile = ServerProfile(kind: .openAICompatible, thinking: .none, structuredOutput: .jsonSchema)
        let data = try ServerRequests.chatBody(model: "m", messages: [.user("@@vauta-schema@@")], options: options, profile: profile)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""content":"@@vauta-schema@@""#), "the message is untouched")
        let parsed = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let spec = try #require((parsed["response_format"] as? [String: Any])?["json_schema"] as? [String: Any])
        #expect((spec["schema"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test func responseFormats() throws {
        let schema = Data(#"{"type":"object","properties":{"title":{"type":"string"}}}"#.utf8)
        let withSchema = ChatOptions(model: .deep, maxTokens: 10, responseFormat: .jsonSchema(name: "minutes", schema: schema))
        let withObject = ChatOptions(model: .deep, maxTokens: 10, responseFormat: .jsonObject)
        func profile(_ s: StructuredOutputSupport) -> ServerProfile { ServerProfile(kind: .openAICompatible, thinking: .none, structuredOutput: s) }

        let full = try #require(try body(profile(.jsonSchema), withSchema)["response_format"] as? [String: Any])
        let spec = try #require(full["json_schema"] as? [String: Any])
        #expect(full["type"] as? String == "json_schema" && spec["name"] as? String == "minutes" && spec["strict"] as? Bool == true)
        #expect((spec["schema"] as? [String: Any])?["type"] as? String == "object")

        #expect((try body(profile(.jsonObject), withSchema)["response_format"] as? [String: String]) == ["type": "json_object"])
        #expect(((try body(profile(.jsonSchema), withObject)["response_format"] as? [String: Any])?["type"] as? String) == "json_schema")
        #expect(try body(profile(.none), withSchema)["response_format"] == nil)
        #expect(try body(.legacy, withSchema)["response_format"] == nil)
    }

    @Test func embeddingsBody() throws {
        let legacy = try ServerRequests.embeddingsBody(model: "e", inputs: ["a"], legacy: true)
        #expect(String(decoding: legacy, as: UTF8.self) == #"{"input":["a"],"model":"e"}"#)
        let current = try ServerRequests.embeddingsBody(model: "e", inputs: ["a"], legacy: false)
        #expect(String(decoding: current, as: UTF8.self) == #"{"encoding_format":"float","input":["a"],"model":"e"}"#)
    }

    // MARK: Destinations and headers

    @Test func requestsStayOnTheConfiguredServer() throws {
        let lan = try F.config(.remote, "https://192.168.1.50:8443/v1").validated()
        for bad in ["https://192.168.1.51:8443/v1/models", "https://192.168.1.50:443/v1/models", "http://192.168.1.50:8443/v1/models",
                    "https://evil.example/v1/models", "https://user:pw@192.168.1.50:8443/v1/models", "https://192.168.1.50:8443/admin",
                    "https://192.168.1.50:8443/api/pull", "https://192.168.1.50:8443/v2/models"] {
            #expect(throws: LLMError.self) { try LLMClient.requireAllowed(URL(string: bad)!, lan) }
        }
        try LLMClient.requireAllowed(URL(string: "https://192.168.1.50:8443/v1/chat/completions")!, lan)
    }

    @Test func nativePathsOnlyForTheProfile() throws {
        let ollama = try F.config(.local, "http://127.0.0.1:11434/v1", profile: .defaults(for: .ollama)).validated()
        try LLMClient.requireAllowed(URL(string: "http://127.0.0.1:11434/api/tags")!, ollama)
        try LLMClient.requireAllowed(URL(string: "http://127.0.0.1:11434/api/show")!, ollama)
        for bad in ["http://127.0.0.1:11434/api/pull", "http://127.0.0.1:11434/api/delete", "http://127.0.0.1:11434/props",
                    "http://127.0.0.1:11435/api/tags", "https://127.0.0.1:11434/api/tags"] {
            #expect(throws: LLMError.self) { try LLMClient.requireAllowed(URL(string: bad)!, ollama) }
        }
        let mlx = try F.config(.local, "http://127.0.0.1:8080/v1", profile: .defaults(for: .mlx)).validated()
        #expect(throws: LLMError.self) { try LLMClient.requireAllowed(URL(string: "http://127.0.0.1:8080/props")!, mlx) }
    }

    @Test func requestURLAndAuthorization() throws {
        let unconfigured = LLMClient(config: nil, bearer: { "sk-test" })
        #expect(throws: LLMError.notConfigured) { try unconfigured.makeRequest(.models, body: nil) }
        let withKey = LLMClient(config: F.config(.remote, "https://192.168.1.50:8443/v1"), bearer: { "sk-test" })
        let request = try withKey.makeRequest(.chat, body: Data("{}".utf8))
        #expect(request.url?.absoluteString == "https://192.168.1.50:8443/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test" && request.httpMethod == "POST")
        let noKey = LLMClient(config: F.config(.local, "http://127.0.0.1:1234/v1"), bearer: { nil })
        let anonymous = try noKey.makeRequest(.models, body: nil)
        #expect(anonymous.url?.absoluteString == "http://127.0.0.1:1234/v1/models" && anonymous.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func roleRequestsUseTheRoleURL() throws {
        var config = F.config(.local, "http://127.0.0.1:8000/v1")
        config.roleBaseURLs = RoleBaseURLs(embedding: "http://127.0.0.1:8001/v1")
        let client = LLMClient(config: config, bearer: { nil })
        #expect(try client.makeRequest(.embeddings, role: .embedding, body: Data()).url?.port == 8001)
        #expect(try client.makeRequest(.chat, role: .deep, body: Data()).url?.port == 8000)
        #expect(try client.makeRequest(.models, body: nil).url?.port == 8000)
    }

    @Test func storedTokenProblemsHaveTheirOwnErrors() {
        let badToken = LLMClient(config: F.config(.local, "http://127.0.0.1:1234/v1"), bearer: { "with space" })
        #expect(throws: LLMError.invalidStoredToken) { try badToken.makeRequest(.models, body: nil) }
        let locked = LLMClient(config: F.config(.local, "http://127.0.0.1:1234/v1"), bearer: { throw StoreError(.keychainUnavailable, detail: "locked") })
        #expect(throws: LLMError.keychainUnavailable) { try locked.makeRequest(.models, body: nil) }
        #expect(LLMError.keychainUnavailable.isRetryable && !LLMError.invalidStoredToken.isRetryable)
        #expect(LLMError.invalidStoredToken.needsConfiguration)
    }

    @Test func tokenValidation() {
        #expect(!LLMClient.isValidToken("with space") && !LLMClient.isValidToken("newline\n") && LLMClient.isValidToken("abc-123_XYZ"))
        #expect(!LLMClient.isValidToken(String(repeating: "a", count: 513)))
    }

    @Test func thinkingIsStripped() {
        #expect(LLMClient.strippingThinking("<think>reasoning\n{x}</think>\n{\"a\":1}") == "{\"a\":1}")
        #expect(LLMClient.strippingThinking("thinking…</think>{}") == "{}")
        #expect(LLMClient.strippingThinking("<think>no end") == "")
        #expect(LLMClient.strippingThinking("{\"b\":2}") == "{\"b\":2}")
    }
}
