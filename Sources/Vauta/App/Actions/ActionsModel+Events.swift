// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import VautaCore

/// The Follow-up sheet's data and the event editor. A follow-up meeting is added through EventKit only when Vauta already has full
/// Calendar access; otherwise an `.ics` file goes to Calendar, which asks where to put it. Vauta never asks for Calendar access here.
extension ActionsModel {
    // MARK: The sheet

    /// ⇧⌘U, the toolbar button and the panel card: the Follow-up sheet of a meeting. Follow-up meetings are detected once per meeting
    /// (never while it is being recorded), and nothing is ticked.
    func openFollowUp(meetingID: Int64, others: [Int64] = []) async {
        guard let meeting = await facts(meetingID: meetingID) else { return }
        if followUpDetectionAvailable, (try? await store.followUpsRecipe(meetingID)) == 0 { _ = try? await store.detectFollowUps(meetingID) }
        var state = FollowUpSheetState(meeting: meeting)
        state.selfEntityID = await selfEntityID()
        state.others = others
        sheet = state
        await reloadSheet()
        await loadEmailInput()
        page = .followUp
        // A draft kept after the system dismissed its sheet is the person's typing: it stays. Only a draft of another meeting goes.
        if reminderEditor?.task.meetingID != meetingID { reminderEditor = nil }
        if eventEditor?.meeting.id != meetingID { eventEditor = nil }
        onFollowUpOpened?(meetingID)
    }

    /// Reads the sheet's data again: the open tasks, their ledger rows (with what Reminders says), the follow-ups and their events.
    func reloadSheet() async {
        guard var current = sheet else { return }
        let id = current.meeting.id
        let all = (try? await store.tasks(id)) ?? []
        let open = ActionOrdering.sheetOrder(all.filter { $0.status == .open }, selfEntityID: current.selfEntityID)
        await refresh(tasks: open, readBack: true)
        let access = reminderAccess
        current.tasks = open
        current.ticked.formIntersection(Set(open.map(\.id)))
        // A task that was added meanwhile (through Edit…, or elsewhere) is no longer a tick: the button counts only what it would add.
        current.ticked = current.ticked.filter { id in
            switch states[id]?.kind { case nil, .none?, .missing?: true; default: false }
        }
        if access == .full {
            current.containers = await writer.containers(.reminder)
            if current.containerID == nil || !current.containers.contains(where: { $0.id == current.containerID }) {
                let (chosen, unavailable) = await chooseList(among: current.containers)
                current.containerID = chosen
                current.unavailableList = unavailable
            }
        } else {
            current.containers = []
        }
        let followUps = (try? await store.followUps(id)) ?? []
        current.followUps = followUps
        let segments = (try? await store.segments(of: id)) ?? []
        let byID = Dictionary(segments.map { ($0.id, $0.text) }, uniquingKeysWith: { a, _ in a })
        current.quotes = Dictionary(uniqueKeysWithValues: followUps.compactMap { f in f.segmentID.flatMap { byID[$0] }.map { (f.id, $0) } })
        // An event the person deleted in Calendar is no longer "Added to Calendar": it becomes a suggestion again.
        if eventAccess == .full { await service.readBackEvents(followUpIDs: followUps.map(\.id)) }
        var events: [Int64: CreatedAction] = [:]
        for follow in followUps {
            for target in [ActionTarget.event, .ics] {
                if let row = try? await store.latestAction(target: target, source: .followUp, sourceID: follow.id), row.isLive { events[follow.id] = row }
            }
        }
        current.events = events
        // An event that was taken back (Undo, Remove, Forget) makes its follow-up a suggestion again.
        for index in followUps.indices where followUps[index].state == .done && events[followUps[index].id] == nil {
            try? await store.setFollowUpState(followUps[index].id, .suggested)
            current.followUps[index].state = .suggested
        }
        // "Already in your calendar": only with full access, only the target calendar's day, in memory.
        var existing: [Int64: ActionItem] = [:]
        if eventAccess == .full, let calendar = await chooseCalendar(among: await writer.containers(.event)).id {
            for follow in followUps where follow.state == .suggested && events[follow.id] == nil {
                guard let draft = EventDraft.make(from: follow, containerID: calendar, meetingTitle: current.meeting.title, meetingDate: current.meeting.start,
                                                  meetingDuration: current.meeting.duration, timeZone: current.meeting.zone,
                                                  includeMeetingName: preferences.includeMeetingName) else { continue }
                if case .existingEvent(let item) = await service.checkEvent(followUp: follow, draft: draft) { existing[follow.id] = item }
            }
        }
        current.existing = existing
        sheet?.tasks = current.tasks
        sheet?.ticked = current.ticked
        sheet?.containers = current.containers
        sheet?.containerID = current.containerID
        sheet?.unavailableList = current.unavailableList
        sheet?.followUps = current.followUps
        sheet?.quotes = current.quotes
        sheet?.events = current.events
        sheet?.existing = current.existing
    }

