// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Why generation stopped, as reported by the server.
public enum FinishReason: Sendable, Equatable {
    case stop
    /// Hit `max_tokens`: the answer is incomplete.
    case length
    case contentFilter
    case toolCalls
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "stop", "eos", "end_turn": self = .stop
        case "length", "max_tokens": self = .length
        case "content_filter": self = .contentFilter
        case "tool_calls", "function_call": self = .toolCalls
        default: self = .other(raw)
        }
    }
}

/// Incremental parser for an OpenAI chat-completions response. Handles SSE
/// (`event:`/`data:` lines, multi-line data, `[DONE]`, error events) and a
/// plain JSON body from servers that ignore `"stream": true`.
struct ChatStreamParser {
    private(set) var content = ""
    private(set) var finishReason: FinishReason?
    private(set) var promptTokens = 0
    private(set) var cachedTokens = 0
    private(set) var completionTokens: Int?
    /// Content and reasoning chunks received (progress only).
    private(set) var produced = 0
    private(set) var done = false

    private var event: String?
    private var data: [String] = []
    /// Not SSE: the whole body is collected and parsed at the end.
    private var plainBody: String?
    private var sawLine = false

    let maxContentBytes: Int

    init(maxContentBytes: Int = LLMClient.maxChatBytes) {
        self.maxContentBytes = maxContentBytes
    }

    /// Feeds one line without its terminator. Returns false once the stream is complete.
    mutating func consume(_ line: String) throws -> Bool {
        if var body = plainBody {
            body += line + "\n"
            guard body.utf8.count <= LLMClient.maxBodyBytes else { throw LLMError.tooLarge }
            plainBody = body
            return true
        }
        if !sawLine {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return true }
            sawLine = true
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                plainBody = line + "\n"
                return true
            }
        }
        if line.isEmpty {
            try dispatch()
            event = nil
            return !done
        }
        if line.hasPrefix(":") { return true }   // SSE comment / keep-alive
        let (field, value) = Self.field(line)
        switch field {
        case "event":
            try dispatch()
            event = value
        case "data":
            if value == "[DONE]" {
                try dispatch()
                done = true
                return false
            }
            // Most servers send one JSON object per line: handle it right away
            // even when the blank separator line never comes.
            if !data.isEmpty, Self.object(value) != nil {
                try dispatch()   // a stale partial payload never swallows the next one
            }
            data.append(value)
            if Self.object(data.joined(separator: "\n")) != nil { try dispatch() }
        default:
            break   // id:, retry:, unknown fields
        }
        return !done
    }

    /// Call when the byte stream ends.
    mutating func finish() throws {
        if let body = plainBody {
            guard let obj = Self.object(body) else { throw LLMError.invalidResponse("not a chat completion") }
            try handleCompletion(obj)
            return
        }
        try dispatch()
    }

    private mutating func dispatch() throws {
        guard !data.isEmpty else { return }
        let payload = data.joined(separator: "\n")
        data.removeAll()
        guard let obj = Self.object(payload) else {
            if event == "error" { throw LLMError.server(message: String(payload.prefix(300))) }
            return
        }
        if event == "error" || obj["error"] != nil { throw ServerErrorBody.streamError(obj) }
        try handleChunk(obj)
    }

    private mutating func handleChunk(_ obj: [String: Any]) throws {
        if let choice = (obj["choices"] as? [[String: Any]])?.first {
            if let delta = choice["delta"] as? [String: Any] {
                try append(delta)
            } else if let message = choice["message"] as? [String: Any] {
                try append(message)   // some servers send a whole message as the only chunk
            }
            if let reason = choice["finish_reason"] as? String { finishReason = FinishReason(reason) }
        }
        readUsage(obj)
    }

    /// A non-streamed `chat.completion` object.
    private mutating func handleCompletion(_ obj: [String: Any]) throws {
        if obj["error"] != nil { throw ServerErrorBody.streamError(obj) }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first, let message = choice["message"] as? [String: Any] else {
            throw LLMError.invalidResponse("not a chat completion")
        }
        try append(message)
        if let reason = choice["finish_reason"] as? String { finishReason = FinishReason(reason) }
        readUsage(obj)
        done = true
    }

    private mutating func append(_ delta: [String: Any]) throws {
        if let piece = delta["content"] as? String, !piece.isEmpty {
            content += piece
            guard content.utf8.count < maxContentBytes else { throw LLMError.tooLarge }
            produced += 1
        }
        // Reasoning is never kept; it only counts as progress (`reasoning_content`
        // in MLX/vLLM/LM Studio/llama.cpp, `reasoning` in Ollama and newer vLLM).
        if let r = (delta["reasoning_content"] ?? delta["reasoning"]) as? String, !r.isEmpty { produced += 1 }
    }

    private mutating func readUsage(_ obj: [String: Any]) {
        if let u = obj["usage"] as? [String: Any] {
            promptTokens = u["prompt_tokens"] as? Int ?? promptTokens
            cachedTokens = (u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? cachedTokens
            completionTokens = u["completion_tokens"] as? Int ?? completionTokens
        }
        // llama.cpp reports prompt cache hits in `timings.cache_n`.
        if let t = obj["timings"] as? [String: Any], let n = t["cache_n"] as? Int, cachedTokens == 0 {
            cachedTokens = n
        }
    }

    private static func field(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: colon)...]
        if value.first == " " { value = value.dropFirst() }
        return (String(line[..<colon]), String(value).trimmingCharacters(in: .whitespaces))
    }

    private static func object(_ s: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]
    }
}
