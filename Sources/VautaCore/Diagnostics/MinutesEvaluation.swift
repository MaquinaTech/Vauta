// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// A key store that lives in memory: the evaluation never touches the Keychain.
final class MemoryKeyStore: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SymmetricKey?

    func existingKey() throws -> SymmetricKey? { lock.withLock { stored } }

    func createKey() throws -> SymmetricKey {
        lock.withLock {
            let key = SymmetricKey(size: .bits256)
            stored = key
            return key
        }
    }

    func replace(with key: SymmetricKey) throws { lock.withLock { stored = key } }

    func remove() throws { lock.withLock { stored = nil } }
}

/// One chat call of an evaluation run: what was asked and measured, never the text.
public struct EvaluationCall: Codable, Sendable {
    public var startedAt: Double
    public var endedAt: Double
    public var promptTokens: Int
    public var completionTokens: Int
    public var cachedTokens: Int
    public var finishReason: String
    /// The answer contains a JSON object that parses.
    public var jsonValid: Bool
    /// From the entry of `ChatModel.chat` for both providers.
    public var timeToFirstTokenSeconds: Double?
    /// The integrated model's engine-internal figure (from the start of its generation loop); nil for Apple.
    public var engineFirstTokenSeconds: Double?
    /// Mask cost of a schema-constrained call (integrated model only).
    public var constraintTiming: ConstraintTiming?
    public var totalSeconds: Double
    public var schemaConstrained: Bool
    /// The output budget the call was given, and the app's own estimate of the prompt (the on-device model reports no usage).
    public var maxTokens: Int?
    public var promptEstimate: Int?
    /// Characters of the answer (never the text itself).
    public var outputCharacters: Int?
    /// The call threw (the error's description); the other figures are then only what was known before it.
    public var error: String?
    /// Where the time before the first token went (the integrated model): tokenising, waits, tokens that had to be read, chunks.
    public var breakdown: LatencyBreakdown?
}

/// A failed evaluation run that still reports the calls it made.
public protocol CallsCarrying: Error {
    var calls: [EvaluationCall] { get }
}

/// Remembers the answers of the model, so the evaluation can count what it proposed before the app's checks, and the
/// timing and size of every call.
final class RecordingChat: ChatModel, @unchecked Sendable {
    fileprivate let base: any ChatModel
    fileprivate let lock = NSLock()
    fileprivate var _warmSeconds: [Double] = []
    private var _last: String?
    private var _replies: [String] = []
    private var _calls: [EvaluationCall] = []

    init(_ base: any ChatModel) { self.base = base }

    var last: String? { lock.withLock { _last } }
    /// Every reply of the run, in order (the sets are public transcripts).
    var replies: [String] { lock.withLock { _replies } }
    var calls: Int { lock.withLock { _calls.count } }
    var records: [EvaluationCall] { lock.withLock { _calls } }
    /// Seconds of each reading of the meeting while it was replayed as a recording (`--warm`).
    var warmSeconds: [Double] { lock.withLock { _warmSeconds } }
    var contextTokens: Int? { get async { await base.contextTokens } }

    func chat(_ messages: [ChatMessage], _ options: ChatOptions, onProgress: (@Sendable (Int) -> Void)?) async throws -> ChatResult {
        let started = Date()
        let result: ChatResult
        do {
            result = try await base.chat(messages, options, onProgress: onProgress)
        } catch {
            lock.withLock {
                _calls.append(EvaluationCall(startedAt: started.timeIntervalSince1970, endedAt: Date().timeIntervalSince1970, promptTokens: 0, completionTokens: 0,
                                             cachedTokens: 0, finishReason: "error", jsonValid: false, timeToFirstTokenSeconds: nil, engineFirstTokenSeconds: nil,
                                             totalSeconds: Date().timeIntervalSince(started), schemaConstrained: options.outputSchema != nil || options.constraint != nil,
                                             maxTokens: options.maxTokens, promptEstimate: PromptText.tokens(messages), outputCharacters: nil, error: "\(error)"))
            }
            throw error
        }
        let ended = Date()
        let json: Bool = {
            guard let a = result.content.firstIndex(of: "{"), let b = result.content.lastIndex(of: "}"), a < b,
                  let d = String(result.content[a...b]).data(using: .utf8) else { return false }
            return (try? JSONSerialization.jsonObject(with: d)) is [String: Any]
        }()
        let reason: String
        switch result.finishReason { case .stop?: reason = "stop"; case .length?: reason = "length"; case nil: reason = "unknown"; default: reason = "other" }
        lock.withLock {
            _last = result.content
            _replies.append(result.content)
            _calls.append(EvaluationCall(startedAt: started.timeIntervalSince1970, endedAt: ended.timeIntervalSince1970, promptTokens: result.promptTokens,
                                         completionTokens: result.completionTokens, cachedTokens: result.cachedTokens, finishReason: reason, jsonValid: json,
                                         timeToFirstTokenSeconds: result.firstTokenSeconds, engineFirstTokenSeconds: result.engineFirstTokenSeconds, totalSeconds: ended.timeIntervalSince(started),
                                         schemaConstrained: options.outputSchema != nil || options.constraint != nil, maxTokens: options.maxTokens,
                                         promptEstimate: PromptText.tokens(messages), outputCharacters: result.content.count, error: nil))
            _calls[_calls.count - 1].constraintTiming = result.constraintTiming
            _calls[_calls.count - 1].breakdown = result.breakdown
        }
        return result
    }
}

