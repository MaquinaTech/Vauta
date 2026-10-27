// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Links to earlier meetings (post-meeting actions, Part B): candidates, scoring, differences and chains. Pure, no store.
@Suite("Links: core rules")
struct LinksCoreTests {
    typealias F = LinkFixture

    // MARK: Policy

    @Test func theReleaseSwitchesAreOffAndThePolicyConstantsAreTheDesigns() {
        for backend in LinkBackend.allCases {
            #expect(!LinksRelease.suggestions(backend) && !LinksRelease.changes(backend) && !LinksRelease.modelCheck(backend))
            #expect(!LinkPolicy.released(backend).showsChanges, "'changes' is hidden everywhere until its false-positive gate passes (D13)")
        }
        let p = LinkPolicy()
        #expect(p.perItem == 1 && p.perMeeting == 6 && p.windowDays == 180 && p.maxCandidates == 200)
        #expect(p.floor == 0.90 && p.keywordAnchorJaccard == 0.4 && p.changesMargin == 0.08 && p.keywordJaccard == 0.5 && p.keywordSharedWords == 3)
        #expect(p.includesDoubted && !p.includesRankedOut)
    }

    @Test func rankedOutItemsAreNotEligibleAndDoubtedOnesAre() {
        let p = LinkPolicy()
        #expect(p.isEligible(unconfirmed: false, reason: nil))
        #expect(!p.isEligible(unconfirmed: true, reason: "rank"))
        #expect(!p.isEligible(unconfirmed: true, reason: "rank:noAgreement"))
        #expect(p.isEligible(unconfirmed: true, reason: "figures"))
        #expect(p.isEligible(unconfirmed: true, reason: nil), "an old unconfirmed row is a doubted one")
        var strict = p
        strict.includesDoubted = false
        #expect(!strict.isEligible(unconfirmed: true, reason: "figures"))
        var diagnostic = p
        diagnostic.includesRankedOut = true
        #expect(diagnostic.isEligible(unconfirmed: true, reason: "rank"))
    }

    // MARK: 26 Candidates

    @Test func candidatesAreSameKindEarlierInTheWindowAndShareContext() {
        let x = F.item(1, meeting: 10, "Send the revised budget to finance", series: 5)
        let ok = F.item(2, meeting: 9, daysAgo: 7, "Send the budget to finance", series: 5)
        let otherKind = F.item(3, .decision, meeting: 9, daysAgo: 7, "Send the budget to finance", series: 5)
        let later = F.item(4, meeting: 11, daysAgo: -3, "Send the budget to finance", series: 5)
        let old = F.item(5, meeting: 3, daysAgo: 181, "Send the budget to finance", series: 5)
        let sameMeeting = F.item(6, meeting: 10, "Send the budget to finance", series: 5)
        let noContext = F.item(7, meeting: 8, daysAgo: 7, "Send the budget to finance")
        let dropped = F.item(8, meeting: 8, daysAgo: 7, "Send the budget to finance", series: 5, status: .dropped)
        let done = F.item(9, meeting: 8, daysAgo: 8, "Send the budget to finance", series: 5, status: .done)
        let found = LinkCandidates.candidates(for: x, in: [ok, otherKind, later, old, sameMeeting, noContext, dropped, done], exclusions: LinkExclusions(), policy: LinkPolicy())
        #expect(found.map(\.id) == [2, 9], "newest first; a done task is a candidate, a dropped one is not")
    }

    @Test func theContextGateNeedsASeriesAPersonAnOwnerOrAProject() {
        let x = F.item(1, meeting: 10, "Plan the offsite", people: [7, 8], owner: 3, projects: [20])
        func gate(_ c: LinkItem) -> Bool { LinkCandidates.sharesContext(x, c) }
        #expect(!gate(F.item(2, meeting: 9, daysAgo: 1, "x")))
        #expect(gate(F.item(2, meeting: 9, daysAgo: 1, "x", people: [8])))
        #expect(gate(F.item(2, meeting: 9, daysAgo: 1, "x", owner: 3)))
        #expect(gate(F.item(2, meeting: 9, daysAgo: 1, "x", projects: [20])))
        var withSeries = x
        withSeries.seriesID = 4
        #expect(LinkCandidates.sharesContext(withSeries, F.item(2, meeting: 9, daysAgo: 1, "x", series: 4)))
        // The owner counts for tasks only.
        let decision = F.item(1, .decision, meeting: 10, "Keep the shell", owner: 3)
        #expect(!LinkCandidates.sharesContext(decision, F.item(2, .decision, meeting: 9, daysAgo: 1, "Keep the shell", owner: 3)))
    }

