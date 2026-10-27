// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Proves that a database image from a backup holds exactly the schema Vauta itself creates, before any statement of
/// ours runs against it. A backup is authenticated but not trusted: an extra trigger, view or virtual table would
/// otherwise execute during restore and later queries.
enum BackupSchemaGuard {
    private static let objects = "SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_schema ORDER BY type, name, tbl_name, 4"

    static func validate(_ image: SQLiteDatabase) throws {
        let version = try Schema.version(of: image)
        guard version >= 0, version <= Schema.currentVersion else {
            throw StoreError(.newerSchema, detail: "schema \(version) > \(Schema.currentVersion)")
        }
        let reference = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(reference, upTo: version)
        let expected = try signature(reference)
        let found = try signature(image)
        guard expected == found else {
            throw StoreError(.backupInvalid, detail: "database schema differs from Vauta's")
        }
    }

    private static func signature(_ db: SQLiteDatabase) throws -> [String] {
        try db.query(objects).map { row in
            [row.string(0), row.string(1), row.string(2), normalized(row.string(3))].joined(separator: "\u{1F}")
        }
    }

    /// The stored SQL without the differences SQLite itself introduces: `ALTER TABLE ... RENAME` rewrites a statement
    /// (adding identifier quotes, and the text has varied across SQLite versions), so an image written by an older build on
    /// an older macOS must still match. Whitespace is collapsed (and dropped beside brackets and commas) and identifier quotes dropped; string literals stay
    /// exactly as they are, so a changed default, check or trigger body is still a difference.
    static func normalized(_ sql: String) -> String {
        var out = ""
        var inLiteral = false
        var pendingSpace = false
        for ch in sql {
            if inLiteral {
                out.append(ch)
                if ch == "'" { inLiteral = false }
                continue
            }
            if ch.isWhitespace { pendingSpace = !out.isEmpty; continue }
            if ch == "\"" || ch == "`" || ch == "[" || ch == "]" { continue }
            if pendingSpace, ch != ")", ch != ",", out.last != "(" { out.append(" ") }
            pendingSpace = false
            out.append(ch)
            if ch == "'" { inLiteral = true }
        }
        return out
    }
}
