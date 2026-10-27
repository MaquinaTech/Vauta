// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The person's choices for the brief (see `BriefPreferences` for where they are kept).
public struct BriefSettings: Sendable, Equatable {
    public var remindersEnabled = false
    public var reminderListIDs: Set<String> = []
    /// "Use the invitation's notes": read in memory, shown as plain text, used for ranking and the local agenda; never stored, never
    /// sent to a server.
    public var useInvitationNotes = true

    public init(remindersEnabled: Bool = false, reminderListIDs: Set<String> = [], useInvitationNotes: Bool = true) {
        self.remindersEnabled = remindersEnabled
        self.reminderListIDs = reminderListIDs
        self.useInvitationNotes = useInvitationNotes
    }
}

/// What the Reminders part of the page should say.
public enum BriefRemindersState: Sendable, Equatable {
    case off
    case notAsked
    case denied
    case noLists
    case shown
}

/// Steps 1 to 5 of the pipeline: the event, the read-only lookup, the candidates, the ranking and the assembly. No model
/// writes anything here; a recording or a Mac that is too hot only makes the ranking lexical (or, at critical heat, builds nothing).
public struct BriefComposer: Sendable {
    public struct Result: Sendable {
        /// nil when the Mac is critically hot (the panel says so).
        public let snapshot: BriefSnapshot?
        public let policy: BriefPolicy
        public let reminders: BriefRemindersState
        /// The attendees for the agenda's name check.
        public let facts: BriefFacts?
    }

    private let store: MeetingStore
    private let retriever: (any BriefRetriever)?
    private let reminderSource: (any BriefReminderSource)?

    public init(store: MeetingStore, retriever: (any BriefRetriever)?, reminders: (any BriefReminderSource)?) {
        self.store = store
        self.retriever = retriever
        self.reminderSource = reminders
    }

    public func build(_ event: BriefEvent, settings: BriefSettings, environment: BriefEnvironment, backend: BriefBackend? = nil,
                      integratedLoaded: Bool = false, now: Date = AppClock.now) async -> Result {
        let policy = BriefPolicy.decide(environment, backend: backend, integratedLoaded: integratedLoaded)
        guard policy.build else { return Result(snapshot: nil, policy: policy, reminders: .off, facts: nil) }

        let facts = (try? await store.briefFacts(for: event)) ?? BriefFacts()
        let invitation = settings.useInvitationNotes ? BriefInvitationNotes.agendaLines(from: event.invitationNotes) : []
        let locale = facts.last?.locale
        let query = BriefQuery.text(event: event, facts: facts, invitationLines: invitation)
        let sufficient = BriefQuery.isSufficient(query, locale: locale)

        // Reminders: chosen lists, incomplete, in the window. Read only when the person turned them on and allowed them.
        var remindersState = BriefRemindersState.off
        var eligible: [BriefReminder] = []
        if settings.remindersEnabled, let source = reminderSource {
            switch await source.access {
            case .notDetermined: remindersState = .notAsked
            case .denied: remindersState = .denied
            case .granted:
                if settings.reminderListIDs.isEmpty {
                    remindersState = .noLists
                } else {
                    remindersState = .shown
                    let fetched = await source.incompleteReminders(in: settings.reminderListIDs, limit: BriefReminderFilter.maximumFetched)
                    // Reminders Vauta created from a task are not listed again: the task is shown once, as the task.
                    let ledger = (try? await store.liveReminderIdentifiers()) ?? LedgerIdentifiers()
                    eligible = BriefReminderFilter.eligible(fetched, listIDs: settings.reminderListIDs, event: event.start, ledger: ledger)
                }
            }
        }

        // Ranking: the search model when it is ready and nothing keeps it idle, else the keyword gate.
        var mode = BriefRankingMode.keyword
        var taskCosines: [Int64: Double]?
        var reminderCosines: [String: Double]?
        if sufficient, policy.embeddings, let retriever, await retriever.mode() == .semantic {
            let taskTexts = facts.openTasks.map(\.task.text)
            let reminderTexts = eligible.map(\.title)
            if let cosines = await retriever.cosines(query: query, texts: taskTexts + reminderTexts), cosines.count == taskTexts.count + reminderTexts.count {
                mode = .semantic
                taskCosines = Dictionary(uniqueKeysWithValues: zip(facts.openTasks.map(\.task.id), cosines.prefix(taskTexts.count)).map { ($0, $1) })
                reminderCosines = Dictionary(uniqueKeysWithValues: zip(eligible.map(\.id), cosines.dropFirst(taskTexts.count)).map { ($0, $1) })
            }
        }
        var meetingHits: [BriefMeetingHit] = []
        var documentHits: [BriefDocumentHit] = []
        if sufficient, let retriever {
            let exclude = Set([facts.last?.meetingID].compactMap { $0 })
            meetingHits = await retriever.meetings(for: query, excluding: exclude, limit: 12, mode: mode)
            documentHits = await retriever.documents(for: query, limit: 12, mode: mode)
        }
        let assembly = BriefAssembly(event: event, facts: facts, invitationLines: invitation, query: query, querySufficient: sufficient, mode: mode,
                                     meetingHits: meetingHits, documentHits: documentHits, taskCosines: taskCosines, reminders: eligible,
                                     reminderCosines: reminderCosines, now: now, locale: locale)
        return Result(snapshot: BriefBuilder.assemble(assembly), policy: policy, reminders: remindersState, facts: facts)
    }
}

