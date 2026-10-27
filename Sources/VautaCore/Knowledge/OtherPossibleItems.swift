// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The items of a meeting's minutes that the model proposed and that did not make the ranked list ("Other possible items").
///
/// They are not doubted by any check on their words (those keep the "Unconfirmed" mark in the main list): they just ranked below the
/// main items of the meeting. They stay `unconfirmed` in the store, so exports, the follow-up email and the follow-up detector treat
/// them exactly as they treat any unconfirmed item; only the Minutes tab shows them apart, in a group that starts collapsed.
public struct OtherPossibleItems: Sendable, Equatable {
    public enum Item: Sendable, Equatable, Identifiable {
        case decision(Decision)
        case task(TaskItem)

        public var id: String {
            switch self {
            case .decision(let d): "d\(d.id)"
            case .task(let t): "t\(t.id)"
            }
        }

        public var text: String {
            switch self {
            case .decision(let d): d.text
            case .task(let t): t.text
            }
        }

        public var t: Double? {
            switch self {
            case .decision(let d): d.t
            case .task(let t): t.t
            }
        }
    }

    /// The decisions that stay in the main list (everything but the ranked-out ones), in the order given.
    public let firmDecisions: [Decision]
    /// The ranked-out decisions and open tasks of the meeting, in the order of the meeting (undated ones last).
    public let items: [Item]

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    public init(decisions: [Decision], tasks: [TaskItem]) {
        firmDecisions = decisions.filter { !$0.isRankedOut }
        let all = decisions.filter(\.isRankedOut).map(Item.decision) + tasks.filter { $0.isRankedOut && $0.status == .open }.map(Item.task)
        // A stable sort: the same time keeps decisions before tasks.
        items = all.enumerated().sorted { a, b in
            let (ta, tb) = (a.element.t ?? .infinity, b.element.t ?? .infinity)
            return ta != tb ? ta < tb : a.offset < b.offset
        }.map(\.element)
    }
}
