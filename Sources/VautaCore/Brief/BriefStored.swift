// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The brief kept with a recorded meeting (`meeting_briefs`, migration 27): references to the items it showed and the agenda lines that
/// passed the checks, so "what did I walk in with" can be read later. The store is encrypted and the row goes with its meeting.
///
/// The decisions, tasks and the summary sentence are read again from the store when the brief is read, so an edit or a deletion there
/// reaches the kept brief.
///
/// It holds no reminder text, no invitation notes and no attendee who is not a known person: those items are not kept, and an agenda line that cites one is not kept either.
/// The JSON keys never change meaning (a new field is optional when decoding).
public struct BriefStoredReferences: Codable, Sendable, Equatable {
    public static let version = 1

    public struct Item: Codable, Sendable, Equatable {
        public var id: String
        public var section: String
        public var kind: String
        public var text: String
        public var meetingID: Int64?
        public var decisionID: Int64?
        public var taskID: Int64?
        public var entityID: Int64?
        public var sourceID: Int64?
        public var relPath: String?
        public var passageKey: String?
        public var segmentID: Int64?
        public var t: Double?
        /// Read again from the store with the text, never stored: a decision or task the minutes mark as unconfirmed keeps its mark here.
        public var unconfirmed = false
        public var ownerUncertain = false

        enum CodingKeys: String, CodingKey {
            case id, section, kind, text, meetingID = "meeting", decisionID = "decision", taskID = "task", entityID = "entity",
                 sourceID = "source", relPath = "path", passageKey = "passage", segmentID = "segment", t
        }
    }

    public var items: [Item]
    public var agenda: [BriefAgendaLine]

    enum CodingKeys: String, CodingKey { case items, agenda }

    public init(items: [Item], agenda: [BriefAgendaLine]) {
        self.items = items
        self.agenda = agenda
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        agenda = try c.decodeIfPresent([BriefAgendaLine].self, forKey: .agenda) ?? []
    }

    /// What of `snapshot` may be kept.
    public init(snapshot: BriefSnapshot) {
        var kept: [Item] = []
        for section in snapshot.sections where section.kind != .reminders && section.kind != .invitation {
            // An attendee the store does not know is invitation text (a calendar name or an address): it is not kept, only people with an entity are.
            for item in section.items where item.kind != .reminder && item.kind != .invitationLine && (item.kind != .person || item.entityID != nil) {
                var stored = Item(id: item.id, section: section.kind.rawValue, kind: item.kind.rawValue, text: item.text)
                stored.meetingID = item.meetingID
                stored.decisionID = item.decisionID
                stored.taskID = item.taskID
                stored.entityID = item.entityID
                stored.unconfirmed = item.unconfirmed
                stored.ownerUncertain = item.ownerUncertain
                switch item.link {
                case .segment(let meeting, let segment): stored.meetingID = meeting; stored.segmentID = segment
                case .meeting(let meeting, let t): stored.meetingID = meeting; stored.t = t
                case .passage(let key, let source, let path): stored.passageKey = key; stored.sourceID = source; stored.relPath = path
                case .file(let source, let path): stored.sourceID = source; stored.relPath = path
                case .person(let entity): stored.entityID = entity
                case .reminder, .event, .none: break
                }
                kept.append(stored)
            }
        }
        let ids = Set(kept.map(\.id))
        self.init(items: kept, agenda: snapshot.agenda.lines.filter { $0.cites.allSatisfy(ids.contains) })
    }
}

extension BriefStoredReferences.Item {
    /// Where the item opened when the brief was shown.
    public var link: BriefLink {
        if let meetingID, let segmentID { return .segment(meetingID: meetingID, segmentID: segmentID) }
        if let sourceID, let relPath {
            if let passageKey { return .passage(key: passageKey, sourceID: sourceID, relPath: relPath) }
            return .file(sourceID: sourceID, relPath: relPath)
        }
        if let entityID, meetingID == nil { return .person(entityID: entityID) }
        if let meetingID { return .meeting(meetingID: meetingID, t: t) }
        if let entityID { return .person(entityID: entityID) }
        return .none
    }
}

