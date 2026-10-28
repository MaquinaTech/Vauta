// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Models: stream parsing and error bodies")
struct ModelsStreamTests {
    private func parse(_ text: String) throws -> ChatStreamParser {
        var parser = ChatStreamParser()
        for line in text.components(separatedBy: "\n") {
            if try !parser.consume(line) { break }
        }
        try parser.finish()
        return parser
    }

    @Test func standardStream() throws {
        let p = try parse(ModelsFixtures.sse([ModelsFixtures.delta("Hel"), ModelsFixtures.delta("lo", finish: "stop"), ModelsFixtures.usage]))
        #expect(p.content == "Hello" && p.finishReason == .stop && p.done)
        #expect(p.promptTokens == 120 && p.cachedTokens == 100 && p.completionTokens == 7)
    }

    @Test func streamWithoutBlankLinesOrDone() throws {
        let text = #"data: {"choices":[{"delta":{"content":"a"}}]}"# + "\n" + #"data: {"choices":[{"delta":{"content":"b"},"finish_reason":"length"}]}"#
        let p = try parse(text)
        #expect(p.content == "ab" && p.finishReason == .length)
    }

    @Test func multiLineDataEventsAndComments() throws {
        let text = ": keep-alive\nevent: message\ndata: {\"choices\":[{\"delta\":\ndata: {\"content\":\"x\"}}]}\n\nid: 7\nretry: 100\ndata: [DONE]\n"
        #expect(try parse(text).content == "x")
    }

    @Test func reasoningCountsAsProgressOnly() throws {
        let chunks: [Any] = [["choices": [["delta": ["reasoning_content": "hmm"]]]], ["choices": [["delta": ["reasoning": "…"]]]],
                             ModelsFixtures.delta("ok")]
        let p = try parse(ModelsFixtures.sse(chunks))
        #expect(p.content == "ok" && p.produced == 3)
    }

    @Test func errorPayloadInTheStream() throws {
        let text = ModelsFixtures.sse([ModelsFixtures.delta("par")], done: false) + #"data: {"error":{"message":"CUDA out of memory","type":"server_error"}}"# + "\n\n"
        #expect(throws: LLMError.server(message: "CUDA out of memory")) { try parse(text) }
    }

    @Test func errorEvent() throws {
        let text = "event: error\ndata: {\"message\":\"the request exceeds the available context size\"}\n\n"
        #expect(throws: LLMError.contextLengthExceeded(message: "the request exceeds the available context size")) { try parse(text) }
        #expect(throws: LLMError.server(message: "boom")) { try parse("event: error\ndata: boom\n\n") }
    }

    @Test func nonStreamedJSONFallback() throws {
        let body = """
            {"id":"x","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"{\\"a\\":1}",
            "reasoning_content":"..."},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":3}}
            """
        let p = try parse(body)
        #expect(p.content == #"{"a":1}"# && p.finishReason == .stop && p.promptTokens == 5 && p.completionTokens == 3)
        #expect(throws: LLMError.self) { try parse(#"{"error":{"message":"bad model"}}"#) }
    }

    @Test func llamaCppCacheTimings() throws {
        let chunk: [String: Any] = ["choices": [["delta": ["content": "x"], "finish_reason": "stop"]], "timings": ["cache_n": 42]]
        #expect(try parse(ModelsFixtures.sse([chunk])).cachedTokens == 42)
    }

