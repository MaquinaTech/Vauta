// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore

/// Published migrations are frozen: stores out there already ran them, so an edit would leave those stores with a schema or data
/// this build does not expect. A change to the schema is a new migration.
///
/// A migration is published once it is merged to `main`, not only once it is in a release: Vauta is built from source and
/// `scripts/install.sh` builds whatever is checked out, so stores built from `main` already ran every migration merged there.
/// Every migration in `Schema.migrations` is therefore frozen here. The pull request that adds one also adds its fingerprint (the
/// failing test prints it); while that pull request is open, an edit to it only updates its line. A change to any other line of
/// the table edits a published migration.
@Suite("Storage schema: published migrations are frozen")
struct SchemaFreezeTests {
    /// What each migration leaves, applied one at a time on an empty database: the number of objects in `sqlite_schema`, the
    /// SHA-256 of their dump (type, name, table and SQL, sorted), and the SHA-256 of the migration's steps. The steps' hash covers
    /// their SQL text, so also the statements that only change data, which `sqlite_schema` does not show; a code step counts by
    /// its place only, and what it writes is checked on seeded rows below. Version 7 is the schema Acta 0.1.0 created (computed
    /// from the 0.1.0 SQL), which is also what makes the v7 fixtures of `StorageSchemaTests` equivalent to real 0.1.0 stores.
    static let fingerprints: [Fingerprint] = [
        Fingerprint(1, 10, "8e061852457a7bb7a707e714a6782fe4d81ef3257db3d389a4c9342b91a5c8de", "bafafe7c52dfba7623464b04c9ca07c43e4fbfb18cba14e503963be01b7bf9d7"),
        Fingerprint(2, 11, "35a735e2e8ce0d3be877f0122737bb951164f3fd654f4db397dc2d12add35c50", "c893151da11510a474a54e768e650e1cd248d13852857d6d7766c3ae95b935c8"),
        Fingerprint(3, 16, "9ce4d4ab6fc1091c8fa08bbe4a87b7e190385cb6f28e6f840e5457e443ff66fb", "110adb9aabc5521377cb3ca78244ba9ebb7822765594fa629a1328376a7f4e61"),
        Fingerprint(4, 73, "b1fa5e493e19acf6e0a8a1189674d367a5c58fe0f146acc462bcce84f7eb21be", "b14dcf2bd79bbf3d3ae39fa8782a98ed60e6a9fb646ee495f3531c41da74a852"),
        Fingerprint(5, 76, "bd451fec13148b2d09787ebac7adf40ac823bd835faae4ba75f029310a44681f", "95b416e16cec08c44f13c15a7a86ab3185085d21b15a2795b6e3c92b8e78a5f9"),
        Fingerprint(6, 76, "bd451fec13148b2d09787ebac7adf40ac823bd835faae4ba75f029310a44681f", "67cf9e2eb72587d4f97e8c62f86fc2de1093ea02e1c718f494c9bea01e5b82d5"),
        Fingerprint(7, 82, "915f7c68ba7445434dbcb987e5500fee322d4f47d71975632ff0538cdd47fcfd", "4f7ee52a265cf7c8b72277a900af8fd48f201577cb8d15ab8871c6b6972accee"),
        Fingerprint(8, 82, "b785064854da925b8552867dde05ae76363de16407a497318f162c66ac63d845", "f9475ed2bd8d60b8d9740dbbd38add82a38fb44f111671f26d62f22e8c8e26f4"),
        Fingerprint(9, 82, "b785064854da925b8552867dde05ae76363de16407a497318f162c66ac63d845", "b57b236c9bcd2a61fcd627b69ae2d7a6eb5bc13f2dc25311348ee08df43bc0c4"),
        Fingerprint(10, 82, "dd77fb0365a285b4c22fac6ff768dc007d3dac86660741132a01e57bc63109ac", "7bc523eba4bcc506b9e4d695c800b4d9137ef8a8582cafdd77fcbf2dc6906a46"),
        Fingerprint(11, 83, "36509c095210240b1a4921a660f7a58a4e8e094cf1cf81f53602a1d2f542b10b", "3b6c6be5a66cc54719fb2662bd3a9a97afdcad1e1cb2d77a7b1b9ed94f263098"),
        Fingerprint(12, 83, "58ce352b14e6baeb5d99118a5d6a09905303b546df04a72cce01b857c640f205", "df637cbb4907d4f945926768e15985aaaf203ddcb8f3dec1c4ad186889ad9799"),
        Fingerprint(13, 83, "5146d458b4f3249713b511c041b86bd8fd0bea70182bdb5a41a21a2b80ec0016", "485cb712f713daaf14e5f23e51886e91366effc492670e082d5d0b7ce88bdd2d"),
        Fingerprint(14, 93, "af9cf1113c9c73105ce1e8b9138eb000c2570da56a21bad808fdda48eea61597", "2c74ec2970c6fedb1579853be78417b387d39061f849f1186f19a541cd9ba76d"),
        Fingerprint(15, 94, "ff84da096262a8096bb8aeddce39e3bcbbf3532b2cd0c44b8b7ddae295dd7f8e", "63bd12dd5030420f574317f01d7cd70ce7a35e1246449751f92c5de7af69246d"),
        Fingerprint(16, 94, "bf71fe9b73e9299eed7361a66da59c8e8c721cccb4f63f45ea11b821bf255748", "16896b9b36162402386011ec114aeaa4f207a7c582c64e765b519ea95b09679f"),
        Fingerprint(17, 94, "8600711ddca3d29c216cb43fb1911d16d1ff9382b7775da629e0822b614cc44a", "90b81cf5304c1bc8391f128e5ffc52fe5573466467ef1ee68ec01f91913297d6"),
        Fingerprint(18, 96, "bc9482385924f203fcdad98b6fa820239a8cb825a093e75779daa9416ef4dd88", "96af72111547ca0d4bf5a54ed51a69280edb9c94472558a5d6706b005bde31b4"),
        Fingerprint(19, 96, "881b6ef753bc9eac1e682cfe213f612c8a0a47fe628ae58c351474c6d2a9bcd5", "c55278b4d62b58af6cab25522d304fbc94a5dc08a68ddca4db21a6eae5d4a100"),
        Fingerprint(20, 96, "881b6ef753bc9eac1e682cfe213f612c8a0a47fe628ae58c351474c6d2a9bcd5", "9437e67e0413d163b560e4b142dc08e3e80092d2336f0548c48d4e78e7e33883"),
        Fingerprint(21, 97, "5d4566017f4050fddb0656016f79dd7e7103ef4da0b81078e213f069e96e08d9", "4a5854236525251ba6e20e3a956e4b62a599277dbca8eaa937d352958bd2255e"),
        Fingerprint(22, 102, "8bbf16aa3574d6c4833f60d942c735599510e8ba57abbe78d9c42988eec94ee7", "9dbb8fab2eea5190bbea174eb0d251ba2b4b809c6dc00b48f407c2ccd7668648"),
        Fingerprint(23, 106, "b8de18d2735eaa492fcb9af1df36dadd2cf1b07615f121ff3018fbb93b1a388e", "a19d53a199ae4957e2d685046fd049312de03d76184feb85e4f1d9afc0bb0a83"),
        Fingerprint(24, 106, "b8de18d2735eaa492fcb9af1df36dadd2cf1b07615f121ff3018fbb93b1a388e", "5252b619c2f1447d969f7870fc61fa48b4842ceea5072946d96f38a28d829e7f"),
        Fingerprint(25, 106, "a791799096d4d15d37ad34fb2cd216e35530169e1a4a7c49d1171f75570f0195", "9e4c9b469bc0195fed28e4bd88a9422a625d6a8e677350a636caffcc5aa2e544"),
        Fingerprint(26, 111, "a1dd65199447c0615ef85adb436d9848f3de5300de099f961de27ede64623d54", "9151340e5f76a1baba24a8c6a7053c1af88b27947b01a6ee980b787202d5e8d8"),
        Fingerprint(27, 112, "70acb21d6b28b49b0a877263a003c399cdf2a3abd847a2301e8e62292e8ea083", "46585dc9938bdf4fff5362af75ff0f00225113e1da3da230a946ac46094380aa"),
        Fingerprint(28, 119, "cc0f270e52b99a307c7253c4a327ac3ddb097d51e77752b4572049bc613563df", "7c03b8b57b4fd9936fe4e968f5c0c5589bad7a778f7f0e1bf778ac8734f79420"),
        Fingerprint(29, 119, "720a2bc93b234bddbb8879b94feef43122b278f5f374f28372208150937ae68b", "3dff9b531f9fe5a15713d6427581e37682967f57e52b377aad8bc427cc06891e"),
        Fingerprint(30, 129, "beaae1e57080e471df4116e5790239158de89883c2523da4f9cf5473b3db80b8", "34d8d011ddeda063fe6efe1bef626ceb2b7769d54538a8ccbf86721ae47c2e1e"),
        Fingerprint(31, 129, "35825f6f40868ae5694534966fc38bfe4c9b5e90f017a03af80ba6cf127f5b41", "74deedefa09081ec1ae1e94eb085e59b03a84f2ae79500be762dc93d5331afb9"),
        Fingerprint(32, 129, "e2420aeace67211ac8eb77e58364c2f1f9a8e6821d0edefce3e583b82624a760", "03fd3ecb6b31aef1fb1e680d9fe9f490f3669a513b1df61cf22082be49550fbc"),
        Fingerprint(33, 130, "dd5b19f765c09694bac604fb27085621c2f4d13dcfbd43ae84332ad7ba799e90", "d7a78fd7c2e6cd317be65358413354dd52d793989641e23c61846946579f6c3d"),
        Fingerprint(34, 131, "229c4b30098587e25707abf52cd44fe386bba1d3df3f488010c36cbc23ef89d1", "2bbc66ecde3e976eaa2d836c97c3d8a272eef7541c3829922cbad5b17058e098"),
        Fingerprint(35, 133, "f11cf70cacad85c97114c94efdda9cffa81375171fb9f1615834b10fcff9eabb", "fa547442c27c475dd9de6bb482c789522eadaece4ecad4e716077c972fac4e96"),
        Fingerprint(36, 133, "7e865426c6be15fbe325264ef7952cb04b01e511c8ee02c285bbcb389a9416bf", "4fbff3b4e443e9283c8569f44d42f243206f5634b6824dca4f671a38f24b755e"),
        Fingerprint(37, 134, "b6eb7f85e6f01f7860402f73d1e8b75df382de5baf1217e8f412b51a2203ebd2", "5155f91af8598cfd3040112dbe893e7b970b2bacf5f148a434d6b5f32b1d16fd"),
        Fingerprint(38, 134, "edf66f52c4fdfb07f0b6fa70f95a8a9657d2048010a397327a5b8a746030e69a", "16b2e4724ba8e41bb3bbb83608e448ecaa91b939eb3c6ebefadfe0daee55e7ee"),
    ]

