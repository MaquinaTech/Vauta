// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// Glossary terms, recurring meetings and the full re-analysis.
extension ContextModel {
    // MARK: Glossary

    @discardableResult
    func saveTerm() async -> Bool {
        let value = termForm.value
        var id: Int64?
        guard await perform(.saveTerm, { id = try await store.saveGlossary(value) }), let id else { return false }
        await reload()
        if !visibleTerms.contains(where: { $0.id == id }) { searchText = "" }
        open(.term(id))
        return true
    }

    func delete(_ term: GlossaryTerm) async {
        guard let id = term.id else { return }
        termToDelete = nil
        if await perform(.deleteTerm, { try await store.deleteGlossary(id) }) {
            if selection == .term(id) { close() }
            await reload()
        }
    }

    // MARK: Recurring meetings

    @discardableResult
    func saveSeries() async -> Bool {
        let value = seriesForm.value
        var id: Int64?
        guard await perform(.saveSeries, { id = try await store.saveSeries(value) }), let id else { return false }
        await reload()
        if !visibleSeries.contains(where: { $0.id == id }) { searchText = "" }
        open(.series(id))
        return true
    }

    func delete(_ s: MeetingSeries) async {
        guard let id = s.id else { return }
        seriesToDelete = nil
        if await perform(.deleteSeries, { try await store.deleteSeries(id) }) {
            if selection == .series(id) { close() }
            await reload()
        }
    }

    // MARK: Re-analysis

    /// Searches the context names again in every meeting that still has its
    /// transcript (after adding people or aliases). Local and deterministic;
    /// what the user decided is kept, and purged meetings are never visited.
    /// A meeting that fails is counted and the run goes on.
    func startReanalysis() {
        guard !reanalysis.isRunning, reanalysisTask == nil else { return }
        isCancellingReanalysis = false
        reanalysisTask = Task { [store] in
            defer { reanalysisTask = nil }
            let ids: [Int64]
            do {
                ids = try await store.analyzableMeetingIDs()
            } catch {
                // After a lock (purge) the failure belongs to a forgotten run.
                if !Task.isCancelled { failure = ContextFailure(error, during: .reanalyze) }
                return
            }
            reanalysis.start(total: ids.count)
            for id in ids {
                if Task.isCancelled {
                    reanalysis.cancel()
                    break
                }
                do {
                    reanalysis.record(try await store.analyze(id))
                } catch {
                    reanalysis.recordFailure()
                }
            }
            reanalysis.finish()
            isCancellingReanalysis = false
            // After a lock (purge) the run is forgotten: nothing to report.
            guard reanalysis.state != .idle, hasLoaded else { return }
            reanalysisReport = reanalysis
            await reload()
        }
    }

    /// Stops before the next meeting; the ones already done keep their results.
    func cancelReanalysis() {
        guard reanalysis.isRunning else { return }
        isCancellingReanalysis = true
        reanalysisTask?.cancel()
    }
}
