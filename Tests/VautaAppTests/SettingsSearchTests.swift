// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta

/// Settings search: what it finds, and that every name it can show is one the app has (and translates).
@Suite("Settings: search in the sidebar")
@MainActor
struct SettingsSearchTests {
    private func found(_ query: String) -> [String] {
        SettingsSearch.results(for: query).map { "\($0.pane.rawValue): \($0.title)" }
    }

    @Test func aSettingIsFoundByAnyPartOfItsNameInAnyCaseAndWithoutAccents() {
        #expect(found("vocab") == ["recording: Custom vocabulary"])
        #expect(found("STOP screen").contains("recording: Stop recording when the screen locks"), "every word, in any order")
        #expect(found("ïntegrated") == ["models: Integrated model"])
        #expect(found("pause").contains("general: Pause or resume recording"))
        #expect(found("").isEmpty && found("   ").isEmpty)
        #expect(found("zzz").isEmpty)
    }

    @Test func aPaneComesBeforeTheSettingsThatShareItsName() {
        let results = SettingsSearch.results(for: "translation")
        #expect(results.first?.pane == .translation && results.first?.key == SettingsModel.Pane.translation.rawValue)
        #expect(results.dropFirst().contains { $0.pane == .general && $0.key == "Turn Live Translation on or off" })
    }

    @Test func everyNameIsOneTheAppShowsAndTranslates() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let english = try String(contentsOf: root.appending(path: "Resources/en.lproj/Localizable.strings"), encoding: .utf8)
        for (pane, names) in SettingsSearch.index {
            for name in names {
                #expect(english.contains("\n\"\(name)\" = "), "\(pane.rawValue): “\(name)” is not a string of the app")
            }
        }
        #expect(Set(SettingsSearch.index.keys) == Set(SettingsModel.Pane.allCases), "every pane has its settings listed")
    }
}
