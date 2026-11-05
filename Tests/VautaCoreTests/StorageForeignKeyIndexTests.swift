// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// With `foreign_keys = ON`, deleting a parent row looks its children up by the child column. Without an index that starts with
/// that column, every deleted row scans the whole child table: deleting a meeting of 2,000 lines, or the daily retention, then
/// costs thousands of full scans of store-wide tables. Every foreign key column of the current schema is indexed.
@Suite("Storage schema: foreign keys are indexed")
struct StorageForeignKeyIndexTests {
    /// Child columns whose table is keyed by them already (a primary key that starts with the column counts as an index) or is
    /// tiny by design. Empty today: add a line only with the reason.
    static let exempt: Set<String> = []

    @Test func everyForeignKeyColumnLeadsAnIndex() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db)
        let tables = try db.query("SELECT name FROM sqlite_schema WHERE type = 'table' AND sql LIKE '%REFERENCES%'").map { $0.string(0) }
        var missing: [String] = []
        for table in tables {
            let keys = try db.query("SELECT \"from\" FROM pragma_foreign_key_list(?1)", [.text(table)]).map { $0.string(0) }
            // An `INTEGER PRIMARY KEY` column is the rowid: the table is keyed by it.
            let pk = try db.query("SELECT name, type FROM pragma_table_info(?1) WHERE pk > 0", [.text(table)])
            var leading = Set<String>()
            if pk.count == 1, pk[0].string(1).uppercased() == "INTEGER" { leading.insert(pk[0].string(0)) }
            for index in try db.query("SELECT name, partial FROM pragma_index_list(?1)", [.text(table)]) {
                guard let first = try db.query("SELECT name FROM pragma_index_info(?1) WHERE seqno = 0", [.text(index.string(0))]).first else { continue }
                let column = first.string(0)
                // A partial index serves the lookup `column = ?` only when its condition is implied by it.
                if index.int(1) == 1 {
                    let sql = try db.query("SELECT sql FROM sqlite_schema WHERE name = ?1", [.text(index.string(0))]).first?.string(0) ?? ""
                    guard sql.hasSuffix("WHERE \(column) IS NOT NULL") else { continue }
                }
                leading.insert(column)
            }
            for key in Set(keys) where !leading.contains(key) && !Self.exempt.contains("\(table).\(key)") {
                missing.append("\(table).\(key)")
            }
        }
        #expect(missing.sorted() == [], "foreign key columns without an index that starts with them")
    }
}