    struct Fingerprint: Equatable, CustomStringConvertible {
        let version: SchemaVersion
        let objects: Int
        let schema: String
        let steps: String

        init(_ version: SchemaVersion, _ objects: Int, _ schema: String, _ steps: String) {
            self.version = version
            self.objects = objects
            self.schema = schema
            self.steps = steps
        }

        var description: String { "Fingerprint(\(version), \(objects), \"\(schema)\", \"\(steps)\")," }
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    /// The fingerprint of `migration` on `db`, which it was just applied to.
    static func fingerprint(of migration: Migration, on db: SQLiteDatabase) throws -> Fingerprint {
        let rows = try db.query("SELECT type, name, tbl_name, ifnull(sql, '') FROM sqlite_schema ORDER BY type, name")
        let dump = rows.map { row in (0..<4).map { row.string($0) }.joined(separator: "|") }.joined(separator: "\n")
        var steps = migration.rebuildsTables ? "rebuild\n" : ""
        for step in migration.steps {
            switch step {
            case .sql(let sql): steps += "sql\n\(sql)\n"
            case .code: steps += "code\n"
            }
        }
        return Fingerprint(migration.version, rows.count, hex(SHA256.hash(data: Data(dump.utf8))), hex(SHA256.hash(data: Data(steps.utf8))))
    }

