// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import Observation

/// Settings → Speakers → Saved voices: who has a voice saved on this Mac, deleting one person's or all of them, and the
/// reminder for voices that have had no suggestion accepted in a year (Vauta only asks; the user decides).
@MainActor
@Observable
final class SavedVoicesModel {
    private(set) var voices: [SavedVoice] = []
    /// Voices unused for `VoiceProfileThresholds.unusedMonths`: proposed for deletion.
    private(set) var unused: [SavedVoice] = []
    private(set) var loaded = false
    private(set) var failure: String?
    /// A voice waiting for the confirmation of its deletion.
    var pendingDelete: SavedVoice?
    var confirmingDeleteAll = false
    var confirmingDeleteUnused = false

    /// The clock the reminder uses (the snapshot scenes move it).
    @ObservationIgnored var clock: () -> Date = { .now }

    /// Reads the saved voices (names and counts; never the fingerprints).
    func reload(_ recorder: RecorderModel) async {
        guard let store = recorder.store else { return }
        let now = clock()
        do {
            voices = try await store.savedVoices()
            unused = try await store.unusedSavedVoices(now: now)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        loaded = true
    }

    /// The reminder is shown: there are unused voices and the user has not said “Keep” recently.
    func showsReminder(_ preferences: Preferences) -> Bool {
        !unused.isEmpty && preferences.voiceReminderSnoozedUntil <= clock().timeIntervalSince1970
    }

    func delete(_ voice: SavedVoice, _ recorder: RecorderModel) async {
        pendingDelete = nil
        await run(recorder) { _ = try await $0.deleteVoiceProfiles(entityID: voice.entityID) }
    }

    func deleteAll(_ recorder: RecorderModel) async {
        confirmingDeleteAll = false
        await run(recorder) { _ = try await $0.deleteAllVoiceProfiles() }
    }

    func deleteUnused(_ recorder: RecorderModel) async {
        confirmingDeleteUnused = false
        let people = unused.map(\.entityID)
        await run(recorder) { store in for id in people { _ = try await store.deleteVoiceProfiles(entityID: id) } }
    }

    /// “Keep for Now”: the reminder comes back in three months.
    func keepUnused(_ preferences: Preferences) {
        let now = clock()
        preferences.voiceReminderSnoozedUntil = (Calendar.current.date(byAdding: .month, value: 3, to: now) ?? now).timeIntervalSince1970
    }

    /// Recognition was turned off: the numeric summaries kept with meetings for “Remember this voice” go. Saved voices stay.
    func recognitionTurnedOff(_ recorder: RecorderModel) async {
        guard let store = recorder.store else { return }
        _ = try? await store.deleteKeptSpeakerVoices()
    }

    private func run(_ recorder: RecorderModel, _ work: (MeetingStore) async throws -> Void) async {
        guard let store = recorder.store else { return }
        do {
            try await work(store)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        await reload(recorder)
        recorder.history?.voicesChanged()
    }
}
