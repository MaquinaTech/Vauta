// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The speakers of a recording in progress. The labels are provisional (the final clustering at the end may merge,
/// split or renumber them), so the panel says so; what the user names is carried over to the final speakers by where
/// the voice was heard. Calendar attendees are offered as chips and never assigned by themselves.
extension RecorderModel {
    /// A final line of the other participants was labelled: remember the voice.
    func noteLiveSpeaker(of segment: Segment) {
        guard segment.channel == .others, let ordinal = segment.speaker?.ordinal else { return }
        if !liveSpeakers.contains(ordinal) {
            liveSpeakers = (liveSpeakers + [ordinal]).sorted()
            syncCaptionSpeakers()
        }
        latestLiveSpeaker = ordinal
    }

    /// The voice the name field is for: the one picked, else the one pinned while the user types or points at the
    /// naming tools, else the one heard last. nil while no voice is told apart (the field then names the other
    /// participants as a whole, as before).
    var namingLiveSpeaker: Int? {
        LiveSpeakers.namingTarget(speakers: liveSpeakers, chosen: chosenLiveSpeaker, pinned: pinnedLiveSpeaker, latest: latestLiveSpeaker)
    }

    /// The voice stays the same while the user writes a name or has the pointer over the naming tools: voices heard in
    /// the meantime change what the label would say, never who the name is for.
    func updateLiveNamingPin(pointerInside: Bool? = nil) {
        if let pointerInside { pointerInLiveNaming = pointerInside }
        if pointerInLiveNaming || !othersQuery.isEmpty {
            if pinnedLiveSpeaker == nil { pinnedLiveSpeaker = namingLiveSpeaker }
        } else {
            pinnedLiveSpeaker = nil
        }
    }

    /// The names the user gave, by the voice's live number.
    var liveSpeakerNames: [Int: String] { liveSpeakerPeople.mapValues(\.displayName) }

    /// What to print for a voice: the name the user gave it, else "Speaker 2".
    func liveSpeakerLabel(_ ordinal: Int) -> String {
        liveSpeakerNames[ordinal] ?? MeetingSpeaker.defaultLabel(channel: .others, ordinal: ordinal)
    }

    /// Who said a line in the live transcript.
    func liveLabel(for segment: Segment) -> String {
        LiveSpeakers.label(channel: segment.channel, speaker: segment.speaker, names: liveSpeakerNames)
    }

    /// Some line of the transcript carries a provisional label of the other participants.
    var showsProvisionalSpeakers: Bool { !liveSpeakers.isEmpty }

    func chooseLiveSpeaker(_ ordinal: Int) { chosenLiveSpeaker = ordinal }

    /// A person is one voice: naming the same person for another voice moves the name.
    func assignLiveSpeaker(_ ordinal: Int, to person: Entity) {
        liveSpeakerPeople = liveSpeakerPeople.filter { $0.value.id != person.id && $0.key != ordinal }
        liveSpeakerPeople[ordinal] = person
        syncCaptionSpeakers()
    }

    /// Forgets the name of one voice. The person is taken out of the meeting’s named participants too (the name chip
    /// goes with the voice), and can be named again from the field or the calendar chips.
    func clearLiveSpeakerName(_ ordinal: Int) {
        guard let person = liveSpeakerPeople[ordinal] else { return }
        unnameOthers(person.id)
    }

    func syncCaptionSpeakers() {
        liveTranslation.setSpeakers(count: liveSpeakers.count, names: liveSpeakerNames)
    }

    func resetLiveSpeakers() {
        liveSpeakers = []
        liveSpeakerPeople = [:]
        chosenLiveSpeaker = nil
        pinnedLiveSpeaker = nil
        pointerInLiveNaming = false
        latestLiveSpeaker = nil
        syncCaptionSpeakers()
    }

    /// After the speakers are written: the names the user gave while recording go to the final speakers that hold the
    /// same voice. They are the user's own word: they win over a name or suggestion from a voice, and a speaker the user already named is never changed. Returns whether a notice about the speakers is
    /// due: labels the user could see may now read differently.
    func carryOverLiveSpeakerNames(meetingID: Int64, store: MeetingStore) async -> Bool {
        let notable = liveSpeakers.count >= 2 || !liveSpeakerPeople.isEmpty
        guard !liveSpeakerPeople.isEmpty else { return notable }
        let live = segments.compactMap { entry -> LiveSpeakers.LiveSpan? in
            guard entry.segment.channel == .others, let ordinal = entry.segment.speaker?.ordinal else { return nil }
            return LiveSpeakers.LiveSpan(ordinal: ordinal, start: entry.segment.start, end: entry.segment.end)
        }
        try? await store.carryOverLiveNames(meetingID: meetingID, named: liveSpeakerPeople.mapValues(\.id), live: live)
        return notable
    }
}
