// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The sidebar search by meaning and the related meetings of the open meeting. Both need the search model to be ranking (the same
/// rule as Ask); otherwise nothing appears and the keyword results stay as they are.
extension MeetingsModel {
    /// Two words or more, or four characters or more (a single word such as “budget” or “contrato” has a meaning to look for; the
    /// keyword results still come first). Shorter than that is a prefix being typed.
    static func isMeaningful(_ query: String) -> Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(whereSeparator: \.isWhitespace).count >= 2 || text.count >= 4
    }

    /// After the keyword results: looks by meaning (after 300 ms) and adds the passages those results do not show. Skipped when a
    /// filter narrows the search to some meetings.
    func scheduleMeaningSearch(_ text: String) {
        meaningTask?.cancel()
        guard filteredIDs == nil, Self.isMeaningful(text), let llm else {
            meaningMeetingHits = []
            meaningDocumentHits = []
            return
        }
        // The search model loads in the background while the person finishes typing.
        SearchModelAccess.shared.requestPreload()
        meaningTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // Asks for 5 more than the keyword results already show, so that up to 5 remain after those are left out.
            let (shownMeetings, shownDocs) = await MainActor.run { (self?.hits.count ?? 0, self?.documentHits.count ?? 0) }
            let found = await llm.meaningMatches(for: text, meetingLimit: 5 + shownMeetings, documentLimit: 5 + shownDocs)
            guard !Task.isCancelled, let self, self.query == text else { return }
            let shownSegments = Set(self.hits.map(\.segment.id))
            let shownDocuments = Set(self.documentHits.map(\.id))
            self.meaningMeetingHits = Array((found?.meetings ?? []).filter { passage in !passage.segments.contains { shownSegments.contains($0.id) } }.prefix(5))
            self.meaningDocumentHits = Array((found?.documents ?? []).filter { !shownDocuments.contains($0.id) }.prefix(5))
        }
    }

    /// Opens a "By meaning" meeting result at its first segment.
    func open(_ passage: RetrievedPassage) {
        open(meeting: passage.meeting.id, segment: passage.segments.first?.id, at: passage.segments.isEmpty ? passage.start : nil)
    }

    /// Up to three other meetings close to this one's topics and decisions (the search model only; no keyword version).
    func loadRelatedMeetings() async {
        guard let id = selectedID, let llm else {
            relatedMeetings = []
            return
        }
        let words = ((draft?.topicsText ?? "") + " " + decisions.map(\.text).joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.count >= 3, let found = await llm.relatedMeetings(for: String(words.prefix(400)), excluding: id) else {
            if selectedID == id { relatedMeetings = [] }
            return
        }
        guard selectedID == id else { return }
        relatedMeetings = found.map(\.meeting)
    }
}
