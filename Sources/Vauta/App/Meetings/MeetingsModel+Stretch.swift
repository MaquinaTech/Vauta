// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// A stretch of transcript lines highlighted together, to take it off the record at once: ⇧-click or ⇧↑ ⇧↓ from the highlighted
/// line, or "Highlight Through This Line" in VoiceOver. The highlighted line is where the stretch starts and stays put;
/// `highlightExtent` is the end that moves.
extension MeetingsModel {
    /// The highlighted lines in transcript order: the highlighted line alone, or the stretch from it to `highlightExtent`.
    var highlightedStretch: [MeetingStore.StoredSegment] {
        guard let start = highlighted.flatMap({ h in transcript.firstIndex { $0.id == h } }) else { return [] }
        guard let end = highlightExtent.flatMap({ h in transcript.firstIndex { $0.id == h } }) else { return [transcript[start]] }
        return Array(transcript[min(start, end)...max(start, end)])
    }

    /// ⇧-click on a line: the stretch runs from the highlighted line to it. With no line highlighted, it highlights the line.
    func extendHighlight(to segment: MeetingStore.StoredSegment) {
        guard let start = highlighted, transcript.contains(where: { $0.id == start }), transcript.contains(where: { $0.id == segment.id }) else {
            highlight(segment)
            return
        }
        noteActivity()
        highlightExtent = segment.id == start ? nil : segment.id
    }

    /// ⇧↑ and ⇧↓: the stretch's moving end goes one line up or down. With no line highlighted, they move the highlight as ↑ and ↓ do.
    func extendHighlight(by step: Int) {
        guard let start = highlighted.flatMap({ h in transcript.firstIndex { $0.id == h } }) else {
            moveHighlight(by: step)
            return
        }
        let end = highlightExtent.flatMap { h in transcript.firstIndex { $0.id == h } } ?? start
        let next = min(max(end + step, 0), transcript.count - 1)
        noteActivity()
        highlightExtent = next == start ? nil : transcript[next].id
    }
}
