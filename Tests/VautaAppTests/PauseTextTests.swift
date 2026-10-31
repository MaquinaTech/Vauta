// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// The line a transcript shows where the recording was paused.
@Suite("Transcript: the line of a pause")
struct PauseTextTests {
    @Test func aPauseSaysFromWhenToWhenAndHowLong() {
        #expect(TranscriptTab.pauseText(MeetingPause(start: 723, end: 1_143)) == "Paused 12:03 – 19:03 (7 min)")
        #expect(TranscriptTab.pauseText(MeetingPause(start: 723, end: 750)) == "Paused 12:03 – 12:30", "under a minute, no length")
        #expect(TranscriptTab.pauseText(MeetingPause(start: 723, end: nil)) == "Paused from 12:03 to the end")
    }
}
