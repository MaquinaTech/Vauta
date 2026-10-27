// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The backend whose minutes and checks a link feature is released for.
public enum LinkBackend: String, Sendable, CaseIterable {
    case apple, integrated, server
}

/// Which parts of the links to earlier meetings (post-meeting actions, Part B) are on in this release, by backend. The code stays and is
/// tested; a part is switched on here only when its judged evaluation meets the gates in docs/ACTIONS.md. The test series was judged on
/// 2026-10-25 (docs/BENCHMARKS.md): no arm passed link precision and recall on Apple's model or on the integrated one, the model check did not
/// help and "different from" suggestions were mostly the wrong relation, so every switch is off on every backend. A backend gets only what
/// passed, and nothing passed. The model server was not measured.
public enum LinksRelease {
    /// Suggestions of "same task" and "same decision" (the deterministic pass).
    public static func suggestions(_ backend: LinkBackend) -> Bool { false }

    /// Whether any backend has suggestions on (Settings says nothing about links otherwise).
    public static var shipsOnAnyBackend: Bool { LinkBackend.allCases.contains { suggestions($0) } }

    /// "Different from…" suggestions (`changes`). Off until the false-positive rate on natural pairs passes its gate on that backend (D13).
    public static func changes(_ backend: LinkBackend) -> Bool { false }

    /// The optional check of the two texts by the backend's model. No model server is ever asked (D19 is not built).
    public static func modelCheck(_ backend: LinkBackend) -> Bool { false }
}

/// The numbers of the link pass. Constants calibrated on the development split (docs/ACTIONS.md); a test pins each of them.
public struct LinkPolicy: Sendable, Equatable {
    /// Bumped when the candidates, the scoring or the difference rules change: meetings of the last `windowDays` run again.
    public static let recipe = 1
    /// Item vectors are made from the item's own words (`LinkText.embeddingText`); a change there bumps this.
    public static let vectorRecipe = 1

    /// The raw cosine a vector pair needs (never a boosted score). Set on the development split: 0.80 (the initial value) let through many
    /// pairs of the same area that are not the same item; the pairs a reader accepts scored 0.87 to 0.94, and 0.90 is the lowest floor under
    /// which the accepted pairs outnumbered the rest (docs/ACTIONS.md, tuning log).
    public var floor: Double = 0.90
    /// A `changes` pair is read from cosines this far under the floor when it shares at least `changesSharedWords` content words.
    public var changesMargin: Double = 0.08
    public var changesSharedWords = 2
    /// Keyword fallback: content-word Jaccard and shared content words.
    public var keywordJaccard: Double = 0.5
    public var keywordSharedWords = 3
    /// The keyword route through a shared code or rare name also needs this content-word Jaccard (a name alone, "Java" or "Euros", is a topic, not an item).
    public var keywordAnchorJaccard: Double = 0.4
    /// A vector pair also has to share this many content words, or a code or rare name.
    public var lexicalSupportWords = 1
    /// At most this many suggestions per item and per meeting (D17).
    public var perItem = 1
    public var perMeeting = 6
    /// Earlier meetings count only this far back (D15).
    public var windowDays = 180
    /// The most candidates compared with one item, newest first.
    public var maxCandidates = 200
    /// An earlier item that is only doubted (not ranked out) can be a source or a candidate. Dev-only switch: if the pairs with a doubted side
    /// miss the precision gate on the development split it is set to false before the test split.
    public var includesDoubted = true
    /// Diagnostics only (arm LS0R): items the ranking left out of the list count too.
    public var includesRankedOut = false
    /// Show `changes` pairs. A pair that differs and is not shown is dropped, never relabelled "same".
    public var showsChanges = false
    /// Ask the backend's model to check the pairs the deterministic pass found (Apple's model and the integrated one; never a server).
    public var modelCheck = false
    /// The integrated model checks only when it is already loaded and the Mac is on the charger. The evaluation turns this off.
    public var modelCheckNeedsLoadedModel = true

    public init() {}

    /// The policy a release runs on `backend`.
    public static func released(_ backend: LinkBackend) -> LinkPolicy {
        var policy = LinkPolicy()
        policy.showsChanges = LinksRelease.changes(backend)
        policy.modelCheck = LinksRelease.modelCheck(backend) && backend != .server
        return policy
    }

    public var window: TimeInterval { Double(windowDays) * 86_400 }

    /// Whether an item can be the source or the candidate of a link. A ranked-out item (Apple's list left it out; about nine in ten of them are
    /// not real) is neither, until the person checks or edits it: then it is theirs and no longer ranked out. A doubted one stays.
    public func isEligible(unconfirmed: Bool, reason: String?) -> Bool {
        guard unconfirmed else { return true }
        if UnconfirmedReason.isRankedOut(reason) { return includesRankedOut }
        return includesDoubted
    }
}
