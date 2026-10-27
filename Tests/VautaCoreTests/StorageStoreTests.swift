// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import VautaCore

@Suite("Storage: files, recording and search")
struct StorageStoreTests {
    @Test func filesAreEncryptedPrivateAndExcludedFromBackup() async throws {
        let fx = StoreFixture()
        let secret = "presupuestoconfidencial"
        var store: MeetingStore? = try fx.open()
        #expect(fx.permissions(fx.dir) == 0o700)
        #expect(try await store!.pragma("temp_store") == 2, "SQLite keeps temporaries in memory")
        let id = try await store!.startMeeting(at: .now)
        try await store!.append(segment(.others, 1, "Revisamos el \(secret) del tercer trimestre"), to: id)
        try await store!.endMeeting(id, at: .now)
        store = nil

        let raw = try Data(contentsOf: fx.snapshotURL)
        #expect(raw.starts(with: SnapshotEnvelope.header(.current)))
        #expect(raw.range(of: Data(secret.utf8)) == nil)
        #expect(raw.range(of: Data("SQLite format".utf8)) == nil)
        #expect(fx.permissions(fx.snapshotURL) == 0o600)
        let excluded = try fx.dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fx.dir.path).allSatisfy { !$0.hasPrefix(MeetingStore.tempPrefix) })
    }

    @Test func aNewStoreNeverAdoptsAKeyThatWasAlreadyThere() async throws {
        let fx = StoreFixture()
        // Planted by another process before Vauta created its store.
        let planted = SymmetricKey(size: .bits256)
        try fx.keys.replace(with: planted)
        var store: MeetingStore? = try fx.open()
        let id = try await store!.startMeeting(at: .now)
        try await store!.endMeeting(id, at: .now)
        store = nil
        let key = try #require(fx.keys.key)
        #expect(key != planted)
        #expect(throws: (any Error).self) { try SnapshotEnvelope.open(Data(contentsOf: fx.snapshotURL), key: planted) }
        #expect((try? fx.open()) != nil, "the store opens with the key it created")
    }

    @Test func secondInstanceIsLockedOut() async throws {
        let fx = StoreFixture()
        do {
            let store = try fx.open()
            await expectStoreError(.alreadyOpen) { try fx.open(waitForLock: false) }
            withExtendedLifetime(store) {}
        }
        #expect((try? fx.open()) != nil, "releasing the store releases the lock")
    }

    @Test func inheritedPermissionsAreRepaired() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        try await store!.flush()
        store = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fx.snapshotURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.dir.path)
        store = try fx.open()
        #expect(fx.permissions(fx.snapshotURL) == 0o600)
        #expect(fx.permissions(fx.dir) == 0o700)
    }

    @Test func readOnlyOpenNeverCreatesAStoreOrKey() async throws {
        let fx = StoreFixture()
        await expectStoreError(.storeNotFound) { try fx.open(createIfMissing: false) }
        #expect(!fx.exists(fx.dir))
        #expect(fx.keys.key == nil)

        var store: MeetingStore? = try fx.open()
        try await store!.flush()
        store = nil
        let stats = try await fx.open(createIfMissing: false).stats()
        #expect(stats.fileBytes > 0 && stats.meetings == 0)
    }

    @Test func dataSurvivesReopenWithChannelCodes() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        let id = try await store!.startMeeting(at: .now)
        try await store!.append(segment(.others, 1, "Revisamos el presupuesto"), to: id)
        try await store!.append(segment(.me, 4, "La migración la hace Juan antes del viernes"), to: id)
        try await store!.endMeeting(id, at: .now)
        store = nil
        store = try fx.open()
        #expect(try await store!.segments(of: id).map(\.channel) == [.others, .me])
        #expect(try await store!.speakerCodes(id) == ["others", "me"])
    }

    @Test func highlightRunsDropTheMarkers() {
        let (s, e) = (SearchHighlight.start, SearchHighlight.end)
        let runs = SearchHighlight.runs(in: "…dijo «\(s)hola\(e)» a \(s)Ana\(e)")
        #expect(runs.map(\.text) == ["…dijo «", "hola", "» a ", "Ana"])
        #expect(runs.map(\.isMatch) == [false, true, false, true])
        #expect(SearchHighlight.runs(in: "plain").map(\.text) == ["plain"])
        #expect(SearchHighlight.runs(in: "cut \(s)mid").map(\.isMatch) == [false, true], "an unterminated match runs to the end")
        #expect(SearchHighlight.runs(in: "").isEmpty)
    }

    @Test func searchFoldsDiacriticsMatchesPrefixesAndIgnoresSyntax() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        try await store.append(segment(.others, 1, "Revisamos el presupuestoconfidencial del trimestre"), to: id)
        try await store.append(segment(.me, 4, "La migración la hace Juan"), to: id)
        try await store.append(segment(.me, 8, "Il a dit « bonjour » à tout le monde"), to: id)
        try await store.endMeeting(id, at: .now)

        #expect(try await store.search("migracion").first?.segment.channel == .me)
        let prefix = try #require(try await store.search("presupuestocon").first)
        #expect(prefix.snippet.contains("\(SearchHighlight.start)presupuestoconfidencial\(SearchHighlight.end)"))
        #expect(try await store.search("\") OR 1=1 --").isEmpty)

        // Quotation marks in the transcript are text, never highlight markers.
        let quoted = try #require(try await store.search("bonjour").first)
        #expect(quoted.snippet.contains("« \(SearchHighlight.start)bonjour\(SearchHighlight.end) »"))
        #expect(SearchHighlight.runs(in: quoted.snippet).filter(\.isMatch).map(\.text) == ["bonjour"])
        #expect(try await store.search("bonjour", in: [id + 1]).isEmpty, "scoped search excludes other meetings")
        #expect(try await store.search("bonjour", in: [id]).count == 1)
    }

    @Test func startMeetingRefusesASecondActiveMeeting() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let first = try await store.startMeeting(at: .now)
        await expectStoreError(.meetingAlreadyActive) { try await store.startMeeting(at: .now) }
        #expect(await store.activeMeetingID == first)
        await expectStoreError(.meetingInProgress) { try await store.deleteMeeting(first) }
        try await store.append(segment(.me, 0, "hola"), to: first)
        try await store.endMeeting(first, at: .now)
        let second = try await store.startMeeting(at: .now)
        #expect(second != first)
    }

    @Test func startMeetingStoresLanguageAndSource() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        let id = try await store!.startMeeting(at: .now, locale: Locale(identifier: "fr_FR"), outputLocale: Locale(identifier: "en_US"),
                                               sourceApp: "us.zoom.xos")
        try await store!.append(segment(.others, 0, "bonjour"), to: id)
        try await store!.endMeeting(id, at: .now)
        store = nil
        store = try fx.open()
        let meeting = try #require(try await store!.meeting(id))
        #expect(meeting.locale == "fr-FR")
        #expect(meeting.outputLocale == "en-US")
        #expect(meeting.sourceApp == "us.zoom.xos")
        #expect(meeting.transcriptionLocale.identifier(.bcp47) == "fr-FR")
        #expect(meeting.minutesLocale.identifier(.bcp47) == "en-US")
        #expect(try await store!.search("bonjour").first?.meeting == meeting, "search hits carry the full meeting")

        let defaults = try await store!.startMeeting(at: .now)
        let legacy = try #require(try await store!.meeting(defaults))
        #expect(legacy.locale == nil && legacy.outputLocale == nil && legacy.sourceApp == nil)
        #expect(legacy.minutesLocale.identifier == MeetingStore.Meeting.legacyLocaleIdentifier)
    }

    @Test func titlesAreOptionalWithALocalizedFallback() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        try await store.append(segment(.me, 0, "hola"), to: id)
        try await store.endMeeting(id, at: .now)
        var meeting = try #require(try await store.meeting(id))
        #expect(meeting.title == nil)
        #expect(!meeting.displayTitle.isEmpty)

        try await store.setTitle("  Weekly sync  ", of: id)
        meeting = try #require(try await store.meeting(id))
        #expect(meeting.title == "Weekly sync" && meeting.displayTitle == "Weekly sync")

        try await store.setTitle("   ", of: id)
        #expect(try await store.meeting(id)?.title == nil, "an empty title goes back to automatic")
    }

    @Test func blobAndIDListRoundTrip() async throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try db.execute("CREATE TABLE blobs(id INTEGER PRIMARY KEY, b BLOB)")
        let blob = Data((0..<1024).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        try db.execute("BEGIN")
        for i in 1...3000 { try db.query("INSERT INTO blobs(id, b) VALUES (?, ?)", [.integer(Int64(i)), .blob(i == 7 ? blob : Data([1]))]) }
        try db.execute("COMMIT")
        #expect(try db.query("SELECT b FROM blobs WHERE id = 7").first?.data(0) == blob)
        let wanted = (1...1000).map { Int64($0 * 3) }
        let rows = try db.query("SELECT id FROM blobs WHERE id IN (SELECT value FROM json_each(?)) ORDER BY id", [.ids(wanted)]).map { $0.int(0) }
        #expect(rows == wanted)
        #expect(try db.query("SELECT COUNT(*) FROM blobs WHERE id IN (SELECT value FROM json_each(?))", [.ids([])])[0].int(0) == 0)
        #expect(try db.query("SELECT length(?)", [.blob(Data())])[0].int(0) == 0, "an empty BLOB is not NULL")
    }

    @Test func invalidImageIsRejected() throws {
        let garbage = "this is not a database image, just some text".utf8
        let buffer = try #require(sqlite3Copy(Data(garbage)))
        #expect(throws: StoreError.self) { _ = try SQLiteDatabase(image: buffer, size: garbage.count) }
    }
}

/// Copies bytes into `sqlite3_malloc64` memory, as `SnapshotEnvelope.open` returns them.
private func sqlite3Copy(_ data: Data) -> UnsafeMutableRawPointer? {
    guard let p = sqlite3_malloc64(UInt64(data.count)) else { return nil }
    data.copyBytes(to: p.assumingMemoryBound(to: UInt8.self), count: data.count)
    return p
}