extension RecordingChat: WarmableChatModel {
    func readMeeting(_ messages: [ChatMessage], onPrefill: (@Sendable (Int, Int) -> Void)?) async throws {
        guard let warmable = base as? WarmableChatModel else { return }
        let started = Date()
        try await warmable.readMeeting(messages, onPrefill: onPrefill)
        lock.withLock { _warmSeconds.append(Date().timeIntervalSince(started)) }
    }
    func meetingPrefixHasRoom() async -> Bool { await (base as? WarmableChatModel)?.meetingPrefixHasRoom() ?? false }
    func pinMeeting() async { await (base as? WarmableChatModel)?.pinMeeting() }
    func unpinMeeting() async { await (base as? WarmableChatModel)?.unpinMeeting() }
    func keptMeetingTokens() async -> Int { await (base as? WarmableChatModel)?.keptMeetingTokens() ?? 0 }
    func keptAskTokens() async -> Int { await (base as? WarmableChatModel)?.keptAskTokens() ?? 0 }
    func readingRate() async -> Double? { await (base as? WarmableChatModel)?.readingRate() }
}

/// The model an evaluation run uses: Apple's on-device model, or the integrated Gemma 4 from a throwaway install folder.
public struct EvaluationModel: Sendable {
    public var name: String
    public var kind: String
    let make: @Sendable () -> (model: any ChatModel, contextTokens: Int, supports: (@Sendable (Locale) -> Bool)?, unavailable: String?)

    public static let apple = EvaluationModel(name: MinutesEvaluation.modelName, kind: "apple") {
        let apple = AppleChatModel()
        return (apple, apple.contextSize, { apple.supports($0) },
                apple.availability == .available ? nil : String(describing: apple.availability))
    }

    /// The integrated model, from the install folder named by `VAUTA_LLM_MODEL_DIR`. `sampling` nil = the card settings with a
    /// seed derived from the prompt; `.greedy` = greedy.
    public static func integrated(store: LanguageModelStore, greedy: Bool, engine: LanguageModelEngine? = nil) -> EvaluationModel {
        let e = engine ?? LanguageModelEngine(store: store)
        return EvaluationModel(name: "Gemma 4 E4B-it, 4-bit, MLX, \(greedy ? "greedy" : "card sampling")", kind: "integrated") {
            guard case .installed = store.disk() else { return (IntegratedChatModel(engine: e), 0, nil, "the language model is not installed") }
            let model = IntegratedChatModel(engine: e, sampling: { greedy ? .greedy : .card(seed: $0) })
            return (model, IntegratedChatModel.contextWindow, { model.supports($0) }, nil)
        }
    }
}

/// The chosen model only: no server, no Keychain. Embeddings are off unless the run names a search model (`llm-eval --search-model`),
/// then they are that model, as with "Search by meaning on this Mac" chosen in Settings.
final class EvaluationProviders: ModelProviding, @unchecked Sendable {
    let chatModel: RecordingChat
    let contextTokens: Int
    let supports: (@Sendable (Locale) -> Bool)?
    let unavailable: String?
    let integrated: Bool
    let searchModel: (any ChunkBudgeting)?

    init(_ model: EvaluationModel, searchModel: (any ChunkBudgeting)? = nil) {
        self.searchModel = searchModel
        integrated = model.kind == "integrated"
        let made = model.make()
        chatModel = RecordingChat(made.model)
        contextTokens = made.contextTokens
        supports = made.supports
        unavailable = made.unavailable
    }

