// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import SwiftUI

/// Find in the meeting shown (⌘F, ⌘G, ⇧⌘G): the places of a text in its transcript (`TranscriptFind`), optionally said by one speaker.
/// The place chosen becomes the highlighted passage, which the transcript scrolls to.
extension MeetingsModel {
    /// ⌘F finds in the meeting shown when it has a transcript; elsewhere it searches the meetings.
    var canFindInMeeting: Bool { mode == .meetings && shownMeeting != nil && !transcript.isEmpty }

    func showFind() {
        guard canFindInMeeting else { searchFocusRequest += 1; return }
        tab = .transcript
        if !findShown {
            findShown = true
            refreshFind()
        }
        findFocusRequest += 1
    }

    /// Closes the bar; the text stays for the next ⌘F, the speaker (one of this meeting's) does not.
    func closeFind() {
        findShown = false
        findSpeaker = nil
        findMatches = []
        findIndex = nil
    }

    /// ⌘G and ⇧⌘G have somewhere to go: the bar has places, or it is closed with a text to find again.
    var canFindNext: Bool { canFindInMeeting && (findShown ? !findMatches.isEmpty : !findText.trimmingCharacters(in: .whitespaces).isEmpty) }

    /// The next place (⌘G) or the previous one (⇧⌘G), wrapping around. With the bar closed, it opens on the first place
    /// from the highlighted passage on, the last text still in it.
    func findNext(forward: Bool = true) {
        guard canFindInMeeting else { return }
        if !findShown {
            showFind()
        } else {
            go(to: TranscriptFind.step(from: findIndex, forward: forward, in: findMatches, from: highlighted, order: transcript.map(\.id)))
        }
        // The count is on screen; VoiceOver hears it, since the focus stays in the field or the transcript.
        if let count = findCount { AccessibilityNotification.Announcement(count).post() }
    }

    /// The places of the text as it stands; while it is typed, the first one from the highlighted passage on.
    func refreshFind() {
        guard findShown else { findMatches = []; findIndex = nil; return }
        let lines = transcript.filter { findSpeaker == nil || $0.speaker?.id == findSpeaker }.map { (id: $0.id, text: $0.text) }
        findMatches = TranscriptFind.matches(of: findText, in: lines)
        findIndex = nil
        go(to: TranscriptFind.step(from: nil, forward: true, in: findMatches, from: highlighted, order: transcript.map(\.id)))
    }

    private func go(to index: Int?) {
        findIndex = index
        if let index, findMatches.indices.contains(index) { highlighted = findMatches[index].segment }
    }

    /// "3 of 12", "No Results" (nothing while the field is empty).
    var findCount: String? {
        guard !findText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard !findMatches.isEmpty else { return String(localized: "No Results") }
        return String(localized: "\((findIndex ?? 0) + 1) of \(findMatches.count)")
    }

    /// The marks of one line: its places, and which of them is the one chosen.
    func findRanges(of segment: Int64) -> (all: [Range<String.Index>], current: Range<String.Index>?) {
        guard findShown, !findMatches.isEmpty else { return ([], nil) }
        let current = findIndex.flatMap { findMatches.indices.contains($0) && findMatches[$0].segment == segment ? findMatches[$0].range : nil }
        return (TranscriptFind.ranges(of: segment, in: findMatches), current)
    }
}
