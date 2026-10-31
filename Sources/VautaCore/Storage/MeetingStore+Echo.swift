// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The speakers' sound picked up by the microphone (`segments.echo`): Me lines that are the other participants' words, and Others
/// lines that are the user's own words sent back by a participant on speakers (`EchoDetection.farEchoes`), marked when a recording
/// ends, and once, at the next launch, in the meetings recorded before and in one a crash left open. An echo is kept
/// and shown dimmed, but everything that reads the transcript as what was said leaves it out: the minutes, live notes and notes,
/// answers and search, owners, mentions, quotes, follow-ups and exports. The person can say a line is theirs, and it is never
/// marked again.
extension MeetingStore {
    /// What a query over `segments s` adds to leave the echoes out.
    static let notEcho = "s.echo <> 1"

    /// Marks the echoes of a meeting, by the meeting's language: the speakers' echo among the Me lines (not with `nearSide` false:
    /// the microphone was measured never to hear the speakers), and the far side's echo of the user among the Others lines. Lines
    /// the person said are not echoes stay as they are. Returns how many were marked.
    @discardableResult
    func markEchoes(_ meetingID: Int64, nearSide: Bool = true) throws -> Int {
        let rows = try db.query("SELECT id, speaker, start, end, text, echo FROM segments WHERE meeting_id = ? ORDER BY start, id",
                                [.integer(meetingID)])
        let lines = rows.map {
            EchoDetection.Line(id: $0.int(0), channel: Channel(storedSpeaker: $0.string(1)), start: $0.double(2), end: $0.double(3), text: $0.string(4))
        }
        let locale = try meetingLocale(meetingID).identifier(.bcp47)
        let echoes = (nearSide ? EchoDetection.echoes(lines, locale: locale) : []) + EchoDetection.farEchoes(lines, locale: locale)
        guard !echoes.isEmpty else { return 0 }
        try run("UPDATE segments SET echo = 1 WHERE meeting_id = ? AND echo = 0 AND id IN (SELECT value FROM json_each(?))",
                [.integer(meetingID), .ids(echoes)])
        let marked = db.changes
        // An echo is not the user talking.
        if marked > 0 { try recomputeTalkTimeInTransaction(meetingID) }
        return marked
    }

    /// Marks the echoes of the meetings on `echo_pending` (recorded before echoes were marked, or left open by a crash), newest
    /// first and one at a time, so the store keeps answering in between, and takes each off the list. A meeting with echoes is
    /// analyzed again, so they name no one. Its minutes are not rewritten. Returns how many lines were marked.
    @discardableResult
    public func markPendingEchoes() async throws -> Int {
        var marked = 0
        var checked = false
        while let id = try db.query("SELECT meeting_id FROM echo_pending ORDER BY meeting_id DESC LIMIT 1").first?.int(0) {
            do {
                marked += try transaction {
                    let found = try markEchoes(id)
                    if found > 0 { _ = try analyzeInTransaction(id) }
                    try run("DELETE FROM echo_pending WHERE meeting_id = ?", [.integer(id)])
                    return found
                }
            } catch {
                // A meeting that can't be checked is left as it is, and never holds up the others.
                try run("DELETE FROM echo_pending WHERE meeting_id = ?", [.integer(id)])
            }
            checked = true
            await Task.yield()
        }
        if checked { try await commitEdit() }
        return marked
    }

    /// The person's word on a line: an echo, or not one (then it is never marked again).
    public func setEcho(_ segmentID: Int64, _ isEcho: Bool) async throws {
        try transaction {
            try run("UPDATE segments SET echo = ? WHERE id = ?", [.integer(isEcho ? 1 : 2), .integer(segmentID)])
            if let meetingID = try db.query("SELECT meeting_id FROM segments WHERE id = ?", [.integer(segmentID)]).first?.int(0) {
                try recomputeTalkTimeInTransaction(meetingID)
            }
        }
        try await commitEdit()
    }

    /// The lines of a meeting marked as echoes.
    public func echoes(of meetingID: Int64) throws -> Set<Int64> {
        Set(try db.query("SELECT id FROM segments WHERE meeting_id = ? AND echo = 1", [.integer(meetingID)]).map { $0.int(0) })
    }
}
