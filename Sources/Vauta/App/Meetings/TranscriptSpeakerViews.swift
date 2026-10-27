// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Who said a transcript line. The name is always printed (a tint helps, it never carries the meaning). A line whose
/// speaker is a guess is italic with a question mark; a line said over other voices has its own sign. With speaker
/// data, the label opens the speaker popover.
struct SpeakerLabel: View {
    /// The room for each sign that follows a name (the 3 pt of spacing and the symbol at small scale, about 17 pt), for
    /// every kind of sign any line has.
    static let flagWidth: CGFloat = 22
    /// Air between the widest name (and its signs) and the text, the same in every row.
    static let gutter: CGFloat = 6
    /// The widest the speaker column grows; a longer name wraps to a second line.
    static let maxWidth: CGFloat = 170

    @Bindable var model: MeetingsModel
    let segment: MeetingStore.StoredSegment
    let width: CGFloat
    @ViewLocalState private var hovering = false

    private var tag: SpeakerTag? { segment.speaker }
    private var tint: Color { segment.channel.tint(ordinal: tag?.ordinal ?? 1) }

    var body: some View {
        if let tag, tag.id != nil {
            Button { model.speakerPopover = .line(segment.id) } label: { label(tag) }
                .buttonStyle(.plain)
                .help(Self.help(segment))
                .pointerStyle(.link)
                .onHover { hovering = $0 }
                .onDisappear { hovering = false }
                .popover(isPresented: Binding(
                    get: { model.speakerPopover == .line(segment.id) },
                    set: { if !$0, model.speakerPopover == .line(segment.id) { model.speakerPopover = nil } }
                ), arrowEdge: .trailing) {
                    SpeakerPopover(model: model, target: .line(segment.id))
                }
                // The row speaks for itself (label, text, translation); its action "Speaker options" opens the popover.
                .accessibilityHidden(true)
        } else {
            Text(segment.speakerLabel)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: width, alignment: .leading)
        }
    }

    private func label(_ tag: SpeakerTag) -> some View {
        let uncertain = tag.isLowConfidence
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            // The column is measured to hold the widest name and its signs, so a name breaks only at a space when it is
            // longer than the column; the signs keep their size and never push a number onto its own line.
            Text(segment.speakerLabel)
                .font(.callout.weight(.semibold))
                .italic(uncertain)
                .underline(hovering)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .layoutPriority(1)
            // Not by colour or style alone: a sign for each state.
            if uncertain { Image(systemName: "questionmark.circle").imageScale(.small).fixedSize() }
            if tag.overlap { Image(systemName: "person.2.wave.2").imageScale(.small).fixedSize() }
        }
        .foregroundStyle(tint)
        .frame(width: width, alignment: .leading)
    }

    // MARK: Words

    static func help(_ segment: MeetingStore.StoredSegment) -> String {
        // The full name first: the column cuts a long one after two lines.
        var lines = [segment.speakerLabel, String(localized: "Speaker options", comment: "Tooltip and VoiceOver action of a speaker's name in the transcript: opens the menu to name the speaker, merge it or fix who said a line")]
        lines += notes(segment)
        return lines.joined(separator: "\n")
    }

    /// What is uncertain about the line's speaker.
    static func notes(_ segment: MeetingStore.StoredSegment) -> [String] {
        var notes: [String] = []
        if segment.hasUncertainSpeaker {
            notes.append(String(localized: "Not sure who said this", comment: "Tooltip and VoiceOver: the app is not sure which speaker said this transcript line"))
        }
        if segment.speaker?.overlap == true {
            notes.append(String(localized: "Several people spoke at once", comment: "Tooltip and VoiceOver: several people talked at the same time in this transcript line"))
        }
        return notes
    }

    /// VoiceOver: "Ana, remote, 12:04: text", or "Ana, 12:04: text" when the line has no speaker data or the voice has no role.
    static func spoken(_ segment: MeetingStore.StoredSegment, time: String) -> Text {
        let name = segment.speakerLabel
        guard let role = segment.speaker?.role(channel: segment.channel) else {
            return Text("\(name), \(time): \(segment.text)", comment: "Transcript passage for VoiceOver: channel name, time, text")
        }
        return Text("\(name), \(role), \(time): \(segment.text)", comment: "Transcript passage for VoiceOver: speaker name, where the voice comes from (remote, in the room), time, text")
    }

    /// VoiceOver value: the translation, then what is uncertain about the speaker.
    static func spokenNotes(_ segment: MeetingStore.StoredSegment, translation: String?) -> String {
        // One line each, never one sentence: a translation and a status note are not items of a list.
        ([translation].compactMap { $0 } + notes(segment)).joined(separator: "\n")
    }
}

