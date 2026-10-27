// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreAudio
import Foundation

/// Which system audio is captured as "Others".
public enum SystemAudioScope: Sendable, Hashable {
    /// Only the processes of these families (all their tabs/windows).
    case apps(Set<MeetingAppFamily>)
    /// The family holding the microphone when recording starts; all system
    /// audio if no known app holds it. See `resolved(with:)`.
    case auto
    /// Everything the Mac plays except Vauta's own sounds.
    case allSystem

    /// The scope of installs that never changed the setting (0.1.0: Safari only).
    public static let legacyDefault = SystemAudioScope.apps([.webkit])

    /// Maps the 0.1.0 preference `captureAllSystemAudio`.
    public static func legacy(captureAllSystemAudio: Bool) -> SystemAudioScope {
        captureAllSystemAudio ? .allSystem : legacyDefault
    }

    /// Replaces `.auto` with a concrete scope for the current presence.
    public func resolved(with presence: PresenceState?) -> SystemAudioScope {
        guard self == .auto else { return self }
        return presence?.family.map { .apps([$0]) } ?? .allSystem
    }

    /// Whether recording with this scope captures a call held by `family`: always for Auto and All system audio, and for
    /// specific apps only when the family is one of them. An unknown family counts as included (nothing to compare).
    public func capturesCall(of family: MeetingAppFamily?) -> Bool {
        guard case .apps(let families) = self, let family else { return true }
        return families.contains(family)
    }

    // MARK: Persistence

    static let defaultsKey = "systemAudioScope"
    /// Written by 0.1.0 (true = all system audio, false/absent = Safari only).
    static let legacyDefaultsKey = "captureAllSystemAudio"

    /// Stable text form: `auto`, `all` or `apps:<family>,<family>`.
    public var storageValue: String {
        switch self {
        case .auto: "auto"
        case .allSystem: "all"
        case .apps(let families): "apps:" + families.map(\.rawValue).sorted().joined(separator: ",")
        }
    }

    public init?(storageValue: String) {
        switch storageValue {
        case "auto": self = .auto
        case "all": self = .allSystem
        default:
            guard storageValue.hasPrefix("apps:") else { return nil }
            let families = storageValue.dropFirst(5).split(separator: ",").compactMap { MeetingAppFamily(rawValue: String($0)) }
            guard !families.isEmpty else { return nil }
            self = .apps(Set(families))
        }
    }

    /// Whether a scope (current or 0.1.0) was ever saved.
    public static func hasSavedValue(in defaults: UserDefaults) -> Bool {
        defaults.string(forKey: defaultsKey).flatMap(SystemAudioScope.init(storageValue:)) != nil
            || defaults.object(forKey: legacyDefaultsKey) != nil
    }

    /// The saved scope; falls back to the 0.1.0 preference. With nothing saved,
    /// a new install (no store yet) starts on `.auto`; an upgrade from 0.1
    /// keeps its Safari-only behaviour.
    public init(defaults: UserDefaults, newInstall: Bool = false) {
        if let value = defaults.string(forKey: Self.defaultsKey), let scope = SystemAudioScope(storageValue: value) {
            self = scope
        } else if newInstall, !Self.hasSavedValue(in: defaults) {
            self = .auto
        } else {
            self = .legacy(captureAllSystemAudio: defaults.bool(forKey: Self.legacyDefaultsKey))
        }
    }

    /// Saves the scope and keeps the 0.1.0 key meaningful, so a downgrade
    /// still captures what the user chose as closely as 0.1.0 can.
    public func save(to defaults: UserDefaults) {
        defaults.set(storageValue, forKey: Self.defaultsKey)
        defaults.set(self == .allSystem, forKey: Self.legacyDefaultsKey)
    }

    // MARK: Tap target

    /// What the process tap includes or excludes for this scope, given the
    /// running Core Audio processes. `.auto` is resolved from `processes`.
    func tapTarget(processes: [AudioProcess], ownPID: pid_t) -> TapTarget {
        switch self {
        case .auto:
            return resolved(with: PresenceState(processes: processes, ownPID: ownPID)).tapTarget(processes: processes, ownPID: ownPID)
        case .allSystem:
            let own = processes.filter { $0.pid == ownPID }.map(\.objectID)
            return TapTarget(bundleIDs: [], processes: own.sorted(), excludes: true)
        case .apps(let families):
            let bundleIDs = Array(Set(families.flatMap(\.tapBundleIDs))).sorted()
            let covered = Set(bundleIDs.map { $0.lowercased() })
            let extra = processes.filter {
                $0.pid != ownPID && !covered.contains($0.bundleID.lowercased())
                    && MeetingAppCatalog.matches($0.bundleID, in: families)
            }
            return TapTarget(bundleIDs: bundleIDs, processes: extra.map(\.objectID).sorted(), excludes: false)
        }
    }
}

/// The processes a tap covers.
struct TapTarget: Equatable {
    /// Exact bundle IDs (followed across relaunches); empty for a global tap.
    var bundleIDs: [String]
    /// Process objects to include, or to exclude when `excludes` is true.
    var processes: [AudioObjectID]
    /// A global tap of everything except `processes`.
    var excludes: Bool
}
