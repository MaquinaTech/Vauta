// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What a pass must not suggest again: pairs the person decided, and earlier items that already sit behind a newer member of their chain.
struct LinkExclusions: Sendable {
    /// `kind|src|dst` of every confirmed or dismissed link.
    var decidedPairs: Set<String> = []
    /// `kind|srcMeeting|srcKey|dstMeeting|dstKey` of every dismissal by content (they survive a rewrite of the minutes).
    var dismissedKeys: Set<String> = []
    /// Items that are the earlier end of a confirmed "same" link, with the start of the newer member's meeting: for an item of that meeting or a
    /// later one only the chain's newest member is a candidate. A meeting in between can still link to them.
    var superseded: [String: Date] = [:]
    /// Meetings that already hold a member of the chain that contains the item (`kind|id`): a second item of one meeting never joins that chain.
    var chainMeetings: [String: Set<Int64>] = [:]
    /// Newer items that already have a confirmed link (nothing more is suggested under them).
    var linkedSources: Set<String> = []

    static func pair(_ kind: LinkKind, _ src: Int64, _ dst: Int64) -> String { "\(kind.rawValue)|\(src)|\(dst)" }
    static func item(_ kind: LinkKind, _ id: Int64) -> String { "\(kind.rawValue)|\(id)" }
    static func dismissal(_ kind: LinkKind, srcMeeting: Int64, srcKey: String, dstMeeting: Int64, dstKey: String) -> String {
        "\(kind.rawValue)|\(srcMeeting)|\(srcKey)|\(dstMeeting)|\(dstKey)"
    }
}

/// The earlier items an item is compared with. Pure.
enum LinkCandidates {
    /// Same kind, earlier meetings inside the window, a shared context, the same language, nothing the person decided, at most `maxCandidates`
    /// (the newest first). The pool holds eligible items only (the store applies `LinkPolicy.isEligible`).
    static func candidates(for x: LinkItem, in pool: [LinkItem], exclusions: LinkExclusions, policy: LinkPolicy) -> [LinkItem] {
        guard !exclusions.linkedSources.contains(LinkExclusions.item(x.kind, x.id)) else { return [] }
        let xKey = LinkText.key(x.text)
        var out: [LinkItem] = []
        for c in pool where c.kind == x.kind && c.meetingID != x.meetingID && c.id != x.id {
            guard c.startedAt < x.startedAt, x.startedAt.timeIntervalSince(c.startedAt) <= policy.window else { continue }
            guard c.status != .dropped, c.language == x.language, sharesContext(x, c) else { continue }
            guard !exclusions.decidedPairs.contains(LinkExclusions.pair(x.kind, x.id, c.id)) else { continue }
            let cKey = LinkExclusions.item(c.kind, c.id)
            if let newerStart = exclusions.superseded[cKey], x.startedAt >= newerStart { continue }
            if exclusions.chainMeetings[cKey]?.contains(x.meetingID) == true { continue }
            let dismissed = LinkExclusions.dismissal(x.kind, srcMeeting: x.meetingID, srcKey: xKey, dstMeeting: c.meetingID, dstKey: LinkText.key(c.text))
            guard !exclusions.dismissedKeys.contains(dismissed) else { continue }
            out.append(c)
        }
        out.sort { ($0.startedAt, $0.id) > ($1.startedAt, $1.id) }
        return Array(out.prefix(policy.maxCandidates))
    }

    /// At least one of: the same series, a person who was at both meetings, the same owner (tasks), a project or client both mention.
    static func sharesContext(_ x: LinkItem, _ c: LinkItem) -> Bool {
        if let a = x.seriesID, a == c.seriesID { return true }
        if !x.people.isDisjoint(with: c.people) { return true }
        if x.kind == .task, let a = x.ownerID, a == c.ownerID { return true }
        return !x.projects.isDisjoint(with: c.projects)
    }

    /// The keyword gate also needs the series or the owner.
    static func sharesSeriesOrOwner(_ x: LinkItem, _ c: LinkItem) -> Bool {
        if let a = x.seriesID, a == c.seriesID { return true }
        return x.kind == .task && x.ownerID != nil && x.ownerID == c.ownerID
    }
}
