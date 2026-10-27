// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The person that stands for the user of this Mac: owner of "my" tasks.
/// Its ID lives in `store_meta` ('self_entity').
extension MeetingStore {
    /// Name stored for the self entity. Prompts refer to the user by this
    /// name, so existing and new stores keep it; the UI shows `displayName`.
    public static let legacySelfName = "Yo"

    /// Localized display name: the self entity shows as "Me" while it still
    /// has its stored legacy name; a name the user typed is shown as is.
    public static func displayName(_ name: String, isSelf: Bool) -> String {
        isSelf && name == legacySelfName ? String(localized: "Me", comment: "The user of the app, as a person in the context and as a task owner") : name
    }

    /// True for the normalized pronoun that names the self entity ("yo", or
    /// the localized "me"): never an alias, it would match almost every sentence.
    static func isSelfPronoun(_ norm: String) -> Bool {
        norm == TextKeys.norm(legacySelfName)
            || norm == TextKeys.norm(String(localized: "Me", comment: "The user of the app, as a person in the context and as a task owner"))
    }

    /// The self entity's ID, if it exists (never creates it). A stale
    /// reference to a merged entity is followed to the entity that remains.
    public func selfEntityID() throws -> Int64? {
        guard let id = try db.query("SELECT v FROM store_meta WHERE k = 'self_entity'").first?.optionalInt(0) else { return nil }
        return try db.query("SELECT coalesce(merged_into, id) FROM entities WHERE id = ?", [.integer(id)]).first?.int(0)
    }

    /// The self entity, created on first use. It has no aliases on purpose:
    /// the pronoun would match almost every sentence of the user's own channel.
    public func selfEntity() async throws -> Int64 {
        if let id = try selfEntityID() {
            if try db.query("SELECT v FROM store_meta WHERE k = 'self_entity'").first?.optionalInt(0) != id {
                try run("UPDATE store_meta SET v = ? WHERE k = 'self_entity'", [.integer(id)])
                try await commitEdit()
            }
            return id
        }
        let id: Int64 = try transaction {
            try run("INSERT INTO entities(kind, name, source, confirmed, created_at) VALUES ('person', ?, 'user', 1, ?)",
                    [.text(Self.legacySelfName), .real(Date.now.timeIntervalSince1970)])
            let id = db.lastInsertRowID
            try run("INSERT INTO store_meta(k, v) VALUES ('self_entity', ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v", [.integer(id)])
            return id
        }
        try await commitEdit()
        return id
    }
}
