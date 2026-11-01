// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Meetings › Upcoming › Today: every event of today in the chosen calendars, all-day ones first, each with its time, its calendar's
/// colour and where it stands (now, next, declined). A meeting the brief is for opens its brief under the list, built when it is opened.
/// Read when shown and dropped when Meetings lock; nothing is written.
struct UpcomingTodayView: View {
    let brief: BriefController
    let entriesView: (BriefController.Entry) -> UpcomingEntriesView

    var body: some View {
        Group {
            switch brief.today {
            case .off, .loading:
                UpcomingLoadingView(locked: brief.isLocked, resume: { brief.openToday() }, refresh: { brief.openToday() })
            case .calendarDenied:
                EmptyStateView(Text("No Access to Calendar", comment: "Meetings, Upcoming: title when Calendar access is turned off for Vauta; the sentence under it says how to turn it on"),
                               symbol: "calendar.badge.exclamationmark", message: nil) { EmptyView() }
            case .items(let items) where items.isEmpty:
                EmptyStateView(Text("Nothing in your calendars today", comment: "Meetings, Upcoming, Today: no event today in the calendars chosen in Settings"), symbol: "calendar") {
                    Button(String(localized: "Refresh", comment: "Meetings, Upcoming: builds the brief again")) { brief.openToday() }
                }
            case .items(let items):
                ScrollView {
                    VStack(alignment: .leading, spacing: PaneLayout.section) {
                        list(items)
                        if let entry = brief.todayEntry { entriesView(entry) }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: brief.isLocked) { if !brief.isLocked { brief.openToday() } }
    }

    private func list(_ items: [BriefTodayItem]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in row(item) }
        }
        .padding(.horizontal, PaneLayout.pane)
        .padding(.top, PaneLayout.pane)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Today", comment: "Meetings, Upcoming: the list of every event of today"))
    }

    @ViewBuilder private func row(_ item: BriefTodayItem) -> some View {
        let open = brief.todayEntry?.event.occurrence == item.id
        let line = HStack(spacing: 8) {
            if let color = item.event.calendarColor {
                Circle().fill(Color(.sRGB, red: color.red, green: color.green, blue: color.blue)).frame(width: 8, height: 8).accessibilityHidden(true)
            } else {
                Circle().fill(.clear).frame(width: 8, height: 8).accessibilityHidden(true)
            }
            Text(verbatim: Self.time(item)).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 96, alignment: .leading).layoutPriority(1)
            Text(verbatim: item.event.title.isEmpty ? " " : item.event.title)
                .lineLimit(1).truncationMode(.middle)
                .strikethrough(item.event.currentUserDeclined)
            if let mark = Self.mark(item) {
                Text(verbatim: mark).font(.caption.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 0)
            if item.hasBrief {
                Image(systemName: open ? "chevron.down" : "chevron.right").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(open ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(item.moment == .past || item.event.currentUserDeclined ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .contentShape(Rectangle())
        if item.hasBrief {
            Button { open ? brief.closeTodayBrief() : brief.openTodayBrief(item) } label: { line }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: Self.spoken(item)))
                .accessibilityHint(open ? Text("Hides the brief", comment: "VoiceOver hint of the Brief row while recording, when it is open")
                                        : Text("Shows the brief", comment: "VoiceOver hint of the Brief row while recording, when it is closed"))
                .accessibilityAddTraits(open ? [.isButton, .isSelected] : .isButton)
        } else {
            line.accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: Self.spoken(item)))
        }
    }

    static func time(_ item: BriefTodayItem) -> String {
        if item.moment == .allDay { return String(localized: "All day", comment: "Meetings, Upcoming, Today: an event that lasts all day, in place of its time") }
        let start = item.event.start.formatted(date: .omitted, time: .shortened)
        return item.event.end > item.event.start ? "\(start) – \(item.event.end.formatted(date: .omitted, time: .shortened))" : start
    }

    static func mark(_ item: BriefTodayItem) -> String? {
        if item.event.currentUserDeclined { return String(localized: "Declined", comment: "Meetings, Upcoming, Today: the person declined this event's invitation") }
        switch item.moment {
        case .now: return String(localized: "Now", comment: "Meetings, Upcoming, Today: this event is happening now")
        case .next: return String(localized: "Up next", comment: "Meetings, Upcoming, Today: the next event to start today")
        default: return nil
        }
    }

    /// What VoiceOver reads: time, title, the mark, and whether it has a brief.
    static func spoken(_ item: BriefTodayItem) -> String {
        var parts = [time(item), item.event.title]
        if let mark = mark(item) { parts.append(mark) }
        if item.hasBrief { parts.append(String(localized: "Brief", comment: "VoiceOver, Meetings, Upcoming, Today: this event has a brief that opens under the list")) }
        return parts.joined(separator: ", ")
    }
}
