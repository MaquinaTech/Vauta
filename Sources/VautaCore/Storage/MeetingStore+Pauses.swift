// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A stretch of a recording that was paused: nothing was captured in it.
public struct MeetingPause: Sendable, Equatable, Hashable {
    /// Seconds on the transcript's clock.
    public let start: Double
    /// Nil while the pause lasts, and when the app quit during it (the pause then runs to the end of the meeting).
    public let end: Double?

    public init(start: Double, end: Double?) {
        self.start = start
        self.end = end
    }
}

/// The pauses of a recording (`meeting_pauses`, schema 35), written while it records. Times only: a transcript shows them where they
/// were ("Paused 12:03 – 12:10"), so a gap in it is never taken for silence.
extension MeetingStore {
    /// A pause of `meetingID`'s recording starts at `start`. A pause still open is closed there first: there is one at a time.
    public func beginPause(_ meetingID: Int64, at start: Double) throws {
        try transaction {
            try run("UPDATE meeting_pauses SET end = max(start, ?2) WHERE meeting_id = ?1 AND end IS NULL", [.integer(meetingID), .real(start)])
            try run("INSERT INTO meeting_pauses(meeting_id, start) VALUES (?, ?)", [.integer(meetingID), .real(max(0, start))])
        }
    }

    /// The open pause of `meetingID`'s recording ends at `end` (never before it started).
    public func endPause(_ meetingID: Int64, at end: Double) throws {
        try run("UPDATE meeting_pauses SET end = max(start, ?2) WHERE meeting_id = ?1 AND end IS NULL", [.integer(meetingID), .real(end)])
    }

    /// The pauses of a meeting, in order.
    public func pauses(of meetingID: Int64) throws -> [MeetingPause] {
        try db.query("SELECT start, end FROM meeting_pauses WHERE meeting_id = ? ORDER BY start, id", [.integer(meetingID)]).map {
            MeetingPause(start: $0.double(0), end: $0.optionalDouble(1))
        }
    }
}
