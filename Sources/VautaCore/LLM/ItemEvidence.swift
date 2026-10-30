// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Checks each validated task and decision against the words around its quote, with no model. What is not a task or a decision at all
/// (a recap of earlier minutes, an unanswered question, a rating, meeting procedure, reported speech, something already done, text read
/// aloud with no vote, a fragment, a repeat) is dropped. What lacks a commitment or an agreement, or is hedged, stays in the minutes
/// marked `unconfirmed` ("to be confirmed"), which the default follow-up email leaves out. Nothing is invented: items only disappear or
/// get the mark. Reasons are counted (`drops["task.recap"]`, `counts["task.noCommitment"]`), never quoted.
enum ItemEvidence {
    /// The meeting around the items.
    struct Context {
        let order: SegmentOrder
        let language: String?
        /// What each segment says on its own, worked out once (items near each other read the same lines).
        private let facts = Facts()
        /// Who spoke each line, when the meeting has speaker data. Without it, the speaker tag of the segment tells voices apart.
        let directory: SpeakerDirectory?
        let selfEntity: Int64?

        init(segments: [CitableSegment], language: String?, directory: SpeakerDirectory? = nil, selfEntity: Int64? = nil) {
            order = SegmentOrder(segments)
            self.language = language
            self.directory = directory
            self.selfEntity = selfEntity
        }

        func voice(of segment: CitableSegment) -> Voice? {
            if let directory { return directory.voice(of: segment, selfEntity: selfEntity) }
            guard let tag = segment.speaker, let id = tag.id else { return nil }
            return Voice(key: "s\(id)", entity: nil, speaker: id, confident: !tag.isLowConfidence && !tag.overlap)
        }

        struct Fact {
            let agreement: Bool, endsWithRequest: Bool, pastAgreement: Bool
        }

        final class Facts: @unchecked Sendable {
            private let lock = NSLock()
            private var cache: [Int64: Fact] = [:]
            private var clauseCache: [Int64: [ItemCues.ClauseInfo]] = [:]

            /// The clauses of a cited segment with their content words (only cited segments need them).
            func infos(_ segment: CitableSegment, language: String?) -> [ItemCues.ClauseInfo] {
                if let known = lock.withLock({ clauseCache[segment.id] }) { return known }
                let made = ItemCues.clauseInfos(segment.text, language: language)
                lock.withLock { clauseCache[segment.id] = made }
                return made
            }

            func get(_ segment: CitableSegment, language: String?) -> Fact {
                if let known = lock.withLock({ cache[segment.id] }) { return known }
                let text = ItemCues.Text(segment.text)
                let clauses = ItemCues.clauses(segment.text)
                let fact = Fact(agreement: clauses.contains { ItemCues.agrees($0) },
                                endsWithRequest: clauses.last.map { ItemCues.Text($0).has(ItemCues.request) || ItemCues.Text($0).has(ItemCues.volunteerCall) } ?? false,
                                pastAgreement: text.has(ItemCues.pastAgreement))
                lock.withLock { cache[segment.id] = fact }
                return fact
            }
        }

        func fact(_ segment: CitableSegment) -> Fact { facts.get(segment, language: language) }
        func clauses(_ segment: CitableSegment) -> [ItemCues.ClauseInfo] { facts.infos(segment, language: language) }
    }

    private enum Verdict {
        case keep
        case unconfirmed(String)
        case drop(String)
    }

