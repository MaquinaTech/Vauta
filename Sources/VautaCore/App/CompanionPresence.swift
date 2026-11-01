// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

/// The meeting companion: the small floating bar with the recording's time and controls, on screen beside the meeting app
/// while the menu-bar panel is closed. When it is on screen; the bar reads everything else from the recording itself, as the
/// panel does, so the two never disagree.
public struct CompanionPresence: Sendable, Equatable {
    /// On screen now.
    public private(set) var isShown = false
    /// The person closed it during this recording: it doesn't come back by itself (Hide Vauta Windows and Show Vauta Windows
    /// leave it closed) until they open it again or the next recording starts.
    public private(set) var closedByPerson = false

    public init() {}

    /// A recording started; `opensByItself` is the setting (Settings → Recording, on by default).
    public mutating func recordingStarted(opensByItself: Bool) {
        closedByPerson = false
        isShown = opensByItself
    }

    /// The recording stopped (or failed): the companion goes, and the next recording starts afresh.
    public mutating func recordingEnded() {
        isShown = false
        closedByPerson = false
    }

    /// The bar's close button, or Recording › Hide Meeting Companion.
    public mutating func close() {
        guard isShown else { return }
        isShown = false
        closedByPerson = true
    }

    /// Recording › Show Meeting Companion, during a recording.
    public mutating func open() {
        isShown = true
        closedByPerson = false
    }
}
