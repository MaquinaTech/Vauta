// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Decides when to tell the user that a meeting app is in a call but nothing from it reaches "Others".
///
/// The signal is a known meeting app holding the microphone (`PresenceState.family`) while the "Others" channel has
/// carried no sound. Both must hold, without interruption, for `silenceThreshold` seconds, so a call that has just
/// connected or an app that briefly released the microphone never raises it. It cannot tell a fault from a far side that
/// is simply silent (a muted participant, noise suppression sending digital silence): both look like a quiet "Others",
/// which is why the alert words its advice as things to check. It fires once per silent
/// stretch: after it fires it stays quiet, whether or not the user dismissed the alert, until sound has really come back
/// to "Others" (not one chime or click: see `soundPersistsFor`); a later silent stretch of its own 60 s can raise it again.
/// `coversCurrentSilence` tells the panel whether the ordinary silence banner may stay hidden.
///
/// Pure logic with an injected clock (seconds on any monotonic scale), so it is tested without audio or a UI.
public struct OthersSilenceDetector: Sendable, Equatable {
    /// How long both conditions must hold before the alert is raised.
    public static let silenceThreshold: TimeInterval = 60

    /// Since when a known meeting app has held the microphone without a break.
    private var holdingSince: TimeInterval?
    /// The alert was raised and sound has not really returned since.
    public private(set) var hasRaised = false
    /// The alert already speaks for the silence that is going on now: it was raised and "Others" has not been heard
    /// since. It becomes false when sound returns for good, so the alert can come back for a later silent stretch.
    public private(set) var coversCurrentSilence = false
    /// Since when "Others" has been heard without a gap.
    private var heardSince: TimeInterval?

    /// "Others" counts as heard right now when it has been silent for less than this many seconds.
    public static let soundReturnedWithin: TimeInterval = 5
    /// Sound must be heard without a gap for this long to count as returned: a join chime or a click lasts about
    /// `soundReturnedWithin` and does not clear the alert.
    public static let soundPersistsFor: TimeInterval = 8

    public init() {}

    /// Feed one observation. Returns true exactly once, at the moment the alert should appear.
    ///
    /// - Parameters:
    ///   - now: a monotonic time in seconds.
    ///   - appHoldsMicrophone: a known meeting app (not Vauta) uses the microphone.
    ///   - othersSilentFor: seconds since "Others" last carried sound (the length of the recording so far if it never
    ///     has); nil when it is not silent now.
    public mutating func observe(now: TimeInterval, appHoldsMicrophone: Bool, othersSilentFor: TimeInterval?) -> Bool {
        if othersSilentFor.map({ $0 < Self.soundReturnedWithin }) ?? true {
            let since = heardSince ?? now
            heardSince = since
            if now - since >= Self.soundPersistsFor {
                coversCurrentSilence = false
                hasRaised = false
            }
        } else {
            heardSince = nil
        }
        guard appHoldsMicrophone else {
            holdingSince = nil
            return false
        }
        if holdingSince == nil { holdingSince = now }
        guard !hasRaised, let silent = othersSilentFor, let since = holdingSince else { return false }
        guard silent >= Self.silenceThreshold, now - since >= Self.silenceThreshold else { return false }
        hasRaised = true
        coversCurrentSilence = true
        return true
    }
}
