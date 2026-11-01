// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Synchronization

/// The integrated Gemma 4 E4B as a `ChatModel`: template ids, optional kept prefix, grammar-constrained decoding, real token
/// counts. Memory and GPU errors become `LLMError.modelUnavailable` / `.busy`.
public struct IntegratedChatModel: ChatModel {
    public static let contextWindow = 65_536
    let engine: LanguageModelEngine
    /// nil = greedy; otherwise the card settings with a seed derived from the prompt (reproducible).
    let sampler: @Sendable (_ seed: UInt64) -> DecodingSettings

    public init(engine: LanguageModelEngine, sampling: @escaping @Sendable (UInt64) -> DecodingSettings = { .card(seed: $0) }) {
        self.engine = engine
        self.sampler = sampling
    }

    public var contextTokens: Int? { Self.contextWindow }

    /// Languages Gemma 4 handles well; others are left to the caller's choice of provider.
    public func supports(_ locale: Locale) -> Bool {
        guard let code = locale.language.languageCode?.identifier else { return true }
        return ["en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "nl", "pl", "ru", "tr", "ar", "hi", "id", "vi", "uk", "cs", "sv", "da", "fi", "no", "nb", "el", "he", "th", "ro", "hu"].contains(code)
    }

    static func seed(for messages: [ChatMessage]) -> UInt64 {
        var h = SHA256()
        for m in messages { h.update(data: Data(m.role.utf8)); h.update(data: Data([0])); h.update(data: Data(m.content.utf8)); h.update(data: Data([1])) }
        return Array(h.finalize()).prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// The caller's temperature: 0 is greedy; another value replaces the temperature of the configured sampling (top-k, top-p and the
    /// seed stay), unless that sampling is greedy on purpose (the evaluation's `--sampler greedy`), which a request does not undo.
    static func sampling(requested: Double?, settings: DecodingSettings) -> DecodingSettings {
        guard let t = requested else { return settings }
        if t <= 0 { return .greedy }
        guard settings.temperature > 0 else { return settings }
        var s = settings
        s.temperature = Float(t)
        return s
    }

    static func timing(_ stats: SchemaConstraint.Stats, setup: Double, upload: Double) -> ConstraintTiming {
        let d = stats.maskDurations.sorted()
        func q(_ p: Double) -> Double { d.isEmpty ? 0 : d[min(d.count - 1, Int(Double(d.count - 1) * p))] }
        return ConstraintTiming(masks: stats.masks, totalSeconds: stats.maskSeconds, p50Seconds: q(0.5), p99Seconds: q(0.99), maxSeconds: d.last ?? 0,
                                firstSeconds: stats.maskDurations.first ?? 0, setupSeconds: setup, uploadSeconds: upload)
    }

    public func chat(_ messages: [ChatMessage], _ options: ChatOptions, onProgress: (@Sendable (Int) -> Void)?) async throws -> ChatResult {
        // The clock starts at the entry, like Apple's, so the figure includes the constraint build and everything inside the engine.
        let entered = Date()
        let out: LanguageModelOutput
        let beforeEngine: Date
        var setup = 0.0
        var used: (any OutputConstraint)?
        do {
            var constraint: (any OutputConstraint)? = options.constraint
            if constraint == nil, let schema = options.outputSchema {
                let c0 = Date()
                constraint = try await engine.constraint(for: schema)
                setup = Date().timeIntervalSince(c0)
            }
            used = constraint
            beforeEngine = Date()
            out = try await engine.generate(messages, maxTokens: options.maxTokens, sampling: Self.sampling(requested: options.temperature, settings: sampler(Self.seed(for: messages))),
                                            constraint: constraint, priority: options.priority, sharedPrefix: options.reusePrefix, slot: options.slot,
                                            maxDecodeSeconds: options.maxSeconds, onProgress: onProgress, onPrefill: options.onPrefill)
        } catch is GenerationPreempted {
            // Stepped aside for a more urgent call that needs the same prefix: the caller tries again on its next turn. Live notes
            // are not an error to anyone (a question has the slot for a moment): they hear it as it is and try again on the next tick.
            if options.purpose == .liveNotes { throw GenerationPreempted() }
            throw LLMError.busy(retryAfter: 1)
        } catch is GenerationTooWarm {
            // Optional work that gave the GPU up because the Mac is too warm: not now.
            throw LLMError.busy(retryAfter: 30)
        } catch let e as IntegratedModelError {
            switch e {
            case .diskFull, .engineFailed: throw LLMError.busy(retryAfter: 10)
            default: throw LLMError.modelUnavailable
            }
        }
        let reason: FinishReason = ["length", "loop", "noToken"].contains(out.finish) ? .length : .stop
        if reason == .length, options.failOnTruncation { throw LLMError.outputTruncated }
        var result = ChatResult(content: out.text, promptTokens: out.promptTokens, cachedTokens: out.reusedTokens, completionTokens: out.tokens.count, finishReason: reason,
                          firstTokenSeconds: out.firstTokenSinceCallSeconds.map { beforeEngine.timeIntervalSince(entered) + $0 },
                          engineFirstTokenSeconds: out.firstTokenSeconds)
        var breakdown = LatencyBreakdown()
        breakdown.tokenizeSeconds = out.tokenizeSeconds
        breakdown.slotWaitSeconds = out.slotWaitSeconds
        breakdown.gateWaitSeconds = out.gateWaitSeconds
        breakdown.newPrefillTokens = max(0, out.promptTokens - out.reusedTokens)
        breakdown.prefillChunks = out.prefillChunks
        breakdown.prefillSeconds = out.prefillSeconds
        breakdown.longestChunkSeconds = out.longestChunkSeconds
        breakdown.longestBurstSeconds = out.longestBurstSeconds
        result.breakdown = breakdown
        if let schema = used as? SchemaConstraint { result.constraintTiming = Self.timing(schema.stats, setup: setup, upload: out.maskUploadSeconds) }
        return result
    }
}

/// What the rest of the app may ask about the integrated language model, from any thread. Set once at start or by the
/// evaluation commands; reading it never touches the disk.
public final class LanguageModelAccess: Sendable {
    public enum Availability: Sendable, Equatable {
        case notInstalled
        case unavailable(String)
        case installed
    }

    private struct State {
        var availability = Availability.notInstalled
        var model: IntegratedChatModel?
    }

    private struct Shared {
        var engine: LanguageModelEngine?
        var recording = false
    }

    private let state = Mutex(State())
    /// The one engine of the process (the weights are loaded once, whoever asks first), kept apart from `state` so that clearing or
    /// marking the model damaged does not forget it: a later install hands the same engine out again.
    private let shared = Mutex(Shared())
    public static let shared = LanguageModelAccess()
    public init() {}

    private let looked = Mutex(false)

    /// With the hidden flag on, looks at the default store once per process (the disk only, no loading).
    public func refreshOnce(store: LanguageModelStore = LanguageModelStore()) {
        guard looked.withLock({ let was = $0; $0 = true; return !was }) else { return }
        refresh(store: store)
    }

    public var availability: Availability { state.withLock { $0.availability } }
    public var chatModel: IntegratedChatModel? { state.withLock { $0.model } }

    /// The hidden flag: `defaults write <bundle-id> integratedLanguageModel -bool YES`, or `VAUTA_INTEGRATED_LLM=1` for the CLI.
    public static func flagEnabled(defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        defaults.bool(forKey: "integratedLanguageModel") || environment["VAUTA_INTEGRATED_LLM"] == "1"
    }

    /// Looks at the disk (quick check only) and makes the model available when it is installed and the Mac qualifies.
    public func refresh(store: LanguageModelStore, engine: LanguageModelEngine? = nil) {
        guard case .installed = store.disk(), LanguageModelVerifier.quickCheck(file: store.weightsURL, spec: store.spec) else {
            state.withLock { $0 = State() }
            return
        }
        if let reason = LanguageModelGate.refusal(gpuSupported: LanguageModelGate.gpuSupported) {
            state.withLock { $0 = State(availability: .unavailable(reason), model: nil) }
            return
        }
        let e = self.engine(for: store, using: engine)
        state.withLock { $0 = State(availability: .installed, model: IntegratedChatModel(engine: e)) }
    }

    /// The process's engine for `store`: the one handed in, the one already built for this store, or a new one. Chat and the
    /// controller (Settings, delete) both end up with the same instance, so there is one set of weights and one set of kept prefixes,
    /// and Delete unloads what chat actually uses.
    public func engine(for store: LanguageModelStore, using given: LanguageModelEngine? = nil) -> LanguageModelEngine {
        shared.withLock { s in
            if let given {
                s.engine = given
                if s.recording { Task { await given.setKeepWarm(true) } }
                return given
            }
            if let existing = s.engine, existing.root == store.root { return existing }
            let e = LanguageModelEngine(store: store, onDamaged: { [weak self] in self?.markDamaged() })
            s.engine = e
            if s.recording { Task { await e.setKeepWarm(true) } }
            return e
        }
    }

    /// A meeting is being recorded (the recorder calls this when it starts and stops): the model, if it is loaded, is not unloaded
    /// for being idle, so a live answer does not wait for a load. Nothing is loaded by this call.
    public func setRecording(_ recording: Bool) {
        let engine = shared.withLock { s -> LanguageModelEngine? in
            s.recording = recording
            return s.engine
        }
        if let engine { Task { await engine.setKeepWarm(recording) } }
    }

    /// Makes `model` the installed one (tests; the app goes through `refresh(store:)`).
    func adopt(_ model: IntegratedChatModel) { state.withLock { $0 = State(availability: .installed, model: model) } }

    /// The model was deleted or is not installed: nothing is offered.
    public func clear() { state.withLock { $0 = State() } }

    /// The reason shown when the files on this Mac no longer match what Vauta pinned.
    public static let damagedReason = "damaged"

    /// The engine found the files damaged (the quick check passed at launch but the full check or a read failed): the model is no
    /// longer offered, so chat goes back to Apple's model at once instead of hashing 4.2 GB again on every call.
    public func markDamaged() {
        state.withLock { $0 = State(availability: .unavailable(Self.damagedReason), model: nil) }
    }
}

/// What the service needs of a chat model that keeps the meeting's transcript read while it is recorded. Only the integrated model
/// does; a test fake can too.
protocol WarmableChatModel: ChatModel {
    /// Reads `messages` (system, people, transcript so far) into the kept prefix of the meeting and stops.
    func readMeeting(_ messages: [ChatMessage], onPrefill: (@Sendable (Int, Int) -> Void)?) async throws
    /// Tokens of the meeting's and of the Ask prefix now, and the measured speed of reading (tokens per second; nil before one).
    func keptMeetingTokens() async -> Int
    func keptAskTokens() async -> Int
    func readingRate() async -> Double?
    /// Whether the kept prefix still has room for more (memory budget).
    func meetingPrefixHasRoom() async -> Bool
    /// The recording stopped: keep the prefix for the minutes.
    func pinMeeting() async
    /// The minutes are written: the normal idle rules apply again.
    func unpinMeeting() async
    /// A meeting was deleted or everything was erased: the kept prefixes named here may not hold its transcript any longer.
    func dropKeptTranscripts(_ slots: Set<KeptSlot>) async
}

extension WarmableChatModel {
    func dropKeptTranscripts(_ slots: Set<KeptSlot>) async {}
}

extension IntegratedChatModel: WarmableChatModel {
    func readMeeting(_ messages: [ChatMessage], onPrefill: (@Sendable (Int, Int) -> Void)?) async throws {
        do {
            try await engine.prefillPrefix(messages, slot: .meeting, onPrefill: onPrefill)
        } catch is GenerationPreempted {
            throw LLMError.busy(retryAfter: 1)
        } catch is IntegratedModelError {
            throw LLMError.modelUnavailable
        }
    }

    func keptMeetingTokens() async -> Int { await engine.keptMeetingTokens() }
    func keptAskTokens() async -> Int { await engine.keptAskTokens() }
    func readingRate() async -> Double? { await engine.readingRate() }
    func meetingPrefixHasRoom() async -> Bool { await engine.keptMeetingBytes() < engine.meetingPrefixBudget * 95 / 100 }
    func pinMeeting() async { await engine.pinMeetingPrefix() }
    func unpinMeeting() async { await engine.unpinMeetingPrefix() }
    func dropKeptTranscripts(_ slots: Set<KeptSlot>) async { await engine.dropKeptTranscripts(slots) }
}
