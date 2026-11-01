// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The role of each model; the user picks the actual names in Settings → Models.
public enum LLMRole: String, Codable, Sendable, CaseIterable {
    /// Live notes while recording: fast, no reasoning.
    case fast
    /// Final minutes and Ask with citations.
    case deep
    /// Embeddings for Ask.
    case embedding
}

public struct ChatMessage: Sendable, Codable, Equatable {
    public let role: String
    public let content: String
    public init(_ role: String, _ content: String) {
        self.role = role
        self.content = content
    }
    public static func system(_ c: String) -> ChatMessage { ChatMessage("system", c) }
    public static func user(_ c: String) -> ChatMessage { ChatMessage("user", c) }
}

/// Which of the integrated model's two kept prefixes a call uses: the meeting being recorded (or just recorded), or anything else.
public enum KeptSlot: Sendable, Equatable { case meeting, ask }

public struct ChatOptions: Sendable {
    public var model: LLMRole
    public var maxTokens: Int
    /// Reasoning on or off; how it is requested depends on the server profile.
    public var thinking: Bool
    /// "low" | "medium" | "high" (with reasoning only).
    public var reasoningEffort: String?
    /// Structured output, sent only when the server profile supports it.
    public var responseFormat: ResponseFormat?
    /// Throw `LLMError.outputTruncated` instead of returning a cut-off answer.
    public var failOnTruncation: Bool
    /// A model name to use instead of the role's configured one (the role still
    /// picks the server address). nil = the role's model.
    public var modelOverride: String?
    /// Replaces the sampling preset's temperature. nil = the profile decides.
    public var temperature: Double?
    /// What the request is for, as the Network Activity window lists it.
    public var purpose: NetworkPurpose
    /// Only the integrated language model: decode within this grammar (see `OutputSchemas`).
    public var constraint: (any OutputConstraint)?
    /// Only the integrated language model: the shape of the JSON answer; it builds the grammar from it.
    public var outputSchema: OutputSchema?
    /// Only the integrated language model: keep the state of everything before the last message for the next call (live answers).
    public var reusePrefix: Bool
    /// Only the integrated language model: who waits for the GPU first.
    public var priority: MLXWorkGate.Priority
    /// Only the integrated language model: stop writing after this many seconds of decoding (a constrained value is still closed as
    /// valid JSON, finish `length`). nil = no limit.
    public var maxSeconds: Double?
    /// Only the integrated language model: which kept prefix a call with `reusePrefix` uses. nil = by priority (live work and the
    /// minutes use the meeting's, an answer uses the Ask one).
    public var slot: KeptSlot?
    /// Only the integrated language model: called as the prompt is read, with the tokens in the caches (kept ones included) and the
    /// prompt's length.
    public var onPrefill: (@Sendable (Int, Int) -> Void)?

    public init(model: LLMRole, maxTokens: Int, thinking: Bool = false, reasoningEffort: String? = nil,
                responseFormat: ResponseFormat? = nil, failOnTruncation: Bool = false,
                modelOverride: String? = nil, temperature: Double? = nil, purpose: NetworkPurpose = .other,
                constraint: (any OutputConstraint)? = nil, outputSchema: OutputSchema? = nil, reusePrefix: Bool = false, priority: MLXWorkGate.Priority = .minutes,
                maxSeconds: Double? = nil, slot: KeptSlot? = nil, onPrefill: (@Sendable (Int, Int) -> Void)? = nil) {
        self.slot = slot
        self.onPrefill = onPrefill
        self.maxSeconds = maxSeconds
        self.constraint = constraint
        self.outputSchema = outputSchema
        self.reusePrefix = reusePrefix
        self.priority = priority
        self.modelOverride = modelOverride
        self.temperature = temperature
        self.purpose = purpose
        self.model = model
        self.maxTokens = maxTokens
        self.thinking = thinking
        self.reasoningEffort = reasoningEffort
        self.responseFormat = responseFormat
        self.failOnTruncation = failOnTruncation
    }
}

public struct LatencyBreakdown: Codable, Sendable, Equatable {
    public var tokenizeSeconds = 0.0
    public var slotWaitSeconds = 0.0
    public var gateWaitSeconds = 0.0
    public var newPrefillTokens = 0
    public var prefillChunks = 0
    public var prefillSeconds = 0.0
    /// The longest the integrated model held the GPU without a checkpoint while reading the prompt, and while decoding: the longest
    /// a more urgent job waited for it because of this call.
    public var longestChunkSeconds = 0.0
    public var longestBurstSeconds = 0.0
    public init() {}
}

/// What a schema-constrained call cost in grammar work (evaluation only): masks computed, their percentiles, the first one (which
/// builds the lazy tables), and the time to build the constraint (the first use builds the trie of the whole vocabulary).
public struct ConstraintTiming: Codable, Sendable, Equatable {
    public var masks: Int
    public var totalSeconds: Double
    public var p50Seconds: Double
    public var p99Seconds: Double
    public var maxSeconds: Double
    public var firstSeconds: Double
    public var setupSeconds: Double
    /// Host time of turning the allowed set into the additive mask array of the logits (the per-step upload of the vocabulary-sized mask).
    public var uploadSeconds: Double
    public init(masks: Int, totalSeconds: Double, p50Seconds: Double, p99Seconds: Double, maxSeconds: Double, firstSeconds: Double, setupSeconds: Double, uploadSeconds: Double) {
        self.masks = masks
        self.totalSeconds = totalSeconds
        self.p50Seconds = p50Seconds
        self.p99Seconds = p99Seconds
        self.maxSeconds = maxSeconds
        self.firstSeconds = firstSeconds
        self.setupSeconds = setupSeconds
        self.uploadSeconds = uploadSeconds
    }
}

public struct ChatResult: Sendable {
    public let content: String
    public let promptTokens: Int
    public let cachedTokens: Int
    public let completionTokens: Int
    /// nil when the provider does not report it.
    public let finishReason: FinishReason?
    /// Seconds from the entry of `ChatModel.chat` to the first generated token, for the on-device models (the evaluation reads it);
    /// nil when not measured. The same starting point for every provider, so it includes loading, tokenisation and queueing.
    public let firstTokenSeconds: Double?
    /// The integrated model's own figure, from the start of its generation loop (excludes the setup above); nil for other providers.
    public let engineFirstTokenSeconds: Double?
    /// Grammar-work timing of a schema-constrained call on the integrated model (evaluation); nil otherwise.
    public var constraintTiming: ConstraintTiming?
    /// Where the time before the first token went on the integrated model (evaluation): tokenising the prompt, waiting for the kept
    /// prefix's lock and for the GPU, the prompt tokens that had to be read (the kept prefix is not counted), and the prefill chunks.
    public var breakdown: LatencyBreakdown?

    public init(content: String, promptTokens: Int, cachedTokens: Int, completionTokens: Int, finishReason: FinishReason? = nil,
                firstTokenSeconds: Double? = nil, engineFirstTokenSeconds: Double? = nil) {
        self.firstTokenSeconds = firstTokenSeconds
        self.engineFirstTokenSeconds = engineFirstTokenSeconds
        self.content = content
        self.promptTokens = promptTokens
        self.cachedTokens = cachedTokens
        self.completionTokens = completionTokens
        self.finishReason = finishReason
    }

    /// The answer stopped at the token limit and is incomplete.
    public var isTruncated: Bool { finishReason == .length }
}
