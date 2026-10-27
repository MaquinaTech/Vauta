// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Brief: notification, preferences, network and privacy rules")
struct BriefPrivacyTests {
    // MARK: Notification

    @Test func theNotificationNeverCarriesBriefContentAndShowsTheTitleOnlyWhenGiven() {
        let plain = AppNotification.brief(minutesBefore: 10, eventTitle: nil)
        #expect(plain.kind == .brief && plain.kind.rawValue == "vauta.brief" && plain.identifier == "vauta.brief" && plain.meetingID == nil)
        #expect(plain.title.contains("10") && !plain.title.contains("Supplier"))
        #expect(plain.body == "Brief ready", "the body says nothing about the brief")
        let titled = AppNotification.brief(minutesBefore: 5, eventTitle: "Supplier review")
        #expect(titled.title.contains("Supplier review") && titled.title.contains("5") && titled.body == plain.body)
        #expect(AppNotification.brief(minutesBefore: 15, eventTitle: "").title == AppNotification.brief(minutesBefore: 15, eventTitle: nil).title)
        #expect(plain.kind.actions == [.openBrief, .recordAtStart] && plain.kind.defaultAction == .openBrief)
        #expect(AppNotification.Action.openBrief.rawValue == "brief" && AppNotification.Action.recordAtStart.rawValue == "recordAtStart")
    }

    @Test func itsOwnPreferenceGatesIt() {
        #expect(AppNotification.isAllowed(.brief, notifyMinutesReady: false, notifyProblems: false, notifyBrief: true))
        #expect(!AppNotification.isAllowed(.brief, notifyMinutesReady: true, notifyProblems: true, notifyBrief: false))
        #expect(AppNotification.isAllowed(.minutesReady, notifyMinutesReady: true, notifyProblems: false, notifyBrief: false), "the others do not depend on it")
    }

