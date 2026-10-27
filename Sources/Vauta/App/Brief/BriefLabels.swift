// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The words of the brief: section headings, what each line is, and what VoiceOver says for it. Marks always have a glyph and a word,
/// never a colour alone.
enum BriefLabels {
    static func title(_ kind: BriefSectionKind) -> String {
        switch kind {
        case .people: String(localized: "brief.section.people", defaultValue: "People", comment: "Meetings and panel, brief: heading of the people coming to the meeting (the attendees of the meeting, not the app’s People tab)")
        case .lastTime: String(localized: "Last time", comment: "Brief: heading of what the previous meeting of the series left (summary, decisions, tasks, questions)")
        case .openTasks: String(localized: "Open tasks", comment: "Brief: heading of the open tasks of the people coming to the meeting")
        case .relatedMeetings: String(localized: "Related meetings", comment: "Brief: heading of other meetings about the same things")
        case .documents: String(localized: "Documents and notes", comment: "Brief: heading of passages of the person's documents and of notes exported from Notes")
        case .reminders: String(localized: "Reminders", comment: "Brief: heading of the person's open reminders that relate to the meeting; the Reminders app")
        case .invitation: String(localized: "From the invitation", comment: "Brief: heading of the agenda lines found in the calendar invitation, shown as plain text")
        }
    }

    static var yours: String { String(localized: "Me", comment: "Brief: sub-heading of the open tasks and reminders that belong to the person") }
    static var others: String { String(localized: "brief.tasks.others", defaultValue: "Others", comment: "Brief: sub-heading of the open tasks that belong to other people, next to the heading for the person's own (\"Me\")") }
    static var suggestedAgenda: String { String(localized: "Suggested agenda", comment: "Brief: heading of the few lines a model suggests for the meeting") }
    static var overdue: String { String(localized: "Overdue", comment: "Brief: mark of a task whose due day has already passed") }
    static var dueBeforeMeeting: String { String(localized: "Due before this meeting", comment: "Brief: mark of a task or reminder that is due before the meeting starts, but is not late yet") }
    static var fromTheMinutes: String { String(localized: "from the minutes", comment: "Brief: an open question that could not be located in the transcript; it opens the meeting's minutes") }
    static var noteBadge: String { String(localized: "Note", comment: "Brief: badge of a passage from a note exported from Notes") }
    static var noEarlierMeetings: String { String(localized: "No earlier meetings", comment: "Brief: a person who was in no earlier meeting of Vauta") }

    static func lastMet(_ date: Date) -> String {
        String(localized: "Last met \(date.formatted(date: .abbreviated, time: .omitted))", comment: "Brief: when the person was last in a meeting with the user; the argument is a date")
    }

    static func meetingsTogether(_ count: Int) -> String {
        String(localized: "Earlier meetings together: \(count)", comment: "Brief: how many earlier meetings the user and this person were in; the argument is a number")
    }

    static func agendaKind(_ kind: BriefAgendaLine.Kind) -> String {
        switch kind {
        case .followUp: String(localized: "brief.agenda.followup", defaultValue: "Follow up", comment: "Brief, suggested agenda: label of a line that follows up on something open")
        case .decide: String(localized: "brief.agenda.decide", defaultValue: "Decide", comment: "Brief, suggested agenda: label of a line that proposes deciding something")
        case .ask: String(localized: "brief.agenda.ask", defaultValue: "Ask", comment: "Brief, suggested agenda: label of a line that proposes asking something")
        case .review: String(localized: "brief.agenda.review", defaultValue: "Review", comment: "Brief, suggested agenda: label of a line that proposes reviewing something")
        }
    }

    static func showAll(_ count: Int) -> String {
        String(localized: "Show all (\(count))", comment: "Brief: button that shows every item of a section; the argument is how many there are")
    }

    static func symbol(_ kind: BriefItem.Kind) -> String {
        switch kind {
        case .person: "person"
        case .summary: "text.alignleft"
        case .decision: "checkmark.seal"
        case .task: "checklist"
        case .openQuestion: "questionmark.bubble"
        case .relatedMeeting: "rectangle.stack"
        case .material, .document: "doc.text"
        case .note: "note.text"
        case .reminder: "bell"
        case .invitationLine: "text.quote"
        }
    }

    static func symbol(_ kind: BriefSectionKind) -> String {
        switch kind {
        case .people: "person.2"
        case .lastTime: "clock.arrow.circlepath"
        case .openTasks: "checklist"
        case .relatedMeetings: "rectangle.stack"
        case .documents: "doc.text"
        case .reminders: "bell"
        case .invitation: "text.quote"
        }
    }

    static func kindName(_ kind: BriefItem.Kind) -> String {
        switch kind {
        case .person: String(localized: "Person", comment: "VoiceOver, brief: what a line is; a person coming to the meeting")
        case .summary: String(localized: "Last meeting", comment: "VoiceOver, brief: what a line is; the summary of the previous meeting")
        case .decision: String(localized: "Decision", comment: "Search result kind")
        case .task: String(localized: "Task", comment: "VoiceOver, brief: what a line is; a task")
        case .openQuestion: String(localized: "Open question", comment: "VoiceOver, brief: what a line is; a question the previous meeting left open")
        case .relatedMeeting: String(localized: "Related meeting", comment: "VoiceOver, brief: what a line is; another meeting about the same things")
        case .material, .document: String(localized: "Document", comment: "VoiceOver, brief: what a line is; a file or a passage of one")
        case .note: String(localized: "Note", comment: "Search result kind")
        case .reminder: String(localized: "Reminder", comment: "VoiceOver, brief: what a line is; a reminder from the Reminders app")
        case .invitationLine: String(localized: "Invitation line", comment: "VoiceOver, brief: what a line is; a line of the calendar invitation")
        }
    }

