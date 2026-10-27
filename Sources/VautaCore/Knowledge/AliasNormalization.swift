// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension MeetingStore {
    /// Recomputes `aliases.alias_norm` with the current `TextKeys.norm`
    /// (a data migration step for stores written by an older normalization).
    ///
    /// Two aliases of the same entity that now share a key are merged: the
    /// row with the strongest origin (user > learned > calendar > llm) is kept
    /// with the highest weight of the group, and an alias whose key became
    /// empty is removed. Runs inside the caller's transaction and is idempotent.
    static func recomputeAliasNormalization(_ db: SQLiteDatabase) throws {
        struct Alias { let id: Int64; let surface: String; let old: String; let entity: Int64; let source: String; let weight: Double }
        let rows = try db.query("SELECT id, alias, alias_norm, entity_id, source, weight FROM aliases ORDER BY id").map {
            Alias(id: $0.int(0), surface: $0.string(1), old: $0.string(2), entity: $0.int(3), source: $0.string(4), weight: $0.double(5))
        }
        let rank = ["user": 0, "learned": 1, "calendar": 2, "llm": 3]
        var winners: [(alias: Alias, norm: String, weight: Double)] = []
        let groups = Dictionary(grouping: rows) { "\($0.entity)|\(TextKeys.norm($0.surface))" }
        for group in groups.values {
            let norm = TextKeys.norm(group[0].surface)
            guard !norm.isEmpty else {
                for a in group { try db.query("DELETE FROM aliases WHERE id = ?", [.integer(a.id)]) }
                continue
            }
            let keep = group.min { (rank[$0.source] ?? 9, -$0.weight, $0.id) < (rank[$1.source] ?? 9, -$1.weight, $1.id) }!
            for a in group where a.id != keep.id {
                try db.query("DELETE FROM aliases WHERE id = ?", [.integer(a.id)])
            }
            let weight = group.map(\.weight).max()!
            if keep.old != norm || keep.weight != weight { winners.append((keep, norm, weight)) }
        }
        // Two phases: a new key may equal another row's old key until that row is updated too.
        for w in winners {
            try db.query("UPDATE aliases SET alias_norm = ? WHERE id = ?", [.text("\u{1}\(w.alias.id)"), .integer(w.alias.id)])
        }
        for w in winners {
            try db.query("UPDATE aliases SET alias_norm = ?, weight = ? WHERE id = ?", [.text(w.norm), .real(w.weight), .integer(w.alias.id)])
        }
    }
}
