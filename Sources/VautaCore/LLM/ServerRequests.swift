// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Builds request bodies in the dialect of the configured server profile.
/// Bodies are serialised with sorted keys so they are deterministic.
enum ServerRequests {
    static func chatBody(model: String, messages: [ChatMessage], options: ChatOptions, profile: ServerProfile) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": options.maxTokens,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        switch profile.thinking {
        case .rootEnableThinking:
            body["enable_thinking"] = options.thinking
            if options.thinking, let effort = options.reasoningEffort { body["reasoning_effort"] = effort }
        case .chatTemplateKwargs:
            body["chat_template_kwargs"] = ["enable_thinking": options.thinking]
            if options.thinking, let effort = options.reasoningEffort { body["reasoning_effort"] = effort }
        case .reasoningEffort:
            body["reasoning_effort"] = options.thinking ? (options.reasoningEffort ?? "medium") : "low"
        case .ollamaThink:
            body["think"] = options.thinking
            body["reasoning_effort"] = options.thinking ? (options.reasoningEffort ?? "medium") : "none"
        case .none:
            break
        }
        if let p = profile.sampling.parameters(thinking: options.thinking) {
            if let v = p.temperature { body["temperature"] = v }
            if let v = p.topP { body["top_p"] = v }
            if let v = p.topK { body["top_k"] = v }
            if let v = p.minP { body["min_p"] = v }
        }
        if let v = options.temperature { body["temperature"] = v }
        if let format = options.responseFormat, let value = try responseFormat(format, support: profile.structuredOutput) {
            body["response_format"] = value
        }
        return try spliceSchema(JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), schema: options.responseFormat)
    }

    /// Stands in for a schema's text while the body is serialised (a dictionary has no key order).
    private static let schemaMarker = "@@vauta-schema@@"

    /// Puts the schema's own text where the marker is, so the order of its properties reaches the server unchanged.
    private static func spliceSchema(_ body: Data, schema format: ResponseFormat?) throws -> Data {
        guard case .jsonSchema(_, let schema)? = format else { return body }
        var text = String(decoding: body, as: UTF8.self)
        // The marker is looked for after the `response_format` key, never in the messages (a message whose whole content is the marker
        // would be taken for it): keys are sorted, so nothing the person or a transcript wrote comes after that key's value.
        guard let key = text.range(of: "\"response_format\":"), let range = text.range(of: "\"schema\":\"\(schemaMarker)\"", range: key.upperBound..<text.endIndex) else { return body }
        let marker = text.range(of: "\"\(schemaMarker)\"", range: range)!
        text.replaceSubrange(marker, with: String(decoding: schema, as: UTF8.self))
        return Data(text.utf8)
    }

    /// The `response_format` value, or nil when the server cannot take it.
    static func responseFormat(_ format: ResponseFormat, support: StructuredOutputSupport) throws -> [String: Any]? {
        switch support {
        case .none:
            return nil
        case .jsonObject:
            return ["type": "json_object"]
        case .jsonSchema:
            switch format {
            case .jsonObject:
                // LM Studio rejects json_object; a permissive schema means the same.
                return ["type": "json_schema", "json_schema": ["name": "response", "schema": ["type": "object"]]]
            case .jsonSchema(let name, let schema):
                guard try JSONSerialization.jsonObject(with: schema) is [String: Any] else {
                    throw LLMError.invalidResponse("JSON schema is not an object")
                }
                // The schema itself is spliced in as written (`spliceSchema`); only its validity is checked here.
                return ["type": "json_schema", "json_schema": ["name": name, "schema": schemaMarker, "strict": true]]
            }
        }
    }

    static func embeddingsBody(model: String, inputs: [String], legacy: Bool) throws -> Data {
        var body: [String: Any] = ["model": model, "input": inputs]
        // Explicit float output: some servers default to base64.
        if !legacy { body["encoding_format"] = "float" }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
