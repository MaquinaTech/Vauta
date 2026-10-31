// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

/// Recording › Hide Vauta Windows, for sharing the screen: Vauta's windows leave the screen together while the recording goes
/// on, and Show Vauta Windows brings back the ones that were hidden, stacked as they were. A window the person opens on purpose
/// meanwhile shows as usual; one that closes meanwhile (a relock, the person) is not brought back. Pure state: the app orders
/// the windows out and in.
public struct WindowConcealment<Window: Hashable & Sendable>: Sendable, Equatable {
    /// Vauta's windows are hidden, until `reveal()`.
    public private(set) var isOn = false
    /// The hidden windows still to bring back, back to front.
    public private(set) var hidden: [Window] = []

    public init() {}

    /// Hides the windows on screen, given front to back. Returns those to order out; none when they are hidden already.
    public mutating func conceal(onScreen frontToBack: [Window]) -> [Window] {
        guard !isOn else { return [] }
        isOn = true
        hidden = frontToBack.reversed()
        return frontToBack
    }

    /// Ends. Returns the windows to bring back, back to front, so the one that was in front is in front again.
    public mutating func reveal() -> [Window] {
        defer {
            isOn = false
            hidden = []
        }
        return hidden
    }

    /// A hidden window closed meanwhile: it is not brought back.
    public mutating func closed(_ window: Window) {
        hidden.removeAll { $0 == window }
    }
}