    /// "Not a Meeting": the candidate is dismissed and does not come back when the minutes are written again.
    func dismissFollowUp(_ follow: FollowUp) async {
        try? await store.setFollowUpState(follow.id, .dismissed)
        await reloadSheet()
        await rebuildEmail()
    }

    // MARK: Which calendar

    func chooseCalendar(among containers: [ActionContainer]) async -> (id: String?, unavailable: String?) {
        let ids = containers.map(\.id)
        var unavailable: String?
        if let chosen = preferences.eventCalendarID {
            if ids.contains(chosen) { return (chosen, nil) }
            unavailable = preferences.eventCalendarName ?? ""
        }
        if let last = preferences.lastEventCalendarID, ids.contains(last) { return (last, unavailable) }
        if let system = await writer.defaultContainerID(.event), ids.contains(system) { return (system, unavailable) }
        return (ids.first, unavailable)
    }

    // MARK: Opening the editor

    /// "Edit and Add…" for a detected follow-up, or "New Event…" (nil): the editor with the exact fields to be written.
    func openEventEditor(_ follow: FollowUp?, fromFollowUp: Bool = true) async {
        guard let meeting = sheet?.meeting else { return }
        returnsToFollowUp = fromFollowUp && sheet != nil
        if let existing = eventEditor, existing.followUpID == follow?.id {
            page = .event
            return
        }
        eventAccess = await writer.access(.event)
        let direct = eventAccess == .full
        let calendars = direct ? await writer.containers(.event) : []
        let (calendarID, unavailable) = direct ? await chooseCalendar(among: calendars) : (nil, nil)
        let meetingDay = DueDay.containing(meeting.start, in: meeting.zone)
        let names = (host?.attendees ?? []).filter { !$0.isSelf }.map(\.displayName)
        var state = EventEditorState(
            followUpID: follow?.id,
            title: follow?.title ?? EventDraft.defaultTitle(meeting: meeting.title),
            containerID: calendarID ?? "",
            day: follow?.day ?? meetingDay.adding(days: 7),
            allDay: false,
            minuteOfDay: follow?.minuteOfDay,
            durationMinutes: follow?.durationMinutes ?? EventDraft.duration(ofMeeting: meeting.duration),
            timeZone: meeting.zone,
            dayInferred: follow?.dayInferred ?? false,
            timeNotSaid: follow != nil && follow?.minuteOfDay == nil,
            quote: follow.flatMap { sheet?.quotes[$0.id] },
            quoteTime: follow?.t,
            meeting: meeting,
            attendeeNames: names,
            calendars: calendars,
            direct: direct,
            unavailableCalendar: unavailable,
            showsFirstWriteNotice: direct && !preferences.calendarWriteNoticeShown)
        state.includeMeetingName = preferences.includeMeetingName
        // A candidate whose day was not said starts on the day after the meeting's week, as an editable guess shown as it is.
        if follow?.day == nil { state.dayInferred = false }
        eventEditor = state
        page = .event
        await recheckEvent()
    }

    func setEventCalendar(_ id: String) async {
        eventEditor?.containerID = id
        eventEditor?.finding = .none
        await recheckEvent()
    }

    func recheckEvent() async {
        guard let state = eventEditor, state.direct, !state.containerID.isEmpty else { return }
        let transient = FollowUp(id: state.followUpID ?? -1, meetingID: state.meeting.id, title: state.title, day: state.day)
        let finding = await service.checkEvent(followUp: transient, draft: state.draft)
        guard eventEditor?.followUpID == state.followUpID else { return }
        eventEditor?.finding = finding
    }

