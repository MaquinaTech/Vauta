// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Testing
@testable import Vauta

/// A window that only remembers whether it is on screen, and the order it came back in.
@MainActor
private final class StandInWindow: ConcealableWindow {
    let name: String
    var isVisible = true
    private let shown: (String) -> Void
    init(_ name: String, shown: @escaping (String) -> Void) {
        self.name = name
        self.shown = shown
    }
    func orderOut(_ sender: Any?) { isVisible = false }
    func orderFrontRegardless() {
        isVisible = true
        shown(name)
    }
}

/// Hide Vauta Windows: no window of Vauta stays on screen, and Show Vauta Windows brings back the same ones, stacked as they
/// were; one opened again meanwhile is left alone, and one that closed meanwhile is not brought back.
@Suite("Hide Vauta Windows: ordering the windows out and back")
@MainActor
struct WindowConcealerTests {
    @Test func noWindowStaysAndTheSameOnesComeBackStackedAsTheyWere() {
        var order: [String] = []
        let meetings = StandInWindow("Meetings") { order.append($0) }
        let settings = StandInWindow("Settings") { order.append($0) }
        let concealer = WindowConcealer()
        concealer.conceal([meetings, settings])
        #expect(concealer.isOn && !meetings.isVisible && !settings.isVisible)
        concealer.reveal()
        #expect(!concealer.isOn && meetings.isVisible && settings.isVisible)
        #expect(order == ["Settings", "Meetings"], "back to front: Meetings, in front before, is in front again")
        concealer.reveal()
        #expect(order.count == 2, "nothing comes back twice")
    }

    @Test func aWindowOpenedAgainIsLeftAloneAndOneClosedStaysClosed() {
        var order: [String] = []
        let meetings = StandInWindow("Meetings") { order.append($0) }
        let settings = StandInWindow("Settings") { order.append($0) }
        let network = StandInWindow("Network Activity") { order.append($0) }
        let concealer = WindowConcealer()
        concealer.conceal([meetings, settings, network])
        meetings.isVisible = true   // the person opened it from the panel
        concealer.closed(ObjectIdentifier(settings))
        concealer.reveal()
        #expect(order == ["Network Activity"])
        #expect(!settings.isVisible)
    }

    @Test func hidingWithNothingOnScreenStillCounts() {
        let concealer = WindowConcealer()
        concealer.conceal([])
        #expect(concealer.isOn, "the notepad and the captions wait for Show Vauta Windows")
        concealer.reveal()
        #expect(!concealer.isOn)
    }

    @Test func aRealWindowThatClosesWhileHiddenIsNotBroughtBack() {
        // Never put on screen: closing it posts the notification a relock or the person would.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let concealer = WindowConcealer()
        concealer.conceal([window])
        window.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        concealer.reveal()
        #expect(!window.isVisible, "a closed window is never shown again by Show Vauta Windows")
    }
}
