// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The new extraction only removes items or marks them: the quote check, the re-anchoring and the verification rate are the ones they were,
/// and no item can be kept without a verified quote.
@Suite("Minutes: citation verification does not regress")
struct MinutesCitationRegressionTests {
    static let lines: [String] = [
        "Okay, so for the case we use hard plastic, agreed.",
        "I'll send the budget numbers to the whole team by Friday.",
        "Can you look into the company logo?", "Yeah I'll do that.",
        "The upper option is the bomb, it is great.",
        "Last meeting we decided to drop teletext.",
        "We should maybe think about a docking station.",
        "Un total de cuarenta mil euros para el proyecto.",
    ]

    static func segments() -> [Int64: CitableSegment] {
        Dictionary(uniqueKeysWithValues: lines.enumerated().map { i, text in
            (Int64(i + 1), CitableSegment(id: Int64(i + 1), channel: .others, start: Double(i + 1) * 10, text: text,
                                          speaker: SpeakerTag(id: Int64(100 + i % 2), ordinal: i % 2 + 1, confidence: 0.9)))
        })
    }

    static let json = #"""
        {"title": "T", "summary": "S", "topics": [], "entities": [], "open_questions": [],
         "decisions": [
           {"text": "Use hard plastic for the case", "seg": 1, "quote": "we use hard plastic"},
           {"text": "The upper option is the bomb", "seg": 5, "quote": "The upper option is the bomb, it is great"},
           {"text": "Drop teletext", "seg": 6, "quote": "Last meeting we decided to drop teletext"},
           {"text": "Use a docking station", "seg": 7, "quote": "this words are not in the segment at all"},
           {"text": "Cuarenta mil euros", "seg": 3, "quote": "Un total de cuarenta mil euros"}],
         "tasks": [
           {"text": "Send the budget numbers", "owner": null, "owner_id": null, "due": "2026-10-16", "seg": 2, "quote": "send the budget numbers to the whole team"},
           {"text": "Look into the company logo", "owner": "Me", "owner_id": null, "due": null, "seg": 3, "quote": "look into the company logo"},
           {"text": "Invented task", "owner": null, "owner_id": null, "due": null, "seg": 99, "quote": "nothing like this"}]}
        """#

    static func run(_ extraction: MinutesExtraction) throws -> ValidatedMinutes {
        let directory = SpeakerDirectory(speakers: [MeetingSpeaker(id: 100, meetingID: 1, channel: .others, ordinal: 1), MeetingSpeaker(id: 101, meetingID: 1, channel: .others, ordinal: 2)], selfEntity: 1)
        let validated = try VautaPrompts.validateMinutes(json, segments: segments(), candidates: [], selfEntity: 1, directory: directory,
                                                         reference: Date(timeIntervalSince1970: 1_791_763_200), timeZone: TimeZone(identifier: "UTC")!, language: "en", extraction: extraction)
        let order = SegmentOrder(Array(segments().values))
        _ = order
        return ItemEvidence.apply(validated, context: .init(segments: Array(segments().values), language: "en"), extraction: extraction)
    }

    @Test func theQuoteChecksCountTheSameWhicheverExtraction() throws {
        let old = try Self.run(.legacy), new = try Self.run(.shipped)
        #expect(old.proposed == new.proposed)
        func quoteKeys(_ m: ValidatedMinutes) -> [String: Int] {
            m.drops.filter { $0.key.contains("quote") || $0.key.contains("Segment") || $0.key.contains("noSegment") }
        }
        #expect(quoteKeys(old) == quoteKeys(new), "the same items fail the same checks")
        #expect(old.counts.filter { $0.key.contains("reanchored") || $0.key.contains("modulo") } == new.counts.filter { $0.key.contains("reanchored") || $0.key.contains("modulo") })
        #expect(old.drops["decision.quoteNotFound"] == 1 && old.drops["task.unknownSegment"] == 1)
    }

    @Test func theNewExtractionOnlyRemovesOrMarks() throws {
        let old = try Self.run(.legacy), new = try Self.run(.shipped)
        #expect(Set(new.decisions.map(\.text)).isSubset(of: Set(old.decisions.map(\.text))))
        #expect(Set(new.tasks.map(\.text)).isSubset(of: Set(old.tasks.map(\.text))))
        #expect(new.decisions.count + new.drops.filter { $0.key.hasPrefix("decision.") && !$0.key.contains("quote") && !$0.key.contains("Segment") }.values.reduce(0, +) >= old.decisions.count,
                "every missing decision is counted under a reason")
        #expect(new.summary == old.summary && new.title == old.title)
        // The recap and the rating are gone; the agreed decision, the committed task and the answered request stay confirmed.
        #expect(!new.decisions.map(\.text).contains("Drop teletext") && !new.decisions.map(\.text).contains("The upper option is the bomb"))
        #expect(new.decisions.first { $0.text == "Use hard plastic for the case" }?.unconfirmed == false)
        #expect(new.tasks.first { $0.text == "Send the budget numbers" }?.unconfirmed == false)
        #expect(new.tasks.first { $0.text == "Look into the company logo" }?.unconfirmed == false)
    }

    @Test func everyKeptItemHasAQuoteThatIsInItsSegment() throws {
        let new = try Self.run(.shipped)
        let byID = Self.segments()
        for d in new.decisions {
            let seg = try #require(byID[d.segment])
            #expect(QuoteAnchor.resolve(quote: d.quote, cited: d.segment, citedText: seg.text, pool: nil, language: "en") != nil, "decision \(d.text)")
        }
        for t in new.tasks {
            let seg = try #require(byID[t.segment])
            #expect(QuoteAnchor.resolve(quote: t.quote, cited: t.segment, citedText: seg.text, pool: nil, language: "en") != nil, "task \(t.text)")
        }
    }
}