    @Test func linksStayInOneLanguage() {
        let x = F.item(1, meeting: 10, "Send the revised budget to finance", series: 1)
        let spanish = F.item(2, meeting: 9, daysAgo: 7, "Enviar el presupuesto revisado a finanzas", locale: "es", series: 1)
        #expect(LinkCandidates.candidates(for: x, in: [spanish], exclusions: LinkExclusions(), policy: LinkPolicy()).isEmpty)
        #expect(LinkText.language(of: "Enviar el presupuesto revisado a finanzas antes del viernes", fallback: Locale(identifier: "en")) == "es")
        #expect(LinkText.language(of: "ok", fallback: Locale(identifier: "es-ES")) == "es", "a short text takes the meeting's language")
    }

    @Test func exclusionsKeepDecidedPairsDismissedKeysAndChainMiddles() {
        let x = F.item(1, meeting: 10, "Send the revised budget to finance", series: 1)
        let a = F.item(2, meeting: 9, daysAgo: 7, "Send the budget to finance", series: 1)
        let b = F.item(3, meeting: 8, daysAgo: 14, "Send the budget to finance", series: 1)
        var decided = LinkExclusions()
        decided.decidedPairs.insert(LinkExclusions.pair(.task, 1, 2))
        #expect(LinkCandidates.candidates(for: x, in: [a, b], exclusions: decided, policy: LinkPolicy()).map(\.id) == [3])
        var dismissed = LinkExclusions()
        dismissed.dismissedKeys.insert(LinkExclusions.dismissal(.task, srcMeeting: 10, srcKey: LinkText.key(x.text), dstMeeting: 9, dstKey: LinkText.key(a.text)))
        #expect(LinkCandidates.candidates(for: x, in: [a, b], exclusions: dismissed, policy: LinkPolicy()).map(\.id) == [3], "by content, not by id")
        var chain = LinkExclusions()
        chain.superseded[LinkExclusions.item(.task, 3)] = a.startedAt
        #expect(LinkCandidates.candidates(for: x, in: [a, b], exclusions: chain, policy: LinkPolicy()).map(\.id) == [2], "only the chain's newest member")
        // A meeting between the two members still sees the older one: the newer member is not earlier than it.
        let between = F.item(5, meeting: 11, daysAgo: 10, "Send the revised budget to finance", series: 1)
        #expect(LinkCandidates.candidates(for: between, in: [b], exclusions: chain, policy: LinkPolicy()).map(\.id) == [3])
        // A meeting that already holds a member of a chain is not offered that chain.
        var held = LinkExclusions()
        held.chainMeetings[LinkExclusions.item(.task, 2)] = [10]
        #expect(LinkCandidates.candidates(for: x, in: [a, b], exclusions: held, policy: LinkPolicy()).map(\.id) == [3])
        var linked = LinkExclusions()
        linked.linkedSources.insert(LinkExclusions.item(.task, 1))
        #expect(LinkCandidates.candidates(for: x, in: [a, b], exclusions: linked, policy: LinkPolicy()).isEmpty)
    }

    @Test func atMostTwoHundredCandidatesNewestFirst() {
        let x = F.item(1, meeting: 1000, "Plan the work", series: 1)
        let pool = (0..<250).map { F.item(Int64(10 + $0), meeting: Int64(10 + $0), daysAgo: 1 + Double($0) * 0.5, "Plan the work", series: 1) }
        let found = LinkCandidates.candidates(for: x, in: pool, exclusions: LinkExclusions(), policy: LinkPolicy())
        #expect(found.count == 200 && found.first?.id == 10)
    }

    // MARK: 27 Vector scoring

    @Test func aVectorPairNeedsTheRawCosineFloorAndOneSharedWord() {
        let x = F.item(1, meeting: 10, "Prepare the quarterly forecast", series: 1)
        let near = F.item(2, meeting: 9, daysAgo: 7, "Draft the forecast for next quarter", series: 1)
        let far = F.item(3, meeting: 8, daysAgo: 14, "Draft the forecast for next quarter", series: 1)
        let noWords = F.item(4, meeting: 7, daysAgo: 21, "Zzz qqq", series: 1)
        let vectors = [F.key(x): F.vector(1), F.key(near): F.vector(0.93), F.key(far): F.vector(0.89), F.key(noWords): F.vector(0.95)]
        let p = F.engine(sources: [x], pool: [near, far, noWords], vectors: vectors)
        #expect(p.count == 1 && p[0].dstID == 2 && p[0].method == .vector && p[0].relation == .same)
        #expect(abs(p[0].score - 0.93) < 0.001, "the raw cosine, no boost")
        // A floor-passing cosine without a shared word or a code is no link.
        #expect(F.engine(sources: [x], pool: [noWords], vectors: vectors).isEmpty)
    }