    func reload() -> ProviderIssue? { nil }
    var settings: ModelProviderSettings { ModelProviderSettings(chat: .onDevice, embeddings: searchModel == nil ? .none : .onDeviceModel) }
    func chat() -> Result<ChatProvider, ProviderUnavailable> {
        if unavailable != nil { return .failure(ProviderUnavailable(issue: .onDeviceModel(.unavailable))) }
        return .success(ChatProvider(model: chatModel, contextTokens: contextTokens, onDevice: true, supports: supports, integrated: integrated))
    }
    func embeddings() -> EmbeddingProvider {
        guard let searchModel else { return .disabled }
        return .available(model: { _ in searchModel }, expectedModel: { _ in GemmaEmbeddingModel.space.model })
    }
    var server: (client: LLMClient, config: LLMServerConfig)? { nil }
    var refinementChat: (any ChatModel)? { nil }
}

/// The preferences an evaluation's services read and write (the "coverage reached" marker of the search model): a suite of its own for
/// this process, removed when the run ends, so an evaluation never touches `UserDefaults.standard`.
enum EvaluationDefaults {
    static let name = "vauta.evaluation.\(UUID().uuidString)"
    /// A suite of its own, never `.standard`: `init(suiteName:)` only fails for the process's own domain names, which this one is not.
    nonisolated(unsafe) static let suite = UserDefaults(suiteName: name)!
    static func remove() { suite.removePersistentDomain(forName: name) }
}

/// `Vauta minutes-file`: EVALUATION ONLY. Writes the minutes of a PUBLIC transcript (the AMI words used for the
/// word-error-rate measurement) with the app's own minutes code and Apple's on-device model, in a throwaway encrypted
/// store in a temporary folder with an in-memory key. It never touches the user's store or Keychain, never contacts a
/// model server and never records or writes audio. Its output feeds `eval/scripts/score_minutes.py`.
public enum MinutesEvaluation {
    public struct Passage: Sendable, Decodable {
        public let id: Int64
        public let text: String
        public let start: Double?
        /// "Speaker 3 (remote)": the only identity in public meeting corpora. It is written in front of the text, as the
        /// speaker's label is in the prompts.
        public let speaker: String?
    }

    public struct Transcript: Sendable, Decodable {
        public let passages: [Passage]
        public let meeting: String?
        public let language: String?
    }

    public struct Item: Sendable, Encodable {
        public let kind: String
        public let text: String
        public let citations: [Int64]
        public let unconfirmed: Bool
        public var owner: String?
        /// `YYYY-MM-DD`.
        public var due: String?
        /// The owner is not backed by the words or a confident speaker label ("owner not confirmed"; the default email leaves the name out).
        public var ownerUncertain = false
        /// "person", "speaker" (a speaker nobody has named) or "none".
        public var ownerKind: String?
        /// Why it is unconfirmed, as the store keeps it (`UnconfirmedReason`: `rank`, `rank:<code>` or the code of a check); nil when it is not.
        public var reason: String?

        public init(kind: String, text: String, citations: [Int64], unconfirmed: Bool, owner: String? = nil, due: String? = nil,
                    ownerUncertain: Bool = false, ownerKind: String? = nil, reason: String? = nil) {
            self.reason = reason
            self.kind = kind
            self.text = text
            self.citations = citations
            self.unconfirmed = unconfirmed
            self.owner = owner
            self.due = due
            self.ownerUncertain = ownerUncertain
            self.ownerKind = ownerKind
        }
    }

    public struct Result: Sendable, Encodable {
        public let model: String
        public let contextTokens: Int
        public let modelCalls: Int
        /// Decisions and tasks the model proposed in its final answer, before the app checked them.
        public let proposed: Int
        /// Proposals the app dropped (no real passage cited, or a quote that is not word for word in it).
        public let dropped: Int
        public let items: [Item]
        public var summary = ""
        public var topics: [String] = []
        public var openQuestions: [String] = []
        /// Timing and size of every model call (no text).
        public let calls: [EvaluationCall]
        /// What the checks did (counts and reasons, no text).
        public var diagnostics: MinutesDiagnostics?
        /// The model's last reply, before the checks (the sets are public transcripts), to see what the checks were given.
        public var lastReply: String?
        /// Every reply of the run in order, to see what each step produced (public transcripts only).
        public var replies: [String]?
        /// With `warm`: the seconds each reading of the meeting took while it was replayed as a recording.
        public var warmSeconds: [Double]?
        public var callsBeforeMinutes: Int?
        /// The decisions Apple's "was it decided?" check dropped (public transcripts only).
        public var filteredDecisions: [String]?
    }

