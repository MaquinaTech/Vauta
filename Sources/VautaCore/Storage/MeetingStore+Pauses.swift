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

extension MeetingPause {
    /// "Paused 12:03 – 12:10 (7 min)", "Paused 12:03 – 12:04" under a minute, "Paused from 12:03 to the end" when the recording stopped
    /// during it. `clock` writes a time of the meeting: the app's form, or the exports' (`ExportTimestamp.clock`).
    public func text(clock: (Double) -> String = ElapsedTime.stamp) -> String {
        let from = clock(start)
        guard let end else {
            return String(localized: "Paused from \(from) to the end", comment: "Transcript: the recording was paused at this time and not resumed before it ended; the argument is a time in the meeting (12:03)")
        }
        let minutes = Int(((end - start) / 60).rounded())
        let to = clock(end)
        if minutes < 1 {
            return String(localized: "Paused \(from) – \(to)", comment: "Transcript: nothing was captured between these two times of the meeting because the recording was paused (12:03 – 12:04)")
        }
        return String(localized: "Paused \(from) – \(to) (\(minutes) min)", comment: "Transcript: nothing was captured between these two times of the meeting because the recording was paused; the last argument is how many minutes (12:03 – 12:10 (7 min))")
    }

    /// Where each pause goes among transcript lines that start at `starts` (in order): before the first line that starts at or
    /// after it, or after all of them (`starts.count`). The pauses of each place keep their order.
    public static func places(of pauses: [MeetingPause], among starts: [Double]) -> [Int: [MeetingPause]] {
        var out: [Int: [MeetingPause]] = [:]
        for pause in pauses.sorted(by: { $0.start < $1.start }) {
            out[starts.firstIndex { $0 >= pause.start } ?? starts.count, default: []].append(pause)
        }
        return out
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
