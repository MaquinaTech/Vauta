// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// What a speaker popover is about: a transcript line (all actions) or a speaker in "Who spoke" (the ones that
/// need no line).
enum SpeakerPopoverTarget: Hashable {
    case line(Int64)
    case speaker(Int64)
}

/// Editing the speakers of the open meeting. The logic is `SpeakerEditor` (VautaCore); this adds the window's part:
/// registering with the undo manager, reloading what the views show and reporting errors.
extension MeetingsModel {
    var speakerEditor: SpeakerEditor { SpeakerEditor(store: store) }

    /// The meeting has speaker data, or the user turned separating off, or it is being recorded with separation on:
    /// the switch is worth showing.
    var offersSpeakerSwitch: Bool {
        !speakers.isEmpty || speakersOff || separationTouched || (isActive && (preferences?.separateSpeakers ?? false))
    }

    /// Applies an edit. Errors reach the caller, which knows whether to ask the user something (an ambiguous name).
    @discardableResult
    func applySpeakerAction(_ action: SpeakerAction) async throws -> SpeakerEditOutcome {
        noteActivity()
        await speakerUndoQueue?.value
        // Accepting “Is this Ana?” confirms a saved voice: the search of earlier meetings is offered afterwards.
        var confirmed: VoiceHistoryPerson?
        if case .assign(let speakerID, let entity?) = action, let speaker = roster.entry(speakerID)?.speaker,
           speaker.source == .suggested, speaker.entityID == entity, let name = speaker.entityName {
            confirmed = VoiceHistoryPerson(entityID: entity, name: MeetingStore.displayName(name, isSelf: speaker.entityIsSelf), isSelf: speaker.entityIsSelf)
        }
        let outcome: SpeakerEditOutcome
        do {
            outcome = try await speakerEditor.apply(action)
        } catch {
            // The speaker or the line may be gone (merged or split elsewhere): show what is there now.
            await reloadSpeakers()
            throw error
        }
        let token = registerUndo(of: outcome)
        if outcome.kind == .turnOff { pendingSpeakerRemoval = (token, outcome) }
        await reloadSpeakers()
        if let confirmed { await offerVoiceHistory(entityID: confirmed.entityID, name: confirmed.name, isSelf: confirmed.isSelf) }
        return outcome
    }

    /// Applies an edit and shows an alert when it fails.
    func performSpeakerAction(_ action: SpeakerAction) async {
        do {
            try await applySpeakerAction(action)
        } catch {
            present(String(localized: "Couldn’t change the speaker", comment: "Alert title: a speaker edit failed"), error)
        }
    }

    /// Edit ▸ Undo for a speaker edit. There is no Redo: the store restores, it does not replay.
    private func registerUndo(of outcome: SpeakerEditOutcome) -> UUID {
        let token = UUID()
        guard let undoManager else { return token }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                if model.spentSpeakerUndos.remove(token) != nil { return }
                if model.pendingSpeakerRemoval?.token == token { model.pendingSpeakerRemoval = nil }
                // One at a time, in the order pressed: a restore may depend on the one before it.
                let previous = model.speakerUndoQueue
                model.speakerUndoQueue = Task {
                    await previous?.value
                    await model.undoSpeakerEdit(outcome)
                }
            }
        }
        undoManager.setActionName(outcome.kind.actionName)
        return token
    }

    func undoSpeakerEdit(_ outcome: SpeakerEditOutcome) async {
        do {
            try await speakerEditor.undo(outcome)
        } catch {
            present(String(localized: "Couldn’t undo the change", comment: "Alert title: taking back a speaker edit failed"), error)
        }
        await reloadSpeakers()
        if !speakers.isEmpty { speakersRemovedHere = false }
    }

    /// The highlighted passage has a speaker whose options can be opened.
    var canOpenSpeakerOptionsOfHighlight: Bool {
        mode == .meetings && tab == .transcript && highlightedSegment?.speaker?.id != nil
    }

    /// Opens the popover of the highlighted passage's speaker (the menu item for keyboard users).
    func openSpeakerOptionsOfHighlight() {
        guard canOpenSpeakerOptionsOfHighlight, let id = highlightedSegment?.id else { return }
        speakerPopover = .line(id)
    }

    /// Undoes the removal of the meeting's speakers, and only that. When the removal is still the latest step of the
    /// undo stack it is taken from there; otherwise (the user typed in a field since, which adds steps of its own) it
    /// is undone directly and its entry is left spent, so nothing else is touched. If restoring fails the alert says so
    /// and nothing more is undone.
    func bringBackSpeakers() async {
        guard let pending = pendingSpeakerRemoval else { return }
        await speakerUndoQueue?.value
        if let undoManager, undoManager.canUndo, undoManager.undoActionName == pending.outcome.kind.actionName {
            undoManager.undo()
            await speakerUndoQueue?.value
        } else {
            spentSpeakerUndos.insert(pending.token)
            pendingSpeakerRemoval = nil
            await undoSpeakerEdit(pending.outcome)
        }
        if !speakers.isEmpty { speakersRemovedHere = false }
    }

    /// The edits of one meeting make no sense for another: Undo starts over when the selection changes.
    func forgetSpeakerEdits() {
        undoManager?.removeAllActions(withTarget: self)
        speakerPopover = nil
        voiceConsent = nil
        voiceHistory = nil
        reviewingPastVoices = false
        confirmingSpeakersOff = false
        speakersRemovedHere = false
        separationTouched = false
        pendingSpeakerRemoval = nil
        spentSpeakerUndos = []
    }

    /// Reads the transcript and the speakers again after an edit (names, lines and talk time changed), and the
    /// search results that show a speaker's name.
    func reloadSpeakers() async {
        guard let id = selectedID else { return }
        // Search and Ask read who said what: the meeting's chunks are embedded again when their text changed.
        // Not awaited: the stale-chunk check hashes the whole transcript and the service may be busy with a job.
        if let llm { Task { await llm.speakersChanged(meetingID: id) } }
        do {
            let segments = try await store.segments(of: id)
            let speakers = try await store.speakers(of: id)
            let off = try await store.speakersOff(meetingID: id)
            let kept = try await store.speakersWithKeptVoice(meetingID: id)
            guard selectedID == id else { return }
            transcript = segments
            keptVoices = kept
            self.speakers = speakers
            speakersOff = off
            roster = SpeakerRoster(speakers: speakers, segments: segments)
            if !hits.isEmpty { await runSearch() }
        } catch {
            present(String(localized: "Couldn’t open this meeting", comment: "Alert title"), error)
        }
    }

    // MARK: What the popover offers

    /// The people the user can pick for a speaker: this meeting's calendar attendees on top as suggestions, then the
    /// rest of the context's people.
    func speakerCandidates(for speaker: MeetingSpeaker) -> (suggested: [Entity], people: [Entity]) {
        SpeakerCandidates.split(attendees: attendees, people: entities, for: speaker)
    }

    /// Turns speaker separation off (after the confirmation) or on.
    func setSpeakerSeparation(off: Bool) async {
        guard let id = selectedID else { return }
        separationTouched = true
        if off, !speakers.isEmpty { speakersRemovedHere = true }
        await performSpeakerAction(off ? .turnOffSeparation(meeting: id) : .turnOnSeparation(meeting: id))
    }
}
