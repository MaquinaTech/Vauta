// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta

/// The reminder of a long pause: once per pause, after `pauseReminderMinutes`.
@Suite("Recording: the reminder of a long pause")
@MainActor
struct PauseReminderTests {
    @Test func aPauseIsRemindedOnceAfterItsMinutes() {
        let minutes = RecorderModel.pauseReminderMinutes
        #expect(!RecorderModel.remindsOfPause(pausedFor: .seconds(minutes * 60 - 1), reminded: false), "a short break is not")
        #expect(RecorderModel.remindsOfPause(pausedFor: .seconds(minutes * 60), reminded: false))
        #expect(!RecorderModel.remindsOfPause(pausedFor: .seconds(minutes * 60 * 3), reminded: true), "once per pause")
        #expect((10...30).contains(minutes))
    }
}
