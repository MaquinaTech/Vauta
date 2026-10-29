// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The closing pass: one more request over the last stretch of the meeting, so the tasks agreed at the very end (which a long meeting's
/// extracts keep one of, and a single call lists one or two of) are not lost. Its items go through the same checks as every other item and
/// join what was found; the earlier items win on a duplicate. It fails open: a reply that cannot be read adds nothing.
extension LLMService {
    /// The extraction the minutes use (the evaluation switches parts on and off to compare the old and the new one). Internal on purpose: the
    /// app module cannot set `.explain`, which puts item text into the counts; the app runs `MinutesRelease.extraction(integrated:)`.
    func setMinutesExtraction(_ extraction: MinutesExtraction) { minutesExtractionOverride = extraction }
    func setMinutesSummary(_ summary: MinutesSummary) { minutesSummaryOverride = summary }
    func setMinutesHarness(_ harness: MinutesHarness) { minutesHarnessOverride = harness }
    func setMinutesQuestions(_ questions: MinutesQuestions) { minutesQuestionsOverride = questions }

    /// What the minutes run on `chat`: each part the evaluation forced, else the release choice for the backend (`MinutesRelease.choices(for:)`).
    /// Only the integrated model reads the request (`MinutesHarness`), whatever is forced.
    func minutesChoices(for chat: ChatProvider) -> MinutesChoices {
        let release = MinutesRelease.choices(for: chat)
        return MinutesChoices(extraction: minutesExtractionOverride ?? release.extraction, summary: minutesSummaryOverride ?? release.summary,
                              harness: chat.integrated ? minutesHarnessOverride ?? release.harness : .legacy, questions: minutesQuestionsOverride ?? release.questions)
    }

    /// Hard cap of the integrated model's closing request: the larger of this and 30% of the first pass.
    static let closingFloor = 20.0
    static let closingShare = 0.3

    /// Integrated model: the existing second-pass request on one window (the closing stretch), on the prefix the first pass left.
    func findClosingItems(minutes: ValidatedMinutes, segments: [CitableSegment], base: [ChatMessage], request: VautaPrompts.MinutesRequest, chat: ChatProvider,
                          entityIDs: Set<Int>, slot: KeptSlot, firstPassSeconds: Double, validate: (String) throws -> ValidatedMinutes) async throws -> ValidatedMinutes {
        guard let window = MinutesWindows.closing(segments, tokens: 3_000, line: VautaPrompts.streamingLine) else { return minutes }
        try Task.checkCancellation()
        let budget = max(Self.closingFloor, Self.closingShare * firstPassSeconds)
        let ids = Set(window.segments.map(\.id))
        let listed = minutes.decisions.filter { ids.contains($0.segment) }.map { "Decision: " + $0.text }
            + minutes.tasks.filter { ids.contains($0.segment) }.map { "Task: " + $0.text }
        let messages = base + [VautaPrompts.itemsInstruction(request, first: window.first, last: window.last, listed: listed, closing: true)]
        let options = ChatOptions(model: .deep, maxTokens: 1_200, purpose: .minutes,
                                  outputSchema: OutputSchemas.items(segments: Set(ids.map { Int($0) }), entities: entityIDs),
                                  reusePrefix: true, priority: .minutes, maxSeconds: budget, slot: slot, onPrefill: nil)
        setStage(.findingItems(part: 1, of: 1))
        defer { setStage(nil) }
        let result: ChatResult
        do { result = try await chat.model.chat(messages, options, onProgress: nil) } catch is CancellationError { throw CancellationError() } catch { return minutes }
        return Self.mergeClosing(result, into: minutes, segments: segments, validate: validate)
    }

    /// Any provider on the map-reduce path: the closing stretch alone, in the standard layout, with the closing instruction.
    func closeMeeting(minutes: ValidatedMinutes, segments: [CitableSegment], job: MinutesJob, validate: (String) throws -> ValidatedMinutes) async -> ValidatedMinutes {
        let instruction = VautaPrompts.closingInstruction(job.request)
        let fixed = PromptText.tokens([job.system, job.entities, instruction])
        let room = max(job.budget.blockInput / 4, job.budget.blockInput - fixed - 16)
        guard let window = MinutesWindows.closing(segments, tokens: room, line: VautaPrompts.line), !Task.isCancelled else { return minutes }
        let ids = Set(window.segments.map { Int($0.id) })
        let messages = [job.system, job.entities, VautaPrompts.transcriptMessage(window.segments), instruction]
        let options = job.options(maxTokens: job.budget.blockOutput, thinking: false, schema: OutputSchemas.items(segments: ids, entities: job.offered.entities))
        guard let result = try? await job.chat.model.chat(messages, options, onProgress: nil) else { return minutes }
        return Self.mergeClosing(result, into: minutes, segments: segments, validate: validate)
    }

    private static func mergeClosing(_ result: ChatResult, into minutes: ValidatedMinutes, segments: [CitableSegment], validate: (String) throws -> ValidatedMinutes) -> ValidatedMinutes {
        let text = result.isTruncated ? (ModelOutput.closingTruncatedJSON(result.content) ?? result.content) : result.content
        guard let wrapped = wrapItems(text), let checked = try? validate(wrapped) else { return minutes }
        let order = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($1.id, $0) })
        var merged = MinutesWindows.merge(minutes, with: checked, order: order)
        merged.minutes.counts["closing.addedTasks"] = merged.addedTasks
        merged.minutes.counts["closing.addedDecisions"] = merged.addedDecisions
        return merged.minutes
    }
}
