// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The recordings whose unkept questions must be removed when they end ("Keep detected questions with the meeting" is off) and have
/// not been yet. A recording is listed while it runs with the setting off and unlisted once its own cleanup ran, so a launch after a
/// quit removes the questions of exactly those meetings. Meetings recorded with the setting on are never listed: turning the setting
/// off later does not touch their questions. Holds meeting ids only, never text.
public struct QuestionCleanupLedger: @unchecked Sendable {
    // UserDefaults is documented as thread-safe.
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String = "liveAnswersPendingCleanup") {
        self.defaults = defaults
        self.key = key
    }

    public var meetings: [Int64] { (defaults.array(forKey: key) as? [NSNumber])?.map(\.int64Value) ?? [] }

    public func add(_ id: Int64) {
        var ids = meetings
        if !ids.contains(id) { ids.append(id) }
        defaults.set(ids.map { NSNumber(value: $0) }, forKey: key)
    }

    public func remove(_ id: Int64) {
        let ids = meetings.filter { $0 != id }
        if ids.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(ids.map { NSNumber(value: $0) }, forKey: key) }
    }

    /// The database was replaced (Erase): the listed ids belong to meetings that no longer exist, and a new meeting may reuse them.
    public func clear() { defaults.removeObject(forKey: key) }

    /// The launch pass: removes the unkept questions of the listed meetings (not the one being recorded) and empties the list.
    public func sweep(_ store: MeetingStore, active: Int64?) async {
        let pending = meetings.filter { $0 != active }
        guard !pending.isEmpty else { return }
        do {
            try await store.removeUnkeptQuestions(ofMeetings: pending)
            pending.forEach(remove)
        } catch {}
    }
}
