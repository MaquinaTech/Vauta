// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What a cached brief was built from. Any change of a part makes the entry stale.
public struct BriefCacheKey: Hashable, Sendable {
    public let occurrence: BriefOccurrence
    /// `MeetingStore.editRevision`.
    public var storeRevision: UInt64
    /// Bumped when a documents sync finishes.
    public var documentsGeneration: Int
    /// Bumped when EventKit reports a change of the reminders.
    public var remindersStamp: Int
    public var searchModelInstalled: Bool
    /// The model provider chosen in Settings (an opaque name).
    public var provider: String
    /// The language of the agenda (BCP-47).
    public var language: String

    public init(occurrence: BriefOccurrence, storeRevision: UInt64 = 0, documentsGeneration: Int = 0, remindersStamp: Int = 0,
                searchModelInstalled: Bool = false, provider: String = "", language: String = "") {
        self.occurrence = occurrence
        self.storeRevision = storeRevision
        self.documentsGeneration = documentsGeneration
        self.remindersStamp = remindersStamp
        self.searchModelInstalled = searchModelInstalled
        self.provider = provider
        self.language = language
    }
}

/// Why the cache lets go of briefs.
public enum BriefInvalidation: Sendable, Equatable {
    /// `EKEventStoreChanged`: the event, its attendees or the reminders changed.
    case eventStoreChanged
    /// The Meetings window locked: no brief stays in memory.
    case locked
    /// Erase Everything.
    case erased
    /// The event ended, its recording ended or it was declined or cancelled.
    case occurrence(BriefOccurrence)
}

/// The briefs in memory (never on disk: persistence is `meeting_briefs`, with a recorded meeting). A few entries at most.
public actor BriefCache {
    public static let capacity = 4
    /// An entry is dropped this long after its event ended.
    public static let retention: TimeInterval = 30 * 60

    private struct Entry {
        var key: BriefCacheKey
        var snapshot: BriefSnapshot
        var storedAt: Date
        /// The calendar or the reminders changed: the entry is only good for its agenda.
        var stale = false
    }

    private var entries: [BriefOccurrence: Entry] = [:]

    public init() {}

    public var count: Int { entries.count }

    /// The cached brief when it was built from exactly `key`.
    public func snapshot(for key: BriefCacheKey) -> BriefSnapshot? {
        guard let entry = entries[key.occurrence], entry.key == key, !entry.stale else { return nil }
        return entry.snapshot
    }

    /// The last brief of this occurrence whatever it was built from, to carry its agenda over (`carryAgenda`).
    public func previous(for occurrence: BriefOccurrence) -> BriefSnapshot? { entries[occurrence]?.snapshot }

    /// What that last brief was built from (its provider says which backend the agenda was asked of).
    public func previousKey(for occurrence: BriefOccurrence) -> BriefCacheKey? { entries[occurrence]?.key }

    public func store(_ snapshot: BriefSnapshot, key: BriefCacheKey, now: Date = .now) {
        entries[key.occurrence] = Entry(key: key, snapshot: snapshot, storedAt: now)
        if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key { entries[oldest] = nil }
    }

    public func invalidate(_ reason: BriefInvalidation) {
        switch reason {
        case .eventStoreChanged:
            // The deterministic part is rebuilt at once (cheap); what is kept is only the agenda, which `carryAgenda` may reuse.
            for key in Array(entries.keys) { entries[key]?.stale = true }
        case .locked, .erased:
            entries.removeAll()
        case .occurrence(let occurrence):
            entries[occurrence] = nil
        }
    }

    /// When the first kept brief is due to be dropped, nil when none is kept.
    public func nextExpiry() -> Date? {
        entries.values.map { $0.snapshot.end.addingTimeInterval(Self.retention) }.min()
    }

    /// Drops what ended more than `retention` ago.
    public func prune(now: Date = .now) {
        for (key, entry) in entries where now.timeIntervalSince(entry.snapshot.end) > Self.retention { entries[key] = nil }
    }

    // MARK: Agenda reuse

    /// The signature of an item, without its ID (IDs are minted again at every build).
    static func signature(_ item: BriefItem) -> String {
        [item.kind.rawValue, item.text, item.detail ?? "", item.owner ?? "", item.due.map { "\($0.timeIntervalSince1970)" } ?? "",
         "\(item.meetingID ?? 0)", "\(item.overdue)", "\(item.dueBeforeMeeting)", "\(item.unconfirmed)"].joined(separator: "\u{1F}")
    }

    /// The new brief with the old agenda, when every item that agenda cites is still there unchanged (the IDs are mapped to the new
    /// ones, and the cites checked again). Otherwise the agenda must be written again: `needsAgenda`.
    public static func carryAgenda(from old: BriefSnapshot?, to new: BriefSnapshot, sameProvider: Bool = true) -> (snapshot: BriefSnapshot, needsAgenda: Bool) {
        var result = new
        guard let old, case .lines(let lines) = old.agenda else {
            // "No suggestions" and "needs a model" are kept only while what the model was given is the same (the same items) and so is the
            // backend. A new item, or a model that became available, asks again.
            if let old, sameProvider, old.agenda == .noSuggestions || old.agenda == .unavailable,
               old.items.map(signature) == new.items.map(signature) {
                result.agenda = old.agenda
                return (result, false)
            }
            return (result, true)
        }
        var byOld: [String: String] = [:]
        for item in new.items { byOld[signature(item)] = item.id }
        var carried: [BriefAgendaLine] = []
        for line in lines {
            var cites: [String] = []
            for id in line.cites {
                guard let item = old.item(id), let mapped = byOld[signature(item)] else { return (result, true) }
                cites.append(mapped)
            }
            carried.append(BriefAgendaLine(kind: line.kind, text: line.text, cites: cites))
        }
        result.agenda = .lines(carried)
        return (result, false)
    }
}
