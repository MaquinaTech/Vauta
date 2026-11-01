// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import Observation

/// Settings → Models → Your templates: the minutes templates the person wrote. Their names and instructions are in the encrypted
/// store and wait for Touch ID, like the Context; the default template goes back to General when its template is gone.
@MainActor
@Observable
final class MinutesTemplatesModel {
    private(set) var templates: [CustomMinutesTemplate] = []
    /// Read while unlocked: an empty list then means there are none.
    private(set) var loaded = false
    private(set) var failure: String?
    /// The template open in the editor sheet.
    var editing: MinutesTemplateDraft?
    /// The template waiting for the confirmation of its deletion.
    var pendingDelete: CustomMinutesTemplate?

    func reload(_ recorder: RecorderModel) async {
        guard recorder.historyUnlocked, let store = recorder.store else {
            templates = []
            loaded = false
            return
        }
        do {
            templates = try await store.customMinutesTemplates()
            loaded = true
            failure = nil
        } catch {
            failure = error.localizedDescription
            return
        }
        // A default whose template is gone (deleted, or everything erased) is the general template again.
        if case .custom(let id) = recorder.preferences.minutesTemplate, !templates.contains(where: { $0.id == id }) {
            recorder.preferences.minutesTemplate = .general
        }
    }

    /// Meetings locked: the names go and the editor closes. What was typed is saved, as the Context saves its open form.
    func locked(_ store: MeetingStore?) {
        if let draft = editing, draft.canSave, let store {
            Task { _ = try? await store.saveCustomMinutesTemplate(id: draft.templateID, name: draft.name, instructions: draft.instructions) }
        }
        editing = nil
        pendingDelete = nil
        templates = []
        loaded = false
    }

    func add() {
        editing = MinutesTemplateDraft()
    }

    func edit(_ template: CustomMinutesTemplate) {
        editing = MinutesTemplateDraft(template)
    }

    /// Saves the open draft and closes the editor; on a failure the editor stays open with the reason.
    func save(_ recorder: RecorderModel) async {
        guard var draft = editing, let store = recorder.store else { return }
        do {
            _ = try await store.saveCustomMinutesTemplate(id: draft.templateID, name: draft.name, instructions: draft.instructions)
            editing = nil
        } catch {
            draft.failure = error.localizedDescription
            editing = draft
            return
        }
        await changed(recorder)
    }

    func delete(_ template: CustomMinutesTemplate, _ recorder: RecorderModel) async {
        pendingDelete = nil
        editing = nil
        guard let store = recorder.store else { return }
        do {
            try await store.deleteCustomMinutesTemplate(template.id)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        await changed(recorder)
    }

    /// The menus in Meetings and the recurring meetings in Context offer the templates too.
    private func changed(_ recorder: RecorderModel) async {
        await reload(recorder)
        recorder.history?.minutesTemplatesChanged()
        await recorder.context?.reload()
    }
}

/// A template in the editor: a new one has no `templateID` yet.
struct MinutesTemplateDraft: Identifiable, Equatable {
    let id = UUID()
    var templateID: Int64?
    var name = ""
    var instructions = ""
    var failure: String?

    init() {}

    init(_ template: CustomMinutesTemplate) {
        templateID = template.id
        name = template.name
        instructions = template.instructions
    }

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
