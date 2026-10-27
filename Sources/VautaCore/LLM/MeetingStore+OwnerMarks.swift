// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension MeetingStore {
    /// Recomputes which owners of the model's tasks the meeting's speakers back, after the speakers changed (a
    /// speaker was named, renamed, merged or separated again). Only the mark changes: an owner is never replaced or
    /// removed here, and the user's own tasks are left alone. An owner is marked when the cited segment, read with
    /// today's speakers (or none, after separation is turned off), no longer points to them. Returns how many marks changed.
    @discardableResult
    public func refreshOwnerMarks(_ meetingID: Int64) async throws -> Int {
        let speakerRows = try speakers(of: meetingID)
        let rows = try db.query("""
            SELECT id, owner_id, segment_id, owner_uncertain FROM tasks
            WHERE meeting_id = ? AND source = 'llm' AND owner_id IS NOT NULL AND segment_id IS NOT NULL
            """, [.integer(meetingID)])
        guard !rows.isEmpty else { return 0 }
        let me = try await selfEntity()
        let directory = SpeakerDirectory(speakers: speakerRows, selfEntity: me)
        let segments = Dictionary(try citableSegments(meetingID).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let candidates = try candidateEntities(meetingID)
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let people = Set(try meetingEntities(meetingID, role: .attendee).map(\.id) + meetingEntities(meetingID, role: .others).map(\.id))
            .union(directory.namedPeople)
        var changes: [(task: Int64, uncertain: Bool)] = []
        for row in rows {
            guard let owner = row.optionalInt(1), let segment = row.optionalInt(2).flatMap({ segments[$0] }) else { continue }
            let verdict = OwnerResolver.resolve(proposed: owner, segment: segment, directory: directory, selfEntity: me,
                                                byID: byID, meetingPeople: people)
            // The owner is kept; a verdict for somebody else, or for nobody, means the words and labels do not back it.
            let uncertain = verdict.owner != owner || verdict.uncertain
            if uncertain != (row.int(3) != 0) { changes.append((row.int(0), uncertain)) }
        }
        guard !changes.isEmpty else { return 0 }
        try transaction {
            for change in changes {
                try run("UPDATE tasks SET owner_uncertain = ? WHERE id = ?", [.integer(change.uncertain ? 1 : 0), .integer(change.task)])
            }
        }
        try await commitEdit()
        return changes.count
    }
}
