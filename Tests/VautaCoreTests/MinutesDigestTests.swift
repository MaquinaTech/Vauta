// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Minutes digest: duplicates across blocks")
struct MinutesDigestTests {
    static func extract(_ decisions: [(String, Int, String)]) -> String {
        let items = decisions.map { #"{"text": "\#($0.0)", "seg": \#($0.1), "quote": "\#($0.2)"}"# }.joined(separator: ",")
        return #"{"summary": "s", "topics": [], "decisions": [\#(items)], "tasks": [], "entities": [], "open_questions": []}"#
    }

    @Test func theCopyWhoseQuoteHoldsIsTheOneKept() {
        let text = [1: "we keep the budget as it is", 2: "approved by everyone here"]
        let sound: ([String: Any]) -> Bool = { item in
            guard let seg = item["seg"] as? Int, let quote = item["quote"] as? String, let body = text[seg] else { return false }
            return body.contains(quote)
        }
        let bad = Self.extract([("Keep the budget", 2, "we keep the budget as it is")])
        let good = Self.extract([("Keep the budget.", 1, "we keep the budget as it is")])
        let digest = MinutesDigest(extracts: [bad, good], isSound: sound)
        #expect(digest.decisions.count == 1 && digest.decisions[0]["seg"] as? Int == 1, "the valid copy replaces the one that fails")
        // The first copy stays when it holds, and the later one does not displace it.
        let other = MinutesDigest(extracts: [good, bad], isSound: sound)
        #expect(other.decisions.count == 1 && other.decisions[0]["seg"] as? Int == 1)
        // Without a check the first copy stays, as before.
        #expect(MinutesDigest(extracts: [bad, good]).decisions[0]["seg"] as? Int == 2)
    }

    @Test func anItemWithNoTextTakesNoPlace() {
        let digest = MinutesDigest(extracts: [Self.extract([("", 1, "x"), ("  ", 1, "x"), ("Real decision", 1, "we keep the budget")])])
        #expect(digest.decisions.count == 1 && digest.decisions[0]["text"] as? String == "Real decision")
    }

    @Test func theLastResortCutKeepsTheClosingDelimiter() {
        let long = String(repeating: "word ", count: 400)
        let digest = MinutesDigest(extracts: [Self.extract([("Decision", 1, "x")]).replacingOccurrences(of: #""summary": "s""#, with: #""summary": "\#(long)""#)])
        let content = digest.message(tokens: 3).content
        #expect(content.hasSuffix("\n>>>") && content.hasPrefix("<<<"), "\(content.debugDescription)")
    }

    @Test func theOpenLinesGoBeforeTheDecidedAndTasksLines() {
        func extract(_ i: Int, open: Bool) -> String {
            let questions = open ? #"["Who will pay for the venue of the event number \#(i) when the budget is still not approved by the board?", "Is the date for the review number \#(i) fixed with the vendors and the legal team?"]"# : "[]"
            return #"{"summary": "Block \#(i) summary of what happened in this stretch of the meeting.", "topics": ["topic \#(i)"], "decisions": [{"text": "Decided \#(i)", "seg": \#(i), "quote": "q"}], "tasks": [{"text": "Task \#(i)", "seg": \#(i), "quote": "q"}], "entities": [], "open_questions": \#(questions)}"#
        }
        let withOpen = MinutesDigest(extracts: (1...12).map { extract($0, open: true) })
        let without = MinutesDigest(extracts: (1...12).map { extract($0, open: false) })
        // A room that holds everything except the open lines: those go, and the decided and tasks lines stay.
        let room = PromptText.tokens(without.message(tokens: 100_000).content) + 1
        let tight = withOpen.message(tokens: room).content
        #expect(!tight.contains("Open:") && tight.contains("Decided: Decided 12") && tight.contains("Tasks: Task 12"), "\(tight.debugDescription)")
        // With room for part of the open lines, they are shortened to one question each before they are dropped.
        let roomy = withOpen.message(tokens: 100_000).content
        #expect(roomy.contains("Open:") && roomy.contains("Decided: Decided 1"))
        let shortened = withOpen.message(tokens: PromptText.tokens(roomy) - 40).content
        #expect(shortened.contains("Decided: Decided 12") && shortened.contains("Tasks: Task 12"))
    }
}
