// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta

@Suite("Search model sizes")
struct SearchModelTextTests {
    /// The unit follows the language, so the card never mixes "574 MB" with the "Go" the integrated model card shows in French.
    @Test func wholeMegabytesUseTheUnitOfTheLanguage() {
        let nbsp = "\u{00A0}"
        #expect(SearchModelText.size(574_200_000, locale: Locale(identifier: "en_US")) == "574\(nbsp)MB")
        let french = SearchModelText.size(574_200_000, locale: Locale(identifier: "fr_FR"))
        #expect(french.hasPrefix("574") && french.hasSuffix("Mo"), "\(french)")
        #expect(!french.contains("MB"))
        #expect(!french.contains(" "), "only no-break spaces: \(french)")
    }

    @Test func fractionsAreRoundedToWholeMegabytes() {
        let text = SearchModelText.size(311_600_000, locale: Locale(identifier: "de_DE"))
        #expect(text.hasPrefix("312") && !text.contains(",") && !text.contains("."), "\(text)")
    }
}
