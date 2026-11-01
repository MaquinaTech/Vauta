// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import Observation

/// State of the context editor (Settings → Context): people, projects and
/// clients, glossary and recurring meetings. Everything is stored in the
/// encrypted store; this model only holds the lists and the open form.
///
/// Mutations live in the `ContextModel+…` extensions; properties they set
/// are internal for that reason, but views only change them through methods
/// (or bind to the forms).
@MainActor
@Observable
final class ContextModel {
    // MARK: Lists

    var section: ContextSection = .people
    /// Kind shown in Projects & Clients (nil = every kind).
    var kindFilter: EntityKind?
    var searchText = ""
    var entities: [Entity] = []
    var glossary: [GlossaryTerm] = []
    var series: [MeetingSeries] = []
    var seriesMeetingCounts: [Int64: Int] = [:]
    /// The minutes templates the person wrote, offered for a recurring meeting.
    var customTemplates: [CustomMinutesTemplate] = []
    var hasLoaded = false

    // MARK: Detail

    var selection: ContextSelection?
    /// A new, not yet saved item is open in the current section.
    var isCreating = false
    var entityForm = EntityForm()
    var entityOriginal = EntityForm()
    var termForm = TermForm()
    var termOriginal = TermForm()
    var seriesForm = SeriesForm()
    var seriesOriginal = SeriesForm()
    /// Relations and footprint of the selected entity.
    var relations: [RelationInfo] = []
    var footprint: EntityFootprint?
    var relationKind: RelationKind = .worksOn
    var relationTarget: Int64?

    // MARK: Confirmations and feedback

    /// Held back while the user decides what to do with unsaved changes.
    var pendingNavigation: ContextNavigation?
    var mergeRequest: MergeRequest?
    var deleteRequest: DeleteRequest?
    var termToDelete: GlossaryTerm?
    var seriesToDelete: MeetingSeries?
    var failure: ContextFailure?
    var isWorking = false
    var reanalysis = ReanalysisProgress()
    var isCancellingReanalysis = false
    /// The finished (or stopped) run, shown once.
    var reanalysisReport: ReanalysisProgress?

    @ObservationIgnored let store: MeetingStore
    @ObservationIgnored var detailTask: Task<Void, Never>?
    @ObservationIgnored var reanalysisTask: Task<Void, Never>?

    init(store: MeetingStore) {
        self.store = store
    }

    // MARK: Derived lists

    /// Confirmed entities of the section, filtered by kind and search.
    var visibleEntities: [Entity] {
        MeetingsModel.selfFirst(entities.filter { e in
            e.confirmed && section.kinds.contains(e.kind) && (kindFilter == nil || e.kind == kindFilter) && matches(e)
        })
    }

    /// Calendar attendees waiting to be confirmed (People only).
    var visiblePending: [Entity] {
        section == .people ? entities.filter { !$0.confirmed && matches($0) } : []
    }

    var pendingCount: Int { entities.count(where: { !$0.confirmed }) }

    var visibleTerms: [GlossaryTerm] {
        glossary.filter { matches([$0.term, $0.expansion, $0.note]) }
    }

    var visibleSeries: [MeetingSeries] {
        series.filter { matches([$0.titlePattern]) }
    }

    /// The current section has nothing to list (after search and filters).
    var isListEmpty: Bool {
        switch section {
        case .people, .work: visibleEntities.isEmpty && visiblePending.isEmpty
        case .glossary: visibleTerms.isEmpty
        case .series: visibleSeries.isEmpty
        }
    }

