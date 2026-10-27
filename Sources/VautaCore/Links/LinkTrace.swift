// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Counts and timings of one link pass: never text, never ids of items. The evaluation writes them to `traces.jsonl`.
public struct LinkTrace: Sendable, Equatable, Codable {
    public enum Pass: String, Sendable, Codable { case keyword, vector, checked }
    public var meetingID: Int64
    public var pass: Pass
    public var sources: Int
    public var pool: Int
    public var vectors: Int
    public var shown: Int
    public var milliseconds: Int
    public var modelCalls = 0
    /// The pass ran while a recording flag was set (the gate says this is always 0).
    public var duringRecording = false

    public init(meetingID: Int64, pass: Pass, sources: Int, pool: Int, vectors: Int, shown: Int, milliseconds: Int) {
        self.meetingID = meetingID
        self.pass = pass
        self.sources = sources
        self.pool = pool
        self.vectors = vectors
        self.shown = shown
        self.milliseconds = milliseconds
    }
}
