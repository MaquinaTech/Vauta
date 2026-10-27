// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Meetings › Upcoming: the brief of the meeting about to start and of the next one within 12 hours. Built when it is opened or
/// refreshed; nothing is read from the calendar when this view is not shown. Suggest-only: its buttons open Calendar or Reminders,
/// they never change them.
struct UpcomingBriefView: View {
    let model: MeetingsModel
    let brief: BriefController
    let openSettings: (SettingsModel.Pane) -> Void
    let openSystemSettings: () -> Void

    var body: some View {
        switch brief.upcoming {
        case .off:
            EmptyStateView(Text("Upcoming", comment: "Meetings: the view with the brief of the next meeting"), symbol: "calendar",
                           message: String(localized: "Turn on Calendar and the brief in Settings to see your next meeting here.", comment: "Meetings, Upcoming: shown when Calendar or the brief is off")) {
                Button(SettingsModel.Pane.calendar.openTitle) { openSettings(.calendar) }
            }
        case .calendarDenied:
            EmptyStateView(Text("No Access to Calendar", comment: "Meetings, Upcoming: title when Calendar access is turned off for Vauta; the sentence under it says how to turn it on"), symbol: "calendar.badge.exclamationmark",
                           message: String(localized: "Calendar access is turned off for Vauta in System Settings.", comment: "Settings → Calendar")) {
                Button("Open System Settings", action: openSystemSettings)
            }
        case .loading:
            UpcomingLoadingView(locked: brief.isLocked, waited: brief.snapshotWaited, resume: { brief.resumeUpcomingIfIdle() }, refresh: { brief.openUpcoming(force: true) })
        case .none:
            EmptyStateView(Text("No meetings coming up", comment: "Meetings, Upcoming: no meeting with a brief in the next 12 hours"), symbol: "calendar") {
                Button(String(localized: "Refresh", comment: "Meetings, Upcoming: builds the brief again")) { brief.openUpcoming(force: true) }
            }
        case .entries(let entries):
            UpcomingEntriesView(entries: entries, index: Binding(get: { min(brief.upcomingIndex, entries.count - 1) }, set: { brief.upcomingIndex = $0 }),
                                reminderSettings: { openSettings(.calendar) }, remindersHintDismissed: brief.prefs.remindersHintDismissed,
                                dismissRemindersHint: { brief.prefs.remindersHintDismissed = true }, linkPerson: { openSettings(.context) },
                                open: { model.open($0) }, refresh: { brief.openUpcoming(force: true) }, openCalendar: { brief.openCalendar($0) })
        }
    }
}

/// "Preparing brief…" while Upcoming loads. A load that was cut short (Meetings were locked and unlocked) starts again when the page can
/// load, and after a few seconds a Refresh button is there in case it takes too long.
struct UpcomingLoadingView: View {
    let locked: Bool
    /// Renderings show the state after the wait.
    var waited = false
    var resume: () -> Void = {}
    var refresh: () -> Void = {}
    @ViewLocalState private var slow = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Preparing brief…", comment: "Menu-bar panel, brief card: the brief is being built").foregroundStyle(.secondary)
            if slow || waited {
                Button(String(localized: "Refresh", comment: "Meetings, Upcoming: builds the brief again"), action: refresh).controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: locked) {
            guard !locked else { return }
            resume()
            try? await Task.sleep(for: .seconds(8))
            slow = true
        }
    }
}

/// The page of one or two upcoming meetings.
struct UpcomingEntriesView: View {
    let entries: [BriefController.Entry]
    @Binding var index: Int
    var reminderSettings: () -> Void = {}
    /// The line about Reminders was closed: it is not shown again.
    var remindersHintDismissed = false
    var dismissRemindersHint: () -> Void = {}
    var linkPerson: () -> Void = {}
    let open: (BriefLink) -> Void
    var refresh: () -> Void = {}
    var openCalendar: (BriefEvent) -> Void = { _ in }

