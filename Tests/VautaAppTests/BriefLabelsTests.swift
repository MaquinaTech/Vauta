// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

@MainActor
@Suite("Brief: what VoiceOver reads")
struct BriefLabelsTests {
    private func task(yours: Bool, uncertain: Bool, owner: String? = "Ana López") -> BriefItem {
        var item = BriefItem(id: "b1", kind: .task, text: "Send the revised budget")
        item.isYours = yours
        item.owner = owner
        item.ownerUncertain = uncertain
        return item
    }

    @Test func aTaskOfTheUserWhoseOwnerIsNotConfirmedIsNotReadAsCertain() {
        let plain = BriefLabels.spoken(task(yours: true, uncertain: false))
        #expect(plain.contains(BriefLabels.yours) && !plain.contains(VerificationText.ownerSpoken(BriefLabels.yours)))
        let uncertain = BriefLabels.spoken(task(yours: true, uncertain: true))
        #expect(uncertain.contains(VerificationText.ownerSpoken(BriefLabels.yours)), Comment(rawValue: uncertain))
        // The same for another person's task.
        let other = BriefLabels.spoken(task(yours: false, uncertain: true))
        #expect(other.contains(VerificationText.ownerSpoken("Ana López")), Comment(rawValue: other))
    }

    @Test func anUnconfirmedLineIsReadAsUnconfirmed() {
        var item = BriefItem(id: "b2", kind: .decision, text: "Keep the C-shaped shell")
        item.unconfirmed = true
        #expect(BriefLabels.spoken(item).contains(VerificationText.unconfirmed))
    }
}
