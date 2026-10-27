// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The store's side of the pre-meeting brief. Every function here is a SELECT: a brief never writes before a meeting is recorded (an
/// invitation must not create people).
extension MeetingStore {
    /// Candidate open tasks handed to the ranker (their texts are embedded on the fly).
    public static let briefTaskCandidateLimit = 100
    /// A meeting counts as the same group when at least this share of the event's attendees were at it.
    static let briefAttendeeOverlap = 0.5

    public func briefFacts(for event: BriefEvent, leavesOutRankedOut: Bool = BriefPolicy.leavesOutRankedOutItems) throws -> BriefFacts {
        var facts = BriefFacts()
        facts.selfEntityID = try selfEntityID()
        facts.notesSourceIDs = Set(try documentSources().filter(\.isNotesExport).map(\.id))
        facts.remindersTaskIDs = try liveReminderIdentifiers().taskIDs
        let resolved = try resolveAttendees(event.calendarMeeting.attendees)
        let selfID = facts.selfEntityID

        // Series: the calendar's recurring event, else a series whose title pattern is in the title.
        if let key = event.seriesKey.map({ Self.clean($0, max: 400) }), !key.isEmpty,
           let row = try db.query("SELECT id, title_pattern FROM series WHERE calendar_key = ?", [.text(key)]).first {
            facts.seriesID = row.int(0)
            facts.seriesName = row.string(1)
        } else if !event.title.isEmpty, let match = try seriesMatching(title: event.title), let id = match.id {
            facts.seriesID = id
            facts.seriesName = match.titlePattern
        }

        // People.
        var entityIDs: [Int64] = []
        for r in resolved {
            if let id = r.entityID {
                guard id != selfID, !entityIDs.contains(id), let entity = try entity(id) else { continue }
                let row = try db.query("""
                    SELECT COUNT(*), MAX(m.started_at) FROM meeting_entities me JOIN meetings m ON m.id = me.meeting_id
                    WHERE me.entity_id = ? AND me.role = 'attendee' AND m.ended_at IS NOT NULL AND m.started_at < ?
                    """, [.integer(id), .real(event.start.timeIntervalSince1970)])[0]
                facts.people.append(BriefPerson(name: entity.displayName, entityID: id, lastMet: row.optionalDouble(1).map(Date.init(timeIntervalSince1970:)),
                                                meetingsTogether: Int(row.int(0))))
                entityIDs.append(id)
            } else {
                let name = r.attendee.name.isEmpty ? (r.attendee.email ?? "") : r.attendee.name
                facts.people.append(BriefPerson(name: Self.clean(name, max: 200), entityID: nil, lastMet: nil, meetingsTogether: 0))
            }
        }

        // The last meeting: the series' newest, else the newest with at least half of the attendees.
        var lastID: Int64?
        if let series = facts.seriesID {
            lastID = try db.query("""
                SELECT id FROM meetings WHERE series_id = ? AND ended_at IS NOT NULL AND started_at < ? ORDER BY started_at DESC, id DESC LIMIT 1
                """, [.integer(series), .real(event.start.timeIntervalSince1970)]).first?.int(0)
        }
        let attendeeCount = resolved.count
        if lastID == nil, !entityIDs.isEmpty {
            let rows = try db.query("""
                SELECT me.meeting_id, COUNT(DISTINCT me.entity_id) FROM meeting_entities me JOIN meetings m ON m.id = me.meeting_id
                WHERE me.role = 'attendee' AND me.entity_id IN (SELECT value FROM json_each(?)) AND m.ended_at IS NOT NULL AND m.started_at < ?
                GROUP BY me.meeting_id ORDER BY m.started_at DESC, m.id DESC
                """, [.ids(entityIDs), .real(event.start.timeIntervalSince1970)])
            lastID = rows.first { Double($0.int(1)) >= Self.briefAttendeeOverlap * Double(attendeeCount) }?.int(0)
        }
        if let lastID { facts.last = try briefLastMeeting(lastID, leavesOutRankedOut: leavesOutRankedOut) }

        // Open tasks of the attendees and of the person (the ranker orders them).
        var seen = Set<Int64>()
        var tasks: [TaskItem] = []
        for owner in entityIDs + (selfID.map { [$0] } ?? []) {
            for task in try openTasks(owner: owner) where seen.insert(task.id).inserted { tasks.append(task) }
        }
        let starts = Dictionary(uniqueKeysWithValues: try tasks.compactMap { $0.meetingID }.reduce(into: Set<Int64>()) { $0.insert($1) }.compactMap { id in
            try meeting(id).map { (id, $0.startedAt) }
        })
        facts.openTasks = tasks.filter { !leavesOutRankedOut || !$0.isRankedOut }.prefix(Self.briefTaskCandidateLimit)
            .map { BriefTaskFact(task: $0, meetingDate: $0.meetingID.flatMap { starts[$0] }) }
        try addLinks(to: &facts)
        return facts
    }

