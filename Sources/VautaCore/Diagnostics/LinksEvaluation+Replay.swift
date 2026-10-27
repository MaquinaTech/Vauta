// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The deterministic replay scenarios of `llm-eval --tasks links` (arm `RP`): what must hold on every cluster whatever the model does.
/// A failed check is counted, and the run fails with the counts.
extension LinksEvaluation {
    /// The minutes a meeting has in the store, as `applyMinutes` takes them (a rewrite that produces the same items again, with new ids).
    /// `reword` changes the words of every item (a rewrite that says the same thing differently).
    static func minutesFromStore(_ store: MeetingStore, meeting: Int64, reword: (String) -> String = { $0 }) async throws -> ValidatedMinutes {
        var minutes = ValidatedMinutes()
        minutes.title = ""
        for d in try await store.decisions(meeting) where d.source == "llm" {
            guard let segment = d.segmentID else { continue }
            var item = ValidatedMinutes.Item(text: reword(d.text), segment: segment, t: d.t ?? 0)
            item.unconfirmed = d.unconfirmed
            item.doubt = d.unconfirmed ? d.unconfirmedReason : nil
            minutes.decisions.append(item)
        }
        for t in try await store.tasks(meeting) where t.source == "llm" && t.status == .open {
            guard let segment = t.segmentID else { continue }
            var task = ValidatedMinutes.Task(text: reword(t.text), owner: t.ownerID, due: t.due, segment: segment, t: t.t ?? 0)
            task.unconfirmed = t.unconfirmed
            task.doubt = t.unconfirmed ? t.unconfirmedReason : nil
            task.dueDay = t.dueDay
            minutes.tasks.append(task)
        }
        return minutes
    }

