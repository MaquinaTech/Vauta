// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Testing
@testable import VautaCore

/// The meeting companion comes with each recording (when the setting is on), goes with it, and stays closed for the rest of a
/// recording once the person closes it.
@Suite("The meeting companion: when it is on screen")
struct CompanionPresenceTests {
    @Test func itComesAndGoesWithTheRecording() {
        var presence = CompanionPresence()
        #expect(!presence.isShown)
        presence.recordingStarted(opensByItself: true)
        #expect(presence.isShown)
        presence.recordingEnded()
        #expect(!presence.isShown)
        presence.recordingStarted(opensByItself: false)
        #expect(!presence.isShown, "the setting is off: only the menu opens it")
        presence.open()
        #expect(presence.isShown)
    }

    @Test func closedByThePersonItStaysClosedUntilTheNextRecording() {
        var presence = CompanionPresence()
        presence.recordingStarted(opensByItself: true)
        presence.close()
        #expect(!presence.isShown && presence.closedByPerson)
        presence.open()
        #expect(presence.isShown && !presence.closedByPerson)
        presence.close()
        presence.recordingEnded()
        presence.recordingStarted(opensByItself: true)
        #expect(presence.isShown && !presence.closedByPerson, "each recording starts afresh")
    }

    @Test func closingWhatIsNotShownChangesNothing() {
        var presence = CompanionPresence()
        presence.close()
        #expect(presence == CompanionPresence())
    }
}
