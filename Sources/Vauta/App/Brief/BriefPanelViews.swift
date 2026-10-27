// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// "Next meeting": the brief's card in the menu-bar panel, from the lead time before the meeting until 15 minutes after it started.
/// It sits above the record button and replaces nothing. While Meetings are locked it shows the event's title and time and nothing
/// else; the brief itself opens in the Meetings window.
struct BriefCardView: View {
    let model: RecorderModel

    var body: some View {
        if model.phase == .idle, !model.isRecording, let card = model.brief.panelCard {
            BriefCardContent(card: card,
                             armed: model.brief.armed == card.occurrence,
                             cancelArmed: { model.brief.cancelArmed() },
                             open: { model.brief.openBrief() },
                             setUp: { model.brief.prefs.hintSeen = true; model.showSettings(.calendar) },
                             dismissHint: { model.brief.prefs.hintSeen = true })
        }
    }
}

/// The card for one state (the scenes render it with invented cards).
struct BriefCardContent: View {
    let card: BriefPanelCard
    /// "Record at Start" was pressed for this meeting: Vauta will ask to record when it starts.
    var armed = false
    var cancelArmed: () -> Void = {}
    let open: () -> Void
    var setUp: () -> Void = {}
    var dismissHint: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Next meeting", systemImage: "calendar.badge.clock")
                    .panelCardTitle()
                    .lineLimit(1)
                Spacer(minLength: 4)
                // The time of day is in the line under the title; the header adds the date only when the meeting is not today.
                if !Calendar.current.isDate(card.summary.start, inSameDayAs: AppClock.now) {
                    Text(verbatim: card.summary.start.formatted(date: .abbreviated, time: .omitted))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityHidden(true)
            Text(verbatim: card.summary.title.isEmpty ? " " : card.summary.title)
                .font(.callout.weight(.semibold))
                // Three lines and the end cut: a middle cut drops the part of a long title that says what the meeting is. The card's
                // own label (VoiceOver) and the help carry the whole title.
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .help(Text(verbatim: card.summary.title))
                .accessibilityHidden(true)
            subtitle
            body(of: card.content)
            if armed, card.content != .setUp { armedRow }
            if card.content == .setUp {
                hintRow
            } else {
                PanelActionRow {
                    Button("Open Brief", action: open)
                        .buttonStyle(.bordered)
                        .disabled(!opens)
                        .accessibilityHint(Text(verbatim: openHint))
                }
                .controlSize(.small)
            }
        }
        .panelCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(String(localized: "Next meeting", comment: "Menu-bar panel: heading of the card about the meeting that is about to start")), \(card.summary.title), \(BriefLabels.whenLine(start: card.summary.start))"))
    }

    /// Open Brief does something: the brief is ready (or can be asked for after unlocking). Not while it is built, paused or off.
    private var opens: Bool {
        switch card.content {
        case .building, .paused, .setUp: false
        case .locked, .ready: true
        }
    }

    private var openHint: String {
        switch card.content {
        case .ready, .locked: BriefLabels.briefReady(at: card.summary.start)
        case .building: String(localized: "Preparing brief…", comment: "Menu-bar panel, brief card: the brief is being built")
        case .paused: String(localized: "Brief paused while the Mac cools down", comment: "Menu-bar panel, brief card: the Mac is too hot to build the brief")
        case .setUp: ""
        }
    }

    @ViewBuilder private var subtitle: some View {
        HStack(spacing: 10) {
            if let service = card.summary.service {
                Label(service.displayName, systemImage: "video").labelStyle(.titleAndIcon)
            }
            Text(verbatim: BriefLabels.timeRange(start: card.summary.start, end: card.summary.end))
            if case .ready(let ready) = card.content, ready.peopleCount > 0 {
                Label { Text(verbatim: ready.peopleCount.formatted()) } icon: { Image(systemName: "person.2") }
                    .accessibilityLabel(Text(verbatim: String(localized: "People: \(ready.peopleCount)", comment: "VoiceOver, menu-bar panel brief card: how many other people are in the meeting; the argument is a number")))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private func body(of content: BriefPanelCard.Content) -> some View {
        switch content {
        case .setUp:
            EmptyView()
        case .locked:
            Label { Text("Unlock to see the brief", comment: "Menu-bar panel, brief card: Meetings are locked, so the brief is not shown") } icon: { Image(systemName: "lock") }
                .font(.callout).foregroundStyle(.secondary)
        case .building:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing brief…", comment: "Menu-bar panel, brief card: the brief is being built").font(.callout).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .paused:
            Label("Brief paused while the Mac cools down", systemImage: "thermometer.high")
                .font(.callout).foregroundStyle(.secondary)
        case .ready(let ready):
            switch ready.body {
            case .firstMeeting:
                VStack(alignment: .leading, spacing: 2) {
                    Text("First meeting with these people", comment: "Menu-bar panel, brief card: nobody coming to the meeting was in an earlier meeting of Vauta").font(.callout).foregroundStyle(.secondary)
                    if !ready.people.isEmpty {
                        let extra = ready.people.count - 3
                        Text(verbatim: ready.people.prefix(3).joined(separator: ", ") + (extra > 0 ? " +\(extra)" : ""))
                            .font(.callout).lineLimit(1).truncationMode(.middle)
                    }
                }
            case .nothingOpen:
                Text("Nothing open from earlier meetings", comment: "Menu-bar panel, brief card: earlier meetings left no open task, decision or question").font(.callout).foregroundStyle(.secondary)
            case .lines(let lines):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(lines) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: BriefLabels.symbol(item.kind)).foregroundStyle(.secondary).frame(width: 14).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: item.text).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                                BriefMarks(item: item)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: BriefLabels.spoken(item)))
                    }
                }
            }
        }
    }

    /// A quiet confirmation of "Record at Start", with a way to take it back. It never records by itself.
    private var armedRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                Text("Vauta will ask to record when it starts", comment: "Menu-bar panel, brief card: Record at Start was chosen in the notification; when the meeting begins Vauta suggests recording, it does not record by itself")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: { Image(systemName: "bell") }
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Cancel", action: cancelArmed).buttonStyle(.link).font(.callout)
        }
        .accessibilityElement(children: .contain)
    }

    private var hintRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vauta can prepare a brief before your meetings.", comment: "Menu-bar panel, brief card: shown once, the first time a meeting with a brief comes up")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            PanelActionRow {
                Button("Set Up…", action: setUp)
                Button("Not Now", action: dismissHint)
            }
            .controlSize(.small)
        }
    }
}

