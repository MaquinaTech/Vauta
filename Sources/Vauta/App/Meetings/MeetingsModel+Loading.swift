// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import Observation
import SwiftUI

extension MeetingsModel {
    // MARK: Loading

    /// Selects nothing by default: the window shows no text when it opens.
    func reload() async {
        do {
            activeMeetingID = await store.activeMeetingID
            meetings = try await store.meetings()
            suggestionCounts = try await store.openSuggestionCounts()
            entities = try await store.entities().filter(\.confirmed)
            if selectedID != nil && selected == nil { selectedID = nil }
            await applyFilter()
            await loadDetail()
            await runSearch()
            await reloadMode()
        } catch {
            alert = .loadFailure(error) { [weak self] in await self?.reload() }
        }
    }

    /// Background changes (a recording ended, retention purged meetings):
    /// reloads only while the window shows them, so a closed or locked window
    /// doesn't pull meeting titles and names back into memory.
    func reloadIfShowing() async {
        if isShowing { await reload() }
    }

    func refreshActive() async {
        activeMeetingID = await store.activeMeetingID
    }

    func reloadMode() async {
        switch mode {
        case .meetings, .ask: break
        case .tasks:
            openTasks = (try? await store.openTasks()) ?? []
            await loadChains()
        case .people: await loadEntity()
        }
    }

    func applyFilter() async {
        guard !tokens.isEmpty else { filteredIDs = nil; return }
        var f = MeetingFilter()
        for t in tokens {
            switch t.kind {
            case .entity(let id): f.entities.append(id)
            case .series(let id): f.series = id
            case .lastDays(let d): f.from = AppClock.now - Double(d) * 86_400
            }
        }
        do {
            filteredIDs = try await store.meetingIDs(matching: f)
            await runSearch()
        } catch {
            present(String(localized: "Couldn’t apply the filter", comment: "Alert title"), error)
        }
    }

    func runSearch() async {
        let text = query
        guard mode.searchesMeetings, text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else {
            hits = []
            knowledgeHits = []
            documentHits = []
            return
        }
        do {
            let scope = filteredIDs
            let found = try await store.search(text, in: scope)
            let known = try await store.searchKnowledge(text, in: scope)
            // Suggested tokens: people and projects, series and dates.
            var suggested: [FilterToken] = []
            for hit in try await store.searchNames(text, limit: 6) {
                if case .entity(let id) = hit.target, let e = entities.first(where: { $0.id == id }) {
                    suggested.append(FilterToken(kind: .entity(id), label: e.displayName, symbol: e.kind.symbol))
                }
            }
            for s in try await store.series() where s.titlePattern.localizedStandardContains(text) {
                if let id = s.id { suggested.append(FilterToken(kind: .series(id), label: s.titlePattern, symbol: "repeat")) }
            }
            for days in [7, 30] {
                let label = String(localized: "Last \(days) days", comment: "Search filter token: meetings of the last N days")
                if label.localizedStandardContains(text) {
                    suggested.append(FilterToken(kind: .lastDays(days), label: label, symbol: "calendar"))
                }
            }
            // The documents (up to five passages): only when no filter narrows the search to some meetings.
            let documents = scope == nil ? ((try? await documentsModel?.index?.keywordHits(text, limit: 5)) ?? []) : []
            guard !Task.isCancelled, text == query else { return }
            hits = found
            knowledgeHits = known
            documentHits = documents
            suggestedTokens = suggested.filter { s in !tokens.contains { $0.id == s.id } }
            scheduleMeaningSearch(text)
        } catch {
            present(String(localized: "Search failed", comment: "Alert title"), error)
        }
    }

    func loadEntity() async {
        guard let id = selectedEntityID else {
            entityRefs = []; entityTimeline = []; entityImpact = []; entityTasks = []; entitySpokeIn = 0; entityQuotes = []; entityVoices = 0
            return
        }
        do {
            let refs = try await store.refs(id)
            let timeline = try await store.timeline(id)
            let impact = try await store.impact(NodeRef(.entity, id), depth: 2)
            let tasks = try await store.openTasks(owner: id)
            let spoke = try await store.speakerMeetingCount(entityID: id)
            let quotes = try await store.spokenQuotes(id)
            let voices = try await store.voiceProfiles(entityID: id).count
            guard selectedEntityID == id else { return }
            entitySpokeIn = spoke
            entityVoices = voices
            entityQuotes = quotes
            entityRefs = refs
            entityTimeline = timeline
            entityImpact = impact
            entityTasks = tasks
        } catch {
            present(String(localized: "Couldn’t load this card", comment: "Alert title"), error)
        }
    }

    // MARK: Navigation

    func open(_ hit: MeetingStore.SearchHit) {
        open(meeting: hit.meeting.id, segment: hit.segment.id)
    }

    func open(_ hit: KnowledgeHit) {
        guard let m = hit.meetingID else {
            // A note on a person or project: open its card.
            if hit.kind == .entityNote { showEntity(hit.refID) }
            return
        }
        if hit.kind == .question {
            // A kept question: the meeting at that moment, with the Questions section open.
            questionsExpanded = true
            revealQuestions = true
            open(meeting: m, tab: .summary)
        } else if hit.kind == .note || hit.kind == .noteExpansion {
            // The user's note, or what the model wrote from it: the Notes tab, with that note in view.
            open(meeting: m, tab: .notes)
            highlightedNote = hit.refID
        } else if hit.kind == .summary {
            open(meeting: m)
        } else if let t = hit.t {
            open(meeting: m, at: t)
        } else {
            open(meeting: m)
            tab = hit.kind == .task ? .tasks : .summary
        }
    }

    func showEntity(_ id: Int64) {
        mode = .people
        selectedEntityID = id
    }

    /// Opens the meeting at the given segment (or at second `t`).
    func open(meeting: Int64, segment: Int64? = nil, at t: Double? = nil, tab target: DetailTab? = nil) {
        mode = .meetings
        if let target {
            selectedID = meeting
            tab = target
            return
        }
        if segment != nil || t != nil { tab = .transcript }
        if let segment {
            pendingHighlight = segment
            if selectedID == meeting { highlighted = segment; pendingHighlight = nil }
            selectedID = meeting
        } else if let t {
            Task {
                let segs = (try? await store.segments(of: meeting)) ?? []
                let target = segs.last { $0.start <= t + 0.5 }?.id ?? segs.first?.id
                pendingHighlight = target
                if selectedID == meeting { highlighted = target; pendingHighlight = nil }
                selectedID = meeting
            }
        } else {
            selectedID = meeting
        }
    }

    /// Ask about the selected meeting (or about all of them).
    func askAboutSelection() {
        ask.thisMeeting = selected != nil
        ask.meetingID = selectedID
        mode = .ask
    }
}
