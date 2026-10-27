// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Observation
import VautaCore

/// Settings › Calendar & Reminders › After meetings: which list and calendar a new item starts in, and the alert. It reads the lists
/// and calendars only while the pane is open and only with the access the person already gave; it never asks for access (the first
/// Add does, in the editor).
@MainActor
@Observable
final class AfterMeetingsSettings {
    var reminderAccess: ActionAccess = .notDetermined
    var eventAccess: ActionAccess = .notDetermined
    var reminderLists: [ActionContainer] = []
    var calendars: [ActionContainer] = []

    @ObservationIgnored private var writer: (any ActionWriter)?
    @ObservationIgnored var makeWriter: () -> any ActionWriter = {
        #if VAUTA_DIAGNOSTICS
        FakeActionWriter()
        #else
        EventKitActionWriter()
        #endif
    }

    private var access: any ActionWriter {
        if let writer { return writer }
        let made = makeWriter()
        writer = made
        return made
    }

    /// Reads the access that exists and the lists it allows (when the pane appears).
    func load() async {
        reminderAccess = await access.access(.reminder)
        eventAccess = await access.access(.event)
        reminderLists = reminderAccess == .full ? await access.containers(.reminder) : []
        calendars = eventAccess == .full ? await access.containers(.event) : []
    }

    /// Drops the names when the pane closes.
    func forget() {
        reminderLists = []
        calendars = []
    }

    func chooseList(_ id: String?, in preferences: ActionsPreferences) {
        preferences.reminderListID = id
        preferences.reminderListName = id.flatMap { id in reminderLists.first { $0.id == id }?.title }
    }

    func chooseCalendar(_ id: String?, in preferences: ActionsPreferences) {
        preferences.eventCalendarID = id
        preferences.eventCalendarName = id.flatMap { id in calendars.first { $0.id == id }?.title }
    }

    #if VAUTA_DIAGNOSTICS
    /// For `Vauta render-ui`: the pane with these accesses and lists (nothing reads EventKit).
    func installSnapshotState(reminders: ActionAccess, events: ActionAccess, lists: [ActionContainer], calendars: [ActionContainer]) {
        let fake = FakeActionWriter(reminderLists: lists, calendars: calendars)
        fake.setAccess(.reminder, reminders)
        fake.setAccess(.event, events)
        writer = fake
        reminderAccess = reminders
        eventAccess = events
        reminderLists = lists
        self.calendars = calendars
    }
    #endif
}
