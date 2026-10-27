// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The kind of OpenAI-compatible server Vauta talks to. It decides the default
/// request dialect and which native (non-`/v1`) endpoints may be queried for
/// detection on the same origin.
public enum ServerKind: String, Codable, Sendable, CaseIterable {
    case lmStudio
    case ollama
    case llamaCpp
    case mlx
    case vllm
    case jan
    case localAI
    /// Any other server that speaks the OpenAI chat/embeddings API.
    case openAICompatible

    /// Port the server listens on by default (used for loopback discovery).
    public var defaultPort: Int {
        switch self {
        case .lmStudio: 1234
        case .ollama: 11434
        case .llamaCpp, .mlx, .localAI: 8080
        case .vllm: 8000
        case .jan: 1337
        case .openAICompatible: 8080
        }
    }

    public var displayName: String {
        switch self {
        case .lmStudio: "LM Studio"
        case .ollama: "Ollama"
        case .llamaCpp: "llama.cpp"
        case .mlx: "MLX"
        case .vllm: "vLLM"
        case .jan: "Jan"
        case .localAI: "LocalAI"
        case .openAICompatible: String(localized: "OpenAI-compatible server", comment: "Generic model server kind")
        }
    }

    /// Native endpoints (outside the `/v1` base) that identify the server and
    /// describe its models. Only these, and only on the configured origin, are
    /// ever requested besides the OpenAI endpoints. A generic server allows the
    /// read-only identification endpoints of every kind, so it can be detected.
    var nativePaths: Set<String> {
        switch self {
        case .ollama: ["api/version", "api/tags", "api/show", "api/ps"]
        case .lmStudio: ["api/v0/models"]
        case .llamaCpp: ["props"]
        case .vllm, .localAI: ["version"]
        case .mlx, .jan: []
        case .openAICompatible:
            Self.allCases.filter { $0 != .openAICompatible }.reduce(into: Set<String>()) { $0.formUnion($1.nativePaths) }
        }
    }

    /// Decodes unknown raw values (written by a newer version) as the generic kind
    /// instead of failing, so a downgrade never makes the whole config unreadable.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ServerKind(rawValue: raw) ?? .openAICompatible
    }
}

/// How a request turns the model's reasoning ("thinking") on or off.
public enum ThinkingControl: String, Codable, Sendable, CaseIterable {
    /// `"enable_thinking": Bool` at the JSON root (custom servers; legacy Vauta default).
    case rootEnableThinking
    /// `"chat_template_kwargs": {"enable_thinking": Bool}` (vLLM, SGLang, llama.cpp `--jinja`, mlx-lm).
    case chatTemplateKwargs
    /// `"reasoning_effort"`: the requested effort, or `"low"` when thinking is off (gpt-oss style).
    case reasoningEffort
    /// `"think": Bool` plus `"reasoning_effort"` (`"none"` when off), as Ollama understands.
    case ollamaThink
    /// Nothing is sent: the server or model decides.
    case none

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ThinkingControl(rawValue: raw) ?? .none
    }
}

/// Structured output the server accepts in `response_format`.
public enum StructuredOutputSupport: String, Codable, Sendable, CaseIterable {
    /// `{"type": "json_schema", ...}` (and `json_object` when no schema is given).
    case jsonSchema
    /// Only `{"type": "json_object"}`.
    case jsonObject
    /// No `response_format` is ever sent.
    case none

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = StructuredOutputSupport(rawValue: raw) ?? .none
    }
}

/// Sampling parameters added to chat requests.
public enum SamplingPreset: Sendable, Equatable {
    /// Server/model defaults.
    case none
    /// Qwen3 non-thinking recommendation (temperature 0.7, top_p 0.8, top_k 20),
    /// sent only when thinking is off. Legacy Vauta default.
    case qwenNonThinking
    /// User-defined values, sent with every chat request.
    case custom(SamplingParameters)

    /// The parameters to send for a request with or without thinking.
    func parameters(thinking: Bool) -> SamplingParameters? {
        switch self {
        case .none: nil
        case .qwenNonThinking: thinking ? nil : SamplingParameters(temperature: 0.7, topP: 0.8, topK: 20)
        case .custom(let p): p
        }
    }
}

public struct SamplingParameters: Codable, Sendable, Equatable {
    public var temperature: Double?
    public var topP: Double?
    /// Not part of the OpenAI API; most local servers accept it.
    public var topK: Int?
    public var minP: Double?

