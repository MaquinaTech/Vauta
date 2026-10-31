// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Testing
@testable import VautaCore

/// Hide Vauta Windows: every window on screen goes, the same ones come back stacked as they were, and a window that closed
/// meanwhile stays closed.
@Suite("Hiding Vauta's windows for presenting")
struct WindowConcealmentTests {
    @Test func theSameWindowsComeBackStackedAsTheyWere() {
        var state = WindowConcealment<String>()
        #expect(!state.isOn)
        #expect(state.conceal(onScreen: ["Meetings", "Settings", "Network Activity"]) == ["Meetings", "Settings", "Network Activity"])
        #expect(state.isOn && state.hidden == ["Network Activity", "Settings", "Meetings"])
        #expect(state.reveal() == ["Network Activity", "Settings", "Meetings"], "back to front: Meetings ends in front, as before")
        #expect(!state.isOn && state.hidden.isEmpty)
        #expect(state.reveal().isEmpty, "nothing to bring back twice")
    }

    @Test func hidingAgainChangesNothing() {
        var state = WindowConcealment<String>()
        _ = state.conceal(onScreen: ["Meetings"])
        // A window the person opened meanwhile is theirs: a second Hide doesn't take it into the list to bring back.
        #expect(state.conceal(onScreen: ["Settings"]).isEmpty)
        #expect(state.hidden == ["Meetings"])
    }

    @Test func aWindowThatClosedMeanwhileStaysClosed() {
        var state = WindowConcealment<Int>()
        _ = state.conceal(onScreen: [1, 2, 3])
        state.closed(2)
        state.closed(9)
        #expect(state.reveal() == [3, 1])
    }

    @Test func withNothingOnScreenTheWindowsAreStillHidden() {
        // Nothing to hide yet, but the mode is on: the notepad and the captions don't come up by themselves meanwhile.
        var state = WindowConcealment<Int>()
        #expect(state.conceal(onScreen: []).isEmpty)
        #expect(state.isOn)
        #expect(state.reveal().isEmpty && !state.isOn)
    }
}
