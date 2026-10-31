// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// When the live notes are written while recording: every 3 minutes with new text, or after about 600 tokens of it, and at once
/// when the person asks ("Update Now"). Never with nothing new to read, and never two at once.
public enum LiveNotesSchedule {
    public static let interval: Duration = .seconds(180)
    public static let characters = 2_100

    /// - Parameters:
    ///   - newCharacters: the text transcribed since the last run started.
    ///   - sinceLast: the time since it started; nil before the first.
    ///   - busy: a run (or the pass over the person's notes, which goes first) is in flight.
    ///   - asked: the person asked for the notes now, so neither the interval nor the length is waited for.
    public static func starts(newCharacters: Int, sinceLast: Duration?, busy: Bool, asked: Bool = false) -> Bool {
        guard !busy, newCharacters > 0 else { return false }
        return asked || newCharacters >= characters || (sinceLast.map { $0 >= interval } ?? true)
    }
}
