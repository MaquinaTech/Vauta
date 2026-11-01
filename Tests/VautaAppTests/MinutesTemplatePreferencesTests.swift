// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// The default minutes template in Preferences, now that it can be a template the person wrote, and the editor's draft.
@MainActor
@Suite("Minutes templates: the default and the editor")
struct MinutesTemplatePreferencesTests {
    private func make(_ body: (UserDefaults, Preferences) throws -> Void) rethrows {
        let name = "vauta.test.templates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults, Preferences(defaults: defaults, legacyInstall: false))
    }

    @Test func aDefaultStoredByAnEarlierVersionIsStillRead() {
        make { defaults, _ in
            defaults.set(MinutesTemplate.standup.rawValue, forKey: Preferences.Keys.minutesTemplate)
            #expect(Preferences(defaults: defaults, legacyInstall: false).minutesTemplate == .builtIn(.standup))
        }
    }

    @Test func aTemplateThePersonWroteIsStoredByItsNumber() {
        make { defaults, prefs in
            #expect(prefs.minutesTemplate == .general, "nothing chosen: the general template")
            prefs.minutesTemplate = .custom(12)
            #expect(defaults.string(forKey: Preferences.Keys.minutesTemplate) == "custom:12")
            #expect(Preferences(defaults: defaults, legacyInstall: false).minutesTemplate == .custom(12))
            // A restore writes the backup's settings, then the open preferences read them again.
            defaults.set(MinutesTemplate.interview.rawValue, forKey: Preferences.Keys.minutesTemplate)
            prefs.reloadFromDefaults()
            #expect(prefs.minutesTemplate == .builtIn(.interview))
        }
    }

    @Test func aValueNoVersionWritesIsTheGeneralTemplate() {
        make { defaults, _ in
            for stored in ["custom:0", "custom:", "a later template"] {
                defaults.set(stored, forKey: Preferences.Keys.minutesTemplate)
                #expect(Preferences(defaults: defaults, legacyInstall: false).minutesTemplate == .general, "\(stored)")
            }
        }
    }

    @Test func theEditorSavesOnlyANamedTemplateWithInstructions() {
        var draft = MinutesTemplateDraft()
        #expect(!draft.canSave)
        draft.name = "Product review"
        draft.instructions = " \n "
        #expect(!draft.canSave)
        draft.instructions = "The feature requests and who asked for each."
        #expect(draft.canSave)
        draft.name = "  "
        #expect(!draft.canSave)
        let template = CustomMinutesTemplate(id: 3, name: "Board", instructions: "The votes.", createdAt: .now)
        #expect(MinutesTemplateDraft(template).templateID == 3 && MinutesTemplateDraft(template).canSave)
    }

    @Test func theRowShowsTheFirstLineOfTheInstructions() {
        #expect(CustomTemplateRows.firstLine("Cover the budget.\nThen the risks.") == "Cover the budget.")
        let long = String(repeating: "word ", count: 40)
        #expect(CustomTemplateRows.firstLine(long).count == 91 && CustomTemplateRows.firstLine(long).hasSuffix("…"))
        #expect(CustomTemplateRows.firstLine("") == "")
    }
}
