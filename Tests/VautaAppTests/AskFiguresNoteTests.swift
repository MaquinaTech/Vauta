// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// The note under a partly verified answer names the figures of its sentence that nothing the model read backs.
@Suite("Ask: the note of figures the answer's sentence gives")
@MainActor
struct AskFiguresNoteTests {
    @Test func theNoteNamesTheFiguresAndKeepsTheClaimsNote() {
        let verified = VerifiedAnswer.Claim(id: "c0", text: "Cut.", citations: [1], verified: true)
        let figures = VerifiedAnswer(answer: "Cut to 55 and 60.", claims: [verified], found: true, unbackedFigures: ["55", "60"])
        let note = AskModel.partlyVerifiedNote(for: figures)
        #expect(note.contains("55") && note.contains("60") && note != AskModel.partlyVerifiedNote)
        let both = VerifiedAnswer(answer: "Cut to 55.", claims: [verified, .init(id: "c1", text: "Signed.", citations: [2], verified: false)],
                                  found: true, unbackedFigures: ["55"])
        #expect(AskModel.partlyVerifiedNote(for: both).hasPrefix(AskModel.partlyVerifiedNote) && AskModel.partlyVerifiedNote(for: both).contains("55"))
        let claimsOnly = VerifiedAnswer(answer: "Signed.", claims: [verified, .init(id: "c1", text: "Signed.", citations: [2], verified: false)], found: true)
        #expect(AskModel.partlyVerifiedNote(for: claimsOnly) == AskModel.partlyVerifiedNote)
    }
}
