// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What the user can do to the speakers of a meeting from the transcript or the summary.
public enum SpeakerAction: Sendable, Equatable {
    /// Says who a speaker is: an existing person, or nobody (back to "Speaker k").
    case assign(speaker: Int64, entity: Int64?)
    /// Types who a speaker is: the person with that name, or a new one.
    case name(speaker: Int64, name: String)
    /// The diarizer split one person in two: `source` joins `target`.
    case merge(source: Int64, into: Int64)
    /// One line was said by another existing speaker of its channel.
    case moveLine(segment: Int64, to: Int64)
    /// One line was said by somebody the diarizer did not find: a new speaker takes it.
    case moveLineToNewSpeaker(segment: Int64, meeting: Int64)
    /// The diarizer put two people in one speaker: this line and the rest of its turn go to a new speaker.
    case splitFromHere(segment: Int64, meeting: Int64)
    /// "Is this Ana?" answered no: the suggestion goes, and it is not made again for this meeting.
    case rejectSuggestion(speaker: Int64)
    /// "Don't separate speakers in this meeting": speakers go, and none are found again.
    case turnOffSeparation(meeting: Int64)
    /// The switch goes back. Speakers that were removed are not found again (use Undo right after).
    case turnOnSeparation(meeting: Int64)
}

/// The kind of edit, for the Edit menu ("Undo Merge Speakers").
public enum SpeakerEditKind: Sendable, Equatable {
    case name, clearName, merge, moveLine, split, turnOff, turnOn, rejectSuggestion

    public var actionName: String {
        switch self {
        case .name: String(localized: "Name Speaker", comment: "Edit menu: the name of the undoable action that names a speaker, as in “Undo Name Speaker”")
        case .clearName: String(localized: "Clear Speaker Name", comment: "Edit menu: the name of the undoable action that removes a speaker's name, as in “Undo Clear Speaker Name”")
        case .merge: String(localized: "Merge Speakers", comment: "Edit menu: the name of the undoable action that merges two speakers, as in “Undo Merge Speakers”")
        case .moveLine: String(localized: "Move Line to Another Speaker", comment: "Edit menu: the name of the undoable action that gives a transcript line to another speaker, as in “Undo Move Line to Another Speaker”")
        case .split: String(localized: "Split Speaker", comment: "Edit menu: the name of the undoable action that splits one speaker in two, as in “Undo Split Speaker”")
        case .turnOff: String(localized: "Don’t Separate Speakers", comment: "Edit menu: the name of the undoable action that stops separating speakers in a meeting, as in “Undo Don’t Separate Speakers”; also the button that confirms it")
        case .rejectSuggestion: String(localized: "Reject Voice Suggestion", comment: "Edit menu: the name of the undoable action that answers “Is this Ana?” with no, as in “Undo Reject Voice Suggestion”")
        case .turnOn: String(localized: "Separate Speakers Again", comment: "Edit menu: the name of the undoable action that allows separating speakers in a meeting again, as in “Undo Separate Speakers Again”")
        }
    }
}

/// What an edit did: its kind and what takes it back. Holds no meeting text and no voice data.
public struct SpeakerEditOutcome: Sendable {
    enum Step: Sendable {
        case restore(SpeakerUndo)
        case setOff(Bool, meetingID: Int64)
    }

    public let kind: SpeakerEditKind
    /// Steps to take it back, in the order they run.
    let steps: [Step]
    /// The person a naming used (an existing one or the one it created).
    public let entityID: Int64?
}

/// Applies the user's speaker edits to the store and takes them back. The Meetings window calls this and
/// registers `undo` with the window's undo manager, so Edit ▸ Undo and ⌘Z walk back through the edits.
/// Every edit is persisted by the store before it returns.
public struct SpeakerEditor: Sendable {
    public let store: MeetingStore

    public init(store: MeetingStore) {
        self.store = store
    }

