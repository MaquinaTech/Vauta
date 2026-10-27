// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// The popover of a speaker, bound to the Meetings window's model: it finds the speaker (or the line's speaker) and
/// sends the user's choice to the model, which applies it, makes it undoable and reloads the views.
struct SpeakerPopover: View {
    @Bindable var model: MeetingsModel
    let target: SpeakerPopoverTarget

    private var line: MeetingStore.StoredSegment? {
        guard case .line(let id) = target else { return nil }
        return model.transcript.first { $0.id == id }
    }

    private var speakerID: Int64? {
        switch target {
        case .line: line?.speaker?.id
        case .speaker(let id): id
        }
    }

    var body: some View {
        if let speakerID, let speaker = model.roster.entry(speakerID)?.speaker, let meeting = model.selectedID {
            let people = model.speakerCandidates(for: speaker)
            SpeakerPopoverContent(roster: model.roster, speakerID: speakerID, line: line, meetingID: meeting,
                                  suggested: people.suggested, people: people.people,
                                  voice: model.voiceOffer(for: speaker), candidate: model.suggestion(for: speaker),
                                  rememberVoice: { model.speakerPopover = nil; model.askToRememberVoice(of: speakerID) },
                                  saveOwnVoice: { try await model.rememberOwnVoice(of: speakerID) },
                                  perform: { try await model.applySpeakerAction($0) },
                                  bringBack: model.pendingSpeakerRemoval == nil ? nil : { Task { await model.bringBackSpeakers() } },
                                  close: { model.speakerPopover = nil })
        }
    }
}

/// The titles of the popover's rows, in one place so the popover can measure them to choose its width.
enum SpeakerPopoverText {
    static var nameThisSpeaker: String { String(localized: "Name This Speaker", comment: "Speaker popover: opens the page to say who this speaker is") }
    static var mergeWithAnother: String { String(localized: "Merge with Another Speaker", comment: "Speaker popover: opens the list of speakers to merge this one with, because the diarizer split one person in two") }
    static var lineIsSomeoneElse: String { String(localized: "This Line Is Someone Else", comment: "Speaker popover: opens the list of speakers to move this transcript line to, because the wrong speaker is shown") }
    static var splitFromHere: String { String(localized: "Split From Here", comment: "Speaker popover: gives this line and the rest of the turn to a new speaker") }
    static var clearName: String { String(localized: "Clear Name", comment: "Speaker popover: removes the name given to this speaker, which goes back to Speaker 1, 2…") }
    static func addPerson(_ name: String) -> String { String(localized: "Add “\(name)” as a New Person", comment: "Button: adds the typed name as a new person and assigns it; the argument is the name") }
    /// A name of ordinary length, to size the popover for the row that adds a typed name.
    static let sampleName = "Maria Gonzalez"
}

/// What the popover shows, apart from the model so the snapshot scenes can draw each of its pages.
struct SpeakerPopoverContent: View {
    enum Mode: Hashable {
        case main
        /// Name the speaker or pick a person.
        case assign
        /// Pick the speaker to merge this one with.
        case merge
        /// Confirm merging into the speaker with this ID.
        case confirmMerge(Int64)
        /// Pick who really said the line.
        case moveLine
        /// Confirm that the speaker is the user and save their voice.
        case confirmOwnVoice
    }

