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
    /// exactly as they are, so a changed default, check or trigger body is still a difference. Comments outside literals
    /// count as whitespace: an apostrophe in one (`-- the person's …`) must not be taken for the start of a literal.
    /// A quoted identifier is read whole, so `"--"` or `"/*"` inside one never hides the SQL after it; one that is
    /// not a plain word keeps canonical quotes, so `"a, b"` is never the same text as two columns.
    static func normalized(_ sql: String) -> String {
        let chars = Array(sql)
        var out = ""
        var inLiteral = false
        var pendingSpace = false
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if inLiteral {
                out.append(ch)
                if ch == "'" { inLiteral = false }
                i += 1
                continue
            }
            if ch == "-", next == "-" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                pendingSpace = !out.isEmpty
                continue
            }
            if ch == "/", next == "*" {
                i += 2
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, chars.count)
                pendingSpace = !out.isEmpty
                continue
            }
            i += 1
            if ch.isWhitespace { pendingSpace = !out.isEmpty; continue }
            var token = String(ch)
            if let close: Character = ch == "\"" ? "\"" : ch == "`" ? "`" : ch == "[" ? "]" : nil {
                var name = ""
                while i < chars.count {
                    if chars[i] == close {
                        // A doubled quote is one quote inside the name ("" and ``; ] cannot be escaped).
                        guard close != "]", i + 1 < chars.count, chars[i + 1] == close else { break }
                        i += 1
                    }
                    name.append(chars[i])
                    i += 1
                }
                i = min(i + 1, chars.count)
                let plain = !name.isEmpty && name.unicodeScalars.allSatisfy { $0.isASCII && ($0 == "_" || CharacterSet.alphanumerics.contains($0)) }
                token = plain ? name : "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            if pendingSpace, token != ")", token != ",", out.last != "(" { out.append(" ") }
            pendingSpace = false
            out.append(token)
            if ch == "'" { inLiteral = true }
        }
        return out
    }
}
