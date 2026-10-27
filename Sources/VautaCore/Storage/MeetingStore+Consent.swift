// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Consent helper: the record that the user told the other participants the
/// meeting is being transcribed. The date is a column of the meeting, so it is
/// deleted with the meeting (retention, "Delete", "Erase everything"), travels
/// in backups and appears in the JSON export.
extension MeetingStore {
    /// When the user marked the participants as informed. nil = not marked.
    public func participantsInformedAt(_ meetingID: Int64) throws -> Date? {
        try db.query("SELECT participants_informed_at FROM meetings WHERE id = ?", [.integer(meetingID)]).first?
            .optionalDouble(0).map(Date.init(timeIntervalSince1970:))
    }

    /// Records that the participants were informed. The first date stays: marking
    /// again changes nothing. Works while the meeting is being recorded.
    public func markParticipantsInformed(_ meetingID: Int64, at date: Date = .now) async throws {
        try run("UPDATE meetings SET participants_informed_at = COALESCE(participants_informed_at, ?) WHERE id = ?",
                [.real(date.timeIntervalSince1970), .integer(meetingID)])
        try await commitEdit()
    }

    /// Removes the record (the user marked the wrong meeting, or the participants were not told after all).
    public func clearParticipantsInformed(_ meetingID: Int64) async throws {
        try run("UPDATE meetings SET participants_informed_at = NULL WHERE id = ?", [.integer(meetingID)])
        try await commitEdit()
    }

    /// An earlier meeting captured from the same app family was marked as informed.
    /// `sourceApp` nil matches meetings without a recorded app (all system audio).
    /// Used by the "first time per meeting app" reminder setting.
    public func hasInformedParticipants(sourceApp: String?) throws -> Bool {
        try !db.query("SELECT 1 FROM meetings WHERE source_app IS ? AND participants_informed_at IS NOT NULL LIMIT 1",
                      [sourceApp.map { .text($0) }]).isEmpty
    }
}
