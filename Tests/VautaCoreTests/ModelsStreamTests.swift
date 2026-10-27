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
