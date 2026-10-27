// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Meeting-level consolidation and ranking of the decisions and tasks, with no model (`MinutesExtraction.ranking`). Apple's model reads a long
/// meeting in blocks of a few minutes and proposes items in every one of them, most of which are not items (a proposal nobody took up, a
/// topic, a restated one). After the checks of `ItemEvidence`, each item is scored with what the transcript shows (where in the meeting it
/// falls, whether somebody agrees in the next lines, whether somebody commits or is asked, whether the meeting keeps coming back to it,
/// whether it is about running the meeting), a near copy of a later item is removed, and only the best items of the meeting stay firm: the
/// others are "to be confirmed" (`unconfirmed`), which the default follow-up email leaves out. Nothing is invented or rewritten.
///
/// The weights are set by hand on the development meetings (a position-only score does almost as well there, so the cues are few and
/// each one is a thing a person can check in the transcript). How many items stay firm (`limit`) is a product choice.
enum MinutesRanking {
    struct Weights: Sendable, Equatable {
        /// 0 at the start of the meeting, 1 at the end: the meeting settles things late, and its first stretch is mostly talk about the topic.
        var position = 4.0
        /// The cited line, or one of the next three, says an agreement.
        var agreeSelf = 1.0
        var agreeNext = 0.5
        /// The item is about running the meeting (slides, agenda, a break).
        var procedure = -1.0
        /// Each other item that says the same, up to two.
        var repeated = 0.7
        /// The checks found a commitment or an agreement (not marked "to be confirmed").
        var firm = 1.0
        /// Fewer than four words.
        var short = -1.3
        /// The cited clause is somebody committing, a group stating what it will do, or a request.
        var action = 0.8
        /// The topic is discussed around the item (lines within ten with two of its words), per unit of the share, at most 0.6.
        var salience = 1.6
        var owner = 0.5
        /// Items per meeting by its length: `base + minutes / perMinutes`, between `floor` and `ceiling`.
        var base = 4.0, perMinutes = 8.0, floor = 6, ceiling = 12
        static let standard = Weights()
    }

    /// What one item shows, kept apart from the score so the tests and the evaluation can read it.
    struct Features: Sendable, Equatable {
        var position = 0.0
        var agreeSelf = false
        var agreeNext = false
        var procedure = false
        var repeats = 0
        var firm = false
        var short = false
        var action = false
        var salience = 0.0
        var owner = false
        var doubt: String?
    }

    /// Overlap of content words above which two items are one matter said twice.
    static let copyOverlap = 0.5

    /// How many items a meeting of `minutes` shows as firm.
    static func limit(minutes: Double, _ w: Weights = .standard) -> Int {
        min(w.ceiling, max(w.floor, Int((w.base + minutes / w.perMinutes).rounded())))
    }

    static func score(_ f: Features, _ w: Weights = .standard) -> Double {
        w.position * f.position + (f.agreeSelf ? w.agreeSelf : 0) + (f.agreeNext ? w.agreeNext : 0) + (f.procedure ? w.procedure : 0)
            + w.repeated * Double(min(f.repeats, 2)) + (f.firm ? w.firm : 0) + (f.short ? w.short : 0) + (f.action ? w.action : 0)
            + w.salience * min(f.salience, 0.6) + (f.owner ? w.owner : 0)
    }

    /// The checks found the item a question or its figures unverified: it never goes into the list, whatever its rank.
    static func neverFirm(_ doubt: String?) -> Bool { doubt == "question" || doubt == "figures" }

    private struct Entry {
        let isTask: Bool
        let at: Int
        let segment: Int64
        let text: String
        var features = Features()
        var removed = false
    }