    @Test func oneSuggestionPerItemAndSixPerMeeting() {
        var sources: [LinkItem] = [], pool: [LinkItem] = [], vectors: [String: LinkVector] = [:]
        let texts = ["Finalize the budget numbers", "Schedule hiring interviews", "Confirm venue booking", "Sign supplier contract", "Update roadmap slides",
                     "Send customer survey", "Review audit findings", "Pay overdue invoice", "Launch pilot program"]
        for (i, text) in texts.enumerated() {
            let x = F.item(Int64(100 + i), meeting: 10, text, series: 1)
            sources.append(x)
            vectors[F.key(x)] = F.vector(1)
            // Two earlier candidates each; the newer one wins a tie, the surer one wins otherwise.
            let older = F.item(Int64(200 + i), meeting: 8, daysAgo: 14, text, series: 1)
            let newer = F.item(Int64(300 + i), meeting: 9, daysAgo: 7, text, series: 1)
            pool += [older, newer]
            vectors[F.key(older)] = F.vector(0.92)
            vectors[F.key(newer)] = F.vector(0.92)
        }
        let p = F.engine(sources: sources, pool: pool, vectors: vectors)
        #expect(p.count == 6, "six per meeting")
        #expect(Set(p.map(\.srcID)).count == 6, "one per item")
        #expect(p.allSatisfy { $0.dstID >= 300 }, "a tie goes to the newer earlier item")
        // The same inputs give the same list.
        #expect(p == F.engine(sources: sources, pool: pool, vectors: vectors))
    }

    @Test func twoItemsOfOneMeetingAreNeverSuggestedAgainstTheSameEarlierItem() {
        let first = F.item(1, meeting: 10, "Send the revised budget to finance", series: 1)
        let second = F.item(2, meeting: 10, "Send the budget to the finance team", series: 1)
        let earlier = F.item(3, meeting: 9, daysAgo: 7, "Send the budget to finance", series: 1)
        let vectors = [F.key(first): F.vector(1), F.key(second): F.vector(1), F.key(earlier): F.vector(0.95)]
        let p = F.engine(sources: [first, second], pool: [earlier], vectors: vectors)
        #expect(p.count == 1 && p[0].dstID == 3, "only one of them can be the earlier item's next mention, so a chain never holds two of one meeting")
    }

    @Test func aPairWithoutVectorsFallsBackToTheKeywordGate() {
        let x = F.item(1, meeting: 10, "Send the revised budget to the finance team", series: 1)
        let c = F.item(2, meeting: 9, daysAgo: 7, "Send the budget to the finance team", series: 1)
        let p = F.engine(sources: [x], pool: [c], vectors: [F.key(x): F.vector(1)])
        #expect(p.count == 1 && p[0].method == .keyword)
    }

    // MARK: 28 Keyword gate

    @Test func theKeywordGateNeedsJaccardAndSharedWordsAndASeriesOrOwner() {
        let x = F.item(1, meeting: 10, "Send the revised budget to the finance team", series: 1)
        #expect(F.engine(sources: [x], pool: [F.item(2, meeting: 9, daysAgo: 7, "Send the budget to the finance team", series: 1)]).count == 1)
        // Jaccard under 0.5.
        #expect(F.engine(sources: [x], pool: [F.item(2, meeting: 9, daysAgo: 7, "Send the budget for the offsite catering contract renewal", series: 1)]).isEmpty)
        // Fewer than three shared content words.
        let short = F.item(3, meeting: 10, "Send the budget", series: 1)
        #expect(F.engine(sources: [short], pool: [F.item(4, meeting: 9, daysAgo: 7, "Send the budget", series: 1)]).isEmpty)
        // A shared person alone is not enough for keywords, a series or an owner is.
        let people = F.item(5, meeting: 10, "Send the revised budget to the finance team", people: [7])
        #expect(F.engine(sources: [people], pool: [F.item(6, meeting: 9, daysAgo: 7, "Send the budget to the finance team", people: [7])]).isEmpty)
        let owner = F.item(7, meeting: 10, "Send the revised budget to the finance team", people: [7], owner: 4)
        #expect(F.engine(sources: [owner], pool: [F.item(8, meeting: 9, daysAgo: 7, "Send the budget to the finance team", people: [7], owner: 4)]).count == 1)
    }

