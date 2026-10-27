// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The person a search of earlier meetings is about.
struct VoiceHistoryPerson: Equatable {
    let entityID: Int64
    /// The name to show; unused when `isSelf` (the user's own voice has its own wording).
    let name: String
    var isSelf = false
}

/// One earlier meeting found by the search, with the user's answer so far.
struct PastVoiceRow: Identifiable, Equatable {
    enum Decision: Equatable { case pending, accepted, rejected }
    let match: PastVoiceMatch
    var decision = Decision.pending
    var id: Int64 { match.speakerID }
}

/// Where the “look for this voice in earlier meetings” flow is. It starts only with the user's answer to an offer, and
/// what it finds are suggestions, never names.
enum VoiceHistoryState: Equatable {
    /// After “Is this Ana?” was accepted or a voice was saved: asks whether to look. Nothing has been read.
    case offer(VoiceHistoryPerson)
    case searching(VoiceHistoryPerson)
    case found(VoiceHistoryPerson, [PastVoiceRow])
    case none(VoiceHistoryPerson)

    var person: VoiceHistoryPerson {
        switch self {
        case .offer(let p), .searching(let p), .found(let p, _), .none(let p): p
        }
    }
}

/// Propagating a confirmed voice to earlier meetings: offered after the user accepts “Is this Ana?” or saves a voice (and
/// only while “Recognize voices across meetings” is on), run on request, reviewed meeting by meeting, undoable.
extension MeetingsModel {
    /// Offers the search for a person whose voice the user just confirmed. Nothing is read until the user agrees.
    func offerVoiceHistory(entityID: Int64, name: String, isSelf: Bool) async {
        guard recognizingVoices, !speakersOff, (try? await store.canLookForVoice(of: entityID)) == true else { return }
        voiceHistory = .offer(VoiceHistoryPerson(entityID: entityID, name: name, isSelf: isSelf))
    }

    /// The user accepted the offer: compares the saved voice with the speakers of the earlier meetings.
    func lookInEarlierMeetings() async {
        guard case .offer(let person)? = voiceHistory, let current = selectedID else { return }
        noteActivity()
        voiceHistory = .searching(person)
        pastVoiceUndos = [:]
        pastVoiceSweepUndo = nil
        do {
            let sweep = try await store.suggestVoiceInPastMeetings(of: person.entityID, excludingMeeting: current, recognizing: recognizingVoices)
            guard case .searching? = voiceHistory else {
                // The user left the meeting while it ran: nothing they cannot see or undo may stay written.
                if !sweep.isEmpty { try? await store.undo(sweep.undo) }
                return
            }
            pastVoiceSweepUndo = sweep.undo
            voiceHistory = sweep.isEmpty ? .none(person) : .found(person, sweep.matches.map { PastVoiceRow(match: $0) })
        } catch {
            voiceHistory = nil
            present(String(localized: "Couldn’t look in earlier meetings", comment: "Alert title: looking for a saved voice in earlier meetings failed"), error)
        }
    }

    func dismissVoiceHistory() {
        voiceHistory = nil
        reviewingPastVoices = false
    }

    /// Opens the review of what the search found.
    func reviewPastVoices() {
        if case .found? = voiceHistory { reviewingPastVoices = true }
    }

    /// Takes back every suggestion the search made. Only while nothing was answered: later, each answer has its own Undo.
    func undoPastVoiceSearch() async {
        guard case .found(_, let rows)? = voiceHistory, rows.allSatisfy({ $0.decision == .pending }), let undo = pastVoiceSweepUndo else { return }
        do {
            try await store.undo(undo)
            pastVoiceSweepUndo = nil
            voiceHistory = nil
            reviewingPastVoices = false
        } catch {
            present(String(localized: "Couldn’t undo the change", comment: "Alert title: taking back a speaker edit failed"), error)
        }
    }

    /// The user's answer for one earlier meeting: Yes names the speaker (an ordinary assignment by the user), No is
    /// remembered for that meeting.
    func answerPastVoice(speakerID: Int64, accept: Bool) async {
        guard case .found(let person, var rows)? = voiceHistory, let index = rows.firstIndex(where: { $0.id == speakerID }),
              rows[index].decision == .pending else { return }
        noteActivity()
        do {
            if accept {
                pastVoiceUndos[speakerID] = try await store.assignSpeaker(speakerID, toEntity: person.entityID)
                if let llm { Task { await llm.speakersChanged(meetingID: rows[index].match.meetingID) } }
            } else {
                pastVoiceUndos[speakerID] = try await store.rejectSuggestion(speakerID: speakerID)
            }
            rows[index].decision = accept ? .accepted : .rejected
            voiceHistory = .found(person, rows)
        } catch {
            present(String(localized: "Couldn’t change the speaker", comment: "Alert title: a speaker edit failed"), error)
        }
    }

    /// Takes back the answer for one earlier meeting: the speaker is a suggestion again.
    func undoPastVoiceAnswer(speakerID: Int64) async {
        guard case .found(let person, var rows)? = voiceHistory, let index = rows.firstIndex(where: { $0.id == speakerID }),
              rows[index].decision != .pending, let undo = pastVoiceUndos[speakerID] else { return }
        do {
            try await store.undo(undo)
            if let llm { Task { await llm.speakersChanged(meetingID: rows[index].match.meetingID) } }
            pastVoiceUndos[speakerID] = nil
            rows[index].decision = .pending
            voiceHistory = .found(person, rows)
        } catch {
            present(String(localized: "Couldn’t undo the change", comment: "Alert title: taking back a speaker edit failed"), error)
        }
    }
}
