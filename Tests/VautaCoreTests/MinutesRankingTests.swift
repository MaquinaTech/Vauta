// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The meeting-level ranking of Apple's decisions and tasks: no model, no network.
@Suite("Minutes: ranking")
struct MinutesRankingTests {
    /// 120 lines, 10 seconds apart (20 minutes); line `n` says "Line n about subject n." unless `lines` overrides it.
    static func meeting(_ lines: [Int: String] = [:], count: Int = 120) -> [CitableSegment] {
        (1...count).map { ItemEvidenceTests.line(Int64($0), lines[$0] ?? "Line \($0) is about subject number \($0) and nothing else.", at: Double($0) * 10) }
    }

    static func item(_ text: String, seg: Int64, doubt: String? = nil) -> ValidatedMinutes.Item {
        var i = ValidatedMinutes.Item(text: text, segment: seg, t: Double(seg) * 10, unconfirmed: doubt != nil, quote: "")
        i.doubt = doubt
        return i
    }

    static func minutes(_ decisions: [ValidatedMinutes.Item]) -> ValidatedMinutes {
        var m = ValidatedMinutes()
        m.decisions = decisions
        return m
    }

    /// What the 120 lines (119 gaps of 10 seconds) allow.
    static let limit = MinutesRanking.limit(minutes: 1_190.0 / 60)

    static func rank(_ m: ValidatedMinutes, _ segments: [CitableSegment]) -> ValidatedMinutes {
        MinutesRanking.apply(m, context: .init(segments: segments, language: "en"), extraction: [.evidence, .ranking])
    }

    /// A word of four letters or more that no other word of the tests shares.
    static func word(_ n: Int) -> String { "zeta" + String(UnicodeScalar(UInt8(97 + n / 26))) + String(UnicodeScalar(UInt8(97 + n % 26))) }

    /// 30 decisions, each in its own line, with words of their own so none is a copy of another.
    static func thirty() -> ValidatedMinutes {
        minutes((0..<30).map { i in item("Approve \(word(i)) \(word(i + 30)) \(word(i + 60))", seg: Int64(3 + i * 3), doubt: "noAgreement") })
    }

    @Test func withoutTheSwitchNothingChanges() {
        let m = Self.thirty()
        #expect(MinutesRanking.apply(m, context: .init(segments: Self.meeting(), language: "en"), extraction: [.evidence]) == m)
        #expect(MinutesRanking.apply(ValidatedMinutes(), context: .init(segments: Self.meeting(), language: "en"), extraction: .ranked) == ValidatedMinutes())
    }

    @Test func onlyTheLimitStaysFirmAndTheRestIsToBeConfirmed() {
        let out = Self.rank(Self.thirty(), Self.meeting())
        let firm = out.decisions.filter { !$0.unconfirmed }
        #expect(out.decisions.count == 30, "nothing is removed, only marked")
        #expect(firm.count == Self.limit)
        #expect(out.counts["rank.shown"] == firm.count && out.counts["rank.proposed"] == 30)
    }

    @Test func laterItemsRankAboveEarlierOnes() {
        let out = Self.rank(Self.thirty(), Self.meeting())
        let firm = out.decisions.filter { !$0.unconfirmed }.map(\.segment)
        let others = out.decisions.filter(\.unconfirmed).map(\.segment)
        #expect(firm.min()! > others.min()!, "the end of the meeting wins over its start")
        #expect(Set(firm) == Set(out.decisions.sorted { $0.segment > $1.segment }.prefix(firm.count).map(\.segment)), "with nothing else to tell them apart, the last ones are the firm ones")
    }

    @Test func anAgreementAndAnActionCueLiftAnItemAndProcedureLowersIt() {
        let plain = MinutesRanking.Features(position: 0.5)
        var agreed = plain
        agreed.agreeNext = true
        var acted = plain
        acted.action = true
        var procedure = plain
        procedure.procedure = true
        #expect(MinutesRanking.score(agreed) > MinutesRanking.score(plain) && MinutesRanking.score(acted) > MinutesRanking.score(plain))
        #expect(MinutesRanking.score(procedure) < MinutesRanking.score(plain))
        var late = plain
        late.position = 0.9
        #expect(MinutesRanking.score(late) > MinutesRanking.score(plain))
    }

    @Test func anAgreementInTheNextLineMakesAnEarlyItemFirm() {
        // Eight items, six stay firm. Without an agreement in the lines around it, the item in line 60 is the lowest; with one, the items in lines 70 and 80 are.
        let positions = [60, 70, 80, 90, 100, 105, 110, 115]
        let items = positions.map { Self.item("Approve \(Self.word($0)) \(Self.word($0 + 1)) \(Self.word($0 + 2))", seg: Int64($0), doubt: "noAgreement") }
        let plain = Self.rank(Self.minutes(items), Self.meeting())
        #expect(plain.decisions.filter { !$0.unconfirmed }.map(\.segment) == [80, 90, 100, 105, 110, 115])
        let agreed = Self.rank(Self.minutes(items), Self.meeting([60: "Okay, agreed, we go with that one.", 61: "Okay, agreed, let's go with that one."]))
        #expect(agreed.decisions.filter { !$0.unconfirmed }.map(\.segment) == [60, 90, 100, 105, 110, 115])
    }