    static func apply(_ minutes: ValidatedMinutes, context: Context, extraction: MinutesExtraction) -> ValidatedMinutes {
        guard extraction.contains(.evidence) else { return minutes }
        var out = minutes
        out.decisions = []
        out.tasks = []
        var kept: [(segment: Int64, text: String, isTask: Bool, actor: Bool, unconfirmedBecause: String?)] = []
        var words: [String: Set<String>] = [:]
        func content(_ text: String) -> Set<String> {
            if let known = words[text] { return known }
            let made = ItemCues.contentWords(text, language: context.language)
            words[text] = made
            return made
        }
        func duplicate(of segment: Int64, _ text: String) -> Int? {
            guard let here = context.order.index(of: segment) else { return nil }
            let mine = content(text)
            return kept.firstIndex { k in
                guard let there = context.order.index(of: k.segment), abs(here - there) <= 2 else { return false }
                // Role words ("designer") are in every line of an enumerated assignment: they do not make two items one.
                return overlap(withoutRoles(content(k.text)), withoutRoles(mine)) >= 0.5
            }
        }
        // Tasks first: when a decision and a task describe the same thing, the task stays if it has an actor cue.
        var taskVerdicts: [(ValidatedMinutes.Task, Verdict, Bool)] = []
        for t in minutes.tasks {
            let (verdict, actor) = assess(task: t, context)
            taskVerdicts.append((t, verdict, actor))
        }
        var decisionVerdicts: [(ValidatedMinutes.Item, Verdict)] = []
        for d in minutes.decisions { decisionVerdicts.append((d, assess(decision: d, context))) }
        if extraction.contains(.explain) {
            for (t, v, _) in taskVerdicts { out.counts["explain|task|\(t.segment)|\(t.text.prefix(40))|\(label(v))"] = 1 }
            for (d, v) in decisionVerdicts { out.counts["explain|decision|\(d.segment)|\(d.text.prefix(40))|\(label(v))"] = 1 }
        }
        for (t, verdict, actor) in taskVerdicts {
            if case .drop(let why) = verdict { removed(&out, "task", why); continue }
            var reason: String?
            if case .unconfirmed(let why) = verdict { reason = why }
            if let at = duplicate(of: t.segment, t.text) {
                // Two copies of one task: the confirmed one stays, whichever came first.
                guard reason == nil, let earlier = kept[at].unconfirmedBecause,
                      let slot = out.tasks.firstIndex(where: { $0.text == kept[at].text && $0.segment == kept[at].segment }) else {
                    removed(&out, "task", "duplicate")
                    continue
                }
                out.tasks.remove(at: slot)
                out.counts["task.\(earlier)", default: 1] -= 1
                removed(&out, "task", "duplicate")
                kept.remove(at: at)
            }
            var task = t
            if let why = reason {
                if extraction.contains(.dropUnconfirmed) { removed(&out, "task", why); continue }
                // The verifier's mark ("figures": a figure, name or date the cited passage does not back) stays: the ranking never shows it firm.
                if !task.unconfirmed { task.doubt = why }
                task.unconfirmed = true
                out.counts["task.\(why)", default: 0] += 1
            }
            kept.append((t.segment, t.text, true, actor, reason))
            out.tasks.append(task)
        }
        for (d, verdict) in decisionVerdicts {
            if case .drop(let why) = verdict { removed(&out, "decision", why); continue }
            if let at = duplicate(of: d.segment, d.text) {
                // The decision repeats a task: the task stays unless it has no actor cue, then the decision replaces it.
                if kept[at].isTask, !kept[at].actor, let slot = out.tasks.firstIndex(where: { $0.text == kept[at].text && $0.segment == kept[at].segment }) {
                    out.tasks.remove(at: slot)
                    removed(&out, "task", "duplicate")
                    kept.remove(at: at)
                } else {
                    removed(&out, "decision", "duplicate")
                    continue
                }
            }
            var decision = d
            if case .unconfirmed(let why) = verdict {
                if extraction.contains(.dropUnconfirmed) { removed(&out, "decision", why); continue }
                if !decision.unconfirmed { decision.doubt = why }
                decision.unconfirmed = true
                out.counts["decision.\(why)", default: 0] += 1
            }
            kept.append((d.segment, d.text, false, false, nil))
            out.decisions.append(decision)
        }
        return out
    }

    /// An item the filter removed. Counted under its reason, but not in `dropped`: that counter is the citation check's (items whose quote
    /// does not verify), and the verification rate must not move because of what the filter does afterwards.
    private static func removed(_ minutes: inout ValidatedMinutes, _ kind: String, _ reason: String) {
        minutes.drops["\(kind).\(reason)", default: 0] += 1
    }

    private static func label(_ v: Verdict) -> String {
        switch v {
        case .keep: "keep"
        case .unconfirmed(let why): "unconfirmed.\(why)"
        case .drop(let why): "drop.\(why)"
        }
    }

    private static func withoutRoles(_ words: Set<String>) -> Set<String> {
        words.filter { w in !ItemCues.roles.contains { w.hasPrefix($0) } }
    }

