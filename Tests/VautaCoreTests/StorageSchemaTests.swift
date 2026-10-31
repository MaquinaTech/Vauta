// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Storage schema and migrations")
struct StorageSchemaTests {
    @Test func versionsAreStrictlyIncreasingAndContiguous() {
        let versions = Schema.migrations.map(\.version)
        #expect(versions.first == 1)
        #expect(versions == Array(1...SchemaVersion(versions.count)))
        #expect(Schema.currentVersion == versions.last)
        #expect(Schema.currentVersion == 36)
    }

    // Published migrations are frozen in `SchemaFreezeTests` (the v7 fixtures here rely on it).

    @Test func freshDatabaseGetsTheCurrentSchema() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        #expect(try Schema.migrate(db))
        #expect(try Schema.version(of: db) == Schema.currentVersion)
        #expect(try !Schema.migrate(db), "migrating again changes nothing")
        let columns = try db.query("SELECT name FROM pragma_table_info('meetings')").map { $0.string(0) }
        #expect(columns.suffix(9) == ["output_locale", "source_app", "template", "participants_informed_at", "speakers_off", "imported", "time_zone", "follow_ups_recipe", "links_recipe"])
        let jobColumns = try db.query("SELECT name FROM pragma_table_info('llm_jobs')").map { $0.string(0) }
        #expect(jobColumns.last == "last_error_code")
        #expect(try db.query("PRAGMA foreign_keys")[0].int(0) == 1)
    }

    @Test func version7StoreMigratesToTheCurrentSchema() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 7) { db in
            try StoreFixture.legacyMeeting(db)
            // A speaker value that is neither legacy label nor code stays untouched.
            try db.query("INSERT INTO segments(meeting_id, speaker, start, end, text) VALUES (1, 'Invitado', 6, 7, 'otra voz')")
            try db.query("INSERT INTO llm_jobs(meeting_id, kind, created_at, last_error) VALUES (1, 'acta', 0, 'el servidor no responde')")
        }
        let store = try fx.open()
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        #expect(try await store.speakerCodes(1) == ["me", "others", "Invitado"])
        #expect(try await store.segments(of: 1).map(\.channel) == [.me, .others, .others])
        let meeting = try #require(try await store.meetings().first)
        #expect(meeting.title == "Reunión heredada")
        #expect(meeting.locale == nil && meeting.outputLocale == nil && meeting.sourceApp == nil)
        #expect(meeting.transcriptionLocale.identifier == "es-ES")
        #expect(meeting.minutesLocale.identifier == "es-ES")
        #expect(try await store.search("heredado").count == 1)
        #expect(try await store.columnNames("meetings").suffix(9) == ["output_locale", "source_app", "template", "participants_informed_at", "speakers_off", "imported", "time_zone", "follow_ups_recipe", "links_recipe"])
        #expect(try await store.minutesTemplate(1) == nil)
    }

    @Test func migratedStoreIsSavedAndReopens() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 7)
        var store: MeetingStore? = try fx.open()
        try await store!.flush()   // migration forces a snapshot
        store = nil
        store = try fx.open()
        #expect(try await store!.pragma("user_version") == Schema.currentVersion)
        #expect(try await store!.speakerCodes(1) == ["me", "others"])
    }

    @Test func version2StoreMigratesAndKeepsData() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 2)
        var store: MeetingStore? = try fx.open(recover: true)
        #expect(try await store!.pragma("user_version") == Schema.currentVersion)
        let legacy = try await store!.meetings()
        #expect(legacy.count == 1)
        #expect(try await store!.segments(of: legacy[0].id).map(\.channel) == [.me, .others])
        #expect(try await store!.search("heredado").count == 1)
        store = nil
        store = try fx.open()
        #expect(try await store!.segments(of: legacy[0].id).count == 2)
    }

    /// Migration 9: a v8 store whose alias keys were computed with the 0.1.0
    /// normalization (which kept ł and ø and Arabic vowel marks) is rekeyed,
    /// so those aliases match transcripts again.
    @Test func version8AliasKeysAreRecomputedAndMatchTranscripts() async throws {
        let names = ["Łukasz", "Bjørn", "مُحَمَّد"]
        for name in names { #expect(Self.normV1(name) != TextKeys.norm(name), "the fixture must use a key that changed") }
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: 8) { db in
            for (i, name) in names.enumerated() {
                let id = Int64(i + 1)
                try db.query("INSERT INTO entities(id, kind, name, created_at) VALUES (?, 'person', ?, 0)", [.integer(id), .text(name)])
                try db.query("INSERT INTO aliases(alias_norm, alias, entity_id, source) VALUES (?, ?, ?, 'user')",
                             [.text(Self.normV1(name)), .text(name), .integer(id)])
            }
        }
        let store = try fx.open()
        #expect(try await store.pragma("user_version") == Schema.currentVersion)
        let keys = try await store.stringsForTest("SELECT alias_norm FROM aliases ORDER BY entity_id")
        #expect(keys == names.map { TextKeys.norm($0) })

        let id = try await store.startMeeting(at: .now)
        try await store.append(segment(.others, 0, "Hablé con Łukasz y con Bjørn"), to: id)
        try await store.append(segment(.me, 2, "Y luego con محمد"), to: id)
        try await store.endMeeting(id, at: .now + 60)
        for entity: Int64 in 1...3 {
            #expect(try await store.refs(entity).map(\.meeting.id) == [id], "entity \(entity) is found in the transcript")
        }
    }

    /// `TextKeys.norm` as Acta 0.1.0 computed it (Spanish-locale folding).
    private static func normV1(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                  locale: Locale(identifier: "es_ES"))
        var out = ""
        var pendingSpace = false
        for ch in folded {
            if ch.isLetter || ch.isNumber {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    @Test func newerSchemaIsRefusedAndLeftUntouched() async throws {
        let fx = StoreFixture()
        try fx.writeLegacyStore(schema: Schema.currentVersion, userVersion: Schema.currentVersion + 1)
        let before = try Data(contentsOf: fx.snapshotURL)
        await expectStoreError(.newerSchema) { try fx.open(recover: true) }
        #expect(try Data(contentsOf: fx.snapshotURL) == before)
    }

    @Test func codeStepRunsInsideTheMigrationTransaction() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db)
        try db.query("INSERT INTO meetings(started_at) VALUES (1)")
        let base = Schema.currentVersion
        let ok = Schema.migrations + [Migration(base + 1, .code { db in
            #expect(try db.query("SELECT 1 FROM sqlite_schema").count > 0)
            try db.query("UPDATE meetings SET title = 'from code'")
        })]
        #expect(try Schema.migrate(db, using: ok))
        #expect(try db.query("SELECT title FROM meetings")[0].string(0) == "from code")
        #expect(try Schema.version(of: db) == base + 1)

        // A failing step rolls back its own changes and the version.
        let failing = ok + [Migration(base + 2, .sql("UPDATE meetings SET title = 'half done'"), .code { _ in
            throw StoreError("boom")
        })]
        do {
            try Schema.migrate(db, using: failing)
            Issue.record("the migration should fail")
        } catch let error as StoreError {
            #expect(error.code == .migrationFailed)
        }
        #expect(try db.query("SELECT title FROM meetings")[0].string(0) == "from code")
        #expect(try Schema.version(of: db) == base + 1)
    }

    /// The documented rebuild helper widens a CHECK constraint on a populated
    /// table that references `meetings`, keeping rows and foreign keys.
    @Test func tableRebuildWidensACheckConstraint() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db)
        try db.query("INSERT INTO meetings(id, started_at) VALUES (1, 0), (2, 0)")
        try db.query("INSERT INTO llm_jobs(meeting_id, kind, created_at) VALUES (1, 'acta', 0), (2, 'embed', 0)")
        let columns = "id, meeting_id, kind, state, attempts, last_error, not_before, created_at, updated_at, last_error_code"
        let rebuild = Migration.rebuild(Schema.currentVersion + 1, table: "llm_jobs", definition: """
            (
                id INTEGER PRIMARY KEY,
                meeting_id INTEGER NOT NULL REFERENCES meetings(id) ON DELETE CASCADE,
                kind TEXT NOT NULL CHECK(kind IN ('acta','embed','title')),
                state TEXT NOT NULL DEFAULT 'queued' CHECK(state IN ('queued','running','done','failed')),
                attempts INTEGER NOT NULL DEFAULT 0,
                last_error TEXT,
                not_before REAL,
                created_at REAL NOT NULL,
                updated_at REAL,
                last_error_code TEXT
            )
            """, columns: columns, then: """
            CREATE UNIQUE INDEX llm_jobs_pending ON llm_jobs(meeting_id, kind) WHERE state IN ('queued','running');
            """)
        #expect(try Schema.migrate(db, using: Schema.migrations + [rebuild]))
        #expect(try db.query("PRAGMA foreign_keys")[0].int(0) == 1, "foreign keys are enabled again")
        #expect(try db.query("SELECT count(*) FROM llm_jobs")[0].int(0) == 2)
        try db.query("INSERT INTO llm_jobs(meeting_id, kind, created_at) VALUES (1, 'title', 0)")
        try db.query("DELETE FROM meetings WHERE id = 1")
        #expect(try db.query("SELECT count(*) FROM llm_jobs")[0].int(0) == 1, "ON DELETE CASCADE still applies")
        #expect(try db.query("SELECT 1 FROM sqlite_schema WHERE name = 'llm_jobs_pending'").count == 1)
        #expect(try db.query("SELECT 1 FROM sqlite_schema WHERE name = 'llm_jobs_new'").isEmpty)
    }

    @Test func failedRebuildRestoresForeignKeys() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db)
        let broken = Migration.rebuild(Schema.currentVersion + 1, table: "llm_jobs", definition: "(id INTEGER PRIMARY KEY)",
                                       columns: "id, no_such_column")
        #expect(throws: StoreError.self) { try Schema.migrate(db, using: Schema.migrations + [broken]) }
        #expect(try db.query("PRAGMA foreign_keys")[0].int(0) == 1)
        #expect(try Schema.version(of: db) == Schema.currentVersion)
    }
}
