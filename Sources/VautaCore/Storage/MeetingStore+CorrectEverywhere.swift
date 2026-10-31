// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// After a line is corrected: the same misheard words elsewhere in the meeting. A name or term the transcriber got wrong once is
/// usually wrong in other lines too, and in the summary, decisions and tasks the model wrote from them. Vauta offers to correct
/// them there as well (`correctEverywhereOffer`) and only does it when the person says so (`correctEverywhere`), with one Undo.
/// Each line changes as a correction of its own (`correctSegment`: its original kept, the marks it calls for). The minutes keep
/// who wrote them and their marks, except an "edited" mark the change answers: the item then says what its line says. A name or
/// term the correction put in that Vauta doesn't know yet is offered for the glossary, so later meetings get it right
/// (`addCorrectedTerm`).
extension MeetingStore {
    public struct CorrectEverywhereOffer: Sendable, Equatable {
        public struct Replacement: Sendable, Equatable {
            public let from: String
            public let to: String
        }

        public let meetingID: Int64
        /// The line the person corrected.
        public let segmentID: Int64
        public let replacements: [Replacement]
        /// How many other lines, and minutes items (the summary counting as one), have the old words.
        public private(set) var lines: Int
        public private(set) var items: Int
        /// The names and terms the correction put in that neither the glossary nor Context has yet (`TranscriptCorrection.newTerms`),
        /// offered for the glossary (`addCorrectedTerm`).
        public private(set) var newTerms: [String]

        /// Other lines or the minutes have the old words: Correct Everywhere is offered.
        public var isElsewhere: Bool { lines + items > 0 }

        /// What is left to offer once the words were corrected everywhere: the terms for the glossary; nil when none.
        public func corrected() -> Self? {
            var left = self
            (left.lines, left.items) = (0, 0)
            return left.newTerms.isEmpty ? nil : left
        }

        /// What is left to offer once `term` is in the glossary; nil when nothing.
        public func adding(_ term: String) -> Self? {
            var left = self
            left.newTerms.removeAll { $0 == term }
            return left.isElsewhere || !left.newTerms.isEmpty ? left : nil
        }
    }

    /// What `correctEverywhere` changed, for Edit ▸ Undo. Kept in memory only.
    public struct CorrectEverywhereUndo: Sendable {
        public let meetingID: Int64
        let lines: [TextCorrection]
        let items: [ItemChange]
        let card: (before: String, after: String)?

        struct ItemChange: Sendable {
            let table: String, id: Int64, before: String, after: String
            let mark: (unconfirmed: Bool, reason: String?), markAfter: (unconfirmed: Bool, reason: String?)
        }
    }

    private struct EverywherePlan {
        var lines: [(id: Int64, text: String)] = []
        var items: [(table: String, id: Int64, before: String, after: String)] = []
        var card: (before: String, after: MeetingCard)?
        var isEmpty: Bool { lines.isEmpty && items.isEmpty && card == nil }
    }

    /// What else in the meeting has the words a correction replaced, and the new names and terms it put in; nil when nothing has
    /// them and there are none (or the correction replaced no words).
    public func correctEverywhereOffer(after c: TextCorrection) throws -> CorrectEverywhereOffer? {
        let profile = LanguageProfile(locale: try meetingLocale(c.meetingID))
        let correction = TranscriptCorrection(from: c.before, to: c.after, profile: profile)
        let replacements = correction.replacements().map { CorrectEverywhereOffer.Replacement(from: $0.from, to: $0.to) }
        guard !replacements.isEmpty else { return nil }
        let plan = try everywherePlan(c.meetingID, except: c.segmentID, replacements, profile)
        let terms = try unknownTerms(correction.newTerms())
        guard !plan.isEmpty || !terms.isEmpty else { return nil }
        return CorrectEverywhereOffer(meetingID: c.meetingID, segmentID: c.segmentID, replacements: replacements,
                                      lines: plan.lines.count, items: plan.items.count + (plan.card == nil ? 0 : 1), newTerms: terms)
    }

