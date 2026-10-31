// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// When the live notes are written: on their own every 3 minutes or ~600 tokens, at once when asked, never two at once.
@Suite("Live notes: when they are written")
struct LiveNotesScheduleTests {
    @Test func onTheirOwnTheyWaitForTheIntervalOrTheLength() {
        #expect(LiveNotesSchedule.starts(newCharacters: 40, sinceLast: nil, busy: false), "the first ones with any text")
        #expect(!LiveNotesSchedule.starts(newCharacters: 400, sinceLast: .seconds(60), busy: false))
        #expect(LiveNotesSchedule.starts(newCharacters: 400, sinceLast: .seconds(180), busy: false), "3 minutes")
        #expect(LiveNotesSchedule.starts(newCharacters: 2_100, sinceLast: .seconds(20), busy: false), "about 600 tokens")
        #expect(!LiveNotesSchedule.starts(newCharacters: 0, sinceLast: .seconds(900), busy: false), "nothing new to read")
    }

    @Test func askingSkipsTheWaitButNotTheRules() {
        #expect(LiveNotesSchedule.starts(newCharacters: 40, sinceLast: .seconds(5), busy: false, asked: true), "Update Now: at once")
        #expect(!LiveNotesSchedule.starts(newCharacters: 40, sinceLast: .seconds(5), busy: true, asked: true),
                "a second press while notes are written does not start another run")
        #expect(!LiveNotesSchedule.starts(newCharacters: 0, sinceLast: .seconds(5), busy: false, asked: true), "nothing new since the last ones")
        #expect(!LiveNotesSchedule.starts(newCharacters: 5_000, sinceLast: .seconds(900), busy: true), "never two at once")
    }
}
