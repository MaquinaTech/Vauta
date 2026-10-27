// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreGraphics
import Testing
@testable import Vauta

@MainActor
@Suite("Live notes: the hidden count")
struct LiveNotesHiddenCountTests {
    private let bottoms: [CGFloat] = [30, 60, 90, 120]

    @Test("Nothing is hidden when every note fits")
    func allFit() {
        #expect(LiveNotesView.hiddenCount(rowBottoms: bottoms, notesHeight: 120, limit: 200, shown: 120) == 0)
        #expect(LiveNotesView.hiddenCount(rowBottoms: bottoms, notesHeight: 120, limit: 120, shown: 120) == 0)
    }

    @Test("Nothing is hidden when the card is open")
    func open() {
        #expect(LiveNotesView.hiddenCount(rowBottoms: bottoms, notesHeight: 120, limit: nil, shown: 120) == 0)
    }

    @Test("The notes below the last whole one are counted")
    func cut() {
        // Limit 70: the notes ending at 30 and 60 are whole (the fade takes 5 pt), the two below are cut.
        #expect(LiveNotesView.hiddenCount(rowBottoms: bottoms, notesHeight: 120, limit: 70, shown: 65) == 2)
        #expect(LiveNotesView.hiddenCount(rowBottoms: bottoms, notesHeight: 120, limit: 100, shown: 95) == 1)
    }
}