    /// Whether the current section shows nothing because of the search or kind filter.
    var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty || (section == .work && kindFilter != nil)
    }

    /// Confirmed entities other than `id`, for relation and series pickers.
    func confirmedEntities(excluding id: Int64? = nil) -> [Entity] {
        entities.filter { $0.confirmed && $0.id != id }
    }

    func entity(_ id: Int64?) -> Entity? {
        guard let id else { return nil }
        return entities.first { $0.id == id }
    }

    var selectedEntity: Entity? {
        if case .entity(let id) = selection { entity(id) } else { nil }
    }

    private func matches(_ e: Entity) -> Bool {
        matches([e.displayName, e.name, e.email ?? ""] + e.aliases)
    }

    private func matches(_ fields: [String]) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || fields.contains { $0.localizedStandardContains(query) }
    }

    // MARK: Editing state

    /// The detail pane shows a form (an existing item or a new one).
    var isEditing: Bool { selection != nil || isCreating }

    var hasUnsavedChanges: Bool {
        guard isEditing else { return false }
        switch section {
        case .people, .work: return entityForm != entityOriginal
        case .glossary: return termForm != termOriginal
        case .series: return seriesForm != seriesOriginal
        }
    }

    /// Name of the item being edited, for prompts.
    var editingTitle: String {
        switch section {
        case .people, .work: entityForm.name
        case .glossary: termForm.term
        case .series: seriesForm.title
        }
    }

    // MARK: Navigation

    /// Selects, switches section or starts a new item, asking first when
    /// there are unsaved changes.
    func navigate(_ navigation: ContextNavigation) {
        if navigation == .select(selection), !isCreating { return }
        if hasUnsavedChanges {
            pendingNavigation = navigation
        } else {
            apply(navigation)
        }
    }

    /// Answer to the unsaved-changes prompt about `navigation`.
    func resolve(_ navigation: ContextNavigation, save: Bool) async {
        pendingNavigation = nil
        if save {
            guard await saveCurrent() else { return }
        }
        apply(navigation)
    }

    func apply(_ navigation: ContextNavigation) {
        switch navigation {
        case .select(let target):
            if case .entity(let id) = target, let e = entity(id) { reveal(e) }
            open(target)
        case .section(let s):
            close()
            section = s
        case .create: startNew()
        }
    }

    /// Opens an item in the detail pane, discarding the current form.
    func open(_ target: ContextSelection?) {
        // Reopening the same entity keeps its relations on screen until the
        // fresh ones arrive (no flicker after a save or reload).
        let keptRelations = target == selection ? relations : []
        let keptFootprint = target == selection ? footprint : nil
        let sameTarget = target == selection
        close()
        selection = target
        relations = keptRelations
        footprint = keptFootprint
        switch target {
        case .entity(let id):
            guard let e = entity(id) else { selection = nil; return }
            // The form follows the section, so an entity of another section
            // brings its section along.
            let home = ContextSection.containing(e.kind)
            if section != home { section = home }
            entityForm = EntityForm(e)
            entityOriginal = entityForm
            if !sameTarget { relationKind = Self.defaultRelation(for: e.kind) }
            loadDetail(of: id)
        case .term(let id):
            guard let g = glossary.first(where: { $0.id == id }) else { selection = nil; return }
            termForm = TermForm(g)
            termOriginal = termForm
        case .series(let id):
            guard let s = series.first(where: { $0.id == id }) else { selection = nil; return }
            seriesForm = SeriesForm(s)
            seriesOriginal = seriesForm
        case nil:
            break
        }
    }

    /// The relation a new entry most likely has: a person works on something, a project is for a client.
    static func defaultRelation(for kind: EntityKind) -> RelationKind {
        switch kind {
        case .person: .worksOn
        case .project: .forClient
        default: .relatedTo
        }
    }

    /// Closes the detail pane without saving.
    func close() {
        detailTask?.cancel()
        selection = nil
        isCreating = false
        entityForm = EntityForm()
        entityOriginal = entityForm
        termForm = TermForm()
        termOriginal = termForm
        seriesForm = SeriesForm()
        seriesOriginal = seriesForm
        relations = []
        footprint = nil
        relationTarget = nil
    }

    /// Restores the form to what is stored.
    func revert() {
        if isCreating {
            close()
        } else {
            open(selection)
        }
    }

    private func startNew() {
        close()
        isCreating = true
        if section.listsEntities {
            entityForm = EntityForm(kind: kindFilter ?? section.kinds.first ?? .person)
            entityOriginal = entityForm
        }
    }

    /// Shows an entity from elsewhere in the app (e.g. the Meetings window):
    /// switches to its section and clears filters that would hide it. Asks
    /// first when the open form has unsaved changes.
    func show(entityID: Int64) {
        guard entity(entityID) != nil else { return }
        navigate(.select(.entity(entityID)))
    }

    /// Makes sure `e` is visible in the sidebar without opening it.
    func reveal(_ e: Entity) {
        let target = ContextSection.containing(e.kind)
        if section != target { section = target }
        if let k = kindFilter, k != e.kind { kindFilter = nil }
        if !visibleEntities.contains(where: { $0.id == e.id }) && !visiblePending.contains(where: { $0.id == e.id }) {
            searchText = ""
        }
    }

    // MARK: Loading

    func reload() async {
        do {
            entities = try await store.entities()
            glossary = try await store.glossary()
            series = try await store.series()
            seriesMeetingCounts = try await store.meetingCountsBySeries()
            customTemplates = try await store.customMinutesTemplates()
            hasLoaded = true
        } catch {
            failure = ContextFailure(error, during: .load)
            return
        }
        refreshOpenItem()
    }

    /// After a reload: follows the open item, or closes it if it is gone.
    /// Unsaved changes are never overwritten.
    private func refreshOpenItem() {
        guard let selection else { return }
        let exists: Bool = switch selection {
        case .entity(let id): entity(id) != nil
        case .term(let id): glossary.contains { $0.id == id }
        case .series(let id): series.contains { $0.id == id }
        }
        if !exists {
            close()
        } else if !hasUnsavedChanges {
            open(selection)
        } else if case .entity(let id) = selection {
            loadDetail(of: id)
        }
    }

    /// Relations and footprint of the selected entity. A newer request
    /// cancels the older one, so a slow load never shows another entity's data.
    func loadDetail(of id: Int64) {
        detailTask?.cancel()
        detailTask = Task { [store] in
            do {
                let relations = try await store.relations(of: NodeRef(.entity, id))
                let footprint = try await store.footprint(of: id)
                guard !Task.isCancelled, selection == .entity(id) else { return }
                self.relations = relations
                self.footprint = footprint
            } catch {
                guard !Task.isCancelled else { return }
                failure = ContextFailure(error, during: .load)
            }
        }
    }

    /// Locking: the open form's unsaved changes are written in the
    /// background with the values captured now (as Meetings does with its
    /// drafts), so a relock never throws away what was typed. Not used after
    /// "Erase Everything", where nothing may be written back.
    func saveUnsavedInBackground() {
        guard hasUnsavedChanges else { return }
        let store = store
        switch section {
        case .people, .work:
            let draft = entityForm.draft(editing: selectedEntity)
            Task { _ = try? await store.saveEntity(draft) }
        case .glossary:
            let value = termForm.value
            Task { _ = try? await store.saveGlossary(value) }
        case .series:
            let value = seriesForm.value
            Task { _ = try? await store.saveSeries(value) }
        }
    }

    /// Forgets everything shown (when the history locks).
    func purge() {
        // The task clears its own handle when it ends, so a new run cannot
        // start while the cancelled one is still finishing its meeting.
        reanalysisTask?.cancel()
        close()
        entities = []
        glossary = []
        series = []
        seriesMeetingCounts = [:]
        customTemplates = []
        searchText = ""
        kindFilter = nil
        pendingNavigation = nil
        mergeRequest = nil
        deleteRequest = nil
        termToDelete = nil
        seriesToDelete = nil
        failure = nil
        reanalysis = ReanalysisProgress()
        isCancellingReanalysis = false
        reanalysisReport = nil
        hasLoaded = false
    }

    /// Runs a store operation; failures become an alert titled after `operation`.
    @discardableResult
    func perform(_ operation: ContextOperation, _ work: () async throws -> Void) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            try await work()
            return true
        } catch {
            failure = ContextFailure(error, during: operation)
            await reload()
            return false
        }
    }

    /// Saves whatever form is open. Returns false if it failed.
    func saveCurrent() async -> Bool {
        switch section {
        case .people, .work: await saveEntity()
        case .glossary: await saveTerm()
        case .series: await saveSeries()
        }
    }
}
