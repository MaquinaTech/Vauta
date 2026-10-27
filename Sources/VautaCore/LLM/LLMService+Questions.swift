// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What the model check (S5) came to.
public enum QuestionCheckResult: Sendable, Equatable {
    case checked(QuestionCheck)
    /// No usable reply (an invalid JSON, a decline, an error): the candidate is dropped.
    case failed
    /// The check did not answer within its time (counted apart: on the integrated model it means energy spent for nothing).
    case timedOut
    /// There is no model to ask for the recording (Apple Intelligence off, no server, the integrated model not ready).
    case unavailable
}

extension LLMService {
    /// The seconds the integrated model may decode for the check (Apple and servers have `liveCheckSeconds`).
    static let checkGemmaSeconds = 4.0
    func setLiveCheckSeconds(_ seconds: Double) { liveCheckSeconds = seconds }
    /// 64 are kept back to close the JSON; the other 96 hold the keys (about 20 tokens) and a 160-character rewrite (about 64 at 2.5 characters a token).
    static let checkGemmaTokens = 160
    /// The other models get room for the whole reply: Apple's reply of a Spanish rewrite was cut at 96 tokens in 63 checks of the first
    /// replay (an unfinished JSON is a failed check).
    static let checkOtherTokens = 192

    /// Whether a model can be used for the recording now (for the "paused" line). Apple's on-device model is not one: live answers are
    /// not offered with it (decision D16), also when it only stands in for a model that is missing.
    public func liveAnswersModelAvailable() -> Bool {
        guard let chat = try? chatProvider(for: .live) else { return false }
        return permitsLiveAnswers(chat)
    }

    /// Whether the backend that answers while recording now is one that offers live answers (`LiveAnswerDefaults.offered`).
    public nonisolated func liveAnswersOffered() -> Bool {
        !liveAnswerGate.enforced || LiveAnswerDefaults.offered(liveAnswersBackend())
    }

    /// The evaluation (`llm-eval`) measures Apple's model on purpose, so it takes the decision D16 gate off for its own service. The app
    /// never calls this.
    public nonisolated func disableLiveAnswerGate() { liveAnswerGate.enforced = false }

    /// Whether the provider that is about to be used offers live answers. Decided on the provider itself, not on a second read of the
    /// settings, so a fallback in between cannot let Apple's model answer.
    nonisolated func permitsLiveAnswers(_ chat: ChatProvider) -> Bool {
        !liveAnswerGate.enforced || LiveAnswerDefaults.offered(Self.backendKind(of: chat))
    }

    nonisolated static func backendKind(of chat: ChatProvider) -> LiveAnswerBackendKind {
        chat.integrated ? .integrated : chat.onDevice ? .apple : .server
    }

    /// Whether the "While recording" model is the integrated one (it keeps the meeting warm and charges energy per call).
    public func liveAnswersUseIntegratedModel() -> Bool {
        (try? chatProvider(for: .live))?.integrated == true
    }

    /// The backend that really answers while recording (with the integrated model chosen and "While recording" on Apple, a missing
    /// Apple model falls back to the integrated one and the other way round), or nil when there is no model for it.
    public nonisolated func liveAnswersBackend() -> LiveAnswerBackendKind? {
        guard case .success(let chat) = providers.chat(for: .live) else { return nil }
        return Self.backendKind(of: chat)
    }