    /// Jaccard overlap of two sets of content words (four letters or more, every character of a script written without spaces), so "the" and
    /// a shared number do not make two items one.
    static func overlap(_ x: Set<String>, _ y: Set<String>) -> Double {
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    // MARK: Tasks

    /// A task stays confirmed when the clause or the lines around it show somebody committing (or being charged with it and accepting),
    /// a role or a third party being charged. A group obligation, a bare obligation or an unanswered request leaves it "to be confirmed".
    private static func assess(task: ValidatedMinutes.Task, _ c: Context) -> (Verdict, Bool) {
        guard let seg = c.order.segment(task.segment) else { return (.keep, true) }
        let infos = c.clauses(seg)
        let index = ItemCues.evidenceIndex(item: task.text, quote: task.quote, infos: infos, language: c.language)
        let clauses = infos.map(\.text)
        let clause = clauses[index]
        let t = ItemCues.Text(clause)
        let item = ItemCues.Text(task.text)
        if let why = commonDrop(item: item, clause: t, rawClause: clause, text: task.text, segment: seg, c, isTask: true) { return (.drop(why), false) }
        let window = c.order.following(seg.id)
        let previous = c.order.previous(of: seg.id)
        let selfCommit = ItemCues.commits(clause)
        let requested = t.has(ItemCues.request) || t.has(ItemCues.volunteerCall) || (ItemCues.vocative(clause) && ItemCues.isQuestion(clause))
        let thirdParty = ItemCues.thirdPartySubject(clause)
        let weakCue = t.has(ItemCues.groupObligation) || t.has(ItemCues.obligation)
        // An answer in the next lines from somebody other than the asker: "Can you do it?" "Yeah, I'll do that." The asker answering their own
        // request, or the first answer being a refusal, confirms nothing.
        let asker = c.voice(of: seg)
        // The commitment must be about the request: "I'll send the minutes tonight" after "Can you look into the logo?" accepts nothing.
        let about = ItemCues.contentWords(task.text + " " + clause, language: c.language)
        let answered = window.contains { s in
            guard s.id != seg.id, ItemCues.clauses(s.text).contains(where: { ItemCues.answersRequest($0, reference: about, language: c.language) }) else { return false }
            guard let asker, let v = c.voice(of: s) else { return true }
            return v.key != asker.key
        }
        let refused = requested && OwnerInference.refusedAnswer(after: window, asker: asker, addressee: nil, voiceOf: { c.voice(of: $0) })
        // The cited line is the answer to a request just before it.
        let answers = previous.map { c.fact($0).endsWithRequest } ?? false
        let actor = selfCommit || requested || thirdParty || weakCue
        // A question to somebody by name is firm once somebody else says yes to it ("Ana, can you send the deck?" "Sure."): silence, or a change of
        // topic, is not acceptance. A directive ("Ana, please send the deck by Friday.") is firm as said. (On the 34 DEV meetings' stored replies this moved no count: the stored requests that reach here were answered.)
        let acceptedByAnother = window.contains { s in
            guard s.id != seg.id, ItemCues.clauses(s.text).contains(where: { ItemCues.acceptsRequest($0, reference: about, language: c.language) }) else { return false }
            guard let asker, let v = c.voice(of: s) else { return true }
            return v.key != asker.key
        }
        let toSomeoneByName = requested && ItemCues.vocative(clause) && (!ItemCues.isQuestion(clause) || acceptedByAnother)
        if ItemCues.isQuestion(clause) && !selfCommit && !answered && !toSomeoneByName && !t.has(ItemCues.agreement) { return (.unconfirmed("question"), actor) }
        if ItemCues.hedged(clause) { return (.unconfirmed("tentative"), actor) }
        if procedureOnlyAround(item: item, clause: t, rawClause: clause, agreed: false, isTask: true) { return (.unconfirmed("procedure"), actor) }
        let strong = selfCommit || thirdParty || (requested && (answered || toSomeoneByName) && !refused) || (answers && (ItemCues.commits(clause, cues: ItemCues.committingAcceptance) || isWeakYes(clause)))
        if !strong { return (.unconfirmed("noCommitment"), actor) }
        return (.keep, actor)
    }

    private static func isWeakYes(_ clause: String) -> Bool { OwnerInference.isWeakAcceptance(clause) }

    // MARK: Decisions

    private static func assess(decision: ValidatedMinutes.Item, _ c: Context) -> Verdict {
        guard let seg = c.order.segment(decision.segment) else { return .keep }
        let infos = c.clauses(seg)
        let index = ItemCues.evidenceIndex(item: decision.text, quote: decision.quote, infos: infos, language: c.language)
        let clauses = infos.map(\.text)
        let clause = clauses[index]
        let t = ItemCues.Text(clause)
        let item = ItemCues.Text(decision.text)
        let window = c.order.following(seg.id)
        let previous = c.order.previous(of: seg.id)
        let agreed = c.fact(seg).agreement || window.contains { c.fact($0).agreement }
            || (previous.map { c.fact($0).agreement } ?? false)
            || (t.has(ItemCues.groupDecision) && !ItemCues.isQuestion(clause))
        if let why = commonDrop(item: item, clause: t, rawClause: clause, text: decision.text, segment: seg, c, isTask: false, agreed: agreed) { return .drop(why) }
        if ItemCues.isQuestion(clause), !agreed { return .unconfirmed("question") }
        if t.has(ItemCues.rating) && !agreed { return .drop("rating") }
        if ItemCues.hedged(clause) { return .unconfirmed("tentative") }
        if procedureOnlyAround(item: item, clause: t, rawClause: clause, agreed: agreed, isTask: false) { return .unconfirmed("procedure") }
        if !agreed { return .unconfirmed("noAgreement") }
        return .keep
    }

    // MARK: Shared drops

    private static func commonDrop(item: ItemCues.Text, clause: ItemCues.Text, rawClause: String, text: String, segment: CitableSegment,
                                   _ c: Context, isTask: Bool, agreed: Bool = false) -> String? {
        if isFragment(text, language: c.language) { return "fragment" }
        if isReported(text) { return "reported" }
        // A recap is told about the clause that holds the quote, and only when that clause is not itself a request or a commitment
        // ("Send the minutes of the last meeting to everyone", "Like last time, Ana will book the room").
        let future = futureAction(rawClause)
        if !future, clause.has(ItemCues.recap) || item.has(ItemCues.recap) { return "recap" }
        // The opening of a meeting often restates what the last one decided: a past-tense agreement in the clause, in the first stretch.
        if !future, let i = c.order.index(of: segment.id), Double(i) < 0.15 * Double(c.order.segments.count), clause.has(ItemCues.pastAgreement) { return "recap" }
        if item.has(ItemCues.procedure) || clause.has(ItemCues.procedure), !procedureExempt(clause: clause, rawClause: rawClause, agreed: agreed, isTask: isTask) {
            // The item itself is about running the meeting: drop. Only the clause around it is: keep it, to be confirmed (see `procedureOnlyAround`).
            if item.has(ItemCues.procedure) { return "procedure" }
        }
        if isTask, clause.has(ItemCues.speakerProcedure) || item.has(ItemCues.speakerProcedure) { return "procedure" }
        if isTask, clause.has(ItemCues.done), !ItemCues.commits(rawClause), !clause.has(ItemCues.groupObligation) { return "done" }
        if clause.has(ItemCues.reading), !agreed {
            let window = c.order.following(segment.id)
            if !window.contains(where: { c.fact($0).agreement }) { return "reading" }
        }
        return nil
    }

    /// The clause is somebody saying who will do something or asking for it: not a retelling and not talk about the meeting.
    static func futureAction(_ rawClause: String) -> Bool {
        let t = ItemCues.Text(rawClause)
        if ItemCues.isQuestion(rawClause) { return ItemCues.vocative(rawClause) || t.has(ItemCues.request) || t.has(ItemCues.volunteerCall) }
        return ItemCues.commits(rawClause) || t.has(ItemCues.request) || t.has(ItemCues.volunteerCall) || ItemCues.thirdPartySubject(rawClause) || ItemCues.vocative(rawClause)
    }

    /// An item that mentions a presentation or the agenda but is an agreement, an assignment (self, request, role, somebody else) or a
    /// future obligation is about the work, not about running the meeting.
    private static func procedureExempt(clause: ItemCues.Text, rawClause: String, agreed: Bool, isTask: Bool) -> Bool {
        agreed || ItemCues.commits(rawClause) || ItemCues.thirdPartySubject(rawClause)
            || (isTask && (clause.has(ItemCues.request) || clause.has(ItemCues.volunteerCall) || clause.has(ItemCues.groupObligation) || clause.has(ItemCues.obligation)))
    }

    /// The cue is in the clause around the item, not in the item: not enough to drop, but the item is not firm either.
    static func procedureOnlyAround(item: ItemCues.Text, clause: ItemCues.Text, rawClause: String, agreed: Bool, isTask: Bool) -> Bool {
        !item.has(ItemCues.procedure) && clause.has(ItemCues.procedure) && !procedureExempt(clause: clause, rawClause: rawClause, agreed: agreed, isTask: isTask)
    }

    /// Fewer than two words: a label ("Topic segmentation" has two and stays), not an item.
    static func isFragment(_ text: String, language: String?) -> Bool {
        QuoteKey.make(text, language: language).count < 2
    }

    /// "Speaker 4 noted that…", "Speaker 4 explained the design", "X said…": reported speech, not an item. "Speaker 4 will send the deck" and
    /// "Speaker 4 and Speaker 5 to meet on Wednesday" are the speakers' own items: a model asked for the owner as the transcript's label
    /// writes them that way (on a model server, 108 of 169 proposed tasks of the development meetings began with the label).
    static func isReported(_ text: String) -> Bool {
        let norm = TextKeys.norm(text)
        if let verb = wordAfterLabels(norm), reportingVerbs.contains(verb) { return true }
        return DateWords.contains(String(norm.prefix(60)), ["noted that", "mentioned that", "said that", "pointed out that", "explained that", "reported that", "dijo que", "menciono que", "comento que", "senalo que"])
    }

    /// The word after the transcript labels an item opens with ("speaker 4", "speaker 4 and speaker 5"); nil when it opens with none.
    static func wordAfterLabels(_ norm: String) -> String? {
        let words = norm.split(separator: " ").map(String.init)
        var i = 0
        while i + 1 < words.count, words[i] == "speaker", words[i + 1].allSatisfy(\.isNumber) {
            i += 2
            if i + 1 < words.count, words[i] == "and" || words[i] == "y", words[i + 1] == "speaker" { i += 1 }
        }
        return i > 0 && i < words.count ? words[i] : nil
    }

    /// What a speaker did with words: telling, not deciding or committing. Not "asked" ("Speaker 2 asked Speaker 3 to send it" is a
    /// request), "suggested" or "proposed" (a proposal the decision checks judge).
    static let reportingVerbs: Set<String> = [
        "noted", "mentioned", "said", "says", "explained", "explains", "described", "presented", "presents", "talked", "discussed", "shared",
        "stated", "commented", "expressed", "raised", "reported", "observed", "noticed", "recalled", "argued", "thinks", "thought", "felt",
        "feels", "believes", "wondered", "pointed", "dijo", "comento", "explico", "menciono", "senalo", "presento", "hablo", "conto", "expuso",
        "indico", "opino", "cree", "piensa",
    ]
}

extension ItemCues {
    /// "needs to", "has to", "must": an obligation without a person. A weak cue: it keeps the task in the minutes, but a task with only this
    /// stays "to be confirmed" (nobody committed).
    static let obligation = PhraseSet([
        "needs to", "has to", "have to", "need to", "must", "gotta", "tiene que", "tienen que", "tengo que", "voy a", "debe", "deben", "hay que", "il faut", "je dois", "muss",
        "deve", "devo", "precisa", "preciso", "tenho que", "必要", "해야",
    ])
}

extension ItemCues {
    /// "we decided", "we've agreed": what a meeting says when it restates earlier decisions.
    static let pastAgreement = PhraseSet([
        "we decided", "we ve decided", "we have decided", "we agreed", "we ve agreed", "we have agreed", "decidimos", "habiamos decidido", "acordamos", "se decidio",
        "nous avons decide", "wir haben beschlossen", "abbiamo deciso", "decidimos", "决定了", "決まりました",
    ])
}
