// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import SQLite3

/// In-memory SQLite connection (the system libsqlite3). It is loaded from and
/// dumped to a blob with sqlite3_deserialize/serialize: the caller encrypts,
/// and the plaintext database never touches the disk.
///
/// The database is ALWAYS a deserialized image (memdb), even when new, so
/// sqlite3_serialize(NOCOPY) gives direct access to its memory without
/// plaintext copies. What cannot be wiped: memdb's internal reallocs as it
/// grows (they free the old buffer without zeroing it).
///
/// The image is deserialized without SQLITE_DESERIALIZE_FREEONCLOSE: this
/// class owns the buffer (SQLite may realloc it while growing) and zeroes it
/// before freeing it, also when deserialization or the first statement fails.
final class SQLiteDatabase {
    private var db: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    /// `image`: database image in memory from `sqlite3_malloc64`; this object
    /// takes ownership of it (also when the initializer throws). `nil` = new database.
    init(image: UnsafeMutableRawPointer?, size: Int) throws {
        let buffer = image ?? sqlite3_malloc64(1)
        let size = image == nil ? 0 : size
        guard let buffer else { throw StoreError(.database, detail: "out of memory") }
        guard sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            // sqlite3_open_v2 returns a handle even on failure; it must be closed.
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close_v2(db)
            db = nil
            Self.free(buffer, size: size)
            throw StoreError(.database, detail: "open: \(detail)")
        }
        let flags = UInt32(SQLITE_DESERIALIZE_RESIZEABLE)
        guard sqlite3_deserialize(db, "main", buffer.assumingMemoryBound(to: UInt8.self),
                                  sqlite3_int64(size), sqlite3_int64(max(size, 1)), flags) == SQLITE_OK else {
            let detail = message
            sqlite3_close_v2(db)
            db = nil
            Self.free(buffer, size: size)
            throw StoreError(.unreadableStore, detail: "deserialize: \(detail)")
        }
        // From here `close()` zeroes and frees the (possibly reallocated) image.
        // secure_delete: deleted content is overwritten with zeros, nothing stays in free pages.
        // temp_store = MEMORY: the system libsqlite3 (TEMP_STORE=1) would write
        // temporaries of large sorts or VACUUM to disk, in plaintext.
        do {
            // trusted_schema = OFF: triggers and views in the image cannot call functions or virtual tables that
            // are not marked innocuous (the macOS default is ON). cell_size_check: b-tree cells are validated as
            // they are read, so a corrupt or crafted page fails instead of reading out of bounds.
            // (SQLITE_DBCONFIG_DEFENSIVE is a variadic C call that Swift cannot make; see docs/CRYPTO_REVIEW.md.)
            // Limits well under SQLite's 1 GB defaults: no string, blob or statement of a hostile image or query can grow past them.
            sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 256 << 20)
            sqlite3_limit(db, SQLITE_LIMIT_SQL_LENGTH, 64 << 20)
            try execute("""
                PRAGMA trusted_schema = OFF; PRAGMA cell_size_check = ON;
                PRAGMA foreign_keys = ON; PRAGMA secure_delete = ON; PRAGMA temp_store = MEMORY;
                """)
            // Deserialization does not validate the image: read the schema now so
            // a bad image fails here and not on first use.
            try query("SELECT count(*) FROM sqlite_schema")
        } catch {
            close()
            throw StoreError(.unreadableStore, detail: "\(error)")
        }
    }

    deinit { close() }

    /// Finalizes statements, zeroes the image, closes the connection and frees
    /// the image (it is ours: no FREEONCLOSE). Idempotent.
    private func close() {
        for stmt in statements.values { sqlite3_finalize(stmt) }
        statements = [:]
        guard let db else { return }
        self.db = nil
        var size: sqlite3_int64 = 0
        let image = sqlite3_serialize(db, "main", &size, UInt32(SQLITE_SERIALIZE_NOCOPY))
        if let image, size > 0 { memset_s(image, Int(size), 0, Int(size)) }
        sqlite3_close_v2(db)
        if let image { sqlite3_free(image) }
    }

    private static func free(_ buffer: UnsafeMutableRawPointer, size: Int) {
        if size > 0 { memset_s(buffer, size, 0, size) }
        sqlite3_free(buffer)
    }

    var message: String { String(cString: sqlite3_errmsg(db)) }

    /// Rows changed by the last statement.
    var changes: Int { Int(sqlite3_changes(db)) }

    /// Several statements without parameters (migrations, PRAGMA, transactions).
    func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError(.database, detail: message) }
    }

    /// Runs one statement with parameters and returns its rows. Statements are
    /// prepared once and reused.
    @discardableResult
    func query(_ sql: String, _ params: [SQLiteValue?] = []) throws -> [Row] {
        let stmt = try statement(sql)
        defer {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
        }
        for (i, param) in params.enumerated() {
            let index = Int32(i + 1)
            let rc: Int32
            switch param {
            case nil: rc = sqlite3_bind_null(stmt, index)
            case .integer(let v): rc = sqlite3_bind_int64(stmt, index, v)
            case .real(let v): rc = sqlite3_bind_double(stmt, index, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                rc = v.withUnsafeBytes { raw in
                    // An empty BLOB is not NULL: zeroblob(0).
                    raw.count == 0 ? sqlite3_bind_zeroblob(stmt, index, 0)
                                   : sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                }
            case .ids(let v):
                // ID list for `IN (SELECT value FROM json_each(?))`, bound as JSON
                // text so no dynamic SQL is built. json_each works on every macOS
                // SQLite build (carray only ships with macOS 27).
                let json = "[" + v.map(String.init).joined(separator: ",") + "]"
                rc = sqlite3_bind_text(stmt, index, json, -1, SQLITE_TRANSIENT)
            }
            guard rc == SQLITE_OK else { throw StoreError(.database, detail: "bind parameter \(index) (code \(rc)): \(message)") }
        }
        var rows: [Row] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: rows.append(Row(stmt))
            case SQLITE_DONE: return rows
            default: throw StoreError(.database, detail: message)
            }
        }
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        if let stmt = statements[sql] { return stmt }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError(.database, detail: message)
        }
        statements[sql] = stmt
        return stmt
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    /// Bulk-reads a BLOB column into owned contiguous memory that is zeroed on
    /// release (e.g. int8 vectors). `width`: bytes per row; rows of any other
    /// size are rejected.
    func blobs(_ sql: String, _ params: [SQLiteValue?] = [], column: Int32 = 0, width: Int) throws -> (ids: [Int64], buffer: SecretBuffer) {
        let rows = try query(sql, params)
        let buffer = SecretBuffer(capacity: rows.count * width)
        var ids: [Int64] = []
        ids.reserveCapacity(rows.count)
        for row in rows {
            let blob = row.data(Int(column))
            guard blob.count == width else { throw StoreError(.database, detail: "unexpected BLOB size (\(blob.count) ≠ \(width))") }
            blob.withUnsafeBytes { (buffer.base + buffer.count).copyMemory(from: $0.baseAddress!, byteCount: width) }
            buffer.count += width
            ids.append(row.int(Int(column) + 1))
        }
        return (ids, buffer)
    }

    /// Gives access to the whole database image without copying it (NOCOPY).
    /// The pointer is valid only inside `body` and while the database is not
    /// modified. If NOCOPY is unavailable, a copy is used and then zeroed.
    func withSerializedBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        var size: sqlite3_int64 = 0
        if let p = sqlite3_serialize(db, "main", &size, UInt32(SQLITE_SERIALIZE_NOCOPY)), size > 0 {
            return try body(UnsafeRawBufferPointer(start: p, count: Int(size)))
        }
        guard let p = sqlite3_serialize(db, "main", &size, 0) else { throw StoreError(.database, detail: "serialize failed") }
        defer {
            memset_s(p, Int(size), 0, Int(size))
            sqlite3_free(p)
        }
        return try body(UnsafeRawBufferPointer(start: p, count: Int(size)))
    }
}

