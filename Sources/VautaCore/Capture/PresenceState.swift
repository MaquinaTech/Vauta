// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Which app, if any, is using the microphone, as seen by `MeetingPresence`.
///
/// Core Audio cannot tell a call from dictation or a voice memo: callers
/// combine this with other hints (a calendar event with a meeting link).
public struct PresenceState: Sendable, Equatable {
    /// Family of the app holding the microphone; nil if no known app does.
    public var family: MeetingAppFamily?
    /// Bundle ID of the process holding the microphone (it may be a helper,
    /// e.g. `com.google.Chrome.helper`; see `MeetingAppCatalog.app(forBundleID:)`).
    public var bundleID: String?
    /// A process other than Vauta is using the microphone.
    public var inputActive: Bool
    /// The holder's family (or, for an unknown app, the process) is playing audio.
    public var outputActive: Bool
    /// Every family with a process using the microphone.
    public var inputFamilies: Set<MeetingAppFamily>

    public static let idle = PresenceState(family: nil, bundleID: nil, inputActive: false, outputActive: false, inputFamilies: [])

    public init(family: MeetingAppFamily?, bundleID: String?, inputActive: Bool, outputActive: Bool,
                inputFamilies: Set<MeetingAppFamily>) {
        self.family = family
        self.bundleID = bundleID
        self.inputActive = inputActive
        self.outputActive = outputActive
        self.inputFamilies = inputFamilies
    }

    /// Whether some process of `family` is using the microphone.
    public func isInputActive(_ family: MeetingAppFamily) -> Bool { inputFamilies.contains(family) }

    /// Derives the state from a snapshot of Core Audio processes, ignoring
    /// `ownPID` (Vauta itself uses the microphone while recording).
    ///
    /// When several processes use the microphone, a known family wins over an
    /// unknown app, then a family that is also playing audio, then catalog order.
    public init(processes: [AudioProcess], ownPID: pid_t) {
        let others = processes.filter { $0.pid != ownPID }
        let outputFamilies = Set(others.filter(\.isRunningOutput).compactMap(\.family))
        let holders = others.filter(\.isRunningInput)
        let order = Dictionary(uniqueKeysWithValues: MeetingAppFamily.allCases.enumerated().map { ($1, $0) })
        func rank(_ p: AudioProcess) -> (Int, Int, Int, String) {
            guard let family = p.family else { return (1, 1, Int.max, p.bundleID) }
            return (0, outputFamilies.contains(family) ? 0 : 1, order[family] ?? Int.max, p.bundleID)
        }
        let holder = holders.min { rank($0) < rank($1) }
        let family = holder?.family
        self.init(family: family,
                  bundleID: holder.flatMap { $0.bundleID.isEmpty ? nil : $0.bundleID },
                  inputActive: holder != nil,
                  outputActive: family.map(outputFamilies.contains) ?? holder?.isRunningOutput ?? false,
                  inputFamilies: Set(holders.compactMap(\.family)))
    }

    /// Delay before publishing `new` when `current` is published (nil: no
    /// change to publish). The first state is published at once; later ones
    /// after 2 s of stability, because apps release and reopen the microphone
    /// when the audio device changes.
    static func publishDelay(current: PresenceState?, new: PresenceState) -> TimeInterval? {
        guard new != current else { return nil }
        return current == nil ? 0 : 2
    }
}