    static func linkAction(_ link: BriefLink) -> String? {
        switch link {
        case .segment: String(localized: "Show in transcript", comment: "VoiceOver, brief: action of a line that opens the passage of the transcript it comes from")
        case .meeting: String(localized: "Show meeting", comment: "VoiceOver, brief: action of a line that opens a meeting")
        case .person: String(localized: "Show person", comment: "VoiceOver, brief: action of a line that opens a person's card")
        case .passage, .file: String(localized: "Show passage", comment: "VoiceOver, brief: action of a line that opens a passage of a document")
        case .reminder: String(localized: "Open in Reminders", comment: "Brief: button or action that opens the reminder in the Reminders app; nothing is changed there")
        case .event: String(localized: "Open in Calendar", comment: "Brief: button that opens the Calendar app; nothing is changed there")
        case .none: nil
        }
    }

    /// What VoiceOver reads for a line: what it is, its date, owner and marks, then the text. The source is the action's name.
    /// The mark of a task that has a reminder Vauta created or linked (the reminder itself is not listed again).
    static var inReminders: String { String(localized: "In Reminders", comment: "Brief: mark on a task that already has a reminder in Reminders") }

    /// What the person confirmed about an item against earlier meetings: "carried over since 12 Sep", "replaces the decision of 12 Sep", "first decided on 12 Sep".
    static func linkMark(_ item: BriefItem) -> String? {
        if item.kind == .task, let since = item.carriedSince {
            let date = TaskDueFormat.text(since)
            return String(localized: "carried over since \(date)", comment: "Brief: mark on an open task the person confirmed is the same as the one from earlier meetings; the argument is the date of the first")
        }
        if item.kind == .decision, let replaces = item.replacesDate {
            let date = TaskDueFormat.text(replaces)
            return String(localized: "replaces the decision of \(date)", comment: "Brief: mark on a decision the person confirmed replaces an earlier one; the argument is the date of the earlier decision")
        }
        if item.kind == .decision, let first = item.firstDecided {
            let date = TaskDueFormat.text(first)
            return String(localized: "first decided on \(date)", comment: "Brief: mark on a decision the person confirmed is the same as an earlier one; the argument is the date of the first")
        }
        return nil
    }

    static func spoken(_ item: BriefItem) -> String {
        var parts: [String] = [kindName(item.kind)]
        if let date = item.meetingDate, item.kind != .person { parts.append(date.formatted(date: .long, time: .omitted)) }
        if item.kind == .task, item.isYours { parts.append(item.ownerUncertain ? VerificationText.ownerSpoken(yours) : yours) } else if let owner = item.owner, !owner.isEmpty {
            parts.append(item.ownerUncertain ? VerificationText.ownerSpoken(owner) : owner)
        }
        if let due = item.due { parts.append(String(localized: "due \(due.formatted(date: .long, time: .omitted))", comment: "VoiceOver, brief: when a task or reminder is due; the argument is a date")) }
        if item.overdue { parts.append(overdue) }
        if item.dueBeforeMeeting { parts.append(dueBeforeMeeting) }
        if item.unconfirmed { parts.append(VerificationText.unconfirmed) }
        if item.fromMinutes { parts.append(fromTheMinutes) }
        if item.inReminders { parts.append(inReminders) }
        if let link = linkMark(item) { parts.append(link) }
        // The row shows the older decision under the newer one, and a spoken row has no children: say what it replaced.
        if item.kind == .decision, item.replacesDate != nil, let older = item.replacesText, !older.isEmpty {
            parts.append(String(localized: "Earlier decision: \(older)", comment: "VoiceOver, in the brief: the text of the older decision that a decision the person confirmed replaces; the argument is that text"))
        }
        if item.kind == .person, item.historyKnown {
            if item.meetingsTogether == 0 { parts.append(noEarlierMeetings) } else if let met = item.lastMet { parts.append(lastMet(met)) }
        }
        // The separators are the language's (、 in Japanese, a no-break space before the colon in French): the strings carry them.
        let details = parts.joined(separator: String(localized: "brief.spoken.separator", defaultValue: ", ", comment: "VoiceOver, brief: separates what a line is, its date, owner and marks; a comma and a space in English"))
        return String(localized: "\(details): \(item.text)", comment: "VoiceOver, brief: what a line is and its marks, then the line's text; the first argument is the marks, the second the text")
    }

    static func briefReady(at start: Date) -> String {
        String(localized: "Brief ready for \(start.formatted(date: .omitted, time: .shortened))", comment: "VoiceOver announcement when the brief of a meeting is built; the argument is the meeting's start time")
    }

    // MARK: Event

    static func timeRange(start: Date, end: Date) -> String {
        "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    static func whenLine(start: Date, now: Date = AppClock.now) -> String {
        Calendar.current.isDate(start, inSameDayAs: now) ? start.formatted(date: .omitted, time: .shortened) : start.formatted(date: .abbreviated, time: .shortened)
    }
}