    @Test func largeMalformedStreamsFinishQuickly() throws {
        // Many partial `data:` lines with no blank line, and a long plain body: each line is handled once.
        let start = ContinuousClock.now
        var parser = ChatStreamParser()
        for _ in 0..<50_000 { _ = try parser.consume(#"data: {"choices":[{"delta":"#) }
        try parser.finish()
        #expect(parser.content.isEmpty)
        var plain = ChatStreamParser()
        _ = try plain.consume("{")
        for _ in 0..<200_000 { _ = try plain.consume(#""k": 1,"#) }
        #expect(throws: LLMError.invalidResponse("not a chat completion")) { try plain.finish() }
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func pendingDataIsCapped() throws {
        var parser = ChatStreamParser(maxPendingBytes: 1024)
        #expect(throws: LLMError.tooLarge) {
            for _ in 0..<200 { _ = try parser.consume("data: " + String(repeating: "x", count: 20)) }
        }
    }

    @Test func aPartialPayloadThenOneLineObjectsStillWork() throws {
        let text = "data: {\"choices\":\n" + #"data: {"choices":[{"delta":{"content":"a"}}]}"# + "\n"
            + #"data: {"choices":[{"delta":{"content":"b"},"finish_reason":"stop"}]}"#
        let p = try parse(text)
        #expect(p.content == "ab" && p.finishReason == .stop)
    }

    @Test func finishReasons() {
        #expect(FinishReason("length") == .length && FinishReason("stop") == .stop && FinishReason("eos") == .stop)
        #expect(FinishReason("tool_calls") == .toolCalls && FinishReason("weird") == .other("weird"))
    }

    // MARK: Error bodies

    @Test func errorBodiesBecomeUsefulErrors() {
        func error(_ status: Int, _ body: String, retryAfter: String? = nil) -> LLMError {
            ServerErrorBody.error(status: status, body: Data(body.utf8), retryAfter: retryAfter)
        }
        #expect(error(400, #"{"error":{"message":"This model's maximum context length is 32768 tokens. However, you requested 40000 tokens.","type":"BadRequestError"}}"#)
                == .contextLengthExceeded(message: "This model's maximum context length is 32768 tokens. However, you requested 40000 tokens."))
        #expect(error(400, #"{"error":{"code":"context_length_exceeded","message":"too long"}}"#) == .contextLengthExceeded(message: "too long"))
        #expect(error(404, #"{"error":"model \"qwen3:8b\" not found, try pulling it first"}"#)
                == .modelNotFound(message: #"model "qwen3:8b" not found, try pulling it first"#))
        #expect(error(422, #"{"detail":[{"loc":["body","max_tokens"],"msg":"must be positive"}]}"#) == .http(422, message: "must be positive"))
        #expect(error(500, "Internal failure") == .http(500, message: "Internal failure"))
        #expect(error(502, "<html>bad gateway</html>") == .http(502, message: nil))
        #expect(error(401, "{}") == .unauthorized)
        #expect(error(503, #"{"error":{"message":"Loading model"}}"#, retryAfter: "7") == .busy(retryAfter: 7))
        #expect(LLMError.http(502, message: nil).isRetryable && !LLMError.http(400, message: nil).isRetryable)
    }

    @Test func credentialsInServerMessagesAreRedacted() {
        let echoed = ServerErrorBody.error(status: 400, body: Data(#"{"error":{"message":"bad header Authorization: Bearer sk-live-123 rejected"}}"#.utf8),
                                           retryAfter: nil)
        #expect(echoed == .http(400, message: "bad header Authorization: ••• rejected"))
        #expect(ServerErrorBody.sanitized("token Bearer abc.def-123 is invalid") == "token Bearer ••• is invalid")
        #expect(ServerErrorBody.sanitized(#"{"api_key": "k-998877", "x-api-key=zz"}"#) == #"{"api_key": "•••", "x-api-key=•••"}"#)
        #expect(ServerErrorBody.sanitized("model not found") == "model not found")
        // The stored key, anywhere and in any case, even cut by the 300-character clip.
        let key = "s3cr3t-key-value-0123456789"
        #expect(LLMError.server(message: "no key S3CR3T-KEY-VALUE-0123456789 here").redacting(key) == .server(message: "no key ••• here"))
        let clipped = ServerErrorBody.sanitized(String(repeating: "a", count: 290) + " " + key)
        #expect(clipped.hasSuffix("…") && clipped.contains("s3cr3t"))   // only the client knows the key: it redacts the rest
        let cut = LLMError.http(500, message: clipped).redacting(key)
        guard case .http(_, let message?) = cut else { Issue.record("not an http error"); return }
        #expect(!message.contains("s3cr3t") && message.hasSuffix("•••…"))
        #expect(LLMError.unauthorized.redacting(key) == .unauthorized)
    }

    @Test func aChatErrorNeverShowsTheStoredKey() async throws {
        let port = StubServer.register { _ in .json(["error": ["message": "invalid key sk-stored-0123 for this proxy"]], status: 400) }
        defer { StubServer.unregister(port) }
        let client = ModelsFixtures.client(port: port, bearer: { "sk-stored-0123" })
        await #expect(throws: LLMError.http(400, message: "invalid key ••• for this proxy")) {
            _ = try await client.chat([.user("q")], ChatOptions(model: .deep, maxTokens: 5))
        }
    }

    @Test func retryAfter() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ServerErrorBody.parseRetryAfter("30", now: now) == 30)
        #expect(ServerErrorBody.parseRetryAfter(nil, now: now) == 10)
        #expect(ServerErrorBody.parseRetryAfter("9999", now: now) == 300)
        #expect(ServerErrorBody.parseRetryAfter("0", now: now) == 1)
        let date = Date(timeIntervalSince1970: 1_800_000_045)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        #expect(ServerErrorBody.parseRetryAfter(f.string(from: date), now: now) == 45)
        #expect(ServerErrorBody.parseRetryAfter("Sun, 06 Nov 1994 08:49:37 GMT", now: now) == 1)
        #expect(ServerErrorBody.parseRetryAfter("soon", now: now) == 10)
        #expect(LLMError.busy(retryAfter: 12).retryAfter == 12 && LLMError.tooLarge.retryAfter == nil)
    }

    @Test func errorsAreLocalized() {
        #expect(LLMError.busy(retryAfter: 12).errorDescription?.contains("12") == true)
        #expect(LLMError.contextLengthExceeded(message: nil).recoverySuggestion != nil)
        #expect("\(LLMError.notConfigured)" == LLMError.notConfigured.errorDescription)
    }
}