    static func replay(cluster: Cluster, minutes: [String: BriefEvaluation.StoredMinutes], options o: LLMEvaluation.Options, directory: URL,
                       providers: EvaluationProviders) async throws -> (failures: Int, detail: [String: String]) {
        let store = try MeetingStore(directory: directory.appendingPathComponent("replay"), keyStore: MemoryKeyStore())
        let seeded = try await seedCluster(cluster, minutes: minutes, sets: o.sets, directory: directory, store: store)
        var failures = 0
        var detail: [String: String] = ["meetings": "\(seeded.ids.count)"]
        func check(_ name: String, _ ok: Bool) {
            detail["check_\(name)"] = ok ? "ok" : "FAILED"
            if !ok { failures += 1 }
        }
        guard seeded.ids.count >= 2 else { detail["skipped"] = "fewer than two meetings"; return (0, detail) }
        let policy = LinkPolicy()
        func pass(_ meeting: Int64) async throws -> [LinkProposal] {
            guard let inputs = try await store.linkInputs(meetingID: meeting, policy: policy) else { return [] }
            return LinkEngine(sources: inputs.sources, pool: inputs.pool, vectors: [:], exclusions: inputs.exclusions, policy: policy).run()
        }
        // Every meeting after the first gets its suggestions; the same inputs give the same list.
        var shown = 0
        var deterministic = true
        var rankedOutUsed = false
        for id in seeded.ids.dropFirst() {
            let first = try await pass(id)
            let again = try await pass(id)
            deterministic = deterministic && first == again
            try await store.replaceSuggestions(meetingID: id, proposals: first)
            shown += first.count
            var ranked = Set<String>()
            for t in try await store.tasks(id) where t.isRankedOut { ranked.insert(LinkExclusions.item(.task, t.id)) }
            for d in try await store.decisions(id) where d.isRankedOut { ranked.insert(LinkExclusions.item(.decision, d.id)) }
            var earlierRanked = Set<String>()
            for meeting in seeded.ids {
                for t in try await store.tasks(meeting) where t.isRankedOut { earlierRanked.insert(LinkExclusions.item(.task, t.id)) }
                for d in try await store.decisions(meeting) where d.isRankedOut { earlierRanked.insert(LinkExclusions.item(.decision, d.id)) }
            }
            rankedOutUsed = rankedOutUsed || first.contains { ranked.contains(LinkExclusions.item($0.kind, $0.srcID)) || earlierRanked.contains(LinkExclusions.item($0.kind, $0.dstID)) }
        }
        detail["suggestions"] = "\(shown)"
        check("deterministic", deterministic)
        check("rankedOutNeverLinked", !rankedOutUsed)
        var chosen: Int64?
        for id in seeded.ids.dropFirst() where chosen == nil { if try await !store.links(ofMeeting: id).isEmpty { chosen = id } }
        guard let target = chosen else {
            detail["note"] = "no suggestion to replay"
            return (failures, detail)
        }
        // A dismissal survives a rewrite of either meeting (new ids, same words).
        let suggestion = try await store.links(ofMeeting: target)[0]
        let words = try await store.linkTexts(kind: suggestion.kind, src: suggestion.srcID, dst: suggestion.dstID)
        let earlierMeeting = try await store.meetingOfItem(kind: suggestion.kind, id: suggestion.dstID) ?? seeded.ids[0]
        try await store.dismissLink(suggestion.id)
        for meeting in Set([earlierMeeting, target]) { try await store.applyMinutes(try await minutesFromStore(store, meeting: meeting), to: meeting) }
        let afterRewrite = try await pass(target)
        var sameAgain = false
        for proposal in afterRewrite where proposal.kind == suggestion.kind {
            if let now = try await store.linkTexts(kind: proposal.kind, src: proposal.srcID, dst: proposal.dstID), now.src == words?.src, now.dst == words?.dst { sameAgain = true }
        }
        check("dismissalSurvivesRewrite", words != nil && !sameAgain)
        // A confirmation keeps both items through a rewrite.
        try await store.replaceSuggestions(meetingID: target, proposals: afterRewrite)
        if let next = try await store.links(ofMeeting: target).first {
            try await store.confirmLink(next.id)
            for meeting in Set([earlierMeeting, target]) { try await store.applyMinutes(try await minutesFromStore(store, meeting: meeting), to: meeting) }
            check("confirmationSurvivesRewrite", (try await store.links(ofMeeting: target)).contains { $0.state == .confirmed })
        }
        // A rewrite of an earlier meeting names the later meetings that lost a suggestion.
        try await store.replaceSuggestions(meetingID: target, proposals: try await pass(target))
        let hadSuggestions = !(try await store.links(ofMeeting: target)).isEmpty
        let pointing = try await store.applyMinutes(try await minutesFromStore(store, meeting: earlierMeeting), to: earlierMeeting)
        let lost = (try await store.links(ofMeeting: target)).isEmpty
        check("rewriteNamesLaterMeetings", !hadSuggestions || !lost || pointing.contains(target) || earlierMeeting == target)
        // A dismissal is kept by the words of the pair, so a rewrite that rewords an item is a new item to the pass: the pair can come back (D17's
        // limit, reported and not counted as a failure).
        if let current = try await store.links(ofMeeting: target).first(where: { $0.state == .suggested }),
           let words = try await store.linkTexts(kind: current.kind, src: current.srcID, dst: current.dstID) {
            let suffix = " as discussed"
            try await store.dismissLink(current.id)
            try await store.applyMinutes(try await minutesFromStore(store, meeting: target, reword: { $0 + suffix }), to: target)
            var back = false
            for proposal in try await pass(target) where proposal.kind == current.kind {
                if let now = try await store.linkTexts(kind: proposal.kind, src: proposal.srcID, dst: proposal.dstID), now.src == words.src + suffix, now.dst == words.dst { back = true }
            }
            detail["dismissalSurvivesRewordedRewrite"] = back ? "no" : "yes"
        }
        // Nothing runs while a recording flag is set.
        let service = LLMService(store: store, providers: providers, searchDefaults: EvaluationDefaults.suite)
        await service.setLinkPolicy(policy)
        await service.setRecording(true, meetingID: nil)
        let before = await service.linkTraces.count
        await service.linksAfterMinutes(target, laterMeetings: [])
        check("nothingWhileRecording", await service.linkTraces.count == before && providers.chatModel.records.isEmpty)
        return (failures, detail)
    }
}

extension MeetingStore {
    /// Evaluation only: the words of both ends of a pair.
    func linkTexts(kind: LinkKind, src: Int64, dst: Int64) throws -> (src: String, dst: String)? {
        let table = kind == .task ? "tasks" : "decisions"
        func text(_ id: Int64) throws -> String? { try db.query("SELECT text FROM \(table) WHERE id = ?", [.integer(id)]).first?.string(0) }
        guard let a = try text(src), let b = try text(dst) else { return nil }
        return (a, b)
    }

    func meetingOfItem(kind: LinkKind, id: Int64) throws -> Int64? {
        try db.query("SELECT meeting_id FROM \(kind == .task ? "tasks" : "decisions") WHERE id = ?", [.integer(id)]).first?.optionalInt(0)
    }
}
