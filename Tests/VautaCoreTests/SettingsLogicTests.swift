// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Settings: retention confirmation")
struct SettingsRetentionTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    @Test func storedValuesMapToOptions() {
        #expect(KnowledgeRetention(days: 0) == .untilDeleted)
        #expect(KnowledgeRetention(days: 365) == .oneYear)
        #expect(KnowledgeRetention(days: 90) == .withTranscript)
        #expect(KnowledgeRetention(days: 12) == .withTranscript)
        #expect(KnowledgeRetention.withTranscript.rawValue == MeetingStore.retentionDays)
    }

    @Test func shorterOnlyWhenMeetingsLiveLess() {
        #expect(RetentionChange(from: .untilDeleted, to: .twoYears).isShorter)
        #expect(RetentionChange(from: .twoYears, to: .withTranscript).isShorter)
        #expect(!RetentionChange(from: .withTranscript, to: .oneYear).isShorter)
        #expect(!RetentionChange(from: .oneYear, to: .untilDeleted).isShorter)
        #expect(!RetentionChange(from: .oneYear, to: .oneYear).isShorter)
    }

    @Test func countsOnlyMeetingsTheNewValueDeletesNow() {
        let dates = [10, 89, 100, 200, 400, 800].map { Self.daysAgo(Double($0)) }
        // Until deleted → 1 year: the 400- and 800-day-old meetings go.
        #expect(RetentionChange(from: .untilDeleted, to: .oneYear).meetingsDeleted(startDates: dates, now: Self.now) == 2)
        // 2 years → with the transcript: 100, 200 and 400 (800 was already gone).
        #expect(RetentionChange(from: .twoYears, to: .withTranscript).meetingsDeleted(startDates: dates, now: Self.now) == 3)
        // Longer values delete nothing.
        #expect(RetentionChange(from: .withTranscript, to: .untilDeleted).meetingsDeleted(startDates: dates, now: Self.now) == 0)
        #expect(RetentionChange(from: .oneYear, to: .withTranscript).meetingsDeleted(startDates: [], now: Self.now) == 0)
    }
}

@Suite("Settings: onboarding steps")
struct SettingsOnboardingTests {
    @Test func walksForwardAndBack() {
        var flow = OnboardingFlow()
        #expect(flow.step == .welcome && flow.isFirst && !flow.canGoBack)
        #expect(flow.position == (1, 6))
        for expected in [OnboardingStep.language, .permissions, .speechModel, .models, .done] {
            flow.advance()
            #expect(flow.step == expected)
        }
        #expect(flow.isLast && flow.canGoBack)   // reached with Continue: Back reviews the model choice
        flow.advance()
        #expect(flow.step == .done)
        flow.goBack()
        #expect(flow.step == .models)
    }

    @Test func skippedPagesArePassedOverBothWays() {
        var flow = OnboardingFlow(step: .permissions, skipped: [.speechModel])
        flow.advance()
        #expect(flow.step == .models)
        #expect(flow.position == (4, 5))
        flow.goBack()
        #expect(flow.step == .permissions)
        flow.skipped.remove(.speechModel)
        flow.advance()
        #expect(flow.step == .speechModel)
    }

    @Test func theCurrentPageCountsEvenWhenItBecomesSkippable() {
        // On the speech model page the model finishes installing: the counter must not fall back to "1 of 5".
        let flow = OnboardingFlow(step: .speechModel, skipped: [.speechModel])
        #expect(flow.position == (4, 6))
    }

    @Test func firstAndLastPagesCannotBeSkipped() {
        var flow = OnboardingFlow(skipped: [.welcome, .done, .language])
        #expect(flow.skipped == [.language])
        flow.skipped.insert(.done)
        #expect(!flow.skipped.contains(.done))
        #expect(flow.visibleSteps.first == .welcome && flow.visibleSteps.last == .done)
    }

    @Test func skipSetupJumpsToTheLastPage() {
        var flow = OnboardingFlow(step: .language)
        flow.finish()
        #expect(flow.step == .done && flow.isLast)
        #expect(!flow.canGoBack)   // skipped: no Back from the last page
        flow.goBack()
        #expect(flow.step == .done)
    }
}

@Suite("Settings: shortcuts")
struct SettingsHotKeyTests {
    typealias R = HotKeyRules
    static let recordDefault: (keyCode: UInt32, modifiers: UInt32) = (15, R.control | R.option)   // ⌃⌥R
    static let markDefault: (keyCode: UInt32, modifiers: UInt32) = (46, R.control | R.option)     // ⌃⌥M

    @Test func defaultsAreValid() {
        #expect(R.issue(keyCode: 15, modifiers: R.control | R.option, other: Self.markDefault) == nil)
        #expect(R.issue(keyCode: 46, modifiers: R.control | R.option, other: Self.recordDefault) == nil)
    }

