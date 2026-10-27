// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Confirmed "same" links form chains: union-find over the items of one kind, the root is the newest member. Pure.
/// `changes` links are never part of a chain and never transitive: a chain only follows `same`.
public struct LinkChain: Sendable, Equatable {
    public struct Member: Sendable, Equatable, Hashable {
        public let id: Int64
        /// When the member's meeting started (the order of the chain).
        public let date: Date
        public init(id: Int64, date: Date) { self.id = id; self.date = date }
    }

    /// The newest member.
    public let newest: Member
    /// Every other member, newest first.
    public let earlier: [Member]

    public var members: [Member] { [newest] + earlier }
    public var count: Int { earlier.count + 1 }

    /// The chains with at least two members. `links` are the confirmed "same" pairs (newer, earlier); `members` give each item's date.
    public static func chains(links: [(newer: Int64, earlier: Int64)], dates: [Int64: Date]) -> [LinkChain] {
        var parent: [Int64: Int64] = [:]
        func find(_ x: Int64) -> Int64 {
            var root = x
            while let p = parent[root], p != root { root = p }
            var node = x
            while let p = parent[node], p != root { parent[node] = root; node = p }
            return root
        }
        for (a, b) in links where dates[a] != nil && dates[b] != nil {
            parent[a] = parent[a] ?? a
            parent[b] = parent[b] ?? b
            let (ra, rb) = (find(a), find(b))
            if ra != rb { parent[ra] = rb }
        }
        var groups: [Int64: [Member]] = [:]
        for id in parent.keys {
            if let date = dates[id] { groups[find(id), default: []].append(Member(id: id, date: date)) }
        }
        return groups.values.compactMap { group -> LinkChain? in
            guard group.count > 1 else { return nil }
            let sorted = group.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
            return LinkChain(newest: sorted[0], earlier: Array(sorted.dropFirst()))
        }.sorted { ($0.newest.date, $0.newest.id) > ($1.newest.date, $1.newest.id) }
    }
}
