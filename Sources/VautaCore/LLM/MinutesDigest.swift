// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The block extracts of a long meeting on a small context window (Apple's 4,096 tokens), read back by Swift.
///
/// The final request of a map-reduce used to ask the model to write the whole minutes again from the extracts: every decision and
/// task with its quote, plus the summary. On 4,096 tokens the prompt (the extracts) takes about 2,500, so at most 1,200 are left for
/// the answer, and that answer needs more: it was cut off at the length limit in most meetings of 30 to 60 minutes. Now the model
/// writes only what needs language (title, summary, topics, open questions) from a digest of the blocks, and Swift carries the
/// decisions, tasks and mentions over from the extracts, where each already has its segment and verbatim quote; `validateMinutes`
/// checks them exactly as if the model had written them.
struct MinutesDigest {
    private struct Block {
        var summary = ""
        var topics: [String] = []
        var decided: [String] = []
        var tasks: [String] = []
        var open: [String] = []
    }

    private var blocks: [Block] = []
    private(set) var decisions: [[String: Any]] = []
    private(set) var tasks: [[String: Any]] = []
    private(set) var entities: [[String: Any]] = []
    /// Extracts that could not be read (cut off or not JSON): their blocks are missing from the minutes.
    private(set) var unreadable = 0
    /// What the meeting settled, after validation and the evidence checks (`MinutesSummary.outcomes`). When set, the message leads with
    /// them and cuts them last; the blocks' own "Decided" and "Tasks" lines (unchecked) are left out.
    var outcomes: [MinutesOutcome] = []

    static let maxDecisions = 30, maxTasks = 40, maxEntities = 40

