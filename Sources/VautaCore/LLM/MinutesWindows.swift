// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The second pass of the minutes on the integrated model: the meeting is read again one stretch at a time, asking only for the
/// decisions and tasks of that stretch, and what it finds joins what the first pass kept. Pure: the windows, the merge.
enum MinutesWindows {
    struct Window: Equatable {
        let segments: [CitableSegment]
        var first: Int64 { segments.first?.id ?? 0 }
        var last: Int64 { segments.last?.id ?? 0 }
    }

    /// Stretches of about `minutes` minutes or `tokens` tokens of transcript, whichever is smaller, cut at segment boundaries.
    static func plan(_ segments: [CitableSegment], minutes: Double = 12, tokens: Int = 3_000) -> [Window] {
        var out: [Window] = []
        var current: [CitableSegment] = []
        var size = 0
        for s in segments {
            let t = PromptText.tokens(VautaPrompts.streamingLine(s))
            if let first = current.first, (s.start - first.start >= minutes * 60 || size + t > tokens) {
                out.append(Window(segments: current))
                current = []
                size = 0
            }
            current.append(s)
            size += t
        }
        if !current.isEmpty { out.append(Window(segments: current)) }
        return out
    }

    /// The closing stretch of a meeting: the last 12% of its time or the last 6 minutes, whichever is longer, started at the beginning of
    /// the speaker turn it falls in, and cut from the front to fit `tokens`. nil for a meeting too short to have one.
    static func closing(_ segments: [CitableSegment], tokens: Int, line: (CitableSegment) -> String) -> Window? {
        guard segments.count >= 8, let first = segments.first, let last = segments.last else { return nil }
        let threshold = last.start - max(0.12 * (last.start - first.start), 360)
        var from = segments.firstIndex { $0.start >= threshold } ?? segments.count - 1
        while from > 0, let a = segments[from].speaker?.id, segments[from - 1].speaker?.id == a { from -= 1 }
        var window = Array(segments[from...])
        var size = window.reduce(0) { $0 + PromptText.tokens(line($1)) }
        while size > tokens, window.count > 1 { size -= PromptText.tokens(line(window.removeFirst())) }
        return window.count >= 2 ? Window(segments: window) : nil
    }

    /// Words of a text, normalised, for the overlap of two items.
    private static func words(_ text: String) -> Set<String> { Set(TextKeys.norm(text).split(separator: " ").map(String.init)) }

    static func jaccard(_ a: String, _ b: String) -> Double {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// Joins the second pass's items to the first pass's: an item whose segment is the same as, or within three segments of, a kept
    /// item's and whose words overlap by at least 0.6 (Jaccard) is the same item, and the first pass's wins. `order` gives the position
    /// of each segment in the meeting. Returns the merged minutes and how many items were added.
    static func merge(_ base: ValidatedMinutes, with extra: ValidatedMinutes, order: [Int64: Int]) -> (minutes: ValidatedMinutes, addedDecisions: Int, addedTasks: Int) {
        var out = base
        func near(_ a: Int64, _ b: Int64) -> Bool {
            guard let x = order[a], let y = order[b] else { return a == b }
            return abs(x - y) <= 3
        }
        var addedDecisions = 0, addedTasks = 0
        for d in extra.decisions where !out.decisions.contains(where: { near($0.segment, d.segment) && jaccard($0.text, d.text) >= 0.6 }) {
            out.decisions.append(d)
            addedDecisions += 1
        }
        for t in extra.tasks where !out.tasks.contains(where: { near($0.segment, t.segment) && jaccard($0.text, t.text) >= 0.6 }) {
            out.tasks.append(t)
            addedTasks += 1
        }
        out.decisions.sort { ($0.t, $0.segment) < ($1.t, $1.segment) }
        out.tasks.sort { ($0.t, $0.segment) < ($1.t, $1.segment) }
        for (k, v) in extra.drops { out.drops["items.\(k)", default: 0] += v }
        for (k, v) in extra.counts { out.counts["items.\(k)", default: 0] += v }
        out.proposed += extra.proposed
        out.dropped += extra.dropped
        return (out, addedDecisions, addedTasks)
    }
}

/// The arms of the minutes on the integrated model that can be turned on or off (the evaluation compares them; the app uses them all).
public struct MinutesArms: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// The streaming layout: stable speaker keys, a legend and the changes in the last message, so the meeting can be read ahead.
    public static let streamingLayout = MinutesArms(rawValue: 1)
    /// The definitions and the recall cue of the instruction (A1).
    public static let recallPrompt = MinutesArms(rawValue: 2)
    /// The windowed second pass over decisions and tasks (A2).
    public static let itemsPass = MinutesArms(rawValue: 4)
    /// One more request over the closing stretch of the meeting (the second-pass code on one window), so the tasks agreed at the end are
    /// not lost (docs/LANGUAGE_MODEL.md, "Tasks, decisions and owners").
    public static let closingPass = MinutesArms(rawValue: 8)
    public static let all: MinutesArms = [.streamingLayout, .recallPrompt, .itemsPass, .closingPass]
    /// What ships: the streaming layout, because the meeting's kept prefix (reading while recording) needs it, and the closing pass, which
    /// runs only when the extraction enables it (`MinutesExtraction.closing`; the legacy extraction never sends that request). The recall
    /// wording (A1) and the second pass (A2) stay behind the evaluation switch (`--arms`) until a blind judge confirms their faithfulness
    /// (criteria C1 and C3) and the recall gates on the development and test meetings; A1 alone failed the first gate (median 5 kept
    /// decisions and tasks against 6). The layout's effect on task owners (C2) is unmeasured: an open question (docs/LANGUAGE_MODEL.md).
    public static let shipped: MinutesArms = [.streamingLayout, .closingPass]
    /// The 11a.1 behaviour (A0).
    public static let baseline: MinutesArms = []
}

extension MinutesArms {
    /// "a0", "a1", "a2", "a3" (the arms of the recall measurement) or a comma list of `streaming`, `recall`, `items`.
    public static func parse(_ text: String) -> MinutesArms? {
        switch text.lowercased() {
        case "a0", "baseline": return .baseline
        case "a1": return [.streamingLayout, .recallPrompt]
        case "a2": return [.streamingLayout, .itemsPass]
        case "a3", "all": return .all
        default:
            var out: MinutesArms = []
            for word in text.lowercased().split(separator: ",") {
                switch word {
                case "streaming": out.insert(.streamingLayout)
                case "recall": out.insert(.recallPrompt)
                case "items": out.insert(.itemsPass)
                case "closing": out.insert(.closingPass)
                case "standard", "none": break
                default: return nil
                }
            }
            return out
        }
    }

    /// For the traces: "streaming+recall+items".
    public var names: String { names(extraction: nil) }

    /// The arms that actually run: with an extraction that does not enable the closing request, the closing arm is left out.
    public func names(extraction: MinutesExtraction?) -> String {
        let closing = contains(.closingPass) && (extraction?.contains(.closing) ?? true)
        let parts = [contains(.streamingLayout) ? "streaming" : nil, contains(.recallPrompt) ? "recall" : nil, contains(.itemsPass) ? "items" : nil, closing ? "closing" : nil].compactMap { $0 }
        return parts.isEmpty ? "baseline" : parts.joined(separator: "+")
    }
}