    @Test func rejectedShortcuts() {
        #expect(R.issue(keyCode: 15, modifiers: 0, other: nil) == .needsModifier)
        #expect(R.issue(keyCode: 15, modifiers: R.shift, other: nil) == .needsModifier)
        #expect(R.issue(keyCode: 12, modifiers: R.command, other: nil) == .reservedBySystem)       // ⌘Q
        #expect(R.issue(keyCode: 49, modifiers: R.command, other: nil) == .reservedBySystem)       // ⌘Space
        #expect(R.issue(keyCode: 46, modifiers: R.control | R.option, other: Self.markDefault) == .sameAsOther)
        // Bits outside the four modifiers are ignored when comparing.
        #expect(R.issue(keyCode: 46, modifiers: R.control | R.option | 0x0001, other: Self.markDefault) == .sameAsOther)
    }

    @Test func functionKeysWorkAlone() {
        #expect(R.issue(keyCode: 96, modifiers: 0, other: nil) == nil)   // F5
        #expect(R.specialKeyName(96) == "F5")
    }

    @Test func labels() {
        #expect(R.modifierSymbols(R.command | R.shift | R.option | R.control) == "⌃⌥⇧⌘")
        #expect(!R.Issue.inUseByAnotherApp.message.isEmpty)
    }
}

@Suite("Settings: support")
struct SettingsSupportTests {
    @Test func systemSettingsLinksArePrivacyPanes() {
        for pane in SystemSettingsPane.allCases {
            #expect(pane.url.scheme == "x-apple.systempreferences")
        }
        #expect(SystemSettingsPane.microphone.url.absoluteString.hasSuffix("Privacy_Microphone"))
        #expect(SystemSettingsPane.systemAudio.url.absoluteString.hasSuffix("Privacy_AudioCapture"))
    }

    @Test func outputLanguagesIncludeTheCurrentChoiceOnce() {
        let ids = OutputLanguageOptions.identifiers(including: ["eu", "es"], locale: Locale(identifier: "en"))
        #expect(ids.contains("eu"))
        #expect(ids.filter { $0 == "es" }.count == 1)
        let names = ids.map { OutputLanguageOptions.displayName($0, locale: Locale(identifier: "en")) }
        #expect(names == names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    @Test func installedSpeechLanguagesComeFirst() {
        let catalog = SpeechLanguageCatalog(speech: [Locale(identifier: "en-US"), Locale(identifier: "es-ES")],
                                            dictation: [Locale(identifier: "ca-ES")],
                                            installedSpeech: [Locale(identifier: "es-ES")])
        let sorted = catalog.sortedForDisplay(locale: Locale(identifier: "en"))
        #expect(sorted.map(\.id) == ["es-ES", "ca-ES", "en-US"])
    }

    @Test func diagnosticsAreOneShortLinePerEntry() {
        let report = DiagnosticsReport(appVersion: "0.2.0", build: "42", system: "macOS 26.1",
                                       entries: [.init("microphone", "granted"),
                                                 .init("models", "line one\nline two " + String(repeating: "x", count: 400))])
        let lines = report.text.split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[0] == "Vauta 0.2.0 (42)")
        #expect(lines[2] == "- microphone: granted")
        #expect(lines[3].hasPrefix("- models: line one line two"))
        #expect(lines[3].count <= "- models: ".count + DiagnosticsReport.maxValueLength)
    }

    /// Report a Problem… opens this address: the bug report form with the two versions and nothing else, whatever the entries hold.
    @Test func theBugReportAddressHoldsTheVersionsOnly() throws {
        let report = DiagnosticsReport(appVersion: "0.9.4", build: "57", system: "macOS Version 27.2 (Build 26B123)",
                                       entries: [.init("models", "server http://192.168.1.50:8443/v1 qwen3")])
        let url = report.issueURL
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https" && components.host == "github.com" && components.path == "/MaquinaTech/Vauta/issues/new")
        #expect(components.queryItems?.map(\.name) == ["template", "vauta-version", "macos-version"])
        #expect(components.queryItems?.map(\.value) == ["bug_report.yml", "0.9.4 (57)", "macOS Version 27.2 (Build 26B123)"])
        #expect(!url.absoluteString.contains("192.168") && !url.absoluteString.contains("qwen"))
    }

    @Test func aVersionCannotAddToTheBugReportAddress() throws {
        let report = DiagnosticsReport(appVersion: "1.0&title=x#y", build: "1\nbody=z", system: "macOS 27 " + String(repeating: "9", count: 80), entries: [])
        let components = try #require(URLComponents(url: report.issueURL, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.map(\.name) == ["template", "vauta-version", "macos-version"])
        #expect(components.queryItems?[1].value == "1.0titlexy (1bodyz)")
        #expect(components.queryItems?[2].value?.count == 40)
        #expect(components.fragment == nil)
    }

    /// GitHub fills a form field from the query item of the same id: renaming a field in the form would leave it empty.
    @Test func theBugReportFormHasTheFieldsTheAddressFills() throws {
        let url = DiagnosticsReport(appVersion: "1", build: "1", system: "macOS", entries: []).issueURL
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let template = try #require(items.first { $0.name == "template" }?.value)
        let form = try String(contentsOf: PackagingTests.root.appendingPathComponent(".github/ISSUE_TEMPLATE/\(template)"), encoding: .utf8)
        for item in items where item.name != "template" {
            #expect(form.contains("    id: \(item.name)\n"), "\(template) has no field \(item.name)")
        }
    }
}