    public enum Failure: Error, CustomStringConvertible {
        case modelUnavailable(String)
        case jobFailed(String)
        case noAnswer
        public var description: String {
            switch self {
            case .modelUnavailable(let why): "Apple's on-device model is not available (\(why))."
            case .jobFailed(let message): "The minutes job failed: \(message)"
            case .noAnswer: "The model gave no answer."
            }
        }
    }

    /// A run that failed after making these calls.
    public struct RunFailure: Error, CustomStringConvertible, CallsCarrying {
        public let failure: Failure
        public let calls: [EvaluationCall]
        public var description: String { failure.description }
    }

    public static var modelName: String {
        "Apple on-device language model (SystemLanguageModel.default), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    /// Removes the preferences suite of this process's evaluations; the command that started them calls it once, when it ends.
    public static func removeEvaluationDefaults() { EvaluationDefaults.remove() }

    /// - Parameters:
    ///   - arms: which parts of the integrated minutes are on.
    ///   - warm: replay the transcript as a recording: the integrated model reads the meeting as the segments arrive (every ~600
    ///     characters), the way the app does, and the minutes are written after the last one.
    ///   - renumberFinal: the final labelling numbers the voices in reverse (the live clustering's number n becomes max + 1 - n).
    ///   - speakerTags: the speakers of the transcript are stored as speakers of the meeting (as after a real recording), not written
    ///     into the text of each line.
    public static func run(_ transcript: Transcript, language: Locale = Locale(identifier: "en-US"), model: EvaluationModel = .apple,
                           arms: MinutesArms = .shipped, warm: Bool = false, speakerTags: Bool = true, renumberFinal: Bool = false,
                           decidedFilter: Bool = false, extraction: MinutesExtraction = .shipped, summary: MinutesSummary = .shipped, harness: MinutesHarness = .shipped,
                           questions: MinutesQuestions = .shipped, outputLocale: Locale? = nil) async throws -> Result {
        let providers = EvaluationProviders(model)
        if let why = providers.unavailable { throw Failure.modelUnavailable(why) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-minutes-eval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try MeetingStore(directory: directory, keyStore: MemoryKeyStore())
        // A fixed date, so "on Friday" resolves the same on every run.
        let date = Date(timeIntervalSince1970: 1_104_537_600)
        let meeting = try await store.startMeeting(at: date, locale: language, outputLocale: outputLocale ?? language)
        // The suite is removed by the entry point that started the run (`removeEvaluationDefaults`), not here: other services share it.
        let service = LLMService(store: store, providers: providers, searchDefaults: EvaluationDefaults.suite)
        await service.setMinutesArms(arms)
        await service.setDecidedFilter(decidedFilter)
        await service.setMinutesExtraction(extraction)
        await service.setMinutesSummary(summary)
        await service.setMinutesHarness(harness)
        await service.setMinutesQuestions(questions)
        var clock = 0.0
        var rowIDs: [Int64] = []
        var ordinals: [Int?] = []
        var charsSinceTick = 0
        var tick = 0
        if warm { await service.setRecording(true, meetingID: meeting) }
        for p in transcript.passages {
            let start = p.start ?? clock
            clock = start + 10
            let ordinal = speakerTags ? p.speaker.flatMap(Self.speakerOrdinal) : nil
            let text = speakerTags && ordinal != nil ? p.text : (p.speaker.map { "\($0): \(p.text)" } ?? p.text)
            let id = try await store.append(Segment(channel: .others, start: start, end: start + 8, text: text, isFinal: true), to: meeting)
            rowIDs.append(id)
            ordinals.append(ordinal)
            if warm {
                await service.segmentSaved(meetingID: meeting, segmentID: id, speaker: ordinal, characters: text.count)
                charsSinceTick += text.count
                if charsSinceTick >= 600 { charsSinceTick = 0; tick += 1; await service.readMeetingNow(meeting) }
            }
        }
        // The speakers of the transcript, finalized after the recording like the app's own (one per label).
        if speakerTags {
            let used = Set(ordinals.compactMap { $0 }).sorted()
            if !used.isEmpty {
                let top = used.max() ?? 1
                func final(_ o: Int) -> Int { renumberFinal ? top + 1 - o : o }
                let assignments = zip(rowIDs, ordinals).compactMap { id, o in o.map { SegmentSpeakerAssignment(segmentID: id, channel: .others, ordinal: final($0)) } }
                try await store.finalizeSpeakers(meetingID: meeting, speakers: used.map { SpeakerDraft(channel: .others, ordinal: final($0)) }, assignments: assignments)
            }
        }
        try await store.endMeeting(meeting, at: date + clock + 5)
        if warm { await service.setRecording(false, meetingID: meeting) }
        // Database ids to the transcript's own ids, by order.
        let stored = try await store.citableSegments(meeting)
        guard stored.count == transcript.passages.count else { throw Failure.noAnswer }
        var passageOf: [Int64: Int64] = [:]
        for (segment, passage) in zip(stored, transcript.passages) { passageOf[segment.id] = passage.id }

        let finished = Finish()
        let callsBeforeMinutes = providers.chatModel.calls
        await service.setJobEventHandler { event in if event.kind == .minutes { finished.set(event.outcome) } }
        await service.regenerateMinutes(meeting)
        let outcome = await finished.wait()
        if case .failed(let message) = outcome { throw RunFailure(failure: .jobFailed(message), calls: providers.chatModel.records) }
        if outcome == .cancelled { throw Failure.noAnswer }

        var items: [Item] = []
        for d in try await store.decisions(meeting) {
            items.append(Item(kind: "decision", text: d.text, citations: d.segmentID.flatMap { passageOf[$0] }.map { [$0] } ?? [], unconfirmed: d.unconfirmed,
                              reason: d.unconfirmed ? d.unconfirmedReason : nil))
        }
        for t in try await store.tasks(meeting) {
            items.append(Item(kind: "task", text: t.text, citations: t.segmentID.flatMap { passageOf[$0] }.map { [$0] } ?? [], unconfirmed: t.unconfirmed,
                              owner: t.ownerName, due: t.dueDay?.string ?? t.due.map { Self.day($0) }, ownerUncertain: t.ownerUncertain,
                              ownerKind: t.ownerID != nil ? "person" : (t.ownerSpeakerID != nil ? "speaker" : "none"),
                              reason: t.unconfirmed ? t.unconfirmedReason : nil))
        }
        let card = try await store.card(meeting)
        // Counted over every reply that proposed items (first pass, blocks, closing request): the last reply alone is the closing request
        // with the new extraction, which would make `proposed` and the rates built from it mean something else than with the old one.
        // `dropped` is the citation check's (quote not found, no segment), not the evidence filter's.
        let diagnostics = await service.lastMinutesDiagnostics
        let proposed = diagnostics?.proposed ?? providers.chatModel.replies.dropFirst(callsBeforeMinutes).reduce(0) { $0 + countProposals($1) }
        var result = Result(model: model.name, contextTokens: providers.contextTokens, modelCalls: providers.chatModel.calls,
                      proposed: max(proposed, items.count), dropped: diagnostics?.dropped ?? max(0, proposed - items.count), items: items,
                      summary: card?.summary ?? "", topics: card?.topics ?? [], openQuestions: card?.openQuestions ?? [], calls: providers.chatModel.records,
                      diagnostics: diagnostics, lastReply: providers.chatModel.last, replies: providers.chatModel.replies,
                      warmSeconds: providers.chatModel.warmSeconds, callsBeforeMinutes: callsBeforeMinutes)
        result.filteredDecisions = await service.lastDecidedDrops
        return result
    }

    /// 3 for "Speaker 3 (remote)" and "Speaker 3"; nil for any other label.
    static func speakerOrdinal(_ label: String) -> Int? {
        let digits = label.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard label.lowercased().hasPrefix("speaker"), let n = Int(digits), n >= 1 else { return nil }
        return n
    }

    static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// How many decisions and tasks the model's JSON proposes.
    static func countProposals(_ answer: String) -> Int {
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"),
              let data = String(answer[start...end]).data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
        return ["decisions", "decisiones", "tasks", "tareas"].reduce(0) { $0 + ((object[$1] as? [Any])?.count ?? 0) }
    }

    private final class Finish: @unchecked Sendable {
        private let lock = NSLock()
        private var outcome: LLMService.JobEvent.Outcome?
        func set(_ value: LLMService.JobEvent.Outcome) { lock.withLock { outcome = value } }
        func wait() async -> LLMService.JobEvent.Outcome {
            while true {
                if let value = lock.withLock({ outcome }) { return value }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}