    func briefLastMeeting(_ id: Int64, leavesOutRankedOut: Bool = BriefPolicy.leavesOutRankedOutItems) throws -> BriefLastMeeting? {
        guard let meeting = try meeting(id) else { return nil }
        let card = try self.card(id)
        let locale = meeting.locale ?? Meeting.legacyLocaleIdentifier
        let segments = try self.segments(of: id).map { (id: $0.id, t: $0.start, text: $0.text) }
        let questions = (card?.openQuestions ?? []).prefix(10).map { text -> BriefOpenQuestion in
            let found = BriefOpenQuestionLocator.locate(question: text, in: segments, locale: locale)
            return BriefOpenQuestion(text: text, segmentID: found?.id, t: found?.t)
        }
        let materials = try meetingMaterials(id)
        var files: [BriefMaterial] = materials.attached.map { BriefMaterial(sourceID: $0.id, relPath: "", name: $0.displayName) }
        files += materials.linked.map { BriefMaterial(sourceID: $0.source, relPath: $0.relPath, name: ($0.relPath as NSString).lastPathComponent) }
        return BriefLastMeeting(meetingID: id, date: meeting.startedAt, title: Meeting.displayTitle(meeting.title, startedAt: meeting.startedAt),
                                locale: meeting.locale, summary: card.map(\.summary).flatMap { $0.isEmpty ? nil : $0 }, topics: card?.topics ?? [],
                                decisions: try decisions(id).filter { !leavesOutRankedOut || !$0.isRankedOut },
                                openTasks: try tasks(id).filter { $0.status == .open && (!leavesOutRankedOut || !$0.isRankedOut) },
                                openQuestions: Array(questions), materials: files)
    }
}

extension MeetingStore {
    /// What the person confirmed about tasks and decisions of earlier meetings (the chains and the links of a decision). Nothing is read
    /// when there are no confirmed links, which is every store until links ship.
    func addLinks(to facts: inout BriefFacts) throws {
        for chain in try linkChains(.task) {
            let info = BriefChainInfo(newest: chain.newest.id, mentions: chain.count, since: chain.members.last?.date ?? chain.newest.date)
            for member in chain.members { facts.taskChains[member.id] = info }
        }
        let rows = try db.query("""
            SELECT l.src_id, l.dst_id, l.rel, d.text, m.started_at FROM item_links l
            JOIN decisions d ON d.id = l.dst_id JOIN meetings m ON m.id = d.meeting_id
            WHERE l.kind = 'decision' AND l.state = 'confirmed'
            """)
        guard !rows.isEmpty else { return }
        let firsts = Dictionary(uniqueKeysWithValues: try linkChains(.decision).flatMap { chain in chain.members.map { ($0.id, chain.members.last?.date ?? $0.date) } })
        for r in rows {
            let src = r.int(0)
            if r.string(2) == "changes" {
                facts.decisionLinks[src] = .changes(earlierText: r.string(3), earlierDate: Date(timeIntervalSince1970: r.double(4)))
            } else if let first = firsts[src], facts.decisionLinks[src] == nil {
                facts.decisionLinks[src] = .same(first: first)
            }
        }
    }
}
