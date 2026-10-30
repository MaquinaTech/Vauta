// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing

/// Checks the English source tables in Resources/en.lproj and how macOS resolves them.
@Suite("Localization")
struct LocalizationTests {
    static let resources = PackagingTests.root.appendingPathComponent("Resources")
    static let english = resources.appendingPathComponent("en.lproj")

    static func plist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// A throwaway bundle holding a copy of en.lproj, so lookups go through Foundation. Its folder is removed by `remove()`: call it
    /// in a `defer`.
    /// `parent` and `source` are for the test of the helper itself.
    static func englishBundle(in parent: URL = FileManager.default.temporaryDirectory, source: URL = english) throws -> TemporaryBundle {
        let dir = parent.appendingPathComponent("vauta-l10n-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: source, to: dir.appendingPathComponent("en.lproj"))
            return TemporaryBundle(url: dir, bundle: try #require(Bundle(url: dir)))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    @Test func infoPlistDeclaresTheSupportedLanguages() throws {
        let info = try Self.plist(Self.resources.appendingPathComponent("Info.plist"))
        #expect(info["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(info["CFBundleLocalizations"] as? [String] == ["en", "es", "fr", "de", "it", "pt-BR", "ja", "ko", "zh-Hans"])
    }

    /// The English InfoPlist.strings repeats the Info.plist prompts, so every language has
    /// the same keys to translate.
    @Test func permissionPromptsMatchInfoPlist() throws {
        let info = try Self.plist(Self.resources.appendingPathComponent("Info.plist"))
        let strings = try Self.plist(Self.english.appendingPathComponent("InfoPlist.strings"))
        let prompts = info.keys.filter { $0.hasSuffix("UsageDescription") }
        #expect(!prompts.isEmpty)
        #expect(Set(strings.keys) == Set(prompts))
        for key in prompts {
            #expect(strings[key] as? String == info[key] as? String, "\(key)")
        }
    }

    /// Keys are the English text, except context keys such as "state.recording" (lowercase
    /// words joined by dots) that disambiguate a word with two meanings.
    @Test func englishValuesAreTheirKeys() throws {
        let strings = try Self.plist(Self.english.appendingPathComponent("Localizable.strings"))
        #expect(strings.count > 500)
        for (key, value) in strings {
            let value = try #require(value as? String)
            if key.wholeMatch(of: /[a-z]+(\.[a-z]+)+/) != nil {
                #expect(!value.isEmpty && value != key, "\(key)")
            } else {
                #expect(value == key)
            }
        }
    }

    @Test func pluralEntriesAreWellFormed() throws {
        let dict = try Self.plist(Self.english.appendingPathComponent("Localizable.stringsdict"))
        let strings = try Self.plist(Self.english.appendingPathComponent("Localizable.strings"))
        #expect(!dict.isEmpty)
        for (key, value) in dict {
            #expect(strings[key] == nil, "plural key also in Localizable.strings: \(key)")
            let entry = try #require(value as? [String: Any])
            let format = try #require(entry["NSStringLocalizedFormatKey"] as? String)
            let variables = entry.keys.filter { $0 != "NSStringLocalizedFormatKey" }
            #expect(!variables.isEmpty, "\(key)")
            for name in variables {
                #expect(format.contains("#@\(name)@"), "\(key): \(name) unused")
                let variable = try #require(entry[name] as? [String: String])
                #expect(variable["NSStringFormatSpecTypeKey"] == "NSStringPluralRuleType")
                #expect(variable["NSStringFormatValueTypeKey"] == "lld")
                #expect(variable["one"] != nil && variable["other"] != nil, "\(key): \(name)")
            }
        }
    }

    /// Both bundle helpers (this suite's and `ConsentTests`') are pointed at a folder of their own: after a normal run and after one that
    /// fails half way, nothing of theirs is left in it.
    @Test func temporaryBundlesLeaveNothingBehind() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-leak-check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        func leftovers() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []) }

        let english = try Self.englishBundle(in: parent)
        let consent = try ConsentTests().appBundle(in: parent)
        #expect(leftovers().count == 2, "both helpers made their folder here")
        english.remove()
        consent.remove()
        #expect(leftovers().isEmpty)

        let missing = parent.appendingPathComponent("no-such-source")
        #expect(throws: (any Error).self) { try Self.englishBundle(in: parent, source: missing) }
        #expect(throws: (any Error).self) { try ConsentTests().appBundle(in: parent, resources: missing) }
        #expect(leftovers().isEmpty, "a helper that throws removes its folder first")
    }

    @Test func pluralsResolveForOneAndMany() throws {
        let temp = try Self.englishBundle()
        defer { temp.remove() }
        let bundle = temp.bundle
        let english = Locale(identifier: "en")
        func format(_ key: String, _ args: any CVarArg...) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: nil), locale: english, arguments: args)
        }
        #expect(format("%lld meetings", 1) == "1 meeting")
        #expect(format("%lld meetings", 3) == "3 meetings")
        #expect(format("%@ · %lld chat models, %lld for search by meaning", "127.0.0.1", 1, 2)
                == "127.0.0.1 · 1 chat model, 2 for search by meaning")
        #expect(format("Found %@ in %lld meetings.", "2 mentions and 1 ambiguous name" as NSString, 1)
                == "Found 2 mentions and 1 ambiguous name in 1\u{00A0}meeting.")
        #expect(format("No new names were found in %lld meetings.", 1) == "No new names were found in 1\u{00A0}meeting.")
        #expect(format("Stopped after %lld of %lld meetings.", 1, 1) == "Stopped after 1 of 1 meeting.")
        #expect(format("Searched %lld meetings (%@).", 1, "Oct 28, 2026" as NSString) == "Searched 1 meeting (Oct 28, 2026).")
        #expect(format("Passages from %lld meetings and %lld documents were sent to the model.", 1, 2)
                == "Passages from 1 meeting and 2 documents were sent to the\u{00A0}model.")

        // Every plural key resolves without leaving a variable unexpanded.
        let dict = try Self.plist(Self.english.appendingPathComponent("Localizable.stringsdict"))
        for key in dict.keys {
            let template = bundle.localizedString(forKey: key, value: nil, table: nil)
            let resolved = String(format: template, locale: english, arguments: Self.sampleArguments(for: key, count: 1))
            #expect(!resolved.contains("%#@") && !resolved.contains("#@"), "\(key) -> \(resolved)")
        }
    }

    /// One argument per specifier of the key: numbers for %lld, text for %@.
    static func sampleArguments(for key: String, count: Int) -> [any CVarArg] {
        key.matches(of: /%(lld|@)/).map { match -> any CVarArg in match.output.1 == "lld" ? count : "x" as NSString }
    }
}

/// A folder under the temporary directory with a bundle opened on it. Tests that make one remove it in a `defer`, so nothing is left
/// behind in `$TMPDIR` (`temporaryBundlesLeaveNothingBehind` checks this suite's helper and `ConsentTests`').
struct TemporaryBundle {
    let url: URL
    let bundle: Bundle
    func remove() { try? FileManager.default.removeItem(at: url) }
}