    @discardableResult
    public func apply(_ action: SpeakerAction) async throws -> SpeakerEditOutcome {
        switch action {
        case .assign(let speaker, let entity):
            let undo = try await store.assignSpeaker(speaker, toEntity: entity)
            return SpeakerEditOutcome(kind: entity == nil ? .clearName : .name, steps: [.restore(undo)], entityID: entity)
        case .name(let speaker, let name):
            let result = try await store.renameSpeaker(speaker, to: name)
            return SpeakerEditOutcome(kind: .name, steps: [.restore(result.undo)], entityID: result.entityID)
        case .merge(let source, let target):
            let undo = try await store.mergeSpeaker(source, into: target)
            return SpeakerEditOutcome(kind: .merge, steps: [.restore(undo)], entityID: nil)
        case .moveLine(let segment, let speaker):
            let undo = try await store.reassignSegment(segment, toSpeaker: speaker)
            return SpeakerEditOutcome(kind: .moveLine, steps: [.restore(undo)], entityID: nil)
        case .moveLineToNewSpeaker(let segment, let meeting):
            guard let line = try await store.segments(of: meeting, echoes: true).first(where: { $0.id == segment }) else { throw MeetingStore.segmentGone }
            let (added, addUndo) = try await store.addSpeaker(meetingID: meeting, channel: line.channel)
            do {
                let undo = try await store.reassignSegment(segment, toSpeaker: added.id)
                return SpeakerEditOutcome(kind: .moveLine, steps: [.restore(undo), .restore(addUndo)], entityID: nil)
            } catch {
                try? await store.undo(addUndo)
                throw error
            }
        case .splitFromHere(let segment, let meeting):
            let segments = try await store.segments(of: meeting, echoes: true)
            let turn = SpeakerRoster.restOfTurn(from: segment, in: segments)
            guard let first = turn.first, let speakerID = first.speaker?.id, let speaker = try await store.speaker(speakerID) else {
                throw MeetingStore.segmentGone
            }
            let (added, addUndo) = try await store.addSpeaker(meetingID: meeting, channel: speaker.channel)
            var steps: [SpeakerEditOutcome.Step] = []
            do {
                for line in turn { steps.insert(.restore(try await store.reassignSegment(line.id, toSpeaker: added.id)), at: 0) }
            } catch {
                for case .restore(let undo) in steps { try? await store.undo(undo) }
                try? await store.undo(addUndo)
                throw error
            }
            return SpeakerEditOutcome(kind: .split, steps: steps + [.restore(addUndo)], entityID: nil)
        case .rejectSuggestion(let speaker):
            let undo = try await store.rejectSuggestion(speakerID: speaker)
            return SpeakerEditOutcome(kind: .rejectSuggestion, steps: [.restore(undo)], entityID: nil)
        case .turnOffSeparation(let meeting):
            let wasOff = try await store.speakersOff(meetingID: meeting)
            try await store.setSpeakersOff(true, meetingID: meeting)
            let cleared: SpeakerUndo
            do {
                cleared = try await store.clearSpeakers(meetingID: meeting)
            } catch {
                // Like the other compound edits: a failed second step leaves the first one undone, with nothing to undo.
                try? await store.setSpeakersOff(wasOff, meetingID: meeting)
                throw error
            }
            // Undo turns the switch back first (a meeting with the switch on refuses to bring speakers back), then restores.
            return SpeakerEditOutcome(kind: .turnOff, steps: [.setOff(wasOff, meetingID: meeting), .restore(cleared)], entityID: nil)
        case .turnOnSeparation(let meeting):
            let wasOff = try await store.speakersOff(meetingID: meeting)
            try await store.setSpeakersOff(false, meetingID: meeting)
            return SpeakerEditOutcome(kind: .turnOn, steps: [.setOff(wasOff, meetingID: meeting)], entityID: nil)
        }
    }

    /// Takes an edit back. Fails, changing nothing more, when the data has moved on so that it can't be restored.
    public func undo(_ outcome: SpeakerEditOutcome) async throws {
        for step in outcome.steps {
            switch step {
            case .restore(let record): try await store.undo(record)
            case .setOff(let off, let meetingID): try await store.setSpeakersOff(off, meetingID: meetingID)
            }
        }
    }
}
