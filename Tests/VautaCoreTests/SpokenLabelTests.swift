// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Spoken labels")
struct SpokenLabelTests {
    @Test func partsAreSeparatedByACommaAndNeverByAConjunction() {
        #expect(SpokenLabel.join(["Open System Settings", "Microphone"], language: "en") == "Open System Settings, Microphone")
        #expect(SpokenLabel.join(["Task", "Send the notes", "Maya"], language: "fr") == "Task, Send the notes, Maya")
    }

    @Test func japaneseAndChineseUseTheIdeographicComma() {
        #expect(SpokenLabel.join(["許可", "マイク"], language: "ja") == "許可、マイク")
        #expect(SpokenLabel.join(["允许", "麦克风"], language: "zh-Hans") == "允许、麦克风")
    }

    @Test func aFinalPeriodOfAPartIsDroppedBeforeTheSeparator() {
        #expect(SpokenLabel.join(["Ship the beta on the 28th.", "Proposed by the model", "Unconfirmed."], language: "en") == "Ship the beta on the 28th, Proposed by the model, Unconfirmed.")
        #expect(SpokenLabel.join(["28日に出荷する。", "モデルによる提案"], language: "ja") == "28日に出荷する、モデルによる提案")
        #expect(SpokenLabel.join(["Wait...", "Next"], language: "en") == "Wait..., Next", "an ellipsis is not a full stop")
    }

    @Test func emptyPartsAreLeftOut() {
        #expect(SpokenLabel.join(["Allow", "", "Microphone"], language: "de") == "Allow, Microphone")
        #expect(SpokenLabel.join([], language: "en") == "")
    }

    @Test func partsAreTrimmedSoGermanEllipsisLeavesNoSpaceBeforeTheComma() {
        #expect(SpokenLabel.join(["Erlauben ", "Mikrofon"], language: "de") == "Erlauben, Mikrofon")
    }

    @Test func noViewJoinsTwoPartsWithAListFormatter() throws {
        // The VoiceOver labels of buttons and rows must not go through ListFormatter (its conjunction comes from the system locale).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Sources/Vauta/App/Onboarding/OnboardingSetupPages.swift", "Sources/Vauta/App/Meetings/OtherPossibleItemsSection.swift",
                     "Sources/Vauta/App/Meetings/SummaryTab.swift", "Sources/Vauta/App/Panel/AnswersCard.swift", "Sources/Vauta/App/Panel/LiveTools.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            #expect(!text.contains("ListFormatter") && !text.contains(".formatted(.list"), "\(file) joins a VoiceOver label with ListFormatter")
        }
    }
}