    public init(temperature: Double? = nil, topP: Double? = nil, topK: Int? = nil, minP: Double? = nil) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
    }
}

extension SamplingPreset: Codable {
    private enum CodingKeys: String, CodingKey { case preset, temperature, topP, topK, minP }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .preset) {
        case "qwen-nonthinking": self = .qwenNonThinking
        case "custom": self = .custom(try SamplingParameters(from: decoder))
        default: self = .none
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try c.encode("none", forKey: .preset)
        case .qwenNonThinking: try c.encode("qwen-nonthinking", forKey: .preset)
        case .custom(let p):
            try c.encode("custom", forKey: .preset)
            try p.encode(to: encoder)
        }
    }
}

/// What Vauta knows about the configured server's request dialect. Stored inside
/// the `llm-server-v1` config. A config without a profile (written by Vauta
/// 0.1.x) uses `ServerProfile.legacy`, which reproduces the 0.1.x requests.
public struct ServerProfile: Codable, Sendable, Equatable {
    public var kind: ServerKind
    public var thinking: ThinkingControl
    public var sampling: SamplingPreset
    public var structuredOutput: StructuredOutputSupport

    public init(kind: ServerKind, thinking: ThinkingControl, sampling: SamplingPreset = .none,
                structuredOutput: StructuredOutputSupport) {
        self.kind = kind
        self.thinking = thinking
        self.sampling = sampling
        self.structuredOutput = structuredOutput
    }

    /// The exact behaviour of the earlier version: root `enable_thinking`, Qwen3
    /// non-thinking sampling and no `response_format`.
    public static let legacy = ServerProfile(kind: .openAICompatible, thinking: .rootEnableThinking,
                                             sampling: .qwenNonThinking, structuredOutput: .none)

    /// Sensible defaults for each server kind (always editable in Settings).
    public static func defaults(for kind: ServerKind) -> ServerProfile {
        switch kind {
        // LM Studio has no per-request thinking switch and only accepts json_schema.
        case .lmStudio: ServerProfile(kind: kind, thinking: .none, structuredOutput: .jsonSchema)
        case .ollama: ServerProfile(kind: kind, thinking: .ollamaThink, structuredOutput: .jsonSchema)
        case .llamaCpp, .vllm: ServerProfile(kind: kind, thinking: .chatTemplateKwargs, structuredOutput: .jsonSchema)
        case .mlx: ServerProfile(kind: kind, thinking: .chatTemplateKwargs, structuredOutput: .none)
        case .localAI: ServerProfile(kind: kind, thinking: .none, structuredOutput: .jsonObject)
        case .jan, .openAICompatible: ServerProfile(kind: kind, thinking: .none, structuredOutput: .none)
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, thinking, sampling, structuredOutput }

    /// Missing fields take the defaults of the kind, so a hand-written profile
    /// such as `{"kind": "vllm"}` is complete.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decodeIfPresent(ServerKind.self, forKey: .kind) ?? .openAICompatible
        let base = Self.defaults(for: kind)
        self.kind = kind
        thinking = try c.decodeIfPresent(ThinkingControl.self, forKey: .thinking) ?? base.thinking
        sampling = try c.decodeIfPresent(SamplingPreset.self, forKey: .sampling) ?? base.sampling
        structuredOutput = try c.decodeIfPresent(StructuredOutputSupport.self, forKey: .structuredOutput) ?? base.structuredOutput
    }
}

/// Optional per-role base URLs, for setups where one process serves one model
/// (vLLM, plain llama.cpp) or embeddings live on another server. Each URL obeys
/// the same mode rules as the main base URL.
public struct RoleBaseURLs: Codable, Sendable, Equatable {
    public var fast: String?
    public var deep: String?
    public var embedding: String?

    public init(fast: String? = nil, deep: String? = nil, embedding: String? = nil) {
        self.fast = fast
        self.deep = deep
        self.embedding = embedding
    }

    subscript(role: LLMRole) -> String? {
        let value = switch role {
        case .fast: fast
        case .deep: deep
        case .embedding: embedding
        }
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }
}

/// `response_format` requested for one chat call. Sent only when the server
/// profile supports it.
public enum ResponseFormat: Sendable, Equatable {
    case jsonObject
    /// A JSON Schema (as UTF-8 JSON) with a short name.
    case jsonSchema(name: String, schema: Data)
}