    @Test func theNotificationTextExistsInTheNineLanguagesWithTheRightArguments() throws {
        let root = NetworkAuditSourceScanTests.packageRoot()
        let wanted: [(key: String, specifiers: [String])] = [("Meeting in %lld minutes", ["%lld"]), ("%@ in %lld minutes", ["%@", "%lld"]), ("Brief ready", []),
                                                             ("Open Brief", []), ("Record at Start", []), ("Preparing a brief", [])]
        for language in ["en", "es", "fr", "de", "it", "pt-BR", "ja", "ko", "zh-Hans"] {
            let url = root.appending(path: "Resources/\(language).lproj/Localizable.strings")
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String], "\(language) table")
            for (key, specifiers) in wanted {
                let text = try #require(table[key], "\(language): \(key)")
                #expect(!text.isEmpty && specifiers.allSatisfy { text.contains($0) || text.contains("%1$") }, "\(language): \(key) keeps its arguments")
                if language != "en" { #expect(text != key || key == "Brief ready", "\(language): \(key) is translated") }
            }
        }
        let permission = try #require(NSDictionary(contentsOf: root.appending(path: "Resources/ja.lproj/InfoPlist.strings")) as? [String: String])
        #expect(permission["NSRemindersFullAccessUsageDescription"] != nil && permission["NSCalendarsFullAccessUsageDescription"] != nil)
    }

    // MARK: Preferences

    @Test func thePreferencesHaveTheDesignedDefaultsAndRoundTrip() throws {
        let suite = "vauta.brief.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = BriefPreferences(defaults: defaults)
        #expect(fresh.enabled && fresh.inPerson && fresh.readInvitationNotes && fresh.leadMinutes == 10)
        #expect(!fresh.remindersEnabled && fresh.reminderListIDs.isEmpty && !fresh.hintSeen, "reminders are off until the person allows them")
        #expect(fresh.notifies, "on once Calendar is on, the notification 10 minutes before")
        var off = fresh
        off.enabled = false
        #expect(!off.notifies, "the brief is off, so no notification")
        defaults.set(false, forKey: BriefPreferences.Keys.enabled)
        #expect(!BriefPreferences(defaults: defaults).enabled, "a stored Off is kept")
        defaults.removeObject(forKey: BriefPreferences.Keys.enabled)
        var changed = fresh
        changed.leadMinutes = 30
        changed.reminderListIDs = ["b", "a"]
        changed.remindersEnabled = true
        changed.write(to: defaults)
        #expect(BriefPreferences(defaults: defaults) == changed)
        defaults.set(7, forKey: BriefPreferences.Keys.leadMinutes)
        #expect(BriefPreferences(defaults: defaults).leadMinutes == 10, "a value that is not one of the options falls back to 10")
        changed.leadMinutes = 0
        #expect(!changed.notifies, "Off")
        #expect(changed.settings == BriefSettings(remindersEnabled: true, reminderListIDs: ["a", "b"], useInvitationNotes: true))
    }

    @Test func theBackupCarriesTheSwitchesButNotTheMacsReminderChoices() {
        let allowed = Set(BackupPreferences.allowed.keys)
        #expect(allowed.isSuperset(of: ["briefEnabled", "briefLeadMinutes", "briefInPersonEvents", "briefReadInvitationNotes"]))
        #expect(allowed.isDisjoint(with: ["remindersEnabled", "reminderListIDs", "briefHintSeen", "briefRemindersHintDismissed"]))
    }

    // MARK: Network Activity

    @Test func theBriefPurposeRoundTripsInTheActivityLogAndItsExport() async throws {
        #expect(NetworkPurpose.allCases.contains(.brief) && NetworkPurpose.brief.rawValue == "brief")
        let entry = NetworkActivityEntry(id: 1, timestamp: Date(timeIntervalSince1970: 0), purpose: .brief, url: URL(string: "https://10.0.0.5:8443/v1/chat/completions")!,
                                         method: "POST", bytesSent: 10)
        let decoded = try JSONDecoder().decode(NetworkActivityEntry.self, from: JSONEncoder().encode(entry))
        #expect(decoded.purpose == .brief && decoded == entry)
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any]
        #expect(old?["purpose"] as? String == "brief")
        #expect(NetworkPurpose(rawValue: "minutes") == .minutes, "the older values did not change")
    }

    // MARK: The brief module's reach

    /// Brief code reads Calendar and Reminders; it never writes to them, never scripts Notes and never starts a process.
    @Test func theBriefSourcesCallNoWriteApiAndNoScripting() throws {
        let root = NetworkAuditSourceScanTests.packageRoot()
        let directories = ["Sources/VautaCore/Brief", "Sources/Vauta/App/Brief"]
        let forbidden: [(String, String)] = [
            ("EventKit write", #"\.(save|remove|commit)\s*\(|\b(saveEvent|saveReminder|saveCalendar|removeEvent|removeReminder|removeCalendar|commit)\s*\("#),
            ("EventKit store reset", #"\breset\s*\(\)|\.refreshSourcesIfNecessary\s*\("#),
            ("Apple Events", #"\bNSAppleScript\b|\bSBApplication\b|\bNSAppleEventDescriptor\b|\bosascript\b|\bAEDesc\b|com\.apple\.Notes"#),
            ("NoteStore", #"NoteStore\.sqlite|group\.com\.apple\.notes"#),
            ("child process", #"\bProcess\s*\(\)|\bNSTask\b|\bposix_spawn\b"#),
            ("network", #"\bURLSession\b|\bNWConnection\b"#),
        ]
        var checked = 0
        for directory in directories {
            let urls = try FileManager.default.contentsOfDirectory(at: root.appending(path: directory), includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
            for url in urls {
                let text = NetworkAuditSourceScanTests.code(try String(contentsOf: url, encoding: .utf8))
                checked += 1
                for (name, pattern) in forbidden {
                    #expect(text.range(of: pattern, options: .regularExpression) == nil, "\(url.lastPathComponent): \(name)")
                }
            }
        }
        #expect(checked >= 15, "the scan sees the files")
    }

    @Test func theBriefSourcesNeverReadTheFieldsReminderAccessDoesNotNeed() throws {
        let root = NetworkAuditSourceScanTests.packageRoot()
        let text = try String(contentsOf: root.appending(path: "Sources/Vauta/App/Brief/EventKitBriefSources.swift"), encoding: .utf8)
        let code = NetworkAuditSourceScanTests.code(text)
        for field in [".notes", ".url", ".location", "alarms", "recurrenceRules", "completionDate"] where field != ".notes" {
            #expect(!code.contains("r\(field)") && !code.contains("reminder\(field)"), "reminders: \(field) is not read")
        }
        #expect(code.contains("incompleteReminders") && code.contains("predicateForIncompleteReminders"), "only incomplete reminders are fetched")
        #expect(!code.contains("predicateForCompletedReminders"))
    }

    // MARK: The model layer

    @Test func theAgendaRequestIsABriefRequestAndIsRefusedWhileRecording() async throws {
        let f = try KnowledgeFixture()
        let chat = ScriptedChat { _, _, _ in ScriptedChat.reply(#"{"agenda":[]}"#) }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        let adapters = service.briefAdapters()
        let schema = BriefAgendaPrompt.schema(offered: [])
        let reply = try await adapters.writer.write([.user("items")], schema: schema, maxTokens: 450, backend: .apple)
        #expect(reply.contains("agenda"))
        let call = try #require(chat.calls.first)
        #expect(call.options.purpose == .brief && call.options.priority == .brief && call.options.maxTokens == 450)
        #expect(call.options.outputSchema == nil, "Apple's model reads the shape from the prompt and the repair path")

        let meeting = try await f.store.startMeeting(at: .now)
        await service.setRecording(true, meetingID: meeting)
        await #expect(throws: LLMError.self) { try await adapters.writer.write([.user("items")], schema: schema, maxTokens: 450, backend: .apple) }
        #expect(chat.calls.count == 1, "no new model call while a meeting is recorded")
        let mode = await adapters.retriever.mode()
        let cosines = await adapters.retriever.cosines(query: "supplier change", texts: ["a"])
        #expect(mode == .keyword && cosines == nil)
    }

    @Test func embeddingsOnAModelServerNeverRankABrief() async throws {
        let f = try KnowledgeFixture()
        let providers = TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }, embedder: FakeEmbedder(space: EmbeddingSpace(model: "server-embed", dimensions: 8)))
        providers.onTheNetwork = true
        let service = LLMService(store: f.store, providers: providers)
        let retriever = service.briefAdapters().retriever
        #expect(await retriever.mode() == .keyword)
        #expect(await retriever.cosines(query: "supplier change shell", texts: ["Send the revised budget"]) == nil, "the topic is not sent to another computer to be embedded")
    }

    @Test func theBackendIsReadFromTheChosenProvider() async throws {
        let f = try KnowledgeFixture()
        func backend(onDevice: Bool, integrated: Bool) async -> BriefBackend? {
            await LLMService(store: f.store, providers: TestProviders(chat: ScriptedChat { _, _, _ in ScriptedChat.reply("{}") }, onDevice: onDevice, integrated: integrated)).briefBackend()
        }
        #expect(await backend(onDevice: true, integrated: false) == .apple)
        #expect(await backend(onDevice: false, integrated: true) == .integrated)
        #expect(await backend(onDevice: false, integrated: false) == .server)
        #expect(await LLMService(store: f.store, providers: TestProviders(chat: nil)).briefBackend() == nil)
    }
}