    @Test func aCodeOrRareNameWithOneMoreSharedWordPasses() {
        let x = F.item(1, meeting: 10, "Close ticket PO-48213 with the vendor", series: 1)
        let y = F.item(2, meeting: 9, daysAgo: 7, "Chase PO-48213, the vendor", series: 1)
        #expect(F.engine(sources: [x], pool: [y]).count == 1)
        let other = F.item(3, meeting: 9, daysAgo: 7, "Chase PO-99999, the vendor", series: 1)
        #expect(F.engine(sources: [x], pool: [other]).isEmpty)
    }

    @Test func aChangedFigureDoesNotLowerTheOverlap() {
        let words = LinkText.words("Budget capped at 40.000 € for the Kobaltix project", locale: "en")
        #expect(!words.contains { $0.contains(where: \.isNumber) })
        #expect(words.contains("budget") && words.contains("kobaltix"))
    }

    @Test func chineseAndJapaneseItemsUseCharacterPairs() {
        let a = LinkText.words("向财务部门发送修订后的预算", locale: "zh-Hans")
        let b = LinkText.words("把修订后的预算发送给财务部门", locale: "zh-Hans")
        #expect(LinkText.jaccard(a, b) > 0.5)
        let x = F.item(1, meeting: 10, "向财务部门发送修订后的预算", locale: "zh-Hans", series: 1)
        let y = F.item(2, meeting: 9, daysAgo: 7, "把修订后的预算发送给财务部门", locale: "zh-Hans", series: 1)
        #expect(F.engine(sources: [x], pool: [y]).count == 1)
    }

    // MARK: 29 Differences

    private func judge(_ newer: String, _ earlier: String, kind: LinkKind = .decision, locale: String = "en") -> LinkDifference.Verdict {
        LinkDifference.judge(kind: kind, newer: newer, earlier: earlier, locale: locale)
    }

    @Test func oneFigureWithTheSameUnitIsAChange() {
        guard case .changes(let e) = judge("Budget capped at 48.200 €", "Budget capped at 40.000 €") else { Issue.record("expected a change"); return }
        #expect(e.earlier == ["40.000 €"] && e.now == ["48.200 €"])
        #expect(judge("Budget capped at 48.200 euros", "Budget capped at 40.000 €") != .same, "euros and the symbol are one unit")
        #expect(judge("Budget capped at 40.000 €", "Budget capped at 40.000 €") == .same)
        #expect(judge("Budget capped at 40k €", "Budget capped at 40k €") == .same)
    }

    @Test func anotherPeriodMeansAnotherSubject() {
        #expect(judge("Q4 budget capped at 50k", "Q3 budget capped at 40k") == .unrelated)
        #expect(judge("Budget for 2027 capped at 50k", "Budget for 2026 capped at 40k") == .unrelated)
        #expect(judge("Budget for week 13 is final", "Budget for week 12 is final") == .unrelated)
        // The same period with a changed figure is a change.
        if case .changes = judge("Q3 budget capped at 50k", "Q3 budget capped at 40k") {} else { Issue.record("expected a change") }
    }

    @Test func severalFiguresOrDifferentUnitsAreNotAChange() {
        #expect(judge("Hire 4 engineers and 3 designers", "Hire 5 engineers and 2 designers") == .unrelated)
        #expect(judge("Budget capped at 48.200 €", "Budget capped at 40.000 $") == .unrelated)
        // A figure only one side has is a detail, not a difference.
        #expect(judge("Keep the C-shaped shell, 40 units", "Keep the C-shaped shell") == .same)
    }

    @Test func aDeadlineDateInTheSameRoleIsAChange() {
        guard case .changes(let e) = judge("Deliver the report by 17 October", "Deliver the report by 10 October") else { Issue.record("expected a change"); return }
        #expect(e.earlier == ["10 October"] && e.now == ["17 October"])
        guard case .changes = judge("Deliver the report on Friday", "Deliver the report on Monday") else { Issue.record("expected a change"); return }
        // A date and a figure at once are different subjects.
        #expect(judge("Order 20 units by 17 October", "Order 10 units by 10 October") == .unrelated)
    }

    @Test func polarityNeedsAReversalAttachedToASharedWord() {
        guard case .changes(let e) = judge("We no longer ship the C-shaped shell", "We ship the C-shaped shell") else { Issue.record("expected a change"); return }
        #expect(e.now == ["no longer"] && e.earlier.isEmpty)
        guard case .changes = judge("Postponed: the launch event", "Hold the launch event") else { Issue.record("expected a change"); return }
        // Bare "no" and "not" never count, and neither does "no later than".
        #expect(judge("Send the report no later than Friday", "Send the report") == .same)
        #expect(judge("We do not know the final shell yet, keep the shell design", "Keep the shell design") == .same)
        // A reversal that touches nothing the two share is not a change.
        #expect(judge("Cancel the catering. Keep the shell design", "Keep the shell design") == .same)
    }

