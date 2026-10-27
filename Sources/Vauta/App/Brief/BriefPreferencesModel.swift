// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import Observation

/// The brief's switches (Settings → Calendar & Reminders) and the Reminders permission they depend on. Non-sensitive: switches and
/// opaque list identifiers only (see `BriefPreferences`). Reminders are off until the person turns them on and allows them.
@MainActor
@Observable
final class BriefPreferencesModel {
    /// Turning the brief on ends the one-time offer to set it up.
    var enabled: Bool { didSet { if enabled { hintSeen = true }; save(); changed() } }
    /// Minutes before the meeting; 0 is Off (no notification; the panel card still appears shortly before the meeting).
    var leadMinutes: Int { didSet { save(); changed() } }
    var inPerson: Bool { didSet { save(); changed() } }
    var readInvitationNotes: Bool { didSet { save(); changed() } }
    var remindersEnabled: Bool {
        didSet {
            save()
            if remindersEnabled { loadLists() } else { forgetLists() }
            changed()
        }
    }
    var reminderListIDs: Set<String> { didSet { save(); changed() } }
    /// The one-line offer in the panel was seen (or dismissed).
    var hintSeen: Bool { didSet { save() } }
    var remindersHintDismissed: Bool { didSet { save() } }

    private(set) var remindersAccess: BriefReminderAccess
    private(set) var reminderLists: [BriefReminderList] = []

    /// Called after a change that affects what is built or when it is announced.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var reminders: EventKitReminderSource?
    @ObservationIgnored private var restoring = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = BriefPreferences(defaults: defaults)
        enabled = stored.enabled
        leadMinutes = stored.leadMinutes
        inPerson = stored.inPerson
        readInvitationNotes = stored.readInvitationNotes
        remindersEnabled = stored.remindersEnabled
        reminderListIDs = stored.reminderListIDs
        hintSeen = stored.hintSeen
        remindersHintDismissed = stored.remindersHintDismissed
        remindersAccess = .notDetermined
    }

    /// The reader of the lists, set once EventKit may be used (never in a rendering).
    func attach(_ source: EventKitReminderSource) {
        reminders = source
        remindersAccess = source.access
    }

    var snapshot: BriefPreferences {
        var value = BriefPreferences()
        value.enabled = enabled
        value.leadMinutes = leadMinutes
        value.inPerson = inPerson
        value.readInvitationNotes = readInvitationNotes
        value.remindersEnabled = remindersEnabled
        value.reminderListIDs = reminderListIDs
        value.hintSeen = hintSeen
        value.remindersHintDismissed = remindersHintDismissed
        return value
    }

    private func save() {
        guard !restoring else { return }
        snapshot.write(to: defaults)
    }

    private func changed() {
        guard !restoring else { return }
        onChange?()
    }

    /// A restore wrote the keys: read them again (the reminder switch and lists are this Mac's own and are not in a backup).
    func reload() {
        restoring = true
        defer { restoring = false }
        let stored = BriefPreferences(defaults: defaults)
        enabled = stored.enabled
        leadMinutes = stored.leadMinutes
        inPerson = stored.inPerson
        readInvitationNotes = stored.readInvitationNotes
        onChange?()
    }

    // MARK: Reminders permission

    /// Access was never asked for: the system prompt can still be shown. Once it was answered, only System Settings can change it.
    var canRequestRemindersAccess: Bool { remindersAccess == .notDetermined }

    func requestRemindersAccess() async {
        guard let reminders else { return }
        _ = await reminders.requestAccess()
        remindersAccess = reminders.access
        loadLists()
        changed()
    }

    /// The lists to choose from (only while the Settings pane is open).
    func loadLists() {
        guard let reminders else { return }
        remindersAccess = reminders.access
        guard remindersEnabled, remindersAccess == .granted else { reminderLists = []; return }
        Task {
            let lists = await reminders.lists()
            reminderLists = lists
        }
    }

    func forgetLists() {
        if reminders != nil { reminderLists = [] }
    }

    func setList(_ id: String, chosen: Bool) {
        if chosen { reminderListIDs.insert(id) } else { reminderListIDs.subtract([id]) }
    }

    #if VAUTA_DIAGNOSTICS
    /// For `Vauta render-ui`: every switch at its default, whatever this Mac's preferences hold (nothing is written).
    func installSnapshotDefaults(enabled: Bool = true, lead: Int = BriefEventSelector.defaultLeadMinutes, inPerson: Bool = true,
                                 notes: Bool = true, hintSeen: Bool = true) {
        restoring = true
        defer { restoring = false }
        self.enabled = enabled
        leadMinutes = lead
        self.inPerson = inPerson
        readInvitationNotes = notes
        remindersEnabled = false
        reminderListIDs = []
        self.hintSeen = hintSeen
        remindersHintDismissed = false
        remindersAccess = .notDetermined
        reminderLists = []
        reminders = nil
    }

    /// For `Vauta render-ui`: the pane as it looks with this access and these lists (nothing reads EventKit).
    func installSnapshotState(remindersEnabled: Bool, access: BriefReminderAccess, lists: [BriefReminderList], chosen: Set<String>) {
        restoring = true
        defer { restoring = false }
        remindersAccess = access
        reminderLists = lists
        self.remindersEnabled = remindersEnabled
        reminderListIDs = chosen
        reminders = nil
    }
    #endif
}