enum SQLiteValue: Sendable, Equatable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    /// ID list for `IN (SELECT value FROM json_each(?))`.
    case ids([Int64])
}

struct Row {
    private let values: [Any?]

    fileprivate init(_ stmt: OpaquePointer?) {
        values = (0..<sqlite3_column_count(stmt)).map { i in
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER: sqlite3_column_int64(stmt, i)
            case SQLITE_FLOAT: sqlite3_column_double(stmt, i)
            case SQLITE_TEXT: String(cString: sqlite3_column_text(stmt, i))
            case SQLITE_BLOB:
                Data(bytes: sqlite3_column_blob(stmt, i) ?? UnsafeRawPointer(bitPattern: 1)!, count: Int(sqlite3_column_bytes(stmt, i)))
            default: nil
            }
        }
    }

    func int(_ i: Int) -> Int64 { values[i] as? Int64 ?? 0 }
    func double(_ i: Int) -> Double { values[i] as? Double ?? (values[i] as? Int64).map(Double.init) ?? 0 }
    func optionalDouble(_ i: Int) -> Double? { values[i] == nil ? nil : double(i) }
    func string(_ i: Int) -> String { values[i] as? String ?? "" }
    func optionalString(_ i: Int) -> String? { values[i] as? String }
    func optionalInt(_ i: Int) -> Int64? { values[i] as? Int64 }
    func data(_ i: Int) -> Data { values[i] as? Data ?? Data() }
    var count: Int { values.count }
}

/// The system SQLite the store runs on, for `doctor` and Copy Diagnostics: its fixes come with macOS updates.
public enum SQLiteLibrary {
    public static var version: String { String(cString: sqlite3_libversion()) }
}

// SQLITE_TRANSIENT is not imported into Swift: SQLite copies the value when binding.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