extension BriefStoredReferences {
    /// The sections of the kept brief, in the order they were shown. Only what was stored is there: the text of each line, where it
    /// opens, and the verified agenda.
    public var sections: [BriefSection] {
        var order: [BriefSectionKind] = []
        var grouped: [BriefSectionKind: [BriefItem]] = [:]
        for stored in items {
            guard let section = BriefSectionKind(rawValue: stored.section), let kind = BriefItem.Kind(rawValue: stored.kind) else { continue }
            var item = BriefItem(id: stored.id, kind: kind, text: stored.text, link: stored.link)
            item.meetingID = stored.meetingID
            item.taskID = stored.taskID
            item.decisionID = stored.decisionID
            item.entityID = stored.entityID
            item.unconfirmed = stored.unconfirmed
            item.ownerUncertain = stored.ownerUncertain
            item.historyKnown = false
            if grouped[section] == nil { order.append(section) }
            grouped[section, default: []].append(item)
        }
        return order.map { BriefSection(kind: $0, items: grouped[$0] ?? []) }
    }
}

extension MeetingStore {
    /// Keeps the brief with the recorded meeting (replacing an earlier one).
    public func saveBrief(_ references: BriefStoredReferences, for meetingID: Int64, at date: Date = .now) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(references), as: UTF8.self)
        try run("""
            INSERT INTO meeting_briefs(meeting_id, created_at, version, json) VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(meeting_id) DO UPDATE SET created_at = excluded.created_at, version = excluded.version, json = excluded.json
            """, [.integer(meetingID), .real(date.timeIntervalSince1970), .integer(Int64(BriefStoredReferences.version)), .text(json)])
        try await commitEdit()
    }

    public func deleteBrief(of meetingID: Int64) async throws {
        try run("DELETE FROM meeting_briefs WHERE meeting_id = ?", [.integer(meetingID)])
        try await commitEdit()
    }

    /// The brief a meeting was recorded with. What no longer exists (a decision, a task, a meeting, a person or a source that was deleted
    /// since) is dropped, and so is an agenda line that cited it.
    public func storedBrief(of meetingID: Int64) throws -> (references: BriefStoredReferences, createdAt: Date)? {
        guard let row = try db.query("SELECT json, created_at FROM meeting_briefs WHERE meeting_id = ?", [.integer(meetingID)]).first,
              var references = try? JSONDecoder().decode(BriefStoredReferences.self, from: Data(row.string(0).utf8)) else { return nil }
        func alive(_ table: String, _ id: Int64?) throws -> Bool {
            guard let id else { return true }
            return try !db.query("SELECT 1 FROM \(table) WHERE id = ?", [.integer(id)]).isEmpty
        }
        var kept: [BriefStoredReferences.Item] = []
        for var item in references.items {
            guard try alive("meetings", item.meetingID), try alive("entities", item.entityID), try alive("doc_sources", item.sourceID) else { continue }
            if let id = item.decisionID {
                guard let decision = try db.query("SELECT text, unconfirmed FROM decisions WHERE id = ?", [.integer(id)]).first else { continue }
                item.text = BriefText.line(decision.string(0))
                item.unconfirmed = decision.int(1) != 0
            }
            if item.kind == BriefItem.Kind.summary.rawValue, let id = item.meetingID {
                // The first sentence of the earlier meeting's card is read again, so a sentence the person edited out is not kept here.
                guard let meeting = try meeting(id) else { continue }
                let summary = try card(id).map(\.summary).flatMap { $0.isEmpty ? nil : $0 }.flatMap { BriefText.firstSentence($0, meetingDate: meeting.startedAt) } ?? ""
                item.text = summary.isEmpty ? BriefText.line(Meeting.displayTitle(meeting.title, startedAt: meeting.startedAt)) : summary
            }
            if let id = item.taskID {
                guard let task = try db.query("SELECT text, unconfirmed, owner_uncertain FROM tasks WHERE id = ?", [.integer(id)]).first else { continue }
                item.text = BriefText.line(task.string(0))
                item.unconfirmed = task.int(1) != 0
                item.ownerUncertain = task.int(2) != 0
            }
            kept.append(item)
        }
        references.items = kept
        let ids = Set(kept.map(\.id))
        references.agenda = references.agenda.filter { $0.cites.allSatisfy(ids.contains) }
        return (references, Date(timeIntervalSince1970: row.double(1)))
    }
}