    static func apply(_ minutes: ValidatedMinutes, context c: ItemEvidence.Context, extraction: MinutesExtraction, weights w: Weights = .standard) -> ValidatedMinutes {
        guard extraction.contains(.ranking), minutes.decisions.count + minutes.tasks.count > 0, let first = c.order.segments.first, let last = c.order.segments.last else { return minutes }
        var entries: [Entry] = minutes.decisions.enumerated().map { Entry(isTask: false, at: $0, segment: $1.segment, text: $1.text) }
            + minutes.tasks.enumerated().map { Entry(isTask: true, at: $0, segment: $1.segment, text: $1.text) }
        let segmentCount = c.order.segments.count
        let words: [Set<String>] = entries.map { e in ItemCues.contentWords(e.text, language: c.language).filter { w in !ItemCues.roles.contains { w.hasPrefix($0) } } }
        let position: [Int] = entries.map { c.order.index(of: $0.segment) ?? 0 }
        func doubt(_ e: Entry) -> String? {
            let item = e.isTask ? (minutes.tasks[e.at].unconfirmed, minutes.tasks[e.at].doubt) : (minutes.decisions[e.at].unconfirmed, minutes.decisions[e.at].doubt)
            return item.0 ? item.1 ?? "figures" : nil
        }

        // One matter said twice (a near copy, usually from another block): the later one stays, unless it cannot be firm and the earlier can.
        var repeats = [Int](repeating: 0, count: entries.count)
        for a in entries.indices {
            for b in entries.indices where b > a && !entries[a].removed && !entries[b].removed && ItemEvidence.overlap(words[a], words[b]) >= copyOverlap {
                repeats[a] += 1
                repeats[b] += 1
                let (earlier, later) = position[a] <= position[b] ? (a, b) : (b, a)
                entries[neverFirm(doubt(entries[later])) && !neverFirm(doubt(entries[earlier])) ? later : earlier].removed = true
            }
        }
        // Computed once per segment: the lines around an item are read by every item near them.
        var contentOf: [Int: Set<String>] = [:]
        func content(_ i: Int) -> Set<String> {
            if let known = contentOf[i] { return known }
            let made = ItemCues.contentWords(c.order.segments[i].text, language: c.language)
            contentOf[i] = made
            return made
        }
        for i in entries.indices where !entries[i].removed {
            var f = Features()
            f.position = Double(position[i]) / Double(max(1, segmentCount - 1))
            f.repeats = repeats[i]
            f.doubt = doubt(entries[i])
            f.firm = f.doubt == nil
            f.procedure = ItemCues.Text(entries[i].text).has(ItemCues.procedure)
            f.short = QuoteKey.make(entries[i].text, language: c.language).count < 4
            if entries[i].isTask { f.owner = minutes.tasks[entries[i].at].owner != nil || minutes.tasks[entries[i].at].ownerSpeaker != nil }
            if let seg = c.order.segment(entries[i].segment) {
                f.agreeSelf = c.fact(seg).agreement
                f.agreeNext = c.order.following(seg.id).contains { c.fact($0).agreement }
                let infos = c.clauses(seg)
                let quote = entries[i].isTask ? minutes.tasks[entries[i].at].quote : minutes.decisions[entries[i].at].quote
                let clause = infos[ItemCues.evidenceIndex(item: entries[i].text, quote: quote, infos: infos, language: c.language)].text
                let t = ItemCues.Text(clause)
                f.action = ItemCues.commits(clause) || t.has(ItemCues.request) || t.has(ItemCues.volunteerCall)
                    || (t.has(ItemCues.groupDecision) && !ItemCues.isQuestion(clause))
                var near = 0
                for j in max(0, position[i] - 10)...min(segmentCount - 1, position[i] + 10) where j != position[i] && !words[i].isEmpty {
                    if content(j).intersection(words[i]).count >= 2 { near += 1 }
                }
                f.salience = Double(near) / 10
            }
            entries[i].features = f
        }

        let live = entries.indices.filter { !entries[$0].removed }
        let minutesLong = max(0, (last.start - first.start) / 60)
        let k = limit(minutes: minutesLong, w)
        let ranked = live.sorted { a, b in
            let (sa, sb) = (score(entries[a].features, w), score(entries[b].features, w))
            return sa != sb ? sa > sb : position[a] < position[b]
        }
        let procedureOut = extraction.contains(.procedureNeverFirm)
        let shown = Set(ranked.filter { !neverFirm(entries[$0].features.doubt) && !(procedureOut && entries[$0].features.procedure) }.prefix(k))

        // An item that did not rank is "ranked out", whether or not a soft check had doubted it (the ranking shows such an item firm when it
        // ranks in, so its doubt says nothing more than "did not rank"); only a question or unbacked figures keep their own mark.
        var out = minutes
        out.decisions = []
        out.tasks = []
        for i in live.sorted() {
            let e = entries[i]
            if e.isTask {
                var t = minutes.tasks[e.at]
                if shown.contains(i) { t.unconfirmed = false } else if !neverFirm(t.unconfirmed ? t.doubt ?? "figures" : nil) { let soft = t.unconfirmed ? t.doubt : nil; t.unconfirmed = true; t.doubt = UnconfirmedReason.rankedOut(after: soft) }
                out.tasks.append(t)
            } else {
                var d = minutes.decisions[e.at]
                if shown.contains(i) { d.unconfirmed = false } else if !neverFirm(d.unconfirmed ? d.doubt ?? "figures" : nil) { let soft = d.unconfirmed ? d.doubt : nil; d.unconfirmed = true; d.doubt = UnconfirmedReason.rankedOut(after: soft) }
                out.decisions.append(d)
            }
        }
        out.counts["rank.proposed"] = entries.count
        out.counts["rank.shown"] = shown.count
        out.counts["rank.limit"] = k
        if procedureOut { out.counts["rank.procedure"] = live.filter { entries[$0].features.procedure }.count }
        let removed = entries.count - live.count
        if removed > 0 { out.drops["item.nearCopy", default: 0] += removed }
        if extraction.contains(.explain) {
            for (i, e) in entries.enumerated() {
                let f = e.features
                out.counts["explain|rank|\(i)|\(e.isTask ? "task" : "decision")|\(e.segment)|\(e.text.prefix(120))|pos=\(String(format: "%.3f", f.position)) ag=\(f.agreeSelf ? 1 : 0) an=\(f.agreeNext ? 1 : 0) pr=\(f.procedure ? 1 : 0) rp=\(f.repeats) fm=\(f.firm ? 1 : 0) sh=\(f.short ? 1 : 0) ac=\(f.action ? 1 : 0) sl=\(String(format: "%.1f", f.salience)) ow=\(f.owner ? 1 : 0) rm=\(e.removed ? 1 : 0) sc=\(String(format: "%.2f", score(f, w))) on=\(shown.contains(i) ? 1 : 0) d=\(f.doubt ?? "-")"] = 1
            }
        }
        return out
    }
}
