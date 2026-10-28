// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Prompts: token estimates and reasoning removal")
struct PromptTextTests {
    @Test func tokensDependOnTheScript() {
        let latin = String(repeating: "abcd", count: 80)          // 320 characters
        let cjk = String(repeating: "会议记录", count: 55)          // 220 characters
        #expect(PromptText.tokens(latin) == 100 + 8)
        #expect(PromptText.tokens(cjk) == 200 + 8)
        // Mixed text is weighted by its share of each script.
        #expect(PromptText.tokens(latin + cjk) == 300 + 8)
        // Other scripts sit in between.
        #expect(PromptText.tokens(String(repeating: "мир", count: 100)) == 150 + 8)
        // Each line adds a few tokens for the segment prefix.
        #expect(PromptText.tokens("a\nb") == PromptText.tokens("ab") + 7)
    }

    @Test(arguments: [
        ("<think>reasoning\n{x}</think>\n{\"a\":1}", "{\"a\":1}"),
        ("thinking…</think>{}", "{}"),
        ("<think>no end", ""),
        ("{\"b\":2}", "{\"b\":2}"),
        ("  <thinking>plan</thinking> {\"c\":3}", "{\"c\":3}"),
        ("[THINK]hmm[/THINK]{\"d\":4}", "{\"d\":4}"),
        ("<think>a</think><think>b</think>{\"e\":5}", "{\"e\":5}"),
        ("<|channel|>analysis<|message|>Let me see<|end|><|start|>assistant<|channel|>final<|message|>{\"f\":6}<|return|>", "{\"f\":6}"),
        ("<|channel|>analysis<|message|>still thinking", ""),
        ("analysisThe user wants JSON.assistantfinal{\"g\":7}", "{\"g\":7}"),
        // Content that only quotes the tags is never cut.
        ("{\"answer\": \"Qwen writes <think> before reasoning\"}", "{\"answer\": \"Qwen writes <think> before reasoning\"}"),
        ("{\"answer\": \"it ends with </think>\"}", "{\"answer\": \"it ends with </think>\"}"),
    ])
    func reasoningIsStrippedOnlyAtTheStart(input: String, expected: String) {
        #expect(ModelOutput.strippingReasoning(input) == expected)
        #expect(LLMClient.strippingThinking(input) == expected)
    }

    @Test func jsonIsFoundInsideFencesAndReasoning() throws {
        struct X: Decodable { let a: Int }
        #expect(try ModelOutput.decodeObject(X.self, from: "<think>{\"a\":0}</think>\n```json\n{\"a\": 2}\n```").a == 2)
        #expect(throws: LLMError.self) { try ModelOutput.decodeObject(X.self, from: "Sorry, I can't.") }
    }

    @Test(arguments: [
        ("{\"a\": [1, 2], \"b\": \"x }\"}", false),
        ("```json\n{\"a\": {\"b\": 1}}\n```", false),
        ("No JSON here.", false),
        ("{\"summary\": \"The team agreed", true),
        ("{\"tasks\": [{\"text\": \"a \\\" quote\"}", true),
    ])
    func answersCutInsideTheJSONAreDetected(input: String, cut: Bool) {
        #expect(ModelOutput.endsInsideJSON(input) == cut)
    }

    /// A number in a text field reads the same on every Mac: in German `formatted()` wrote "2.026" for a year and "1,5".
    @Test func numbersInTextFieldsDoNotDependOnTheRegion() throws {
        struct Item: Decodable {
            let values: [String?]
            init(from decoder: any Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                values = ["year", "half", "big", "negative", "word"].map { c.text($0) }
            }
        }
        let json = #"{"year": 2026, "half": 1.5, "big": 1234567.25, "negative": -3, "word": "Q3"}"#
        let item = try ModelOutput.decodeObject(Item.self, from: json)
        #expect(item.values == ["2026", "1.5", "1234567.25", "-3", "Q3"])
        #expect(2026.0.formatted(.number.locale(Locale(identifier: "de_DE"))) == "2.026", "what the old rendering gave in German")
        #expect(1e20.plainText == "1e+20")
    }
}