    /// `isSound`: whether an item's quote is in the segment it cites (the check `validateMinutes` will make). Two blocks may extract
    /// the same decision, one with a quote that fails and one that holds: the copy that holds is the one kept. Items with no text
    /// take no place in the lists. `openObjects`: the open questions written as objects count too. `cleanSummaries` (the outcome-first digest): the block summaries lose segment numbers and the sentences that
    /// only say nothing was settled.
    init(extracts: [String], cleanSummaries: Bool = false, openObjects: Bool = false, isSound: (([String: Any]) -> Bool)? = nil) {
        var decisionAt = [String: Int](), taskAt = [String: Int](), seenEntities = Set<String>()
        func place(_ item: [String: Any], key: String, in list: inout [[String: Any]], at index: inout [String: Int], limit: Int) {
            if let i = index[key] {
                if let isSound, !isSound(list[i]), isSound(item) { list[i] = item }
            } else if list.count < limit {
                index[key] = list.count
                list.append(item)
            }
        }
        for extract in extracts {
            guard let object = Self.object(extract) else { unreadable += 1; continue }
            func strings(_ key: String) -> [String] { (object[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
            func objects(_ key: String) -> [[String: Any]] { (object[key] as? [Any])?.compactMap { $0 as? [String: Any] } ?? [] }
            // Apple's block extract writes each open question as {"text", "seg", "quote"} (`openObjects`, `MinutesQuestions.digest`): the text is the question.
            func openQuestions() -> [String] {
                (object["open_questions"] as? [Any])?.compactMap { ($0 as? String) ?? (openObjects ? ($0 as? [String: Any])?["text"] as? String : nil) } ?? []
            }
            var block = Block(summary: cleanSummaries ? SummaryChecks.cleaningBlockSummary((object["summary"] as? String) ?? "") : (object["summary"] as? String) ?? "", topics: strings("topics"), open: openQuestions())
            for d in objects("decisions") {
                let text = (d["text"] as? String) ?? ""
                block.decided.append(text)
                if !TextKeys.norm(text).isEmpty { place(d, key: TextKeys.norm(text), in: &decisions, at: &decisionAt, limit: Self.maxDecisions) }
            }
            for t in objects("tasks") {
                let text = (t["text"] as? String) ?? ""
                block.tasks.append(text)
                if !TextKeys.norm(text).isEmpty { place(t, key: TextKeys.norm(text), in: &tasks, at: &taskAt, limit: Self.maxTasks) }
            }
            for e in objects("entities") where entities.count < Self.maxEntities {
                if seenEntities.insert("\(e["id"] ?? "")/\(e["seg"] ?? "")").inserted { entities.append(e) }
            }
            blocks.append(block)
        }
    }

    private static func object(_ text: String) -> [String: Any]? {
        let cleaned = ModelOutput.strippingReasoning(text)
        guard let a = cleaned.firstIndex(of: "{"), let b = cleaned.lastIndex(of: "}"), a < b else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(cleaned[a...b].utf8))) as? [String: Any]
    }

    /// The digest as one delimited message of at most `tokens` tokens: first with everything, then with the open questions cut and then
    /// dropped, then without the lists of decisions and tasks, then without the topics, and finally with the summaries cut to what fits.
    func message(tokens: Int) -> ChatMessage {
        if !outcomes.isEmpty { return outcomeMessage(tokens: tokens) }
        func render(decisions: Bool, topics: Bool, open: (count: Int, characters: Int), summaryLimit: Int) -> String {
            let body = blocks.enumerated().map { i, block -> String in
                var lines = ["Block \(i + 1):", "Summary: \(PromptText.defang(PromptText.clip(SingleLineText.flatten(block.summary), summaryLimit)))"]
                func list(_ label: String, _ items: [String], limit: Int, characters: Int = 120) {
                    let kept = items.prefix(limit).map { PromptText.defang(PromptText.clip(SingleLineText.flatten($0), characters)) }.filter { !$0.isEmpty }
                    if !kept.isEmpty { lines.append("\(label): " + kept.joined(separator: "; ")) }
                }
                if topics { list("Topics", block.topics, limit: 4) }
                if decisions {
                    list("Decided", block.decided, limit: 3)
                    list("Tasks", block.tasks, limit: 4)
                }
                if open.count > 0 { list("Open", block.open, limit: open.count, characters: open.characters) }
                return lines.joined(separator: "\n")
            }
            return "<<<NOTES ON THE BLOCKS OF THE MEETING\n" + body.joined(separator: "\n\n") + "\n>>>"
        }
        // The open questions are cut before the decisions and tasks: they are the lines of the least weight in the summary, and on a long
        // meeting they used to push the "Decided" and "Tasks" lines out first (the summary then missed what the meeting settled).
        let full = (count: 2, characters: 120), short = (count: 1, characters: 80), none = (count: 0, characters: 0)
        let levels: [(decisions: Bool, topics: Bool, open: (count: Int, characters: Int), summary: Int)] = [
            (true, true, full, 500), (true, true, short, 500), (true, true, none, 500), (false, true, full, 400), (false, false, full, 300),
        ]
        for level in levels {
            let text = render(decisions: level.decisions, topics: level.topics, open: level.open, summaryLimit: level.summary)
            if PromptText.tokens(text) <= tokens { return .user(text) }
        }
        // Still too long (a meeting of hours): one line per block, the summaries cut until they fit, and as a last resort the last blocks go.
        func oneLine(_ count: Int, _ limit: Int) -> String {
            let lines = blocks.prefix(count).enumerated().map { i, block in
                "\(i + 1). " + PromptText.defang(PromptText.clip(SingleLineText.flatten(block.summary), limit))
            }
            return "<<<NOTES ON THE BLOCKS OF THE MEETING\n" + lines.joined(separator: "\n") + "\n>>>"
        }
        var count = blocks.count
        var limit = max(40, (tokens - count * 10) * 3 / max(1, count))
        while true {
            let text = oneLine(count, limit)
            if PromptText.tokens(text) <= tokens { return .user(text) }
            if limit > 40 { limit = max(40, limit * 3 / 4) } else if count > 1 { count -= 1 } else { return .user(String(text.dropLast(4).prefix(max(0, tokens * 3 - 4))) + "\n>>>") }
        }
    }

    /// The model's JSON with the decisions, tasks and entities of the extracts in place of whatever it wrote for them. nil when the
    /// reply is not a JSON object (the caller hands it on unchanged, so it is rejected and asked again as before).
    func combine(_ reply: String) -> String? {
        guard var object = Self.object(reply) else { return nil }
        object["decisions"] = decisions
        object["tasks"] = tasks
        object["entities"] = entities
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Outcome first

    /// `text` cut to at most `limit` characters at the end of a word, so a summary never stops in the middle of one.
    static func clipped(_ text: String, _ limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = String(text.prefix(limit))
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 { return String(cut[..<space]) + " …" }
        return cut + "…"
    }

    /// The share of the digest the outcomes may take before they are shortened: the rest is the narrative of the blocks.
    static let outcomeShare = 0.55

    /// The digest that leads with the outcomes. Under budget the narrative goes first: the topics, the open questions, then the summaries
    /// of the earlier blocks before those of the last third, where a meeting settles its results; only then are the outcomes shortened
    /// (proposed first, then tasks, then the oldest).
    private func outcomeMessage(tokens: Int) -> ChatMessage {
        func header(_ lines: String) -> String { "<<<NOTES ON THE MEETING\n" + lines + "\n\nBackground, in order:\n" }
        func render(_ lines: String, topics: Bool, open: Bool, early: Int, late: Int) -> String {
            let lateFrom = blocks.count - max(1, blocks.count / 3)
            let body = blocks.enumerated().compactMap { i, block -> String? in
                let limit = i >= lateFrom ? late : early
                var parts: [String] = []
                if limit > 0 { parts.append(PromptText.defang(Self.clipped(SingleLineText.flatten(block.summary), limit))) }
                func list(_ label: String, _ items: [String], count: Int) {
                    let kept = items.prefix(count).map { PromptText.defang(PromptText.clip(SingleLineText.flatten($0), 100)) }.filter { !$0.isEmpty }
                    if !kept.isEmpty { parts.append("(\(label): " + kept.joined(separator: "; ") + ")") }
                }
                if topics && limit > 0 { list("Topics", block.topics, count: 3) }
                if open && limit > 0 { list("Open", block.open, count: 2) }
                return parts.isEmpty ? nil : "- " + parts.joined(separator: " ")
            }
            return header(lines) + body.joined(separator: "\n") + "\n>>>"
        }
        let blockLevels: [(topics: Bool, open: Bool, early: Int, late: Int)] = [
            (true, true, 300, 500), (false, true, 240, 450), (false, false, 160, 360), (false, false, 80, 260), (false, false, 0, 160), (false, false, 0, 0),
        ]
        // The outcomes, whole first and then shortened. Cut order: proposed, tasks, then the oldest of the rest.
        var variants: [[MinutesOutcome]] = [outcomes]
        let settled = outcomes.filter { $0.status != .proposed }
        let decisionsOnly = settled.filter { $0.status != .task }
        for variant in [settled, decisionsOnly] where !variant.isEmpty && variant != variants.last! { variants.append(variant) }
        var trimmed = decisionsOnly.isEmpty ? settled : decisionsOnly
        while trimmed.count > 3 {
            trimmed.removeFirst()
            variants.append(trimmed)
        }
        for (v, variant) in variants.enumerated() {
            for characters in v == 0 ? [MinutesOutcome.lineCharacters, 90] : [90, 70] {
                let lines = MinutesOutcome.lines(variant, characters: characters)
                if Double(PromptText.tokens(header(lines) + ">>>")) > Double(tokens) * Self.outcomeShare, v < variants.count - 1 { continue }
                for level in blockLevels {
                    let text = render(lines, topics: level.topics, open: level.open, early: level.early, late: level.late)
                    if PromptText.tokens(text) <= tokens { return .user(text) }
                }
            }
        }
        // Not even the outcomes fit: the last resort of the plain digest.
        let plain = render(MinutesOutcome.lines(variants.last!, characters: 70), topics: false, open: false, early: 0, late: 0)
        return .user(String(plain.dropLast(4).prefix(max(0, tokens * 3 - 4))) + "\n>>>")
    }
}