    /// Wide enough for the longest row of the first pages in the interface language, so a menu-like row never breaks
    /// onto a second line (a translation is often longer than English); never narrower than 300 pt or wider than 380 pt.
    static var width: CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .body)
        func measure(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        // Row padding (12 + 4 on each side) and the icon column (18 + 8); a drilling row also has a chevron (8 + 8).
        let chrome: CGFloat = 32 + 26
        let drilling = [SpeakerPopoverText.nameThisSpeaker, SpeakerPopoverText.mergeWithAnother, SpeakerPopoverText.lineIsSomeoneElse].map(measure).max() ?? 0
        let others = [SpeakerPopoverText.splitFromHere, SpeakerPopoverText.clearName, SpeakerPopoverText.addPerson(SpeakerPopoverText.sampleName)].map(measure).max() ?? 0
        return min(380, max(300, max(drilling + 16, others) + chrome))
    }

    let roster: SpeakerRoster
    let speakerID: Int64
    /// The transcript line the popover was opened from; nil when it was opened from "Who spoke".
    let line: MeetingStore.StoredSegment?
    let meetingID: Int64
    /// Attendees of the meeting's calendar event: suggestions only, shown first.
    let suggested: [Entity]
    let people: [Entity]
    /// What the popover offers about saving this speaker's voice.
    let voice: VoiceOffer
    /// The person a saved voice matched without enough certainty (“Is this Ana?”).
    let candidate: SpeakerSuggestion?
    /// Opens the consent sheet (the popover closes).
    let rememberVoice: () -> Void
    /// Saves the user's own voice for this speaker.
    let saveOwnVoice: () async throws -> Void
    let perform: (SpeakerAction) async throws -> Void
    /// Brings the meeting's removed speakers back; nil when that is no longer possible.
    let bringBack: (() -> Void)?
    let close: () -> Void
    @ViewLocalState private var mode: Mode
    @ViewLocalState private var typed: String
    @ViewLocalState var failure: String?
    /// The speaker or the line was removed meanwhile: nothing in the popover can work any more.
    @ViewLocalState private var gone: Bool
    /// Separation was turned off for the meeting meanwhile: no name can be given until the speakers are back.
    @ViewLocalState private var separationOff: Bool
    @ViewLocalState var busy = false
    /// The page the merge confirmation came from, where Cancel goes back to.
    @ViewLocalState private var mergeOrigin: Mode = .merge
    @FocusState private var nameFocused: Bool

    init(roster: SpeakerRoster, speakerID: Int64, line: MeetingStore.StoredSegment?, meetingID: Int64, suggested: [Entity], people: [Entity],
         voice: VoiceOffer = .none, candidate: SpeakerSuggestion? = nil, rememberVoice: @escaping () -> Void = {},
         saveOwnVoice: @escaping () async throws -> Void = {},
         mode: Mode = .main, typed: String = "", failure: String? = nil, gone: Bool = false, separationOff: Bool = false,
         perform: @escaping (SpeakerAction) async throws -> Void, bringBack: (() -> Void)? = nil, close: @escaping () -> Void) {
        self.voice = voice
        self.candidate = candidate
        self.rememberVoice = rememberVoice
        self.saveOwnVoice = saveOwnVoice
        self.roster = roster
        self.speakerID = speakerID
        self.line = line
        self.meetingID = meetingID
        self.suggested = suggested
        self.people = people
        self.perform = perform
        self.bringBack = bringBack
        self.close = close
        _mode = ViewLocalState(initialValue: mode)
        _typed = ViewLocalState(initialValue: typed)
        _failure = ViewLocalState(initialValue: failure)
        _gone = ViewLocalState(initialValue: gone)
        _separationOff = ViewLocalState(initialValue: separationOff)
    }

    private var entry: SpeakerRoster.Entry? { roster.entry(speakerID) }

    /// Why nothing in the popover can work any more, if so: the speaker or the line was removed, or separation was
    /// turned off. (A speaker to merge into that disappeared is not here: this speaker is still valid, so the list to
    /// choose from comes back with a line saying why.)
    private var unusableNotice: String? {
        if separationOff, let failure { return failure }
        if gone, let failure { return failure }
        return nil
    }

    /// The speaker chosen to merge into is gone.
    private var mergeTargetGone: Bool {
        if case .confirmMerge(let target) = mode { return roster.entry(target) == nil }
        return false
    }

    private var shownFailure: String? {
        failure ?? (mergeTargetGone ? StoreError(.speakerGone).localizedDescription : nil)
    }
    private var alternatives: [SpeakerRoster.Entry] { roster.alternatives(to: speakerID) }

    var body: some View {
        if let notice = unusableNotice {
            goneNotice(notice)
        } else if let entry {
            VStack(alignment: .leading, spacing: 0) {
                header(entry)
                Divider()
                Group {
                    switch mode {
                    case .main: main(entry)
                    case .assign: assign(entry)
                    case .merge: pick(title: Text("Merge with", comment: "Speaker popover: title of the page that lists the speakers this one can be merged into"), alternatives, then: { mergeOrigin = .merge; mode = .confirmMerge($0.id) })
                    case .confirmMerge(let target):
                        if mergeTargetGone {
                            pick(title: Text("Merge with", comment: "Speaker popover: title of the page that lists the speakers this one can be merged into"), alternatives, then: { mergeOrigin = .merge; mode = .confirmMerge($0.id) })
                        } else {
                            confirmMerge(entry, target: target)
                        }
                    case .moveLine: moveLine()
                    case .confirmOwnVoice: confirmOwnVoice(entry)
                    }
                }
                .disabled(busy)
                if let failure = shownFailure {
                    Label { Text(failure).fixedSize(horizontal: false, vertical: true) } icon: { StatusSymbol.warning.image }
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                }
            }
            .frame(width: Self.width)
            .padding(.vertical, 6)
        }
    }

    /// Nothing in the popover would work, so it says what happened, what to do, and has the button that does it (the
    /// speakers can come back when the removal can still be undone). The transcript was already read again.
    private func goneNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text(message).fixedSize(horizontal: false, vertical: true) } icon: { StatusSymbol.warning.image }
                .font(.callout.weight(.semibold))
            if separationOff {
                Text("Names can’t be given to speakers while they aren’t separated.", comment: "Speaker popover: what is true after speaker separation was turned off for the meeting while the popover was open")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The transcript is up to date now. Choose the speaker again.", comment: "Speaker popover: what to do after the speaker or the line was removed while the popover was open (merged or split elsewhere)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    Spacer(minLength: 0)
                    bringBackButton
                    closeButton
                }
                VStack(spacing: 6) {
                    closeButton.frame(maxWidth: .infinity)
                    bringBackButton.frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private var closeButton: some View {
        Button("Close", action: close).keyboardShortcut(.defaultAction)
    }

    @ViewBuilder
    private var bringBackButton: some View {
        if separationOff, let bringBack {
            Button("Bring Back Speakers") { bringBack(); close() }
        }
    }

    // MARK: Header

    private func header(_ entry: SpeakerRoster.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.displayName)
                .font(.headline)
                .foregroundStyle(entry.channel.tint(ordinal: entry.speaker.ordinal))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if entry.speaker.talkSeconds > 0 {
                Text("\(SpeakerFormat.talkTime(entry.speaker.talkSeconds)) · \(SpeakerFormat.share(roster.displayShare(of: entry))) of the talking",
                     comment: "Speaker popover: how long the speaker talked and the share of all the talking that is, as in “12 min · 42% of the talking”")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Pages

    private func main(_ entry: SpeakerRoster.Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let candidate { suggestionBlock(candidate) }
            PopoverRow(title: Text(verbatim: SpeakerPopoverText.nameThisSpeaker), symbol: "person.text.rectangle", drills: true) { open(.assign) }
            if !alternatives.isEmpty {
                PopoverRow(title: Text(verbatim: SpeakerPopoverText.mergeWithAnother), symbol: "arrow.triangle.merge", drills: true) { open(.merge) }
            }
            if line != nil {
                Divider().padding(.vertical, 4)
                PopoverRow(title: Text(verbatim: SpeakerPopoverText.lineIsSomeoneElse), symbol: "arrow.left.arrow.right", drills: true) { open(.moveLine) }
                PopoverRow(title: Text(verbatim: SpeakerPopoverText.splitFromHere), symbol: "scissors",
                           detail: Text("This line and the ones after it in the same turn move to a new speaker.", comment: "Speaker popover: explains what Split From Here moves")) {
                    guard let line else { return }
                    run(.splitFromHere(segment: line.id, meeting: meetingID))
                }
            }
            if entry.speaker.name != nil {
                Divider().padding(.vertical, 4)
                PopoverRow(title: Text(verbatim: SpeakerPopoverText.clearName), symbol: "person.crop.circle.badge.minus") {
                    run(.assign(speaker: speakerID, entity: nil))
                }
            }
            voiceRows(entry)
        }
    }

    private func assign(_ entry: SpeakerRoster.Entry) -> some View {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = { (e: Entity) in text.isEmpty || ([e.displayName, e.name] + e.aliases).contains { $0.localizedStandardContains(text) } }
        let suggestions = suggested.filter(match), others = people.filter(match)
        let exact = exactMatches(text)
        return VStack(alignment: .leading, spacing: 0) {
            BackBar(title: Text("Who is this?", comment: "Speaker popover: title of the page where the user names the speaker")) { open(.main) }
            TextField(String(localized: "Type a name or search people", comment: "Speaker popover: placeholder of the field to type who the speaker is or to search the people of the context"), text: $typed)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .onSubmit { submit(text, exact: exact) }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                .onAppear { nameFocused = true }
            if exact.count > 1 {
                // Return would have to guess: the matching people are listed below, and the user picks one.
                Label { Text(StoreError(.speakerNameAmbiguous).localizedDescription).fixedSize(horizontal: false, vertical: true) } icon: { StatusSymbol.info.image }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                    .accessibilityElement(children: .combine)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !suggestions.isEmpty {
                        SectionLabel(title: Text("From the calendar", comment: "Heading of the calendar attendees offered as suggestions for who a speaker or the other participants are (speaker popover and recording panel)"))
                        ForEach(suggestions) { person in personRow(person, entry) }
                    }
                    if !others.isEmpty {
                        SectionLabel(title: Text("People", comment: "Speaker popover: heading of the people of the user’s context that a speaker can be assigned to"))
                        ForEach(others) { person in personRow(person, entry) }
                    }
                    // Only for a name nobody answers to (by name or alias): the row then does what it says.
                    if !text.isEmpty && exact.isEmpty {
                        Divider().padding(.vertical, 4)
                        PopoverRow(title: Text(verbatim: SpeakerPopoverText.addPerson(text)), symbol: "person.badge.plus") { run(.name(speaker: speakerID, name: text)) }
                    }
                }
            }
            .frame(maxHeight: 230)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The people whose name, display name or an alias is the typed text, ignoring case and accents. A name that is
    /// an alias of someone is that person, never a new one.
    private func exactMatches(_ text: String) -> [Entity] {
        guard !text.isEmpty else { return [] }
        let key = TextKeys.norm(text)
        var seen = Set<Int64>()
        return (suggested + people).filter { person in
            ([person.displayName, person.name] + person.aliases).contains { TextKeys.norm($0) == key } && seen.insert(person.id).inserted
        }
    }

    /// Another speaker of this meeting that already is this person: giving the person to two speakers would split one
    /// voice in two colours, so the row offers to merge the two instead.
    private func holder(of person: Entity, besides entry: SpeakerRoster.Entry) -> SpeakerRoster.Entry? {
        roster.entries.first { $0.id != entry.id && $0.channel == entry.channel && $0.speaker.name != nil && $0.speaker.entityID == person.id }
    }

    private func personRow(_ person: Entity, _ entry: SpeakerRoster.Entry) -> some View {
        let chosen = entry.speaker.name != nil && entry.speaker.entityID == person.id
        if let other = holder(of: person, besides: entry) {
            // Said in words the user can see: the speaker's number is gone from the interface once it has a name.
            return PopoverRow(verbatim: person.displayName,
                              subtitle: String(localized: "Already speaking in this meeting", comment: "Speaker popover, under a person who already is another speaker of this meeting: picking the row leads to merging this speaker with that one"),
                              drills: true) {
                mergeOrigin = .assign
                mode = .confirmMerge(other.id)
            }
        }
        return PopoverRow(verbatim: person.displayName, subtitle: person.note, checked: chosen) {
            // Already this person: nothing to change, so no edit and no step on the undo stack.
            if chosen { close() } else { run(.assign(speaker: speakerID, entity: person.id)) }
        }
    }

    private func moveLine() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BackBar(title: Text("Who said this line?", comment: "Speaker popover: title of the page that lists the speakers a transcript line can be moved to")) { open(.main) }
            ForEach(alternatives) { other in
                PopoverRow(verbatim: other.displayName, tint: other.channel.tint(ordinal: other.speaker.ordinal)) {
                    guard let line else { return }
                    run(.moveLine(segment: line.id, to: other.id))
                }
            }
            Divider().padding(.vertical, 4)
            PopoverRow(title: Text("New Speaker", comment: "Speaker popover: moves this line to a new speaker, because the diarizer put two people in one"), symbol: "plus") {
                guard let line else { return }
                run(.moveLineToNewSpeaker(segment: line.id, meeting: meetingID))
            }
        }
    }

    private func pick(title: Text, _ choices: [SpeakerRoster.Entry], then: @escaping (SpeakerRoster.Entry) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            BackBar(title: title) { open(.main) }
            ForEach(choices) { choice in
                PopoverRow(verbatim: choice.displayName, tint: choice.channel.tint(ordinal: choice.speaker.ordinal)) { then(choice) }
            }
        }
    }

    private func confirmMerge(_ entry: SpeakerRoster.Entry, target id: Int64) -> some View {
        // The target is there: the list to choose from is shown instead when it is not.
        let into = roster.entry(id)?.displayName ?? ""
        return VStack(alignment: .leading, spacing: 10) {
            Text("Merge “\(Self.unbroken(entry.displayName))” into “\(Self.unbroken(into))”?")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(mergeDetail(entry, into: into))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Side by side when both labels fit the popover, else stacked at full width (a long translation is never cut).
            ViewThatFits(in: .horizontal) {
                HStack {
                    Spacer(minLength: 0)
                    cancelMergeButton
                    mergeButton(into: id)
                }
                VStack(spacing: 6) {
                    mergeButton(into: id).frame(maxWidth: .infinity)
                    cancelMergeButton.frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// A name of ordinary length stays on one line in the title (“Daniel Okafor” never splits between its words).
    private static func unbroken(_ name: String) -> String {
        name.count <= 24 ? name.replacingOccurrences(of: " ", with: "\u{00A0}") : name
    }

    private var cancelMergeButton: some View {
        Button("Cancel", role: .cancel) { open(mergeOrigin) }
            .keyboardShortcut(.cancelAction)
    }

    private func mergeButton(into id: Int64) -> some View {
        Button("Merge Speakers") { run(.merge(source: speakerID, into: id)) }
            .keyboardShortcut(.defaultAction)
    }

    /// What the merge gives away, with the number of lines and the time: "The 6 lines (3 min) of “Speaker 1” will be attributed to “Daniel”."
    private func mergeDetail(_ entry: SpeakerRoster.Entry, into: String) -> String {
        if entry.lines > 0 {
            return String(localized: "The \(entry.lines) lines (\(SpeakerFormat.talkTime(entry.speaker.talkSeconds))) of “\(entry.displayName)” will be attributed to “\(into)”. You can undo this from the Edit menu.",
                          comment: "Speaker popover, merge confirmation: how many transcript lines (a plural) and how much talk time (such as 3 min) the speaker has, then the speaker, then the other speaker they are attributed to")
        }
        return String(localized: "Everything “\(entry.displayName)” said will be attributed to “\(into)”. You can undo this from the Edit menu.",
                      comment: "Speaker popover, merge confirmation, for a speaker with no lines: the first argument is the speaker, the second the one it is merged into")
    }

    // MARK: Actions

    func open(_ page: Mode) {
        failure = nil
        mode = page
    }

    /// Return in the name field: the one person the typed name is (by name or alias), else a new person with that name.
    /// It never assigns somebody whose name merely starts like the typed text, and with several people of that name it
    /// waits for the user to pick one.
    private func submit(_ text: String, exact: [Entity]) {
        guard !text.isEmpty else { return }
        switch exact.count {
        case 0: run(.name(speaker: speakerID, name: text))
        case 1: run(.assign(speaker: speakerID, entity: exact[0].id))
        default: break
        }
    }

    func run(_ action: SpeakerAction) {
        busy = true
        failure = nil
        Task {
            do {
                try await perform(action)
                close()
            } catch {
                failure = error.localizedDescription
                if let store = error as? StoreError {
                    if store.code == .speakerGone || store.code == .segmentGone { gone = true }
                    if store.code == .speakersOff { separationOff = true }
                }
            }
            busy = false
        }
    }
}