    /// S5: one small call with the "While recording" model. Fails closed.
    public func checkQuestion(_ question: SettledQuestion, meetingID: Int64) async -> QuestionCheckResult {
        guard recording, liveSessionMeeting == meetingID else { return .failed }
        // One read of the provider: the one checked is the one used (decision D16).
        guard let chat = try? chatProvider(for: .live), permitsLiveAnswers(chat) else { return .unavailable }
        do { try await acquire(.auto) } catch { return .failed }
        defer { release() }
        var messages: [ChatMessage] = [.system(VautaPrompts.system), .user(QuestionCheck.instruction(for: question, compact: chat.integrated))]
        // The integrated model's grammar keeps 64 tokens back to close the JSON, so its budget is that plus the text it may write
        // (a rewrite of up to 160 characters); the others have no such reserve.
        var options = ChatOptions(model: .fast, maxTokens: chat.integrated ? Self.checkGemmaTokens : Self.checkOtherTokens, purpose: .liveAnswers, outputSchema: chat.integrated ? QuestionCheck.schema : nil,
                                  priority: .autoAnswer, maxSeconds: chat.integrated ? Self.checkGemmaSeconds : nil)
        // On the integrated model the transcript read so far is already in the kept prefix: the check is a suffix on it and reads
        // only the lines around the question. The prefix is not rewritten (the suffix is not kept).
        if chat.integrated, let prefix = await checkPrefix(chat: chat, meetingID: meetingID) {
            messages = prefix + [.user(QuestionCheck.instruction(for: question, afterOnly: true, compact: true))]
            options.reusePrefix = true
            options.slot = .meeting
        } else if !chat.integrated, !chat.onDevice {
            options.responseFormat = .jsonSchema(name: "question_check", schema: QuestionCheck.serverSchema.jsonSchemaData())
        }
        let model = chat.model
        let seconds = liveCheckSeconds
        let sentMessages = messages, sentOptions = options
        let (reply, timedOut) = await Self.raceWithTimeout(seconds: seconds + 2) { try? await Self.chatOnce(model, sentMessages, sentOptions) }
        guard let reply else { return timedOut ? .timedOut : .failed }
        status.reachable = true
        guard let check = QuestionCheck.parse(reply.content, candidate: question.candidate.text, language: question.candidate.language) else { return .failed }
        return .checked(check)
    }

    /// The meeting's transcript so far as the kept prefix has it, when the prefix is warm and at most `AutoAskRequest.maxCheckLag`
    /// tokens behind: the check has `liveCheckSeconds + 2` seconds, and the model reads about 150 tokens a second, so a longer lag
    /// would be read for nothing and the check would time out. Beyond it the check is the short standalone prompt (the lines
    /// around the question only).
    private func checkPrefix(chat: ChatProvider, meetingID: Int64) async -> [ChatMessage]? {
        guard let state = warm, state.meetingID == meetingID, state.segmentsRead > 0, !state.stopped,
              let all = try? await store.citableSegments(meetingID) else { return nil }
        let segments = withProvisionalSpeakers(all, meetingID: meetingID)
        let prefix: [ChatMessage] = [.system(VautaPrompts.system),
                                     await streamingPeople(meetingID: meetingID, entities: state.entities, selfEntity: state.selfEntity),
                                     VautaPrompts.streamingTranscriptMessage(segments)]
        let total = PromptText.tokens(prefix)
        guard total <= ContextBudget(contextTokens: chat.contextTokens).minutesInput,
              total - state.estimatedTokensRead <= AutoAskRequest.maxCheckLag else { return nil }
        return prefix
    }
}

extension LLMService {
    /// The first of `work` and a timeout. The work is an unstructured task that is cancelled when the timeout wins, and the race does not wait
    /// for it: a model that ignores cancellation cannot hold the lane (and so a typed Ask) past the timeout.
    static func raceWithTimeout(seconds: Double, _ work: @escaping @Sendable () async -> ChatResult?) async -> (ChatResult?, Bool) {
        let race = Race()
        let job = Task { await race.finish((await work(), false)) }
        let timer = Task {
            // A cancelled sleep is not a timeout.
            guard (try? await Task.sleep(for: .seconds(seconds))) != nil else { return }
            job.cancel()
            await race.finish((nil, true))
        }
        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            job.cancel()
            timer.cancel()
            Task { await race.finish((nil, false)) }
        }
        timer.cancel()
        return outcome
    }

    /// The result of a race: set once, read by one waiter.
    private actor Race {
        private var outcome: (ChatResult?, Bool)?
        private var waiter: CheckedContinuation<(ChatResult?, Bool), Never>?
        func finish(_ value: (ChatResult?, Bool)) {
            guard outcome == nil else { return }
            outcome = value
            waiter?.resume(returning: value)
            waiter = nil
        }
        func wait() async -> (ChatResult?, Bool) {
            if let outcome { return outcome }
            return await withCheckedContinuation { waiter = $0 }
        }
    }

    /// One request; a server that does not understand `response_format` (400, 415 or 422) is asked again without it.
    static func chatOnce(_ model: any ChatModel, _ messages: [ChatMessage], _ options: ChatOptions) async throws -> ChatResult {
        do {
            return try await model.chat(messages, options, onProgress: nil)
        } catch LLMError.http(let status, _) where options.responseFormat != nil && [400, 415, 422].contains(status) {
            var plain = options
            plain.responseFormat = nil
            return try await model.chat(messages, plain, onProgress: nil)
        }
    }
}
