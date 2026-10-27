// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// The strip over a meeting that offers to look for a confirmed voice in earlier meetings, shows the search and what it
/// found. It never acts by itself: Look, Review and every answer are the user's.
struct VoiceHistoryBanner: View {
    let state: VoiceHistoryState
    let look: () -> Void
    let review: () -> Void
    let undo: () -> Void
    let dismiss: () -> Void

    static func offerTitle(_ person: VoiceHistoryPerson) -> Text {
        person.isSelf
            ? Text("Look for your voice in recent meetings?", comment: "Banner over a meeting after the user saved or confirmed their own voice: asks whether to look for it in earlier meetings")
            : Text("Look for \(person.name) in recent meetings?", comment: "Banner over a meeting after the user confirmed or saved a person’s voice: asks whether to look for the same voice in earlier meetings; the argument is the person’s name")
    }

    static func searchingTitle(_ person: VoiceHistoryPerson) -> Text {
        person.isSelf
            ? Text("Looking for your voice in recent meetings…", comment: "Banner while the saved voice of the user is compared with the speakers of earlier meetings")
            : Text("Looking for \(person.name) in recent meetings…", comment: "Banner while a saved voice is compared with the speakers of earlier meetings; the argument is the person’s name")
    }

    static func foundTitle(_ person: VoiceHistoryPerson, count: Int) -> Text {
        person.isSelf
            ? Text("Found your voice in \(count) earlier meetings", comment: "Banner after the search: the user’s voice resembles a speaker in this many earlier meetings; the argument is a number (plural)")
            : Text("Found \(person.name) in \(count) earlier meetings", comment: "Banner after the search: the saved voice resembles a speaker in this many earlier meetings; the first argument is the person’s name, the second a number (plural)")
    }

    static func noneTitle(_ person: VoiceHistoryPerson) -> Text {
        person.isSelf
            ? Text("No recent meeting sounds like you.", comment: "Banner after the search found nobody who resembles the user’s saved voice")
            : Text("No recent meeting sounds like \(person.name).", comment: "Banner after the search found nobody who resembles a saved voice; the argument is the person’s name")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                switch state {
                case .searching:
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                default:
                    Image(systemName: "waveform.badge.magnifyingglass").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
                title.font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                // Not while searching: the search writes its suggestions as one step that only this banner can undo.
                if case .searching = state {} else {
                    Button(action: dismiss) { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel(Text("Dismiss"))
                }
            }
            if case .offer = state {
                Text("Vauta compares the saved voice with the speakers of your meetings from the last \(VoiceProfileThresholds.keptSummaryDays) days on this Mac. Nothing is renamed: a match is only a suggestion that you accept or reject for each meeting.",
                     comment: "Banner offering to look for a saved voice in earlier meetings: what it does and that it never names anybody by itself")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .found = state {
                Text("These are suggestions only. Nothing is renamed until you say yes for a meeting.",
                     comment: "Banner after the search of earlier meetings: the matches are suggestions, never names")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)) }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
    }

    private var title: Text {
        switch state {
        case .offer(let p): Self.offerTitle(p)
        case .searching(let p): Self.searchingTitle(p)
        case .found(let p, let rows): Self.foundTitle(p, count: rows.count)
        case .none(let p): Self.noneTitle(p)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .offer:
            HStack {
                Button(String(localized: "Look", comment: "Banner button: compares the saved voice with the speakers of earlier meetings"), action: look)
                    .buttonStyle(.borderedProminent)
                Button(String(localized: "Not Now"), action: dismiss)
            }
            .controlSize(.small)
        case .found(_, let rows):
            HStack {
                Button(String(localized: "Review…", comment: "Banner button: opens the list of earlier meetings where the voice was found, to accept or reject each"), action: review)
                    .buttonStyle(.borderedProminent)
                if rows.allSatisfy({ $0.decision == .pending }) {
                    Button(String(localized: "Undo"), action: undo)
                }
            }
            .controlSize(.small)
        case .searching, .none:
            EmptyView()
        }
    }
}

/// The earlier meetings where a saved voice was found, each with Yes and No. A Yes is the user naming the speaker; the
/// rows never show how close the match is.
struct PastVoiceReviewSheet: View {
    let person: VoiceHistoryPerson
    let rows: [PastVoiceRow]
    let answer: (PastVoiceRow, Bool) -> Void
    let undo: (PastVoiceRow) -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(person.isSelf
                        ? Text("Earlier meetings with your voice", comment: "Sheet title: the earlier meetings where a speaker resembles the user’s saved voice")
                        : Text("Earlier meetings with \(person.name)", comment: "Sheet title: the earlier meetings where a speaker resembles a saved voice; the argument is the person’s name"),
                        message: Text("In each meeting, one speaker sounds like this saved voice. Read what they said and say yes only when you are sure it is them; a voice alone never names a speaker.",
                                      comment: "Sheet message: how to answer the suggestions found in earlier meetings"),
                        symbol: "waveform.badge.magnifyingglass")
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        reviewRow(row)
                        if row.id != rows.last?.id { Divider() }
                    }
                }
            }
            .frame(maxHeight: 320)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Spacer()
                Button(BackupAnnouncement.doneTitle, action: done)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    /// "Mar 3, 2026, 4:10 PM · Speaker 2 · 3 min": when, which speaker of that meeting and for how long they talk.
    static func detail(_ match: PastVoiceMatch) -> String {
        var parts = [match.meetingDate.formatted(date: .abbreviated, time: .shortened),
                     MeetingSpeaker.defaultLabel(channel: .others, ordinal: match.speakerOrdinal)]
        if match.talkSeconds >= 1 {
            let seconds = max(60, (match.talkSeconds / 60).rounded() * 60)
            // A no-break space keeps the number with its unit when the row wraps.
            parts.append(Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
                .replacingOccurrences(of: " ", with: "\u{00A0}"))
        }
        return parts.joined(separator: " · ")
    }

    private func reviewRow(_ row: PastVoiceRow) -> some View {
        let suggestion = SpeakerSuggestion(entityID: person.entityID, name: person.name, isSelf: person.isSelf)
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                (row.match.meetingTitle.map { Text(verbatim: $0) } ?? Text("Untitled meeting"))
                    .lineLimit(2)
                Text(verbatim: Self.detail(row.match))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let line = row.match.excerpt {
                    // What the speaker said in that meeting: the evidence the user has to judge the match.
                    Text(verbatim: line)
                        .font(.callout.italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            switch row.decision {
            case .pending:
                Button { answer(row, true) } label: { Text("Yes") }
                    .accessibilityLabel(suggestion.yesLabel)
                Button { answer(row, false) } label: { Text("No") }
                    .accessibilityLabel(suggestion.noLabel)
            case .accepted:
                Label { Text("Accepted", comment: "Review of earlier meetings: the user said yes for this meeting") } icon: {
                    Image(systemName: StatusSymbol.ok.name).foregroundStyle(StatusSymbol.ok.color)
                }
                .font(.callout)
                Button(String(localized: "Undo")) { undo(row) }.buttonStyle(.link)
            case .rejected:
                Label { Text("Rejected", comment: "Review of earlier meetings: the user said no for this meeting") } icon: {
                    Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                }
                .font(.callout)
                Button(String(localized: "Undo")) { undo(row) }.buttonStyle(.link)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}