/// While a meeting is recorded: a collapsed "Brief" row that opens onto "Last time", "Open tasks" and the suggested agenda. It never
/// expands by itself, and VoiceOver does not read it unprompted. Escape closes it.
struct BriefRecordingRow: View {
    let model: RecorderModel
    @ViewLocalState private var expanded = false
    @Environment(\.briefViewOptions) private var options

    var body: some View {
        if model.isRecording, let snapshot = model.brief.recordingRow {
            BriefRecordingRowContent(snapshot: snapshot, expanded: $expanded) { model.openBriefLink($0) }
                .onAppear { if options.startsExpanded { expanded = true } }
        }
    }
}

struct BriefRecordingRowContent: View {
    let snapshot: BriefSnapshot
    @Binding var expanded: Bool
    let open: (BriefLink) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Label("Brief", systemImage: "doc.text.magnifyingglass").panelCardTitle()
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .default, value: expanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Brief", comment: "Menu-bar panel while recording: the row that opens the brief the meeting started with"))
            .accessibilityValue(Text(verbatim: snapshot.title))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(expanded ? Text("Hides the brief", comment: "VoiceOver hint of the Brief row while recording, when it is open") : Text("Shows the brief", comment: "VoiceOver hint of the Brief row while recording, when it is closed"))
            if expanded {
                // What the person owes comes first: the panel is short and the end of the row scrolls out of sight.
                BriefContentView(sections: snapshot.sections.sorted { ($0.kind == .openTasks ? 0 : 1) < ($1.kind == .openTasks ? 0 : 1) }, agenda: snapshot.agenda,
                                 only: [.lastTime, .openTasks], compact: true, open: open)
                    .onExitCommand { expanded = false }
            }
        }
        .panelCard()
    }
}