    /// The fingerprints of every migration in this build.
    static func computed() throws -> [Fingerprint] {
        let db = try SQLiteDatabase(image: nil, size: 0)
        return try Schema.migrations.map { migration in
            try Schema.migrate(db, upTo: migration.version)
            return try fingerprint(of: migration, on: db)
        }
    }

    @Test func theTableListsEveryMigration() throws {
        let listed = Self.fingerprints.map(\.version)
        guard listed != Array(1...Schema.currentVersion) else { return }
        // Only the missing lines: a listed one is never replaced by what this build computes.
        let missing = try Self.computed().filter { !listed.contains($0.version) }
        Issue.record("""
            The fingerprints must list versions 1 to \(Schema.currentVersion) in order, each once. Missing, as this build computes them:
            \(missing.map(\.description).joined(separator: "\n"))
            """)
    }

    @Test func noPublishedMigrationWasEdited() throws {
        // A version listed twice fails the test above; here its first line counts.
        let expected = Dictionary(Self.fingerprints.map { ($0.version, $0) }, uniquingKeysWith: { first, _ in first })
        let edited = try Self.computed().filter { now in expected[now.version].map { $0 != now } ?? false }
        #expect(edited.isEmpty, """
            A published migration was edited (or what it builds changed); add a new migration instead. Now:
            \(edited.map(\.description).joined(separator: "\n"))
            """)
    }

    // MARK: Code steps

    /// A code step changes data, which `sqlite_schema` does not show: each one is also frozen by what it writes on a few seeded
    /// rows (the tests below).
    @Test func everyCodeStepHasADataFingerprint() {
        let withCode = Schema.migrations.filter { migration in
            migration.steps.contains { if case .code = $0 { true } else { false } }
        }
        #expect(withCode.map(\.version) == [9, 28], "a migration with a code step needs a test of the rows it writes")
    }

    /// Migration 9 rekeys the aliases with `TextKeys.norm` and merges the aliases of one person that now share a key. It runs live
    /// code: if this fails because the normalization changed on purpose, stores need a new migration that recomputes the keys
    /// (`MeetingStore.recomputeAliasNormalization`), and the rows below show what migration 9 now writes.
    @Test func migration9RekeysAliasesAsPublished() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db, upTo: 8)
        try db.query("""
            INSERT INTO entities(id, kind, name, created_at) VALUES
                (1, 'person', 'Łukasz', 0), (2, 'person', 'Bjørn', 0), (3, 'person', 'Ana', 0), (4, 'person', 'Mía', 0),
                (5, 'person', 'Øyvind', 0)
            """)
        // Old keys: ł and ø as 0.1.0 kept them; the others are seeded so that each pair of one person now shares a key.
        try db.query("""
            INSERT INTO aliases(id, alias_norm, alias, entity_id, source, weight) VALUES
                (1, 'łukasz', 'Łukasz', 1, 'llm', 2),
                (2, 'lukasz', 'Lukasz', 1, 'calendar', 0.5),
                (3, 'bjørn', 'Bjørn', 2, 'learned', 1),
                (4, 'bjorn', 'Bjorn', 2, 'calendar', 3),
                (5, 'ana', 'Ana', 3, 'learned', 1),
                (6, 'ána', 'Ána', 3, 'user', 0.5),
                (7, 'mia', 'Mia', 4, 'llm', 1),
                (8, 'mía', 'Mía', 4, 'llm', 1.5),
                (9, '-', '—', 3, 'llm', 1),
                (10, 'lukasz', 'Łukasz', 3, 'learned', 1),
                (11, 'øyvind', 'Øyvind', 5, 'llm', 1),
                (12, 'oyvind', 'Oyvind', 5, 'llm', 1)
            """)
        try Schema.migrate(db, upTo: 9)
        let rows = try db.query("SELECT id, alias_norm, alias, entity_id, source, weight FROM aliases ORDER BY id").map {
            "\($0.int(0))|\($0.string(1))|\($0.string(2))|\($0.int(3))|\($0.string(4))|\($0.double(5))"
        }
        // Of each pair, the stronger origin stays (user > learned > calendar > llm; then the higher weight; then the lower id) with
        // the highest weight of the two. 9's key is empty: removed. 10 is another person's alias with the same key: kept.
        #expect(rows == ["2|lukasz|Lukasz|1|calendar|2.0", "3|bjorn|Bjørn|2|learned|3.0", "6|ana|Ána|3|user|1.0", "8|mia|Mía|4|llm|1.5",
                         "10|lukasz|Łukasz|3|learned|1.0", "11|oyvind|Øyvind|5|llm|1.0"])
    }

    /// Migration 28 fills `tasks.due_day` with the day of each due date in this Mac's time zone. The seeded due dates are local
    /// times of the Mac running the test, so the days written are the same in every zone. A migration that used another zone
    /// (UTC instead of this Mac's) is caught only off UTC: by the 00:01 date east of it, by the 23:59 one west of it. A runner in
    /// UTC, such as CI's, does not see it; the release procedure also runs the tests on the maintainer's Mac.
    @Test func migration28BackfillsDueDaysAsPublished() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db, upTo: 27)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> SQLiteValue {
            let date = try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
            return .real(date.timeIntervalSince1970)
        }
        try db.query(
            "INSERT INTO tasks(id, text, due, created_at) VALUES (1, 'a', ?, 0), (2, 'b', ?, 0), (3, 'c', ?, 0), (4, 'd', NULL, 0)",
            [try local(2026, 3, 14, 12, 0), try local(2025, 12, 31, 23, 59), try local(2024, 2, 29, 0, 1)])
        try Schema.migrate(db, upTo: 28)
        let rows = try db.query("SELECT id, ifnull(due_day, 'NULL') FROM tasks ORDER BY id").map { "\($0.int(0))|\($0.string(1))" }
        #expect(rows == ["1|2026-03-14", "2|2025-12-31", "3|2024-02-29", "4|NULL"])
    }
}
