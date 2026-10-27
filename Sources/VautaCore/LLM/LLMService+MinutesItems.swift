// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The second pass of the minutes on the integrated model (A2): after the one-call minutes, the meeting is read again one stretch at a
/// time (about 12 minutes or 3,000 tokens of transcript) and the model lists the decisions and tasks of that stretch only. Every call
/// shares the meeting's kept prefix with the first, so it costs its own suffix. What it lists goes through the same checks as the first
/// pass (quote, figures, owner) and joins what the first pass kept; the first pass wins on a duplicate.
extension LLMService {
    /// The wall time of the whole pass is capped at the larger of this and 60% of the first pass's.
    static let itemsPassFloor = 45.0
    static let itemsPassShare = 0.6
    /// The least time worth starting another window with.
    static let minimumWindowSeconds = 5.0

    /// Tests and the evaluation shorten the cap.
    func setItemsPassBudget(floor: Double, share: Double) { itemsPassBudget = (floor, share) }

    /// Arms of the integrated minutes (the evaluation switches them; the app uses all).
    public func setMinutesArms(_ arms: MinutesArms) { minutesArms = arms }

    /// - Returns: the merged minutes, or `minutes` unchanged when nothing could be added.
    func findMoreItems(minutes: ValidatedMinutes, segments: [CitableSegment], base: [ChatMessage], request: VautaPrompts.MinutesRequest,
                       chat: ChatProvider, entityIDs: Set<Int>, slot: KeptSlot, firstPassSeconds: Double,
                       validate: (String) throws -> ValidatedMinutes) async throws -> ValidatedMinutes {
        let windows = MinutesWindows.plan(segments)
        guard !windows.isEmpty else { return minutes }
        let order = Dictionary(uniqueKeysWithValues: segments.enumerated().map { ($1.id, $0) })
        let budget = max(itemsPassBudget.floor, itemsPassBudget.share * firstPassSeconds)
        let started = Date()
        var merged = minutes
        var skipped = 0
        defer { setStage(nil) }
        for (i, window) in windows.enumerated() {
            try Task.checkCancellation()
            // Less than a useful stretch of writing left: the pass ends here, so the total never goes past its cap.
            if budget - Date().timeIntervalSince(started) < Self.minimumWindowSeconds {
                skipped = windows.count - i
                break
            }
            setStage(.findingItems(part: i + 1, of: windows.count))
            let ids = Set(window.segments.map(\.id))
            let listed = merged.decisions.filter { ids.contains($0.segment) }.map { "Decision: " + $0.text }
                + merged.tasks.filter { ids.contains($0.segment) }.map { "Task: " + $0.text }
            let messages = base + [VautaPrompts.itemsInstruction(request, first: window.first, last: window.last, listed: listed)]
            let options = ChatOptions(model: .deep, maxTokens: 1_800, purpose: .minutes,
                                      outputSchema: OutputSchemas.items(segments: Set(ids.map { Int($0) }), entities: entityIDs),
                                      reusePrefix: true, priority: .minutes, maxSeconds: max(1, budget - Date().timeIntervalSince(started)),
                                      slot: slot, onPrefill: nil)
            let result: ChatResult
            do { result = try await chat.model.chat(messages, options, onProgress: nil) } catch is CancellationError { throw CancellationError() } catch { continue }
            // The reply is only a part of the minutes' shape: it is read as minutes with nothing else in them.
            let text = result.isTruncated ? (ModelOutput.closingTruncatedJSON(result.content) ?? result.content) : result.content
            guard let wrapped = Self.wrapItems(text), let checked = try? validate(wrapped) else { continue }
            merged = MinutesWindows.merge(merged, with: checked, order: order).minutes
        }
        if skipped > 0 { merged.counts["items.windowsSkipped"] = skipped }
        return merged
    }

    /// The items reply as a full minutes object (empty title, summary and lists), so `validateMinutes` can check it.
    static func wrapItems(_ content: String) -> String? {
        let cleaned = ModelOutput.strippingReasoning(content)
        guard let a = cleaned.firstIndex(of: "{"), let b = cleaned.lastIndex(of: "}"), a < b,
              var object = (try? JSONSerialization.jsonObject(with: Data(cleaned[a...b].utf8))) as? [String: Any] else { return nil }
        object["title"] = ""
        object["summary"] = ""
        object["topics"] = [Any]()
        object["entities"] = [Any]()
        object["open_questions"] = [Any]()
        if object["decisions"] == nil { object["decisions"] = [Any]() }
        if object["tasks"] == nil { object["tasks"] = [Any]() }
        return (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) }
    }
}