/// What the confirmation of turning separation off says (the snapshot scenes draw the same words).
enum SpeakerSeparationConfirmation {
    static var title: Text { Text("Don’t separate speakers in this meeting?") }
    static var action: Text { Text("Don’t Separate Speakers") }
    static func message(speakers: Int) -> Text {
        Text("The \(speakers) speakers in this meeting, and any names you gave them, are removed. Vauta can’t separate them again because it keeps no audio. You can undo this from the Edit menu until you open another meeting.",
             comment: "Confirmation of turning off speaker separation for a meeting: how many speakers (a plural) are removed with the names given to them, that Vauta keeps no audio to separate them again, and that Undo brings them back")
    }
}

/// "Separate speakers in this meeting" in the transcript's controls: the one control for the feature (on by default).
/// Turning it off removes the meeting's speakers (and the names given to them), so it asks first; the answer can be
/// undone from the Edit menu. The box always matches what the transcript shows: right after the removal, checking it
/// brings the speakers back; when separation was already off, nothing can bring them back (Vauta keeps no audio), so
/// the box stays unchecked and dimmed.
struct SpeakerSeparationSwitch: View {
    @Bindable var model: MeetingsModel

    /// Off before this session touched the switch: there is nothing to restore, so the box cannot be changed.
    private var locked: Bool { model.speakersOff && !model.separationTouched }

    var body: some View {
        Toggle("Separate speakers in this meeting", isOn: Binding(
            get: { !model.speakersOff },
            set: { on in
                if !on {
                    if model.speakers.isEmpty { Task { await model.setSpeakerSeparation(off: true) } } else { model.confirmingSpeakersOff = true }
                } else if model.speakersRemovedHere, model.pendingSpeakerRemoval != nil {
                    Task { await model.bringBackSpeakers() }
                } else {
                    Task { await model.setSpeakerSeparation(off: false) }
                }
            }))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(locked)
            .help(locked ? "Vauta keeps no audio, so it can’t separate this meeting’s speakers now"
                         : "Removes this meeting’s speakers and keeps them from being separated again")
            .confirmationDialog(SpeakerSeparationConfirmation.title, isPresented: $model.confirmingSpeakersOff, titleVisibility: .visible) {
                Button(role: .destructive) { Task { await model.setSpeakerSeparation(off: true) } } label: { SpeakerSeparationConfirmation.action }
                Button("Cancel", role: .cancel) {}
            } message: {
                SpeakerSeparationConfirmation.message(speakers: model.roster.entries.count)
            }
    }
}

/// Directly under the switch: why the transcript reads as before speakers. It looks like the window's other notices
/// (a status symbol and the sentence). The way back is the switch above, not a second control here.
struct SpeakerSeparationNote: View {
    var model: MeetingsModel

    /// The small checkbox's box, and the space between the box and its label.
    private static let boxWidth: CGFloat = 14
    private static let gap: CGFloat = 5

    var body: some View {
        if let text {
            // The glyph sits under the checkbox and the sentence starts at the checkbox's label.
            HStack(alignment: .firstTextBaseline, spacing: Self.gap) {
                StatusSymbol.info.image
                    .frame(width: Self.boxWidth)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// The way back is the box above: the note says how to use it. Without it (the undo was consumed or lost), the full
    /// sentence says why the speakers cannot come back.
    private var canBringBack: Bool { model.speakersRemovedHere && model.speakers.isEmpty && model.pendingSpeakerRemoval != nil }

    private var text: String? {
        if model.speakersOff, canBringBack {
            return String(localized: "Check the box to bring the speakers back. You can do this until you open another meeting.",
                          comment: "Transcript tab, under the unchecked Separate speakers box right after the user removed the meeting’s speakers: how to undo it")
        }
        // Off from the start, or switched in a meeting that had no speakers: they are not separated afterwards either.
        if model.speakersOff || (model.speakers.isEmpty && model.separationTouched && !canBringBack) {
            return String(localized: "Speakers aren’t separated in this meeting. Vauta keeps no audio, so it can’t separate them after the meeting.",
                          comment: "Transcript tab, under the switch of a meeting whose speakers are not separated: they are not separated afterwards because Vauta keeps no audio")
        }
        return nil
    }
}
