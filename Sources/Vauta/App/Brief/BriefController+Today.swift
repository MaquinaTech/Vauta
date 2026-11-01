// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import VautaCore

/// Meetings › Upcoming › Today: every event of today in the chosen calendars (`BriefToday`), read when the list is shown and dropped
/// when Meetings lock. The brief of one of its meetings is built when the person opens it, as any brief is (the event is read again by
/// the brief's own reader, so its notes are read only when that setting is on).
extension BriefController {
    func openToday() {
        guard prefs.enabled, calendarOn else { today = .off; return }
        guard calendarAccess else { today = .calendarDenied; return }
        guard !isLocked else { today = .loading; return }
        if case .items = today {} else { today = .loading }
        todayTask?.cancel()
        todayTask = Task { [weak self] in await self?.readToday() }
    }

    private func readToday() async {
        guard canRead, let source = activeSource else { today = .items([]); return }
        let now = Date.now
        let day = BriefToday.window(now: now, calendar: .current)
        let events = await source.dayEvents(from: day.start, to: day.end, calendarIDs: selectedCalendars, limit: BriefToday.limit)
        guard !Task.isCancelled, !isLocked else { return }
        let items = BriefToday.items(events, now: now, rules: rules, calendar: .current)
        today = .items(items)
        // A brief that was open stays open while its meeting is still on the list.
        if let open = todayEntry?.event.occurrence, !items.contains(where: { $0.id == open && $0.hasBrief }) { closeTodayBrief() }
    }

    func openTodayBrief(_ item: BriefTodayItem, force: Bool = false) {
        guard item.hasBrief, !isLocked, let source = activeSource else { return }
        if todayEntry?.event.occurrence != item.id { todayEntry = Entry(event: item.event) }
        todayBriefTask?.cancel()
        let calendars = selectedCalendars
        todayBriefTask = Task { [weak self] in
            let read = await source.events(from: item.event.start, to: item.event.end, calendarIDs: calendars, matching: [item.id]).first
            guard let self, !Task.isCancelled, !self.isLocked else { return }
            if force { await self.cache.invalidate(.occurrence(item.id)) }
            let entry = await self.buildEntry(read ?? item.event, force: force)
            guard !Task.isCancelled, !self.isLocked, self.todayEntry?.event.occurrence == item.id else { return }
            self.todayEntry = entry
        }
    }

    func closeTodayBrief() {
        todayBriefTask?.cancel()
        todayEntry = nil
    }

    /// Meetings locked or Calendar turned off: nothing of today stays in memory.
    func forgetToday() {
        todayTask?.cancel()
        closeTodayBrief()
        if case .items = today { today = .loading }
    }
}