/// Writes the agenda. The app's implementation asks the person's model (Apple, the integrated model or a server); tests use fakes.
public protocol BriefAgendaWriter: Sendable {
    /// The model's reply to the prompt, or an error. `schema` is used only by the backends that decode within a grammar.
    func write(_ messages: [ChatMessage], schema: OutputSchema, maxTokens: Int, backend: BriefBackend) async throws -> String
}

public enum BriefAgenda {
    /// What a run did, as counts only (never the text): for diagnostics and the evaluation.
    public struct Report: Sendable, Equatable {
        public var offered = 0
        public var promptTokens = 0
        public var proposed = 0
        public var accepted = 0
        public var rejected: [BriefVerifier.Rejection: Int] = [:]
        public init() {}
    }

    /// Step 6: one request, then the verifier. Only this section depends on the model: a failure, a timeout or fewer than two verified
    /// lines gives `.noSuggestions` and the rest of the brief is untouched.
    public static func run(snapshot: BriefSnapshot, backend: BriefBackend?, writer: any BriefAgendaWriter, language: OutputLanguage, budget: ContextBudget,
                           environment: BriefEnvironment, integratedLoaded: Bool = false, calendar: Calendar = .current,
                           timeout: Double? = nil, report: (@Sendable (Report) -> Void)? = nil) async -> BriefAgendaState {
        let policy = BriefPolicy.decide(environment, backend: backend, integratedLoaded: integratedLoaded)
        switch policy.agenda {
        case .waitForRecording, .skip(.lowPower), .skip(.thermal): return .paused
        case .skip: return .unavailable
        case .run: break
        }
        guard let backend else { return .unavailable }
        let instructionTokens = PromptText.tokens(BriefAgendaPrompt.instructions(language: language)) + 80
        let offered = BriefAgendaPrompt.pack(snapshot, backend: backend, budget: budget, instructionTokens: instructionTokens)
        guard !offered.isEmpty else { return .none }
        let people = snapshot.section(.people)?.items ?? []
        let messages = BriefAgendaPrompt.messages(snapshot: snapshot, offered: offered, language: language, attendees: people.map(\.text))
        let schema = BriefAgendaPrompt.schema(offered: offered)
        let maxTokens = budget.briefOutput
        let reply: String
        do {
            reply = try await withTimeout(seconds: timeout ?? backend.timeoutSeconds) { try await writer.write(messages, schema: schema, maxTokens: maxTokens, backend: backend) }
        } catch {
            return .noSuggestions
        }
        let context = BriefVerifier.Context(snapshot: snapshot, offered: Set(offered.map(\.id)), resolvedNames: people.filter { $0.entityID != nil }.map(\.text),
                                            unresolvedNames: people.filter { $0.entityID == nil }.map(\.text), language: language.identifier, calendar: calendar)
        let proposed = BriefAgendaPrompt.parse(reply)
        let result = BriefVerifier.verify(proposed, context: context)
        var counts = Report()
        counts.offered = offered.count
        counts.promptTokens = PromptText.tokens(messages)
        counts.proposed = proposed.count
        counts.accepted = result.accepted.count
        counts.rejected = result.rejectionCounts
        report?(counts)
        return result.isShown ? .lines(result.accepted) : .noSuggestions
    }

    struct TimedOut: Error {}

    static func withTimeout<T: Sendable>(seconds: Double, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }
}
