// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI
import VautaCore

/// "Edit and Add…" for a follow-up meeting, and "New Event…": the exact fields of the Calendar event. With full Calendar access it is
/// added through EventKit; without it an `.ics` file goes to Calendar, which asks where to put it. Vauta never asks for Calendar
/// access here, and never creates an event that looks like one already there.
struct EventEditor: View {
    @Bindable var actions: ActionsModel
    let state: EventEditorState

    static let width: CGFloat = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(Text("Add to Calendar", comment: "Title of the sheet that adds a follow-up meeting to Calendar"), symbol: "calendar.badge.plus")
            if let quote = state.quote { source(quote) }
            fields
            notices
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { actions.cancelEditor() }.keyboardShortcut(.cancelAction)
                if case .existingEvent(let item) = state.finding {
                    Button("Open in Calendar") { actions.openCalendar(item.itemID) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Add to Calendar") { Task { await actions.addEvent() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!state.canAdd)
                }
            }
        }
        .padding(20)
        .frame(width: Self.width)
    }

    /// Where the follow-up was found: the moment and the words.
    private func source(_ quote: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let t = state.quoteTime { Text(verbatim: ElapsedTime.stamp(t)).font(.callout.monospacedDigit()) }
            Text("“\(ActionClock.shortQuote(quote))”", comment: "Words heard in the meeting between quotation marks (a question, or the line that names the next meeting); the argument is the quote. Use the quotation marks of the language").lineLimit(3).truncationMode(.middle)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            ContextFieldRow("Title") {
                NoCopyField(title: String(localized: "Title", comment: "Placeholder of the reminder title field"),
                            text: Binding(get: { state.title }, set: { actions.eventEditor?.title = $0 }),
                            accessibilityLabel: String(localized: "Title", comment: "Accessibility label of the reminder title field"),
                            takesInitialFocus: true)
            }
            if state.direct {
                ContextFieldRow("Calendar", centersLabel: true) {
                    Picker("Calendar", selection: Binding(get: { state.containerID }, set: { id in Task { await actions.setEventCalendar(id) } })) {
                        if !state.hasCalendar { Text(verbatim: "—").tag(state.containerID) }
                        ForEach(state.calendars) { Text(verbatim: ActionsModel.label($0)).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(state.calendars.isEmpty)
                }
            }
            ContextFieldRow("Day", centersLabel: true) {
                DatePicker("Day", selection: Binding(get: { ActionClock.date(of: state.day) }, set: { date in Task { await actions.setEventDay(ActionClock.day(of: date)) } }),
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
            }
            ContextFieldRow("Time", centersLabel: true) { time }
            ContextFieldRow("Duration", centersLabel: true) {
                Picker("Duration", selection: Binding(get: { state.durationMinutes }, set: { actions.eventEditor?.durationMinutes = $0 })) {
                    ForEach(Self.durations(including: state.durationMinutes), id: \.self) { minutes in
                        Text(verbatim: Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))).tag(minutes)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(state.allDay)
            }
            if state.timeZone.identifier != TimeZone.current.identifier {
                Text("Times are in \(state.timeZone.localizedName(for: .standard, locale: .current) ?? state.timeZone.identifier), the time zone of the meeting.", comment: "Event editor: the meeting was in another time zone than this Mac's; the argument is the zone's name")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ContextFieldRow(verbatim: String(localized: "event.field.notes", defaultValue: "Notes",
                                              comment: "Label of the notes field of a reminder or an event in the editor; Apple’s Reminders and Calendar name this field (zh-Hans 备注), unlike the Notes tab of a meeting")) { notes }
            Toggle("Include the meeting’s name", isOn: Binding(get: { state.includeMeetingName }, set: { actions.eventEditor?.includeMeetingName = $0 }))
                .toggleStyle(.checkbox)
            if !state.attendeeNames.isEmpty {
                Toggle("Add attendee names to notes", isOn: Binding(get: { state.includeAttendeeNames }, set: { actions.eventEditor?.includeAttendeeNames = $0 }))
                    .toggleStyle(.checkbox)
            }
        }
    }

    /// The notes exactly as they will be written (the meeting's name and date, and the attendee names when asked).
    private var notes: some View {
        Text(verbatim: state.draft.write().notes ?? "—")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func durations(including current: Int) -> [Int] {
        Set([15, 30, 45, 60, 90, 120, current]).sorted()
    }

    private var time: some View {
        HStack(spacing: 8) {
            Toggle("All day", isOn: Binding(get: { state.allDay }, set: { actions.eventEditor?.allDay = $0 })).toggleStyle(.checkbox)
            if !state.allDay {
                if let minute = state.minuteOfDay {
                    DatePicker("Time", selection: Binding(get: { ActionClock.date(minute: minute) }, set: { actions.eventEditor?.minuteOfDay = ActionClock.minute(of: $0) }),
                               displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                } else {
                    if state.timeNotSaid { Text("Time not said", comment: "Event editor: the meeting did not say what time the follow-up is").foregroundStyle(.secondary) }
                    Button("Set a Time") { actions.eventEditor?.minuteOfDay = 10 * 60 }
                }
            }
        }
    }

    // MARK: Notices

    @ViewBuilder private var notices: some View {
        if state.dayInferred {
            NoticeLabel(Text("Day inferred from “\(ActionClock.datePhrase(in: state.quote ?? "", meeting: state.meeting, day: state.day))”: check it", comment: "Event editor: the day came from a phrase such as next Tuesday, not from a date; the argument is the phrase"), status: .warning)
        }
        if state.needsTime {
            NoticeLabel(Text("Choose a time or All day to add this event.", comment: "Event editor: a time is required"), status: .info, secondary: true)
        }
        if state.direct {
            if state.calendars.isEmpty {
                NoticeLabel(Text("You have no calendar Vauta can add to.", comment: "Event editor: no writable calendar"), status: .warning)
            }
            if let name = state.unavailableCalendar {
                NoticeLabel(Text("Your calendar “\(name)” is not available.", comment: "Event editor: the default calendar chosen in Settings is gone; the argument is its name"), status: .info, secondary: true)
            }
            if state.showsFirstWriteNotice, let calendar = actions.containerLabel(state.containerID) ?? state.calendars.first(where: { $0.id == state.containerID }).map(ActionsModel.label) {
                NoticeLabel(Text("Vauta will add this event to \(calendar). It never changes events you made.", comment: "Event editor, first event written: where it goes and what Vauta never does"), status: .info)
            }
        } else {
            NoticeLabel(Text("Calendar will ask where to add it.", comment: "Event editor without full Calendar access: Calendar shows its own dialog for the file"), status: .info)
        }
        if case .existingEvent(let item) = state.finding {
            NoticeLabel(Text("Already in your calendar: \(ActionClock.whenText(day: item.day ?? state.day, minute: item.minuteOfDay ?? (state.allDay ? nil : state.minuteOfDay)))", comment: "Event editor: an event like this one is in the calendar; the argument is its day and, when known, its time"), status: .info)
        }
        if case .alreadyAdded = state.finding {
            NoticeLabel(Text("This follow-up was already added.", comment: "Event editor: the follow-up has an event from Vauta"), status: .info)
        }
        if actions.copyProtected {
            NoticeLabel(Text("Copy protection is on. This text will leave Vauta for \(ActionAppName.calendar).", comment: "Editor, with copy protection on: the text goes to another app; the argument is the app's name, Reminders or Calendar"), status: .info, secondary: true)
        }
        if state.failed {
            NoticeLabel(Text("Vauta couldn’t add the event. Nothing was added.", comment: "Event editor: the save failed"), status: .error)
        }
    }
}
