// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// An `ActionWriter` that keeps everything in memory. The tests and `llm-eval --tasks actions` use it, so no test or evaluation ever
/// touches a person's Reminders or Calendar. It records every write and removal (`log`), can fail before or after saving, and can play
/// what the person or a sync service does in the other apps: edit, complete or delete an item, re-identify it.
public final class FakeActionWriter: ActionWriter, @unchecked Sendable {
    public enum Failure: Sendable { case none, beforeSave, afterSave }

    public enum Entry: Sendable, Equatable {
        case addReminder(ReminderWrite)
        case addEvent(EventWrite)
        case remove(ActionKind, String)
    }

    private let lock = NSLock()
    private var kinds: [ActionKind: ActionAccess] = [.reminder: .full, .event: .full]
    private var lists: [ActionKind: [ActionContainer]]
    private var defaults: [ActionKind: String]
    private var items: [String: Stored] = [:]
    private var entries: [Entry] = []
    private var counter = 0
    private var failure: Failure = .none
    private var clockValue: () -> Date = { AppClock.now }
    private var requested: [ActionKind] = []
    private var readContainers: [String] = []

    private struct Stored {
        var kind: ActionKind
        var item: ActionItem
        var reminder: ReminderWrite?
        var event: EventWrite?
        var completedAt: Date?
    }

    public init(reminderLists: [ActionContainer] = [ActionContainer(id: "list-work", title: "Work", account: "iCloud"),
                                                    ActionContainer(id: "list-home", title: "Home", account: "iCloud")],
                calendars: [ActionContainer] = [ActionContainer(id: "cal-work", title: "Work", account: "iCloud")]) {
        lists = [.reminder: reminderLists, .event: calendars]
        defaults = [.reminder: reminderLists.first?.id ?? "", .event: calendars.first?.id ?? ""]
    }

    // MARK: Test controls

    public func setAccess(_ kind: ActionKind, _ access: ActionAccess) { lock.withLock { kinds[kind] = access } }
    public func setFailure(_ value: Failure) { lock.withLock { failure = value } }
    public func setClock(_ clock: @escaping @Sendable () -> Date) { lock.withLock { clockValue = clock } }
    public func setContainers(_ kind: ActionKind, _ value: [ActionContainer]) { lock.withLock { lists[kind] = value } }

    public var log: [Entry] { lock.withLock { entries } }
    public var writes: Int { lock.withLock { entries.filter { if case .remove = $0 { false } else { true } }.count } }
    public var removals: Int { lock.withLock { entries.filter { if case .remove = $0 { true } else { false } }.count } }
    /// The access requests made (one per `requestAccess` call).
    public var accessRequests: [ActionKind] { lock.withLock { requested } }
    /// The containers whose items were listed (the duplicate check must read the target list only).
    public var containersRead: [String] { lock.withLock { readContainers } }
    public var allItems: [ActionItem] { lock.withLock { items.values.map(\.item).sorted { $0.itemID < $1.itemID } } }
    public func storedReminder(_ itemID: String) -> ReminderWrite? { lock.withLock { items[itemID]?.reminder } }
    public func storedEvent(_ itemID: String) -> EventWrite? { lock.withLock { items[itemID]?.event } }

    /// An item that was already in the person's list.
    @discardableResult
    public func seedReminder(_ title: String, in containerID: String = "list-work", completed: Bool = false, day: DueDay? = nil,
                             completedAt: Date? = nil) -> String {
        lock.withLock {
            counter += 1
            let id = "seed-\(counter)"
            let now = clockValue()
            items[id] = Stored(kind: .reminder, item: ActionItem(itemID: id, externalID: "ext-\(id)", containerID: containerID, title: title, isCompleted: completed,
                                                              day: day, creationDate: now.addingTimeInterval(-86_400), lastModified: now.addingTimeInterval(-86_400)),
                               completedAt: completed ? completedAt ?? now.addingTimeInterval(-86_400) : nil)
            return id
        }
    }

    @discardableResult
    public func seedEvent(_ title: String, on day: DueDay, at minuteOfDay: Int? = nil, in containerID: String = "cal-work") -> String {
        lock.withLock {
            counter += 1
            let id = "seed-\(counter)"
            let now = clockValue()
            items[id] = Stored(kind: .event, item: ActionItem(itemID: id, externalID: "ext-\(id)", containerID: containerID, title: title, day: day,
                                                           minuteOfDay: minuteOfDay, creationDate: now.addingTimeInterval(-86_400), lastModified: now.addingTimeInterval(-86_400)))
            return id
        }
    }

    /// The person edits the item in another app.
    public func editExternally(_ itemID: String, title: String) {
        lock.withLock { items[itemID]?.item.title = title; items[itemID]?.item.lastModified = clockValue().addingTimeInterval(60) }
    }

    public func completeExternally(_ itemID: String) {
        lock.withLock { items[itemID]?.item.isCompleted = true; items[itemID]?.completedAt = clockValue().addingTimeInterval(60)
            items[itemID]?.item.lastModified = clockValue().addingTimeInterval(60) }
    }

    public func setDueExternally(_ itemID: String, _ day: DueDay?) {
        lock.withLock { items[itemID]?.item.day = day; items[itemID]?.item.lastModified = clockValue().addingTimeInterval(60) }
    }