    @Test func aNearCopyIsRemovedAndTheLaterOneStays() {
        var m = Self.minutes([Self.item("Order the bluish batteries from the supplier in Madrid", seg: 20), Self.item("Order the bluish batteries from the Madrid supplier", seg: 90)])
        m.decisions += Self.thirty().decisions
        let out = Self.rank(m, Self.meeting())
        #expect(out.decisions.count == 31)
        #expect(out.decisions.contains { $0.segment == 90 } && !out.decisions.contains { $0.segment == 20 })
        #expect(out.drops["item.nearCopy"] == 1)
    }

    @Test func aQuestionOrUnverifiedFiguresAreNeverFirmWhateverTheirRank() {
        var m = Self.minutes([Self.item("Should we move the launch to September next year", seg: 118, doubt: "question"), Self.item("Budget is 40000 euros for the whole project", seg: 119, doubt: "figures")])
        m.decisions += Self.thirty().decisions
        let out = Self.rank(m, Self.meeting())
        #expect(out.decisions.filter { $0.segment >= 118 }.allSatisfy { $0.unconfirmed })
        #expect(MinutesRanking.neverFirm("question") && MinutesRanking.neverFirm("figures") && !MinutesRanking.neverFirm("tentative") && !MinutesRanking.neverFirm(nil))
    }

    /// The path the app takes: the citation check marks the figure, the evidence filter finds a reason of its own, the ranking decides what is firm.
    @Test func anItemWhoseFigureIsNotInTheCitedLineStaysUnconfirmedThroughTheEvidenceFilterAndTheRanking() throws {
        let text = "Maybe the budget could end up somewhere near that, we will see later on."
        let segs = Self.meeting([118: text, 119: "Okay."])
        let reply = #"{"title": "T", "summary": "S", "decisions": [{"text": "The budget is 40000 euros for the whole project", "seg": 118, "quote": "the budget could end up somewhere near that"}], "tasks": [], "entities": []}"#
        let validated = try VautaPrompts.validateMinutes(reply, segments: Dictionary(uniqueKeysWithValues: segs.map { ($0.id, $0) }), candidates: [], selfEntity: nil,
                                                         language: "en", extraction: .ranked)
        let decision = try #require(validated.decisions.first)
        #expect(decision.unconfirmed && decision.doubt == "figures", "the citation check says why")
        let checked = ItemEvidence.apply(validated, context: .init(segments: segs, language: "en"), extraction: .ranked)
        let afterEvidence = try #require(checked.decisions.first)
        #expect(afterEvidence.unconfirmed && afterEvidence.doubt == "figures", "the evidence filter keeps the citation check's reason: \(String(describing: afterEvidence.doubt))")
        let ranked = MinutesRanking.apply(checked, context: .init(segments: segs, language: "en"), extraction: .ranked)
        #expect(ranked.decisions.first?.unconfirmed == true, "an item the passage does not back is never shown firm, whatever its rank")
    }

    @Test func theLimitGrowsWithTheMeetingAndStaysBetweenItsBounds() {
        #expect(MinutesRanking.limit(minutes: 5) == 6 && MinutesRanking.limit(minutes: 20) == 7 && MinutesRanking.limit(minutes: 48) == 10)
        #expect(MinutesRanking.limit(minutes: 85) == 12 && MinutesRanking.limit(minutes: 600) == 12)
        var last = 0
        for minutes in stride(from: 0.0, through: 120.0, by: 4.0) {
            let k = MinutesRanking.limit(minutes: minutes)
            #expect(k >= last && (6...12).contains(k))
            last = k
        }
    }

    @Test func theRankingIsDeterministic() {
        let segs = Self.meeting()
        #expect(Self.rank(Self.thirty(), segs) == Self.rank(Self.thirty(), segs))
    }

    @Test func tasksAreRankedWithTheDecisions() {
        var m = Self.thirty()
        m.tasks = (0..<6).map { i in
            var t = ValidatedMinutes.Task(text: "Send the quarter\(i) report about topic\(i) to the board", owner: nil, due: nil, segment: Int64(100 + i), t: 1_000)
            t.unconfirmed = true
            t.doubt = "noCommitment"
            return t
        }
        let out = Self.rank(m, Self.meeting())
        #expect(out.decisions.filter { !$0.unconfirmed }.count + out.tasks.filter { !$0.unconfirmed }.count == Self.limit, "one limit for the whole list")
        #expect(out.tasks.contains { !$0.unconfirmed }, "the late tasks outrank the early decisions")
    }

