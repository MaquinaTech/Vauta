// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
@testable import VautaCore

/// A chat model whose answers come from a closure; records every request.
final class ScriptedChat: ChatModel, @unchecked Sendable {
    typealias Handler = @Sendable (_ messages: [ChatMessage], _ options: ChatOptions, _ call: Int) async throws -> ChatResult
    struct Call: Sendable {
        let messages: [ChatMessage]
        let options: ChatOptions
        var text: String { messages.map(\.content).joined(separator: "\n") }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    var calls: [Call] { lock.withLock { _calls } }
    var contextTokens: Int? { get async { nil } }

    func chat(_ messages: [ChatMessage], _ options: ChatOptions, onProgress: (@Sendable (Int) -> Void)?) async throws -> ChatResult {
        let n = lock.withLock { () -> Int in
            _calls.append(Call(messages: messages, options: options))
            return _calls.count
        }
        return try await handler(messages, options, n)
    }

    static func reply(_ content: String, finish: FinishReason? = .stop) -> ChatResult {
        ChatResult(content: content, promptTokens: 0, cachedTokens: 0, completionTokens: 10, finishReason: finish)
    }

    /// The first transcript segment in the request: its ID and text.
    static func firstSegment(_ messages: [ChatMessage]) -> (id: Int64, text: String)? {
        for m in messages {
            for line in m.content.split(separator: "\n") where line.hasPrefix("[S") {
                guard let close = line.firstIndex(of: "]"),
                      let id = Int64(line.dropFirst(2).prefix { $0.isNumber }) else { continue }
                return (id, String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    /// Valid English minutes JSON citing the first segment of the request.
    static func minutesJSON(_ messages: [ChatMessage], title: String = "Budget review") -> String {
        guard let (id, text) = firstSegment(messages) else { return "{}" }
        let quote = String(text.prefix(40)).replacingOccurrences(of: "\"", with: "")
        return """
            {"title": "\(title)", "summary": "The team reviewed the budget.", "topics": ["budget"],
             "decisions": [{"text": "Keep the budget", "seg": \(id), "quote": "\(quote)"}],
             "tasks": [], "entities": [], "open_questions": ["Who signs?"]}
            """
    }
}

/// Holds embedding calls until the test lets them go (a slow embedding server).
actor EmbedGate {
    private(set) var held = 0
    private var open = true

    func close() { open = false }
    func release() { open = true }
    func wait() async {
        guard !open else { return }
        held += 1
        while !open { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

/// Embeddings from a closure, in a fixed space.
struct FakeEmbedder: EmbeddingModel {
    let space: EmbeddingSpace
    var fails = false
    var gate: EmbedGate?

    func embed(_ texts: [String], purpose: EmbeddingPurpose) async throws -> EmbeddingBatch {
        if fails { throw LLMError.network("offline") }
        await gate?.wait()
        let vectors = texts.map { text in
            (0..<space.dimensions).map { i in Float((text.unicodeScalars.reduce(i) { ($0 &* 31 &+ Int($1.value)) % 997 })) + 1 }
        }
        return EmbeddingBatch(vectors: vectors, space: space)
    }
}

/// Providers chosen by the test: no Keychain, no server, no Apple model.
final class TestProviders: ModelProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _chat: (any ChatModel)?
    private var _contextTokens: Int
    private var _embedder: (any EmbeddingModel)?
    private var _refinementChat: (any ChatModel)?
    private let onDevice: Bool
    private var _integrated: Bool
    /// The minutes provider can be switched away from the integrated model (a settings change).
    var integrated: Bool {
        get { lock.withLock { _integrated } }
        set { lock.withLock { _integrated = newValue } }
    }
    private let supports: (@Sendable (Locale) -> Bool)?

    init(chat: (any ChatModel)?, contextTokens: Int = 32_768, embedder: (any EmbeddingModel)? = nil, onDevice: Bool = false,
         supports: (@Sendable (Locale) -> Bool)? = nil, integrated: Bool = false) {
        self.onDevice = onDevice || integrated
        _integrated = integrated
        self.supports = supports
        _chat = chat
        _contextTokens = contextTokens
        _embedder = embedder
    }

    var embedder: (any EmbeddingModel)? {
        get { lock.withLock { _embedder } }
        set { lock.withLock { _embedder = newValue } }
    }

    func reload() -> ProviderIssue? { nil }

    /// A test can say the embeddings run with the search model on this Mac.
    var embeddingChoice: ModelProviderSettings.Embeddings?

    var settings: ModelProviderSettings {
        ModelProviderSettings(chat: .server, embeddings: embeddingChoice ?? (embedder == nil ? .none : .server))
    }

    func chat() -> Result<ChatProvider, ProviderUnavailable> {
        let (chat, context) = lock.withLock { (_chat, _contextTokens) }
        guard let chat else { return .failure(ProviderUnavailable(issue: .serverNotConfigured)) }
        return .success(ChatProvider(model: chat, contextTokens: context, onDevice: onDevice, supports: supports, integrated: integrated))
    }

    /// "While recording" is another model (Apple Intelligence): live work gets this one while the main provider stays integrated.
    var liveModel: (any ChatModel)?

    func chat(for task: ChatTask) -> Result<ChatProvider, ProviderUnavailable> {
        guard task == .live, let live = lock.withLock({ liveModel }) else { return chat() }
        return .success(ChatProvider(model: live, contextTokens: 4_096, onDevice: true, supports: supports, integrated: false))
    }

    /// The languages the embedding model covers (all when nil): a language outside it has no model, as on a Mac without that script's model.
    var embeddedLanguages: (@Sendable (Locale.Language) -> Bool)?

    func embeddings() -> EmbeddingProvider {
        guard let embedder else { return .disabled }
        let model = (embedder as? FakeEmbedder)?.space.model ?? ((embedder is BudgetedEmbedder || embedder is RecordingEmbedder) ? ConceptEmbedder.space.model : nil)
        let covered = embeddedLanguages
        return .available(model: { language in covered?(language) == false ? nil : embedder }, expectedModel: { _ in model })
    }

    var server: (client: LLMClient, config: LLMServerConfig)? { nil }

    /// Tests of the documents' embeddings say whether the model is on the network.
    var onTheNetwork = false
    var embeddingsLeaveThisMac: Bool { onTheNetwork }

    /// The chat model standing in for the model server in live-translation tests (nil = no server).
    var refinementChat: (any ChatModel)? {
        get { lock.withLock { _refinementChat } }
        set { lock.withLock { _refinementChat = newValue } }
    }
}

/// Collects job events.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [LLMService.JobEvent] = []
    var events: [LLMService.JobEvent] { lock.withLock { _events } }
    func append(_ e: LLMService.JobEvent) { lock.withLock { _events.append(e) } }
}

extension LLMService {
    /// Returns once the queue's worker has ended. A test that makes a second service on the same store waits for this first: the
    /// store's job queue is shared, and the first service's worker would otherwise take the second one's job (and report it to
    /// the first one's handler).
    func waitUntilQueueIdle() async {
        _ = await eventually { await self.worker == nil }
    }
}

/// A gate a scripted model waits on (to hold the lane during a test).
actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Polls `condition` until it holds or `timeout` passes (a throwing check counts as false).
func eventually(timeout: Duration = .seconds(240), _ condition: @Sendable () async throws -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + TestTiming.scaled(timeout)
    while ContinuousClock.now < deadline {
        if (try? await condition()) == true { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return (try? await condition()) == true
}

extension KnowledgeFixture {
    /// An ended meeting with explicit languages.
    func meeting(_ lines: [String], locale: String?, outputLocale: String? = nil, at date: Date = .now) async throws -> Int64 {
        let id = try await store.startMeeting(at: date, locale: locale.map(Locale.init(identifier:)),
                                              outputLocale: outputLocale.map(Locale.init(identifier:)))
        for (i, line) in lines.enumerated() {
            try await store.append(Segment(channel: i % 2 == 0 ? .others : .me, start: Double(i * 10), end: Double(i * 10 + 8),
                                           text: line, isFinal: true), to: id)
        }
        try await store.endMeeting(id, at: date + 600)
        return id
    }
}

extension ScriptedChat {
    /// True when the request asks to expand the user's notes.
    static func isNoteRequest(_ messages: [ChatMessage]) -> Bool { messages.contains { $0.content.contains("<<<NOTE") } }

    /// A valid answer for a notes request: every note gets one sentence that quotes the first segment sent.
    static func notesJSON(_ messages: [ChatMessage], differs: Bool = false) -> String {
        guard let (id, text) = firstSegment(messages) else { return #"{"sentences": []}"# }
        let quote = String(text.prefix(30)).replacingOccurrences(of: "\"", with: "")
        let sentence = #"{"text": "Said: \#(quote).", "seg": [\#(id)], "quote": "\#(quote)", "differs": \#(differs)}"#
        let content = messages.first { $0.content.contains("<<<NOTE") }?.content ?? ""
        let count = (1...9).filter { content.contains("<<<NOTE \($0)\n") }.count
        if count == 0 { return #"{"sentences": [\#(sentence)]}"# }
        return #"{"notes": [\#((1...count).map { #"{"n": \#($0), "sentences": [\#(sentence)]}"# }.joined(separator: ","))]}"#
    }
}

/// A chat model that keeps the meeting read: records what it was asked to read and how often it was pinned.
final class WarmChat: ChatModel, WarmableChatModel, @unchecked Sendable {
    typealias Handler = ScriptedChat.Handler
    private let lock = NSLock()
    private var _reads: [[ChatMessage]] = []
    private var _pins = 0, _unpins = 0, _active = 0, _maxActive = 0, _drops = 0
    private var _dropped: [Set<KeptSlot>] = []
    private let handler: Handler
    var kept = 0
    var rate: Double? = 150
    var hasRoom = true
    var readDelay: Duration = .zero
    var contextTokens: Int? { get async { nil } }

    init(_ handler: @escaping Handler) { self.handler = handler }

    var reads: [[ChatMessage]] { lock.withLock { _reads } }
    var pins: Int { lock.withLock { _pins } }
    var unpins: Int { lock.withLock { _unpins } }
    var drops: Int { lock.withLock { _drops } }
    var dropped: [Set<KeptSlot>] { lock.withLock { _dropped } }
    var maxConcurrentReads: Int { lock.withLock { _maxActive } }

    private var _chatCalls: [ScriptedChat.Call] = []
    var calls: [ScriptedChat.Call] { lock.withLock { _chatCalls } }

    func chat(_ messages: [ChatMessage], _ options: ChatOptions, onProgress: (@Sendable (Int) -> Void)?) async throws -> ChatResult {
        let n = lock.withLock { () -> Int in _chatCalls.append(.init(messages: messages, options: options)); return _chatCalls.count }
        return try await handler(messages, options, n)
    }

    func readMeeting(_ messages: [ChatMessage], onPrefill: (@Sendable (Int, Int) -> Void)?) async throws {
        lock.withLock { _reads.append(messages); _active += 1; _maxActive = max(_maxActive, _active) }
        defer { lock.withLock { _active -= 1 } }
        if readDelay > .zero { try await Task.sleep(for: readDelay) }
    }
    func meetingPrefixHasRoom() async -> Bool { hasRoom }
    func pinMeeting() async { lock.withLock { _pins += 1 } }
    func unpinMeeting() async { lock.withLock { _unpins += 1 } }
    func dropKeptTranscripts(_ slots: Set<KeptSlot>) async { lock.withLock { _drops += 1; _dropped.append(slots) } }
    func keptMeetingTokens() async -> Int { kept }
    func keptAskTokens() async -> Int { 0 }
    func readingRate() async -> Double? { rate }
}
