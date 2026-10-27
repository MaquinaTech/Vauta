// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// How long a meeting's minutes, decisions, notes and tasks are kept after its
/// transcript is deleted (`MeetingStore.retentionDays`). The raw value is the
/// stored `knowledgeRetentionDays` preference (0 = until the user deletes it).
public enum KnowledgeRetention: Int, CaseIterable, Identifiable, Sendable {
    /// Everything goes with the transcript (the 0.1 behaviour).
    case withTranscript = 90
    case oneYear = 365
    case twoYears = 730
    case untilDeleted = 0

    public var id: Int { rawValue }

    /// The stored value, or the 0.1 default for anything unknown.
    public init(days: Int) {
        self = KnowledgeRetention(rawValue: days) ?? .withTranscript
    }

    /// Days after which a whole meeting is deleted; nil = never.
    public var meetingLifetimeDays: Int? {
        rawValue == 0 ? nil : max(rawValue, MeetingStore.retentionDays)
    }

    public var displayName: String {
        switch self {
        case .withTranscript:
            String(localized: "Delete with the transcript (after \(MeetingStore.retentionDays) days)",
                   comment: "Knowledge retention option; the argument is a number of days")
        case .oneYear: String(localized: "Keep minutes, decisions, notes and tasks for 1 year", comment: "Knowledge retention option")
        case .twoYears: String(localized: "Keep minutes, decisions, notes and tasks for 2 years", comment: "Knowledge retention option")
        case .untilDeleted: String(localized: "Keep minutes, decisions, notes and tasks until I delete them", comment: "Knowledge retention option")
        }
    }
}

/// A change of knowledge retention and what it would delete right away.
public struct RetentionChange: Equatable, Sendable {
    public let from: KnowledgeRetention
    public let to: KnowledgeRetention

    public init(from: KnowledgeRetention, to: KnowledgeRetention) {
        self.from = from
        self.to = to
    }

    /// The new value keeps meetings for less time, so it can delete data.
    public var isShorter: Bool {
        switch (from.meetingLifetimeDays, to.meetingLifetimeDays) {
        case (_, nil): false
        case (nil, _?): true
        case (let a?, let b?): b < a
        }
    }

    /// How many of the meetings started at `startDates` the new value deletes
    /// now: older than its lifetime but still kept by the current one.
    public func meetingsDeleted(startDates: [Date], now: Date = .now) -> Int {
        guard isShorter, let newDays = to.meetingLifetimeDays else { return 0 }
        let newCut = now.addingTimeInterval(-Double(newDays) * 86_400)
        let oldCut = from.meetingLifetimeDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        return startDates.filter { date in date < newCut && oldCut.map { date >= $0 } ?? true }.count
    }
}
