// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// People, projects and clients: save, delete, merge, calendar people, relations.
extension ContextModel {
    // MARK: Save

    @discardableResult
    func saveEntity() async -> Bool {
        let form = entityForm
        // An empty name is reported by the store, so a Save from the
        // unsaved-changes prompt never fails silently.
        let draft = form.draft(editing: selectedEntity)
        isWorking = true
        defer { isWorking = false }
        let id: Int64
        do {
            id = try await store.saveEntity(draft)
        } catch {
            var failure = ContextFailure(error, during: .saveEntity(form.kind))
            if case KnowledgeError.emailInUse(let email) = error {
                failure.action = emailConflictAction(email: email, form: form)
            }
            self.failure = failure
            await reload()
            return false
        }
        await reload()
        if let e = entity(id) { reveal(e) }
        open(.entity(id))
        return true
    }

    /// Offer to merge with the person who already has the email: merge the
    /// stored entry, or open that person with the new entry's names as aliases.
    private func emailConflictAction(email: String, form: EntityForm) -> ContextFailure.Action? {
        guard let owner = entities.first(where: { $0.email == email && $0.id != form.id }) else { return nil }
        if let source = entity(form.id) {
            return .merge(source: source, into: owner.id)
        }
        return .useExisting(owner, aliases: AliasList.adding(form.aliasInput, to: [form.name] + form.aliases, name: owner.name))
    }

    /// Runs the action offered by an error alert.
    func performFailureAction(_ action: ContextFailure.Action) async {
        failure = nil
        switch action {
        case .merge(let source, let target):
            await requestMerge(of: source, into: target)
        case .useExisting(let owner, let aliases):
            reveal(owner)
            open(.entity(owner.id))
            entityForm.aliases = AliasList.adding(aliases.joined(separator: "\n"), to: entityForm.aliases, name: entityForm.name)
        }
    }

    // MARK: Calendar people

    /// Keeps a person suggested by the calendar. The open form is saved as is.
    func confirm(_ e: Entity) async {
        if selection == .entity(e.id) {
            await saveEntity()
            return
        }
        if await perform(.confirm, { try await store.saveEntity(EntityDraft(e)) }) {
            await reload()
        }
    }

    /// Removes a person suggested by the calendar; asks first when something
    /// already points to them (mentions, tasks, relations…).
    func dismiss(_ e: Entity) async {
        guard let footprint = await loadFootprint(of: e, for: .dismiss) else { return }
        let summary = DeletionSummary(footprint: footprint)
        if summary.mentions + summary.relations + summary.mergedEntries > 0 || summary.detachesAnything {
            deleteRequest = DeleteRequest(entity: e, summary: summary, isDismissal: true)
        } else {
            await delete(e, operation: .dismiss)
        }
    }

    // MARK: Delete

    /// Asks before removing `item`: a sheet for entities (or an immediate
    /// dismissal of an unused calendar person), a dialog for terms and series.
    /// The self entity cannot be deleted.
    func requestRemoval(of item: ContextSelection?) async {
        switch item {
        case .entity(let id):
            guard let e = entity(id), !e.isSelf else { return }
            if e.confirmed { await requestDelete(e) } else { await dismiss(e) }
        case .term(let id): termToDelete = glossary.first { $0.id == id }
        case .series(let id): seriesToDelete = series.first { $0.id == id }
        case nil: break
        }
    }

    func requestDelete(_ e: Entity) async {
        guard let footprint = await loadFootprint(of: e, for: .deleteEntity) else { return }
        deleteRequest = DeleteRequest(entity: e, summary: DeletionSummary(footprint: footprint), isDismissal: false)
    }

    func confirmDelete() async {
        guard let request = deleteRequest else { return }
        deleteRequest = nil
        await delete(request.entity, operation: request.isDismissal ? .dismiss : .deleteEntity)
    }

    private func delete(_ e: Entity, operation: ContextOperation) async {
        if await perform(operation, { try await store.deleteEntity(e.id) }) {
            if selection == .entity(e.id) { close() }
            await reload()
        }
    }

    // MARK: Merge

    /// Merging `e` would discard the edits in its open form.
    func mergeBlockedByEdits(_ e: Entity) -> Bool {
        selection == .entity(e.id) && hasUnsavedChanges
    }

    /// Opens the merge sheet for `source`, with `target` preselected if given.
    func requestMerge(of source: Entity, into target: Int64? = nil) async {
        guard let footprint = await loadFootprint(of: source, for: .merge) else { return }
        let preselected = target ?? (mergeCandidates(for: source).count == 1 ? mergeCandidates(for: source).first?.id : nil)
        mergeRequest = MergeRequest(source: source, footprint: footprint, targetID: preselected)
    }

    /// Entries `source` can be merged into: confirmed ones of the same kind.
    func mergeCandidates(for source: Entity) -> [Entity] {
        entities.filter { $0.id != source.id && $0.kind == source.kind && $0.confirmed }
    }

    func mergeSummary(for request: MergeRequest) -> MergeSummary? {
        guard let target = entity(request.targetID) else { return nil }
        return MergeSummary(source: request.source, footprint: request.footprint, target: target)
    }

    func confirmMerge() async {
        guard let request = mergeRequest, let target = request.targetID else { return }
        mergeRequest = nil
        // Follow the merge to the target only when that loses no edits: the
        // source was open (it is gone now), or the open form is unchanged.
        let showTarget = selection == .entity(request.source.id) || !hasUnsavedChanges
        if await perform(.merge, { try await store.mergeEntity(request.source.id, into: target) }) {
            await reload()
            if showTarget, let e = entity(target) {
                reveal(e)
                open(.entity(target))
            }
        }
    }

    private func loadFootprint(of e: Entity, for operation: ContextOperation) async -> EntityFootprint? {
        do {
            guard let footprint = try await store.footprint(of: e.id) else { throw KnowledgeError.entityGone }
            return footprint
        } catch {
            failure = ContextFailure(error, during: operation)
            await reload()
            return nil
        }
    }

    // MARK: Relations

    func addRelation() async {
        guard case .entity(let id) = selection, let target = relationTarget else { return }
        if await perform(.addRelation, { try await store.addRelation(NodeRef(.entity, id), relationKind, NodeRef(.entity, target)) }) {
            relationTarget = nil
            loadDetail(of: id)
        }
    }

    func removeRelation(_ r: RelationInfo) async {
        guard case .entity(let id) = selection else { return }
        if await perform(.removeRelation, { try await store.deleteRelation(r.id) }) {
            loadDetail(of: id)
        }
    }

    /// Origin of each alias of the selected entity (keyed by alias text).
    var aliasOrigins: [String: AliasOrigin] {
        Dictionary((footprint?.aliases ?? []).map { ($0.text, $0.origin) }, uniquingKeysWith: { a, _ in a })
    }
}