    var body: some View {
        let entry = entries[min(max(0, index), entries.count - 1)]
        ScrollView {
            VStack(alignment: .leading, spacing: PaneLayout.section) {
                if entries.count > 1 { picker }
                header(entry)
                page(entry)
            }
            .padding(PaneLayout.pane)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One compact row per meeting (time and title, one line each, the title cut in the middle), so the second meeting is not anonymous and
    /// a long title cannot widen the window. The chosen one carries a filled marker, not a colour alone.
    private var picker: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(entries.enumerated()), id: \.offset) { offset, entry in
                let chosen = offset == min(max(0, index), entries.count - 1)
                Button { index = offset } label: {
                    HStack(spacing: 8) {
                        Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(chosen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                            .accessibilityHidden(true)
                        Text(verbatim: BriefLabels.whenLine(start: entry.event.start)).monospacedDigit().foregroundStyle(.secondary).layoutPriority(1)
                        Text(verbatim: entry.event.title.isEmpty ? " " : entry.event.title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(chosen ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: "\(BriefLabels.whenLine(start: entry.event.start)), \(entry.event.title)"))
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Upcoming", comment: "Meetings: the view with the brief of the next meeting"))
        .frame(maxWidth: 480, alignment: .leading)
    }

    private func header(_ entry: BriefController.Entry) -> some View {
        let event = entry.event
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: event.title.isEmpty ? " " : event.title)
                .font(.title2.weight(.semibold))
                .lineLimit(2)
                .truncationMode(.middle)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                // The calendar's colour, as the Calendar app shows it (the time says when; the dot says which calendar).
                if let color = event.calendarColor {
                    Circle().fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue)).frame(width: 9, height: 9).accessibilityHidden(true)
                }
                Text(verbatim: "\(BriefLabels.whenLine(start: event.start)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                if let service = event.service { Label(service.displayName, systemImage: "video") }
                if let people = entry.snapshot?.section(.people)?.items.count, people > 0 {
                    Label { Text(verbatim: people.formatted()) } icon: { Image(systemName: "person.2") }
                        .accessibilityLabel(Text(verbatim: String(localized: "People: \(people)", comment: "VoiceOver, menu-bar panel brief card: how many other people are in the meeting; the argument is a number")))
                }
                if let series = entry.snapshot?.seriesName { Label { Text(verbatim: series) } icon: { Image(systemName: "arrow.triangle.2.circlepath") } }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            HStack(spacing: 12) {
                Button("Open in Calendar") { openCalendar(event) }
                Button(String(localized: "Refresh", comment: "Meetings, Upcoming: builds the brief again"), action: refresh)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    @ViewBuilder private func page(_ entry: BriefController.Entry) -> some View {
        if entry.hot {
            Label("Brief paused while the Mac cools down", systemImage: "thermometer.high").foregroundStyle(.secondary)
        } else if let snapshot = entry.snapshot {
            if snapshot.isFirstMeeting {
                Text("First meeting with these people", comment: "Menu-bar panel, brief card: nobody coming to the meeting was in an earlier meeting of Vauta").foregroundStyle(.secondary)
            } else if snapshot.section(.lastTime) == nil, snapshot.section(.openTasks) == nil {
                Text("Nothing open from earlier meetings", comment: "Menu-bar panel, brief card: earlier meetings left no open task, decision or question").foregroundStyle(.secondary)
            }
            BriefContentView(sections: snapshot.sections, agenda: snapshot.agenda, agendaFirst: true,
                             reminders: remindersHintDismissed && [.notAsked, .denied, .noLists].contains(entry.reminders) ? .off : entry.reminders,
                             openSettings: reminderSettings, dismissRemindersHint: dismissRemindersHint, explainsAgenda: true, linkPerson: linkPerson, open: open)
            if snapshot.isFirstMeeting {
                Text("Vauta will remember this one after you record it.", comment: "Meetings, Upcoming: under the brief of a first meeting with these people")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            // The skeleton: the section headings the page will have, until the brief is built.
            VStack(alignment: .leading, spacing: PaneLayout.section) {
                ForEach([BriefSectionKind.people, .lastTime, .openTasks], id: \.self) { kind in
                    Label(BriefLabels.title(kind), systemImage: BriefLabels.symbol(kind)).font(.headline).foregroundStyle(.tertiary)
                }
                ProgressView().controlSize(.small)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Preparing brief…", comment: "Menu-bar panel, brief card: the brief is being built"))
        }
    }
}

/// The "Brief" tab of a recorded meeting: what Vauta showed before it started, as far as what it pointed to still exists. Reminders and
/// the invitation's notes are not kept.
struct StoredBriefView: View {
    let references: BriefStoredReferences
    let createdAt: Date
    let open: (BriefLink) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PaneLayout.section) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The brief you had when this meeting started", comment: "Meetings, Brief tab of a recorded meeting: heading")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text("Prepared \(createdAt.formatted(date: .abbreviated, time: .shortened)). Reminders and the invitation’s notes are not kept.",
                         comment: "Meetings, Brief tab of a recorded meeting: when the brief was prepared (argument: date and time) and what is not stored")
                        .font(.callout).foregroundStyle(.secondary)
                }
                let sections = references.sections
                // The same rule as the live brief: fewer than two verified lines are not a suggested agenda (deleted lines can leave one).
                let agenda = references.agenda.count >= BriefAgendaPrompt.minimumLines ? references.agenda : []
                if sections.isEmpty && agenda.isEmpty {
                    Text("Nothing from this brief is left to show.", comment: "Meetings, Brief tab of a recorded meeting: every line it pointed to was deleted").foregroundStyle(.secondary)
                } else {
                    BriefContentView(sections: sections, agenda: agenda.isEmpty ? .none : .lines(agenda), agendaFirst: true, open: open)
                }
            }
            .padding(PaneLayout.pane)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
