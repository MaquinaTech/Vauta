// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Answers from a fixed table; texts not in it come back unchanged.
private struct TableTranslator: Translator {
    let table: [String: String]
    func translate(_ text: String) async throws -> String { table[text] ?? text }
}

@Suite("Translation: output guard")
struct TranslationOutputGuardTests {
    // Outputs Apple's high-fidelity English → Spanish model really produced in the benchmark.
    @Test func loopsAreDetected() {
        #expect(TranslationOutputCheck.isDegenerate("¡¡¡¡¡¡¡¡¡¡¡¡¡¡¡¡¡¡¡¡¡¡¡¡", source: "Wow! What a game!"))
        #expect(TranslationOutputCheck.isDegenerate("Revisamos la planificación a mitad de año... ¡¡¡¡¡¡¡¡¡¡¡¡",
                                                    source: "We reviewed the mid-year planning... And then it went great!"))
        #expect(TranslationOutputCheck.isDegenerate("¿Son 2,8 km? ¿¿¿¿¿¿¿¿¿¿¿¿¿¿", source: "Is that 2.8 km? Then we walk."))
        #expect(TranslationOutputCheck.isDegenerate("vale vale vale vale vale", source: "okay, let's go"))
    }

    @Test func normalTextIsNotALoop() {
        #expect(!TranslationOutputCheck.isDegenerate("Hola, ¿qué tal?", source: "Hi, how are you?"))
        #expect(!TranslationOutputCheck.isDegenerate("Cuesta 1000000 de euros.", source: "It costs 1000000 euros."))
        #expect(!TranslationOutputCheck.isDegenerate("No, no, no, no, eso no.", source: "No, no, no, no, not that."))
        #expect(!TranslationOutputCheck.isDegenerate("¡¡¡¡¡¡Gol!!!!!!", source: "!!!!!!Goal!!!!!!"))
        #expect(!TranslationOutputCheck.isDegenerate("会議は十時に始まります。", source: "The meeting starts at ten."))
    }

    @Test func trimmingCutsTheLoopAndDanglingMarks() {
        #expect(TranslationOutputCheck.trimmed("Revisamos el plan... ¡¡¡¡¡¡¡¡¡¡", source: "We reviewed the plan... Great!")
                == "Revisamos el plan...")
        #expect(TranslationOutputCheck.trimmed("¡¡¡¡¡¡¡¡¡¡¡¡", source: "Wow!") == "")
        #expect(TranslationOutputCheck.trimmed("Vale, vale vale vale vale", source: "Okay, sure") == "Vale,")
    }

    @Test func aLoopingTextIsTranslatedAgainSentenceBySentence() async throws {
        let source = "We reviewed the plan. Then it went great!"
        let inner = TableTranslator(table: [
            source: "Revisamos el plan. ¡¡¡¡¡¡¡¡¡¡¡¡",
            "We reviewed the plan.": "Revisamos el plan.",
            "Then it went great!": "¡Luego salió genial!",
        ])
        let translator = GuardedTranslator(inner, target: Locale.Language(identifier: "es"))
        #expect(try await translator.translate(source) == "Revisamos el plan. ¡Luego salió genial!")
        #expect(try await translator.translate(batch: [source, "Hi"]) == ["Revisamos el plan. ¡Luego salió genial!", "Hi"])
    }

    @Test func chineseAndJapaneseSentencesJoinWithoutSpaces() async throws {
        let source = "We met. We agreed."
        let inner = TableTranslator(table: [
            source: "我们见面了。。。。。。。。。",
            "We met.": "我们见面了。",
            "We agreed.": "我们达成了一致。",
        ])
        let translator = GuardedTranslator(inner, target: Locale.Language(identifier: "zh-Hans"))
        #expect(try await translator.translate(source) == "我们见面了。我们达成了一致。")
    }

    @Test func aSingleLoopingSentenceIsTrimmedNeverShownRaw() async throws {
        let inner = TableTranslator(table: ["Wow!": "¡¡¡¡¡¡¡¡¡¡¡¡¡¡"])
        let translator = GuardedTranslator(inner, target: Locale.Language(identifier: "es"))
        #expect(try await translator.translate("Wow!") == "")
    }

    @Test func goodOutputsPassThroughUntouched() async throws {
        let inner = TableTranslator(table: ["Hi": "Hola"])
        let translator = GuardedTranslator(inner, target: Locale.Language(identifier: "es"))
        #expect(try await translator.translate("Hi") == "Hola")
    }
}