    /// Writes the offer's new words wherever the meeting still has the old ones. nil when nothing has them any more. Refuses the
    /// meeting being recorded.
    @discardableResult
    public func correctEverywhere(_ offer: CorrectEverywhereOffer, now: Date = .now) async throws -> CorrectEverywhereUndo? {
        let undo: CorrectEverywhereUndo? = try transaction {
            guard offer.meetingID != activeMeetingID else { throw StoreError(.meetingInProgress) }
            let profile = LanguageProfile(locale: try meetingLocale(offer.meetingID))
            let plan = try everywherePlan(offer.meetingID, except: offer.segmentID, offer.replacements, profile)
            guard !plan.isEmpty else { return nil }
            let lines = try plan.lines.compactMap { try correctInTransaction($0.id, to: $0.text, now: now, analyze: false) }
            var items: [CorrectEverywhereUndo.ItemChange] = []
            for item in plan.items {
                guard let row = try db.query("SELECT unconfirmed, unconfirmed_reason, segment_id FROM \(item.table) WHERE id = ?",
                                             [.integer(item.id)]).first else { continue }
                let mark = (unconfirmed: row.int(0) != 0, reason: row.optionalString(1))
                var markAfter = mark
                if mark.reason == UnconfirmedReason.edited, let segment = row.optionalInt(2),
                   try answers(item.after, line: segment, offer.replacements, profile) {
                    markAfter = (false, nil)
                }
                try run("UPDATE \(item.table) SET text = ?, unconfirmed = ?, unconfirmed_reason = ? WHERE id = ?",
                        [.text(item.after), .integer(markAfter.unconfirmed ? 1 : 0), markAfter.reason.map { .text($0) }, .integer(item.id)])
                try linkEdited(kind: item.table == "tasks" ? .task : .decision, id: item.id, old: item.before, new: item.after, meetingID: offer.meetingID)
                items.append(.init(table: item.table, id: item.id, before: item.before, after: item.after, mark: mark, markAfter: markAfter))
            }
            var card: (before: String, after: String)?
            if let change = plan.card {
                let after = try change.after.json()
                try run("UPDATE meetings SET card = ?, card_version = card_version + 1 WHERE id = ?", [.text(after), .integer(offer.meetingID)])
                card = (change.before, after)
            }
            _ = try analyzeInTransaction(offer.meetingID)
            return CorrectEverywhereUndo(meetingID: offer.meetingID, lines: lines, items: items, card: card)
        }
        guard let undo else { return nil }
        try await commitEdit()
        itemsEditedHandler?(offer.meetingID)
        return undo
    }

    /// Takes `correctEverywhere` back. Fails, changing nothing, when one of its lines was corrected again, split or deleted since;
    /// an item or summary the person edited since is left as they made it.
    public func undoCorrectEverywhere(_ u: CorrectEverywhereUndo) async throws {
        try transaction {
            for i in u.items.reversed() {
                try run("UPDATE \(i.table) SET text = ?, unconfirmed = ?, unconfirmed_reason = ? WHERE id = ? AND text = ?",
                        [.text(i.before), .integer(i.mark.unconfirmed ? 1 : 0), i.mark.reason.map { .text($0) }, .integer(i.id), .text(i.after)])
            }
            if let card = u.card {
                try run("UPDATE meetings SET card = ?, card_version = card_version + 1 WHERE id = ? AND card = ?",
                        [.text(card.before), .integer(u.meetingID), .text(card.after)])
            }
            for c in u.lines.reversed() { try undoInTransaction(c, analyze: false) }
            _ = try analyzeInTransaction(u.meetingID)
        }
        try await commitEdit()
        itemsEditedHandler?(u.meetingID)
    }

    /// Whether an item marked "edited" says, with the new words, what its line says now: the line as transcribed with the same
    /// replacements reads as the line now, or what else changed does not touch the item.
    private func answers(_ item: String, line segment: Int64, _ replacements: [CorrectEverywhereOffer.Replacement],
                         _ profile: LanguageProfile) throws -> Bool {
        guard let row = try db.query("SELECT text, original_text FROM segments WHERE id = ?", [.integer(segment)]).first else { return false }
        var expected = row.optionalString(1) ?? row.string(0)
        for r in replacements { expected = TranscriptCorrection.replacing(r.from, with: r.to, in: expected, profile: profile) ?? expected }
        return !TranscriptCorrection(from: expected, to: row.string(0), profile: profile).touches(item)
    }

    private func everywherePlan(_ meetingID: Int64, except segmentID: Int64, _ replacements: [CorrectEverywhereOffer.Replacement],
                                _ profile: LanguageProfile) throws -> EverywherePlan {
        func replaced(_ text: String) -> String? {
            var out = text
            for r in replacements { out = TranscriptCorrection.replacing(r.from, with: r.to, in: out, profile: profile) ?? out }
            return out == text ? nil : out
        }
        var plan = EverywherePlan()
        for row in try db.query("SELECT s.id, s.text FROM segments s WHERE s.meeting_id = ? AND s.id <> ? AND \(Self.notEcho) ORDER BY s.start, s.id",
                                [.integer(meetingID), .integer(segmentID)]) {
            if let text = replaced(row.string(1)) { plan.lines.append((row.int(0), text)) }
        }
        for table in ["decisions", "tasks"] {
            for row in try db.query("SELECT id, text FROM \(table) WHERE meeting_id = ? ORDER BY id", [.integer(meetingID)]) {
                if let text = replaced(row.string(1)) { plan.items.append((table, row.int(0), row.string(1), text)) }
            }
        }
        if let json = try db.query("SELECT card FROM meetings WHERE id = ?", [.integer(meetingID)]).first?.optionalString(0),
           let card = try? JSONDecoder().decode(MeetingCard.self, from: Data(json.utf8)) {
            var after = card
            after.summary = replaced(card.summary) ?? card.summary
            after.topics = card.topics.map { replaced($0) ?? $0 }
            after.openQuestions = card.openQuestions?.map { replaced($0) ?? $0 }
            if after != card { plan.card = (json, after) }
        }
        return plan
    }
}
