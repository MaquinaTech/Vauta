// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Accelerate
import Foundation

/// An item's stored vector: int8 values and their scale, with the norm worked out once.
struct LinkVector: Sendable {
    let values: [Float]
    let norm: Float

    init?(q: Data, scale: Float) {
        guard scale > 0, !q.isEmpty else { return nil }
        let v = q.map { Float(Int8(bitPattern: $0)) * scale }
        let n = sqrt(vDSP.sumOfSquares(v))
        guard n > 0, n.isFinite else { return nil }
        values = v
        norm = n
    }

    init?(_ vector: [Float]) {
        let n = sqrt(vDSP.sumOfSquares(vector))
        guard n > 0, n.isFinite else { return nil }
        values = vector
        norm = n
    }

    /// The raw cosine of two vectors of one space (0 for vectors of another size).
    func cosine(_ other: LinkVector) -> Double {
        guard values.count == other.values.count else { return 0 }
        return Double(vDSP.dot(values, other.values) / (norm * other.norm))
    }
}

/// Scores the candidates of an item and picks what to suggest. Pure: the vectors come in, nothing is stored.
enum LinkScorer {
    /// How a candidate passed.
    private struct Match {
        var candidate: LinkItem
        var method: LinkMethod
        var score: Double
        /// Under the floor but inside the `changes` band: only a deterministic difference can make it a suggestion.
        var changesOnly: Bool
    }

    /// The proposal for one item `x`, or none. `vectors` hold the vectors by `LinkExclusions.item`.
    static func propose(for x: LinkItem, candidates: [LinkItem], vectors: [String: LinkVector], policy: LinkPolicy) -> LinkProposal? {
        let xWords = LinkText.words(x.text, locale: x.locale)
        let xAnchors = LinkText.anchors(x.text, locale: x.locale)
        let xVector = vectors[LinkExclusions.item(x.kind, x.id)]
        var matches: [Match] = []
        for c in candidates {
            let cWords = LinkText.words(c.text, locale: c.locale)
            let shared = xWords.intersection(cWords)
            let sharedAnchors = xAnchors.intersection(LinkText.anchors(c.text, locale: c.locale))
            let sharedAnchor = !sharedAnchors.isEmpty
            if let xVector, let cVector = vectors[LinkExclusions.item(c.kind, c.id)] {
                // The raw cosine, with at least one shared content word or a shared code or rare name.
                let cosine = xVector.cosine(cVector)
                let support = shared.count >= policy.lexicalSupportWords || sharedAnchor
                if cosine >= policy.floor, support {
                    matches.append(Match(candidate: c, method: .vector, score: cosine, changesOnly: false))
                } else if x.kind == .decision, cosine >= policy.floor - policy.changesMargin, shared.count >= policy.changesSharedWords {
                    matches.append(Match(candidate: c, method: .vector, score: cosine, changesOnly: true))
                }
            } else if LinkCandidates.sharesSeriesOrOwner(x, c) {
                // Keywords: content-word Jaccard and shared words, or a shared code or rare name with one more word.
                let jaccard = LinkText.jaccard(xWords, cWords)
                let passes = (jaccard >= policy.keywordJaccard && shared.count >= policy.keywordSharedWords) || (sharedAnchor && shared.subtracting(sharedAnchors).count >= 1 && jaccard >= policy.keywordAnchorJaccard)
                if passes { matches.append(Match(candidate: c, method: .keyword, score: jaccard, changesOnly: false)) }
            }
        }
        // The best candidate first: a vector score before a keyword one, then the score, then the newer earlier item.
        matches.sort { a, b in
            if (a.method == .vector) != (b.method == .vector) { return a.method == .vector }
            if a.score != b.score { return a.score > b.score }
            return (a.candidate.startedAt, a.candidate.id) > (b.candidate.startedAt, b.candidate.id)
        }
        for m in matches {
            let verdict = LinkDifference.judge(kind: x.kind, newer: x.text, earlier: m.candidate.text, locale: x.locale, language: x.language)
            switch verdict {
            case .unrelated:
                continue
            case .changes(let evidence):
                // A pair that differs and is not shown is dropped, never relabelled "same".
                guard policy.showsChanges else { continue }
                return LinkProposal(kind: x.kind, srcID: x.id, dstID: m.candidate.id, relation: .changes, method: m.method, score: m.score, evidence: evidence)
            case .same:
                if m.changesOnly { continue }
                return LinkProposal(kind: x.kind, srcID: x.id, dstID: m.candidate.id, relation: .same, method: m.method, score: m.score)
            }
        }
        return nil
    }

    /// At most `perMeeting` proposals, the surest first (ties: the lower item id, so a replay gives the same list), and at most one for each
    /// earlier item.
    static func cap(_ proposals: [LinkProposal], policy: LinkPolicy) -> [LinkProposal] {
        let ordered = proposals.sorted { a, b in
            if (a.method == .vector) != (b.method == .vector) { return a.method == .vector }
            if a.score != b.score { return a.score > b.score }
            return (a.kind.rawValue, a.srcID) < (b.kind.rawValue, b.srcID)
        }
        // One earlier item is the answer for one newer item only: two items of a meeting never join one chain through it.
        var used = Set<String>()
        var out: [LinkProposal] = []
        for p in ordered where out.count < policy.perMeeting {
            guard used.insert(LinkExclusions.item(p.kind, p.dstID)).inserted else { continue }
            out.append(p)
        }
        return out
    }
}

/// One pass over the items of a meeting: pure. The store gathers its inputs (`MeetingStore.linkInputs`) and writes its output.
struct LinkEngine: Sendable {
    var sources: [LinkItem]
    var pool: [LinkItem]
    var vectors: [String: LinkVector]
    var exclusions: LinkExclusions
    var policy: LinkPolicy

    func run() -> [LinkProposal] {
        var proposals: [LinkProposal] = []
        for x in sources.sorted(by: { ($0.kind.rawValue, $0.t ?? .infinity, $0.id) < ($1.kind.rawValue, $1.t ?? .infinity, $1.id) }) {
            let candidates = LinkCandidates.candidates(for: x, in: pool, exclusions: exclusions, policy: policy)
            guard !candidates.isEmpty else { continue }
            if let p = LinkScorer.propose(for: x, candidates: candidates, vectors: vectors, policy: policy) { proposals.append(p) }
        }
        return LinkScorer.cap(proposals, policy: policy)
    }
}
