// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension ActionsEvaluation {
    /// The deterministic replay scenarios of the gates "duplicates created: 0", "due day written equals the minutes' day: 100%" and "undo
    /// removes only Vauta's item: 100%", over one meeting's real tasks and a fake writer: press twice, reopen, rewrite the minutes, press
    /// again; a save that threw after saving; due days in four time zones; an orphaned task added again; undo of everything.
    /// Everything it reports is a count.
    static func replay(seeded: Seeded, fixture: Fixture?, directory: URL) async -> (detail: [String: String], failures: Int) {
        let store = seeded.store
        let tasks = seeded.tasks.filter { $0.status == .open }
        var d: [String: String] = ["replayTasks": "\(tasks.count)"]
        var failures = 0
        let writer = FakeActionWriter()
        var foreign: [String] = []
        for title in fixture?.existingReminders ?? [] { foreign.append(writer.seedReminder(title, in: "list-work")) }
        foreign.append(writer.seedReminder("A reminder the person made themselves", in: "list-work"))
        let title = "Meeting"
        func draft(_ t: TaskItem) -> ReminderDraft {
            ReminderDraft.make(task: t, selfEntityID: nil, containerID: "list-work", meetingTitle: title, meetingDate: seeded.start, meetingTimeZone: seeded.zone)
        }

        // 1. Press Add twice at once on every task; a look-alike in the list is offered and the person takes it ("Use This One").
        let service = ActionService(store: store, writer: writer)
        var added = 0, doubleAdded = 0, usedExisting = 0
        var addedTasks = Set<Int64>()
        for t in tasks {
            async let a = service.addReminder(task: t, draft: draft(t))
            async let b = service.addReminder(task: t, draft: draft(t))
            var addedHere = 0
            for outcome in await [a, b] {
                switch outcome {
                case .added: addedHere += 1
                case .duplicate(let finding):
                    if case .existing = finding, await service.useExisting(task: t, finding: finding) != nil { usedExisting += 1; addedTasks.insert(t.id) }
                default: break
                }
            }
            if addedHere > 0 { added += 1; addedTasks.insert(t.id) }
            if addedHere > 1 { doubleAdded += 1 }
        }
        // 2. Reopen (a new service on the same store) and press again; then rewrite the minutes and press again.
        let reopened = ActionService(store: store, writer: writer)
        var reAdded = 0
        for t in tasks { if case .added = await reopened.addReminder(task: t, draft: draft(t)) { reAdded += 1 } }
        var rewrite = ValidatedMinutes()
        if let first = try? await store.segments(of: seeded.meetingID).first {
            rewrite.tasks = tasks.map { .init(text: $0.text, owner: nil, due: $0.due, segment: first.id, t: first.start, dueDay: $0.dueDay) }
        }
        try? await store.applyMinutes(rewrite, to: seeded.meetingID)
        let after = (try? await store.tasks(seeded.meetingID)) ?? []
        let twins = Dictionary(grouping: after, by: { TextKeys.norm($0.text) }).values.filter { $0.count > 1 }.count
        var reAddedAfterRewrite = 0
        for t in after where addedTasks.contains(t.id) { if case .added = await ActionService(store: store, writer: writer).addReminder(task: t, draft: draft(t)) { reAddedAfterRewrite += 1 } }
        d["added"] = "\(added)"
        d["usedExisting"] = "\(usedExisting)"
        d["doubleAdded"] = "\(doubleAdded)"
        d["reAdded"] = "\(reAdded + reAddedAfterRewrite)"
        d["rewriteTwins"] = "\(twins)"
        d["writes"] = "\(writer.writes)"
        // Duplicates created: any write beyond one per task that was added, and any task written twice.
        let duplicates = max(0, writer.writes - added) + doubleAdded + reAdded + reAddedAfterRewrite + twins
        d["duplicatesCreated"] = "\(duplicates)"
        failures += duplicates

        // 3. A save that threw after saving: adopted, not repeated.
        let probeID = try? await store.addTask(seeded.meetingID, text: "Crash probe task \(UUID().uuidString.prefix(6))")
        if let probeID, let probe = (try? await store.tasks(seeded.meetingID))?.first(where: { $0.id == probeID }) {
            let before = writer.writes
            writer.setFailure(.afterSave)
            let first = await service.addReminder(task: probe, draft: draft(probe))
            writer.setFailure(.none)
            let second = await service.addReminder(task: probe, draft: draft(probe))
            var adopted = false
            if case .added = first, case .duplicate = second { adopted = true }
            d["crashAdopted"] = "\(adopted)"
            d["crashWrites"] = "\(writer.writes - before)"
            if !adopted || writer.writes - before != 1 { failures += 1 }
        }

        // 4. The due day written is the day the minutes wrote, in four zones.
        // A day before the meeting or more than a year after it is not believed: nothing is written for it (and that is checked too).
        var checked = 0, wrong = 0, dropped = 0
        let meetingDay = DueDay.containing(seeded.start, in: seeded.zone)
        for t in after where addedTasks.contains(t.id) {
            guard let day = t.dueDay, let row = try? await store.latestAction(target: .reminder, source: .task, sourceID: t.id), row.state == .created,
                  let id = row.itemID, let written = writer.storedReminder(id) else { continue }
            guard day.isPlausible(meetingDay: meetingDay) else {
                dropped += 1
                if written.due != nil { wrong += 1 }
                continue
            }
            checked += 1
            let parts = day.string.split(separator: "-").compactMap { Int($0) }
            var ok = written.due.map { [$0.year, $0.month, $0.day] == parts.map { Optional($0) } && $0.timeZone == nil } ?? false
            for name in ["Europe/Madrid", "America/Los_Angeles", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
                guard let zone = TimeZone(identifier: name), let due = written.due else { ok = false; continue }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                let read = calendar.date(from: due).map { calendar.dateComponents([.year, .month, .day], from: $0) }
                if [read?.year, read?.month, read?.day] != parts.map({ Optional($0) }) { ok = false }
            }
            if !ok { wrong += 1 }
        }
        d["dueDayChecked"] = "\(checked)"
        d["dueDayDropped"] = "\(dropped)"
        d["dueDayMismatches"] = "\(wrong)"
        failures += wrong

        // 5. A task deleted here and added again: the reminder is found, not repeated.
        if let victim = after.first(where: { addedTasks.contains($0.id) }) {
            let text = victim.text
            try? await store.deleteTask(victim.id)
            if let id = try? await store.addTask(seeded.meetingID, text: text), let again = (try? await store.tasks(seeded.meetingID))?.first(where: { $0.id == id }) {
                let before = writer.writes
                let outcome = await service.addReminder(task: again, draft: draft(again))
                var caught = false
                if case .duplicate(.orphan) = outcome { caught = true } else if case .duplicate = outcome { caught = true }
                d["orphanCaught"] = "\(caught)"
                if !caught || writer.writes != before { failures += 1 }
            }
        }

        // 6. Undo everything Vauta created: only those items go; the person's own reminders stay.
        let created = ((try? await store.actions(ofMeeting: seeded.meetingID)) ?? []).filter { $0.state == .created }
        let removalsBefore = writer.removals
        let results = await service.undo(actionIDs: created.map(\.id))
        let removedOK = results.values.filter { $0 == .removed }.count
        let wrongRemovals = writer.log.compactMap { entry -> String? in if case .remove(_, let id) = entry, !created.contains(where: { $0.itemID == id }) { return id }; return nil }.count
        let foreignLeft = Set(writer.allItems.map(\.itemID)).isSuperset(of: foreign)
        d["undoCreated"] = "\(created.count)"
        d["undoRemoved"] = "\(removedOK)"
        d["undoRemovals"] = "\(writer.removals - removalsBefore)"
        d["undoWrongRemovals"] = "\(wrongRemovals)"
        d["undoForeignKept"] = "\(foreignLeft)"
        if removedOK != created.count || wrongRemovals != 0 || !foreignLeft { failures += 1 }
        d["replayFailures"] = "\(failures)"
        return (d, failures)
    }
}