    /// The person moves the item to another list: its identifiers stay, its list changes.
    public func moveExternally(_ itemID: String, to containerID: String) {
        lock.withLock { items[itemID]?.item.containerID = containerID; items[itemID]?.item.lastModified = clockValue().addingTimeInterval(60) }
    }

    public func deleteExternally(_ itemID: String) { lock.withLock { _ = items.removeValue(forKey: itemID) } }

    /// A sync service gives the item a new local identifier; the external identifier stays.
    public func reidentify(_ itemID: String, as newID: String) {
        lock.withLock {
            guard var stored = items.removeValue(forKey: itemID) else { return }
            stored.item.itemID = newID
            items[newID] = stored
        }
    }

    // MARK: ActionWriter

    public func access(_ kind: ActionKind) async -> ActionAccess { lock.withLock { kinds[kind] ?? .notDetermined } }

    public func requestAccess(_ kind: ActionKind) async -> Bool {
        lock.withLock {
            requested.append(kind)
            if kinds[kind] == .notDetermined { kinds[kind] = .full }
            return kinds[kind] == .full
        }
    }

    public func containers(_ kind: ActionKind) async -> [ActionContainer] {
        lock.withLock { kinds[kind] == .full || kinds[kind] == .writeOnly ? lists[kind] ?? [] : [] }
    }

    public func defaultContainerID(_ kind: ActionKind) async -> String? { lock.withLock { defaults[kind].flatMap { $0.isEmpty ? nil : $0 } } }

    public func addReminder(_ write: ReminderWrite) async throws -> ActionReceipt {
        try save(kind: .reminder, containerID: write.containerID, title: write.title, day: nil, entry: .addReminder(write)) { $0.reminder = write }
    }

    public func addEvent(_ write: EventWrite) async throws -> ActionReceipt {
        try save(kind: .event, containerID: write.containerID, title: write.title, day: write.day, entry: .addEvent(write)) { $0.event = write }
    }

    private func save(kind: ActionKind, containerID: String, title: String, day: DueDay?, entry: Entry, fill: (inout Stored) -> Void) throws -> ActionReceipt {
        try lock.withLock {
            guard kinds[kind] == .full || (kind == .event && kinds[kind] == .writeOnly) else { throw ActionWriterError.accessDenied }
            guard lists[kind]?.contains(where: { $0.id == containerID }) == true else { throw ActionWriterError.containerUnavailable }
            if failure == .beforeSave { throw ActionWriterError.saveFailed }
            counter += 1
            let id = "item-\(counter)"
            let now = clockValue()
            let dueDay: DueDay? = day ?? { () -> DueDay? in
                if case .addReminder(let w) = entry, let c = w.due, let y = c.year, let m = c.month, let d = c.day { return DueDay(year: y, month: m, day: d) }
                return nil
            }()
            var stored = Stored(kind: kind, item: ActionItem(itemID: id, externalID: "ext-\(id)", containerID: containerID, title: title, day: dueDay,
                                                             creationDate: now, lastModified: now))
            fill(&stored)
            if case .addEvent(let w) = entry { stored.item.minuteOfDay = w.minuteOfDay }
            items[id] = stored
            entries.append(entry)
            if failure == .afterSave { throw ActionWriterError.saveFailed }
            return ActionReceipt(itemID: id, externalID: "ext-\(id)", containerID: containerID)
        }
    }

    public func remove(_ kind: ActionKind, itemID: String) async throws {
        try lock.withLock {
            entries.append(.remove(kind, itemID))
            guard items[itemID]?.kind == kind else { throw ActionWriterError.saveFailed }
            items.removeValue(forKey: itemID)
        }
    }

    public func item(_ kind: ActionKind, itemID: String?, externalID: String?, containerID: String?) async -> ActionItem? {
        lock.withLock {
            if let itemID, let s = items[itemID], s.kind == kind { return s.item }
            if let externalID { return items.values.first { $0.kind == kind && $0.item.externalID == externalID && (containerID == nil || $0.item.containerID == containerID) }?.item }
            return nil
        }
    }

    public func incompleteReminders(in containerID: String) async -> [ActionItem] {
        lock.withLock {
            readContainers.append(containerID)
            return items.values.filter { $0.kind == .reminder && $0.item.containerID == containerID && !$0.item.isCompleted }.map(\.item).sorted { $0.itemID < $1.itemID }
        }
    }

    public func completedReminders(in containerID: String, since date: Date) async -> [ActionItem] {
        lock.withLock {
            readContainers.append(containerID)
            return items.values.filter { $0.kind == .reminder && $0.item.containerID == containerID && $0.item.isCompleted && ($0.completedAt ?? .distantPast) >= date }.map(\.item).sorted { $0.itemID < $1.itemID }
        }
    }

    public func events(around day: DueDay, in containerID: String, timeZone: TimeZone) async -> [ActionItem] {
        lock.withLock {
            readContainers.append(containerID)
            return items.values.filter { s in
                guard s.kind == .event, s.item.containerID == containerID, let d = s.item.day else { return false }
                return abs(d.epochDay - day.epochDay) <= 1
            }.map(\.item).sorted { $0.itemID < $1.itemID }
        }
    }
}