    @Test func approvedAgainstRejectedIsAStatusPair() {
        guard case .changes = judge("The vendor contract was rejected", "The vendor contract was approved") else { Issue.record("expected a change"); return }
        guard case .changes = judge("El presupuesto del proveedor fue rechazado", "El presupuesto del proveedor fue aprobado", locale: "es") else { Issue.record("expected a change"); return }
    }

    @Test func differencesAreReadInSixLanguages() {
        if case .changes = judge("Presupuesto máximo de 48.200 €", "Presupuesto máximo de 40.000 €", locale: "es") {} else { Issue.record("es figure") }
        if case .changes = judge("Ya no enviamos la carcasa en forma de C", "Enviamos la carcasa en forma de C", locale: "es") {} else { Issue.record("es polarity") }
        if case .changes = judge("Le budget plafonné à 48 200 €", "Le budget plafonné à 40 000 €", locale: "fr") {} else { Issue.record("fr figure") }
        if case .changes = judge("Wir senden die Schale nicht mehr aus", "Wir senden die Schale aus", locale: "de") {} else { Issue.record("de polarity") }
        if case .changes = judge("予算は48,200円に変更", "予算は40,000円に変更", locale: "ja") {} else { Issue.record("ja figure") }
        if case .changes = judge("取消发布活动", "发布活动", locale: "zh-Hans") {} else { Issue.record("zh polarity") }
        #expect(judge("Presupuesto máximo de 40.000 €", "Presupuesto máximo de 40.000 €", locale: "es") == .same)
    }

    @Test func tasksAreNeverChanges() {
        #expect(judge("Send the report by 17 October", "Send the report by 10 October", kind: .task) == .same)
        #expect(judge("Send 20 invoices", "Send 10 invoices", kind: .task) == .same)
    }

    @Test func aChangeThatIsNotShownIsDroppedNeverRelabelledSame() {
        let x = F.item(1, .decision, meeting: 10, "Budget capped at 48.200 € for the Kobaltix project", series: 1)
        let c = F.item(2, .decision, meeting: 9, daysAgo: 7, "Budget capped at 40.000 € for the Kobaltix project", series: 1)
        #expect(F.engine(sources: [x], pool: [c]).isEmpty, "default: no 'different' suggestions")
        var shown = LinkPolicy()
        shown.showsChanges = true
        let p = F.engine(sources: [x], pool: [c], policy: shown)
        #expect(p.count == 1 && p[0].relation == .changes && p[0].evidence?.now == ["48.200 €"])
        // A changes-band cosine (under the floor) only ever becomes a change.
        let vectors = [F.key(x): F.vector(1), F.key(c): F.vector(0.85)]
        #expect(F.engine(sources: [x], pool: [c], vectors: vectors, policy: shown).first?.relation == .changes)
        let same = F.item(3, .decision, meeting: 9, daysAgo: 7, "Budget for the Kobaltix project", series: 1)
        #expect(F.engine(sources: [x], pool: [same], vectors: [F.key(x): F.vector(1), F.key(same): F.vector(0.85)], policy: shown).isEmpty)
    }

    // MARK: 32 Chains

    @Test func chainsFollowConfirmedSameLinksAndTheNewestIsTheRoot() {
        let dates: [Int64: Date] = [1: F.base, 2: F.base.addingTimeInterval(-7 * F.day), 3: F.base.addingTimeInterval(-14 * F.day),
                                    4: F.base.addingTimeInterval(-3 * F.day), 5: F.base.addingTimeInterval(-10 * F.day)]
        let chains = LinkChain.chains(links: [(1, 2), (2, 3), (4, 5)], dates: dates)
        #expect(chains.count == 2)
        let long = chains.first { $0.newest.id == 1 }
        #expect(long?.members.map(\.id) == [1, 2, 3] && long?.earlier.count == 2 && long?.count == 3)
        #expect(chains.first { $0.newest.id == 4 }?.members.map(\.id) == [4, 5])
        // Deleting the middle member removes its links: the chain splits.
        #expect(LinkChain.chains(links: [], dates: dates).isEmpty)
        #expect(LinkChain.chains(links: [(1, 2)], dates: dates).first?.members.map(\.id) == [1, 2])
        // The order does not matter, and a link to an unknown item is ignored.
        #expect(LinkChain.chains(links: [(2, 3), (1, 2), (9, 1)], dates: dates).first?.members.map(\.id) == [1, 2, 3])
    }
}