    @Test func theReleaseRanksAppleListsAndTheIntegratedModelKeepsItsExtraction() {
        #expect(MinutesRelease.ranked(integrated: false) && !MinutesRelease.ranked(integrated: true))
        #expect(MinutesRelease.extraction(integrated: false) == .ranked && MinutesRelease.extraction(integrated: true) == .shipped)
        #expect(!MinutesExtraction.shipped.contains(.ranking) && MinutesExtraction.ranked.contains([.ranking, .blockShape, .evidence, .closing]))
        #expect(MinutesExtraction.parse("rank,evidence") == [.ranking, .evidence] && MinutesExtraction.parse("old") == .legacy)
    }

    @Test func theBlockShapeLeavesOutEntitiesOnlyWhenAsked() {
        func keys(_ schema: OutputSchema) -> [String] {
            guard case .object(let props) = schema else { return [] }
            return props.map(\.name)
        }
        #expect(keys(OutputSchemas.minutesExtract(.init(segments: [1, 2]))).contains("entities"))
        #expect(!keys(OutputSchemas.minutesExtract(.init(segments: [1, 2]), entities: false)).contains("entities"))
        #expect(keys(OutputSchemas.minutesExtract(.init(segments: [1, 2]), entities: false)) == ["summary", "topics", "decisions", "tasks", "open_questions"])
        let lean = VautaPrompts.blockInstruction(MinutesExtractionTests.english, wording: .init(blockEntities: false)).content
        let full = VautaPrompts.blockInstruction(MinutesExtractionTests.english, wording: .init()).content
        #expect(!lean.contains("\"entities\"") && full.contains("\"entities\""))
    }

    @Test func aFirmItemThatRanksOutDoesNotCarryAStaleDoubtIntoItsReason() {
        var m = Self.thirty()
        for i in m.decisions.indices { m.decisions[i].unconfirmed = false }
        let out = Self.rank(m, Self.meeting())
        let ranked = out.decisions.filter { $0.unconfirmed }
        #expect(!ranked.isEmpty)
        #expect(ranked.allSatisfy { $0.doubt == "rank" }, "an item nobody had marked is plain rank, whatever its doubt field held")
    }

    @Test func anItemThatRanksOutIsStoredAsRankedOutWhateverSoftDoubtTheEvidenceCheckPutOnIt() {
        var m = Self.minutes([Self.item("Should we move the launch to September next year", seg: 3, doubt: "question"),
                              Self.item("Budget is 40000 euros for the whole project", seg: 6, doubt: "figures")])
        m.decisions += Self.thirty().decisions
        m.decisions.append(Self.item("Ship the zetaxx zetayy zetazz plan", seg: 9))
        let out = Self.rank(m, Self.meeting())
        let byDoubt = Dictionary(grouping: out.decisions.filter(\.unconfirmed), by: { $0.doubt ?? "-" })
        #expect(byDoubt["question"]?.count == 1 && byDoubt["figures"]?.count == 1, "a question and unbacked figures keep their own reason")
        let ranked = out.decisions.filter { UnconfirmedReason.isRankedOut($0.doubt) && $0.unconfirmed }
        #expect(ranked.count == out.decisions.filter(\.unconfirmed).count - 2, "every other item that did not rank is ranked out")
        #expect(ranked.contains { $0.doubt == "rank:noAgreement" }, "the soft doubt is kept after the code")
        #expect(ranked.contains { $0.doubt == "rank" }, "an item nothing doubted is plain rank")
        #expect(out.decisions.filter { !$0.unconfirmed }.count == Self.limit)
    }

    @Test func procedureItemsTakeAFirmPlaceOnlyWhenTheSwitchIsOff() {
        let segs = Self.meeting([115: "Okay, let me show you the next slide on the screen now."])
        var m = Self.thirty()
        m.decisions.append(Self.item("Go to the next slide on the screen", seg: 115))
        func run(_ ext: MinutesExtraction) -> ValidatedMinutes { MinutesRanking.apply(m, context: .init(segments: segs, language: "en"), extraction: ext) }
        let off = run([.evidence, .ranking])
        let on = run([.evidence, .ranking, .procedureNeverFirm])
        let procedureOff = off.decisions.first { $0.text.contains("next slide") }
        let procedureOn = on.decisions.first { $0.text.contains("next slide") }
        #expect(procedureOff?.unconfirmed == false, "the late item ranks inside the limit")
        #expect(procedureOn?.unconfirmed == true && UnconfirmedReason.isRankedOut(procedureOn?.doubt), "with the switch it does not take a firm place")
        #expect(on.decisions.filter { !$0.unconfirmed }.count == Self.limit && off.decisions.filter { !$0.unconfirmed }.count == Self.limit, "the next item takes the place")
        #expect(on.counts["rank.procedure"] == 1 && off.counts["rank.procedure"] == nil)
        #expect(MinutesExtraction.parse("rank,procedure") == [.ranking, .procedureNeverFirm] && MinutesExtraction.parse("noprocedure") == nil)
        #expect(!MinutesRelease.extraction(integrated: false).contains(.procedureNeverFirm) && !MinutesRelease.extraction(integrated: true).contains(.procedureNeverFirm))
    }
}
