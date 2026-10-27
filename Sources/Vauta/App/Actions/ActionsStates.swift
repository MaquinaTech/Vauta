// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import VautaCore

/// The reminder editor's draft: exactly what will be written, and what the editor knows about the place it goes to. It lives in
/// `ActionsModel`, not in the view, so the macOS permission prompt, a dismissed sheet or a switch of meeting never loses it.
struct ReminderEditorState: Equatable {
    var task: TaskItem
    var draft: ReminderDraft
    var meeting: ActionsModel.MeetingFacts?
    var selfEntityID: Int64?
    var containers: [ActionContainer] = []
    var access: ActionAccess = .notDetermined
    /// What the checks before a write found (an equal reminder in the list, one added before): the editor says so first.
    var finding: DuplicateFinding = .none
    var busy = false
    var requestingAccess = false
    /// "Vauta couldn’t add the reminder. Nothing was added."
    var failed = false
    /// The default list chosen in Settings is gone: its name, so the editor can say so.
    var unavailableList: String?
    var includeMeetingName = true
    /// The alert's time while the Alert switch is on (09:00 unless the setting says otherwise).
    var alertMinute = ReminderDraft.defaultAlertMinute

    var hasList: Bool { containers.contains { $0.id == draft.containerID } }
    var warnsUnconfirmed: Bool { task.unconfirmed || (task.ownerMarked) }
    var canAdd: Bool {
        access == .full && hasList && !busy && !draft.title.trimmingCharacters(in: .whitespaces).isEmpty && finding == .none
    }
}

/// The event editor's draft.
struct EventEditorState: Equatable {
    /// The detected (or earlier added) follow-up this edits; nil for a new event, which becomes one when it is added.
    var followUpID: Int64?
    var title: String
    var containerID: String
    var day: DueDay
    var allDay: Bool
    /// nil with `allDay` off: the time was not said, and the editor requires one (or All day).
    var minuteOfDay: Int?
    var durationMinutes: Int
    var timeZone: TimeZone
    /// The day came from "next Tuesday" or "next week", never said as a date: the editor says to check it.
    var dayInferred: Bool
    var timeNotSaid: Bool
    /// The phrase the follow-up was found in and the moment of the meeting.
    var quote: String?
    var quoteTime: Double?
    var meeting: ActionsModel.MeetingFacts
    var attendeeNames: [String] = []
    var includeAttendeeNames = false
    var includeMeetingName = true
    var calendars: [ActionContainer] = []
    /// Full Calendar access: the event is added through EventKit. Without it an `.ics` file goes to Calendar, which asks where.
    var direct = false
    var finding: DuplicateFinding = .none
    var busy = false
    var failed = false
    var unavailableCalendar: String?
    /// Shown once, at the first event written to Calendar.
    var showsFirstWriteNotice = false

    var hasCalendar: Bool { !direct || calendars.contains { $0.id == containerID } }
    var needsTime: Bool { !allDay && minuteOfDay == nil }
    var canAdd: Bool {
        let existing: Bool
        if case .existingEvent = finding { existing = true } else { existing = false }
        return hasCalendar && !needsTime && !busy && !existing && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var draft: EventDraft {
        EventDraft.make(title: title, day: day, minuteOfDay: allDay ? nil : minuteOfDay, durationMinutes: durationMinutes, containerID: containerID,
                        meetingTitle: meeting.title, meetingDate: meeting.start, timeZone: timeZone, includeAttendeeNames: includeAttendeeNames, attendeeNames: attendeeNames,
                        includeMeetingName: includeMeetingName)
    }
}

/// What the Follow-up sheet knows: the open tasks to offer, the follow-up meetings found, the email being built.
struct FollowUpSheetState {
    var meeting: ActionsModel.MeetingFacts
    var tasks: [TaskItem] = []
    /// Nothing is pre-ticked: a tick is the per-item confirmation.
    var ticked: Set<Int64> = []
    var containers: [ActionContainer] = []
    var containerID: String?
    var unavailableList: String?
    /// After a batch: what happened to the rows that were not added (an equal reminder in the list, one added before, a failure).
    var notes: [Int64: BatchNote] = [:]
    var busy = false
    var followUps: [FollowUp] = []
    /// The transcript line each follow-up was found in.
    var quotes: [Int64: String] = [:]
    var events: [Int64: CreatedAction] = [:]
    var existing: [Int64: ActionItem] = [:]
    var selfEntityID: Int64?
    var email = EmailState()
    /// Back-to-back meetings still to review, newest first, for "Next Meeting".
    var others: [Int64] = []

    var openTasks: [TaskItem] { tasks }

    /// The ticked tasks the batch would add: a row that still shows an unresolved "already there" banner waits for Use This One or Add
    /// Anyway, so the button does not count it.
    var addableTicked: [TaskItem] {
        tasks.filter { task in
            guard ticked.contains(task.id) else { return false }
            if case .duplicate? = notes[task.id] { return false }
            return true
        }
    }
    var visibleFollowUps: [FollowUp] { followUps.filter { $0.state != .dismissed } }
}

enum BatchNote: Equatable {
    case duplicate(DuplicateFinding)
    case failed
}

/// The email section: the stored fields, the options, the drafts built from them and who each one goes to.
struct EmailState {
    var input: FollowUpEmailInput?
    var options = FollowUpEmailOptions(locale: .current)
    /// The language in the picker (one of `ActionsModel.emailLanguages`).
    var languageID = "en"
    var drafts: [FollowUpEmailDraft] = []
    var selectedDraft: String?
    var recipients = EmailRecipients(recipients: [], selfDomainKnown: false)
    /// Addresses ticked per draft (nothing is pre-ticked).
    var ticked: [String: Set<Int64>] = [:]
    /// The email can include the summary on this model (an unmeasured model never offers it).
    var summaryOffered = false

    var current: FollowUpEmailDraft? { drafts.first { $0.id == selectedDraft } ?? drafts.first }

    /// The addresses a draft could go to: every attendee for the one email; only the owner's own for a per-owner draft.
    func candidates(for draft: FollowUpEmailDraft) -> [EmailRecipient] {
        guard let owner = draft.ownerEmail?.lowercased() else { return options.mode == .perOwner ? [] : recipients.recipients }
        return recipients.recipients.filter { $0.email.lowercased() == owner }
    }

    func chosen(for draft: FollowUpEmailDraft) -> [EmailRecipient] {
        let picked = ticked[draft.id] ?? []
        return candidates(for: draft).filter { picked.contains($0.entityID) }
    }
}