    func setEventDay(_ day: DueDay) async {
        eventEditor?.day = day
        eventEditor?.dayInferred = false
        eventEditor?.finding = .none
        await recheckEvent()
    }

    // MARK: Adding

    /// Add to Calendar in the editor: through EventKit with full access, else an `.ics` for Calendar. Never a second event for the same
    /// follow-up, and never on top of an event that looks like it.
    func addEvent() async {
        guard var state = eventEditor, state.canAdd, !state.busy else { return }
        state.busy = true
        state.failed = false
        eventEditor = state
        let meeting = state.meeting
        var created = false
        var follow: FollowUp?
        if let id = state.followUpID { follow = ((try? await store.followUps(meeting.id)) ?? []).first { $0.id == id } }
        if follow == nil {
            created = true
            if let id = try? await store.addFollowUp(meeting.id, title: state.title, day: state.day, minuteOfDay: state.allDay ? nil : state.minuteOfDay,
                                                      durationMinutes: state.durationMinutes) {
                follow = ((try? await store.followUps(meeting.id)) ?? []).first { $0.id == id }
            }
        }
        guard let follow else {
            eventEditor?.busy = false
            eventEditor?.failed = true
            return
        }
        let draft = state.draft
        let outcome: AddOutcome
        var file: URL?
        if state.direct {
            outcome = await service.addEvent(followUp: follow, draft: draft)
        } else {
            let result = await service.handOffEvent(followUp: follow, draft: draft, meetingTitle: meeting.title, meetingDate: meeting.start, caches: caches)
            outcome = result.outcome
            file = result.file
        }
        eventEditor?.busy = false
        switch outcome {
        case .added(let row):
            try? await store.setFollowUpState(follow.id, .done)
            if let file {
                openFile(file)
                scheduleHandoffCleanup()
                host?.show(MeetingsNotice(text: String(localized: "Sent to Calendar", comment: "Notice after an event file was handed to Calendar, which asks where to add it"), symbol: StatusSymbol.ok.name))
            } else {
                preferences.lastEventCalendarID = draft.containerID
                preferences.calendarWriteNoticeShown = true
            }
            let name = containerNames[draft.containerID] ?? state.calendars.first { $0.id == draft.containerID }.map(Self.label) ?? ""
            finishEditor()
            await afterChange()
            await rebuildEmail()
            if file == nil {
                showUndoBar(text: String(localized: "Added to Calendar · \(name)", comment: "Bar after adding a calendar event; the argument is the calendar and its account, such as Work · iCloud"),
                            rows: [row], kind: .event)
            }
        case .duplicate(let finding):
            eventEditor?.finding = finding
            if created { try? await store.deleteFollowUp(follow.id); eventEditor?.followUpID = nil }
        case .noContainer:
            if created { try? await store.deleteFollowUp(follow.id); eventEditor?.followUpID = nil }
            eventEditor?.calendars = await writer.containers(.event)
            eventEditor?.unavailableCalendar = containerNames[draft.containerID] ?? ""
            eventEditor?.containerID = ""
        case .failed, .accessNeeded, .handOff:
            if created { try? await store.deleteFollowUp(follow.id); eventEditor?.followUpID = nil }
            eventEditor?.failed = true
        }
    }

    /// The hand-off files go 10 minutes after they were made (and the folder is emptied at every launch).
    private func scheduleHandoffCleanup() {
        let folder = caches
        Task.detached {
            try? await Task.sleep(for: .seconds(ICSHandoff.lifetime + 5))
            ICSHandoff.purge(in: folder)
        }
    }

    /// "Forget" on an `.ics` hand-off row: Calendar owns the event; the row stops counting.
    func forgetEvent(_ follow: FollowUp) async {
        guard let row = sheet?.events[follow.id] else { return }
        await service.forget(actionID: row.id)
        await reloadSheet()
    }

    func requestEventRemoval(_ follow: FollowUp) async {
        guard let row = sheet?.events[follow.id] else { return }
        await requestRemoval(rowID: row.id)
    }
}
