// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The consent helper: the stored "participants informed" record, the reminder setting
/// and the notice in the meeting's language.
@Suite("Consent helper")
struct ConsentTests {
    private func record(_ store: MeetingStore, sourceApp: String? = nil, at date: Date = .now) async throws -> Int64 {
        let id = try await store.startMeeting(at: date, sourceApp: sourceApp)
        try await store.append(segment(.me, 0, "hello"), to: id)
        try await store.endMeeting(id, at: date + 60)
        return id
    }

    // MARK: Storage

    @Test func version11StoreMigratesAndGainsTheColumn() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 11)
        let store = try fx.open()
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        #expect(try await store.columnNames("meetings").contains("participants_informed_at"))
        #expect(try await store.meetings().count == 1, "old data is untouched")
        #expect(try await store.participantsInformedAt(1) == nil)
        try await store.markParticipantsInformed(1)
        #expect(try await store.participantsInformedAt(1) != nil)
    }

    @Test func markingStoresTheDateAndKeepsTheFirstOne() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await record(store)
        #expect(try await store.participantsInformedAt(id) == nil)
        let first = Date(timeIntervalSince1970: 1_760_000_000)
        try await store.markParticipantsInformed(id, at: first)
        try await store.markParticipantsInformed(id, at: first + 600)
        #expect(try await store.participantsInformedAt(id) == first)
    }

    @Test func aMistakenMarkCanBeTakenBack() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await record(store)
        try await store.markParticipantsInformed(id, at: Date(timeIntervalSince1970: 1_760_000_000))
        try await store.clearParticipantsInformed(id)
        #expect(try await store.participantsInformedAt(id) == nil)
        // Marking again afterwards records the new date.
        let again = Date(timeIntervalSince1970: 1_760_000_900)
        try await store.markParticipantsInformed(id, at: again)
        #expect(try await store.participantsInformedAt(id) == again)
    }

    @Test func theRecordSurvivesReopeningFromTheJournalAndFromASnapshot() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        let id = try await record(store!)
        let when = Date(timeIntervalSince1970: 1_760_000_000)
        try await store!.markParticipantsInformed(id, at: when)   // reaches the journal at once
        try await store!.flush()
        store = nil
        store = try fx.open()
        #expect(try await store!.participantsInformedAt(id) == when)
        try await store!.flush()   // a snapshot, no journal
        store = nil
        store = try fx.open()
        #expect(try await store!.participantsInformedAt(id) == when)
    }

    @Test func markingWorksWhileTheMeetingIsBeingRecorded() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        try await store.markParticipantsInformed(id)
        #expect(try await store.participantsInformedAt(id) != nil)
        try await store.endMeeting(id, at: .now)
    }

    @Test func informedBeforeIsPerMeetingApp() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let zoom = try await record(store, sourceApp: "zoom")
        _ = try await record(store, sourceApp: "teams")
        _ = try await record(store, sourceApp: nil)
        #expect(try await store.hasInformedParticipants(sourceApp: "zoom") == false)
        try await store.markParticipantsInformed(zoom)
        #expect(try await store.hasInformedParticipants(sourceApp: "zoom"))
        #expect(try await store.hasInformedParticipants(sourceApp: "teams") == false)
        #expect(try await store.hasInformedParticipants(sourceApp: nil) == false)
        let other = try await record(store, sourceApp: nil)
        try await store.markParticipantsInformed(other)
        #expect(try await store.hasInformedParticipants(sourceApp: nil), "no recorded app is its own group")
    }

    @Test func theRecordGoesWithItsMeetingOnDeleteAndRetention() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let day: TimeInterval = 86_400
        let old = try await record(store, sourceApp: "zoom", at: .now - 120 * day)
        let recent = try await record(store, sourceApp: "teams")
        try await store.markParticipantsInformed(old)
        try await store.markParticipantsInformed(recent)
        #expect(try await store.purgeExpired() > 0)
        #expect(try await store.participantsInformedAt(old) == nil)
        #expect(try await store.hasInformedParticipants(sourceApp: "zoom") == false, "the expired meeting took its record along")
        #expect(try await store.participantsInformedAt(recent) != nil)
        try await store.deleteMeeting(recent)
        #expect(try await store.hasInformedParticipants(sourceApp: "teams") == false)
    }

    @Test func eraseEverythingRemovesTheRecord() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await record(store, sourceApp: "zoom")
        try await store.markParticipantsInformed(id)
        try await store.eraseEverything()
        #expect(try await store.hasInformedParticipants(sourceApp: "zoom") == false)
        #expect(try await store.rowCount("meetings") == 0)
    }

    @Test func aBackupCarriesTheRecord() async throws {
        let source = StoreFixture()
        let store = try source.open()
        let id = try await record(store)
        let when = Date(timeIntervalSince1970: 1_760_000_000)
        try await store.markParticipantsInformed(id, at: when)
        let file = try await store.createBackup(password: "a long test password", appVersion: "0.9.0")
        let backup = try await MeetingStore.openBackup(file, password: "a long test password")
        let target = StoreFixture()
        let restored = try target.open()
        try await restored.restore(backup)
        let meeting = try #require(try await restored.meetings().first)
        #expect(try await restored.participantsInformedAt(meeting.id) == when)
    }

    @Test func theJSONExportHasTheDate() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await record(store)
        let plain = try #require(try await store.meetingExport(id))
        #expect(plain.participantsInformedAt == nil)
        let json = try MeetingExportJSON.encode(plain, options: ExportRendererTests.options)
        #expect(json.contains("\"participantsInformedAt\" : null"))

        try await store.markParticipantsInformed(id, at: Date(timeIntervalSince1970: 1_760_000_000))
        let marked = try #require(try await store.meetingExport(id))
        let text = try MeetingExportJSON.encode(marked, options: ExportRendererTests.options)
        #expect(text.contains("\"participantsInformedAt\" : \"2025-10-09T08:53:20Z\""))
    }

    // MARK: Reminder setting

    /// Under "First time per meeting app" only "Mark as Informed" ends the reminders: dismissing the
    /// reminder records nothing, so the next meeting from the same app is reminded again.
    @Test func dismissingTheReminderDoesNotCountAsInformed() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        // A meeting whose reminder was dismissed (nothing is stored for a dismissal).
        let dismissed = try await record(store, sourceApp: "zoom")
        #expect(try await store.participantsInformedAt(dismissed) == nil)
        var informedBefore = try await store.hasInformedParticipants(sourceApp: "zoom")
        #expect(!informedBefore && ConsentReminder.firstPerApp.shouldRemind(informedBefore: informedBefore))
        // "Mark as Informed" is what changes it.
        let informed = try await record(store, sourceApp: "zoom")
        try await store.markParticipantsInformed(informed)
        informedBefore = try await store.hasInformedParticipants(sourceApp: "zoom")
        #expect(informedBefore && !ConsentReminder.firstPerApp.shouldRemind(informedBefore: informedBefore))
    }

    @Test func theDismissActionStoresNothing() throws {
        let source = try String(contentsOf: NetworkAuditSourceScanTests.packageRoot()
            .appending(path: "Sources/Vauta/App/RecorderModel+Consent.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "func dismissConsentPrompt()"))
        let body = String(source[start.lowerBound...].prefix(while: { $0 != "}" }))
        #expect(!body.contains("markParticipantsInformed") && !body.contains("store"))
        let clear = try #require(source.range(of: "func clearConsentPrompt()"))
        #expect(!String(source[clear.lowerBound...].prefix(while: { $0 != "}" })).contains("store"))
    }

    @Test func theSpanishNoticeIsTheNeutralPlural() throws {
        let temp = try appBundle()
        defer { temp.remove() }
        let spanish = ConsentNotice.resolve(meetingLocale: "es-ES", bundle: temp.bundle).text
        #expect(spanish.contains("Avísenme") && spanish.contains("si prefieren"))
        #expect(!spanish.contains("Avísame") && !spanish.contains("si prefieres"))
    }

    @Test func reminderSettingDecidesWhenToRemind() {
        #expect(ConsentReminder.default == .always)
        #expect(ConsentReminder.always.shouldRemind(informedBefore: false))
        #expect(ConsentReminder.always.shouldRemind(informedBefore: true))
        #expect(ConsentReminder.firstPerApp.shouldRemind(informedBefore: false))
        #expect(!ConsentReminder.firstPerApp.shouldRemind(informedBefore: true))
        #expect(!ConsentReminder.never.shouldRemind(informedBefore: false))
        #expect(!ConsentReminder.never.shouldRemind(informedBefore: true))
        #expect(ConsentReminder(rawValue: "firstPerApp") == .firstPerApp)
    }

    // MARK: The notice

    private static let languages = ["en", "es", "fr", "de", "it", "pt-BR", "ja", "ko", "zh-Hans"]

    /// A bundle holding the real translations, like the app bundle. Its folder is removed by `remove()`: call it in a `defer`.
    func appBundle(in parent: URL = FileManager.default.temporaryDirectory, resources: URL = LocalizationTests.resources) throws -> TemporaryBundle {
        let dir = parent.appendingPathComponent("vauta-consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            for language in Self.languages {
                try FileManager.default.copyItem(at: resources.appendingPathComponent("\(language).lproj"),
                                                 to: dir.appendingPathComponent("\(language).lproj"))
            }
            return TemporaryBundle(url: dir, bundle: try #require(Bundle(url: dir)))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// The notice is pasted to other people. A model server may run on another computer of the user's network, so it
    /// must not say the app "runs only on my Mac"; the claim that holds in every setup is that nothing goes to the internet.
    @Test func noticeNeverPromisesMoreThanNothingGoesToTheInternet() throws {
        let temp = try appBundle()
        defer { temp.remove() }
        let words = ["en": "internet", "de": "internet", "es": "internet", "fr": "internet", "it": "internet",
                     "pt-BR": "internet", "ja": "インターネット", "ko": "인터넷", "zh-Hans": "互联网"]
        for (language, word) in words {
            for voices in [false, true] {
                let text = ConsentNotice.resolve(meetingLocale: language, recognizesVoices: voices, bundle: temp.bundle).text
                #expect(text.localizedCaseInsensitiveContains(word), "\(language) voices=\(voices)")
                for banned in ["only on my Mac", "uploaded", "solo en mi Mac", "nur auf meinem Mac", "uniquement sur mon Mac",
                               "solo sul mio Mac", "apenas no meu Mac", "だけで動作", "에서만 실행", "只在我自己的"] {
                    #expect(!text.contains(banned), "\(language) voices=\(voices): \(banned)")
                }
            }
        }
    }

    @Test func everyLanguageHasItsOwnNotice() throws {
        let temp = try appBundle()
        defer { temp.remove() }
        let bundle = temp.bundle
        var seen: Set<String> = []
        for language in Self.languages {
            let resolved = ConsentNotice.resolve(meetingLocale: language, bundle: bundle)
            #expect(resolved.language == language, "\(language)")
            #expect(resolved.text != ConsentNotice.key && resolved.text.count > 40, "\(language)")
            #expect(!resolved.text.contains("%"), "a notice has no placeholders (\(language))")
            #expect(seen.insert(resolved.text).inserted, "each language has its own text (\(language))")
        }
    }

    @Test func theNoticeFollowsTheMeetingLanguageNotTheInterface() throws {
        let temp = try appBundle()
        defer { temp.remove() }
        let bundle = temp.bundle
        let spanish = ConsentNotice.resolve(meetingLocale: "es-ES", bundle: bundle)
        #expect(spanish.language == "es" && spanish.text.contains("transcribiendo"))
        #expect(ConsentNotice.text(meetingLocale: "ja-JP", bundle: bundle).contains("文字起こし"))
        #expect(ConsentNotice.text(meetingLocale: "pt-PT", bundle: bundle).contains("transcrevendo"))
        #expect(ConsentNotice.text(meetingLocale: "en-GB", bundle: bundle).contains("transcribing"))
        #expect(ConsentNotice.resolve(meetingLocale: "zh-CN", bundle: bundle).language == "zh-Hans")
    }

    @Test func aLanguageWithoutTranslationFallsBackToTheInterfaceLanguage() throws {
        let temp = try appBundle()
        defer { temp.remove() }
        let bundle = temp.bundle
        let fallback = ConsentNotice.resolve(meetingLocale: nil, bundle: bundle)
        for unknown in ["nl-NL", "ru-RU", "zh-TW", "zh-Hant-HK", "", "not a locale"] {
            #expect(ConsentNotice.resolve(meetingLocale: unknown, bundle: bundle) == fallback, "\(unknown)")
        }
    }

    @Test func withoutResourcesTheNoticeIsTheEnglishSource() {
        let empty = Bundle(for: BundleToken.self)
        let notice = ConsentNotice.resolve(meetingLocale: "es-ES", bundle: empty)
        #expect(notice.text.contains("transcribing") && notice.language == nil)
    }

    @Test func theNoticeAlsoSaysSoOnlyWhileRecognitionIsOn() throws {
        let temp = try appBundle()
        defer { temp.remove() }
        let bundle = temp.bundle
        for language in Self.languages {
            let plain = ConsentNotice.resolve(meetingLocale: language, bundle: bundle)
            let voices = ConsentNotice.resolve(meetingLocale: language, recognizesVoices: true, bundle: bundle)
            #expect(voices.language == plain.language, "\(language)")
            #expect(voices.text != plain.text && voices.text.count > plain.text.count, "\(language): a notice of its own, longer than the plain one")
            #expect(!voices.text.contains(ConsentNotice.voicesKey) && !voices.text.contains("%"), "\(language)")
            #expect(voices.text.contains(String(VoiceProfileThresholds.keptSummaryDays)), "\(language): the notice states the kept-summary days")
            #expect(ConsentNotice.text(meetingLocale: language, bundle: bundle) == plain.text, "off is the notice as before")
        }
        let english = ConsentNotice.resolve(meetingLocale: "es-ES", recognizesVoices: true, bundle: Bundle(for: BundleToken.self))
        #expect(english.language == nil && english.text.contains("suggest who is speaking"))
    }

    private final class BundleToken {}
}
