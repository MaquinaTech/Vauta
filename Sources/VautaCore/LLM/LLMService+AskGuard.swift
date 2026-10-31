// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The guards of a live answer on the integrated model: a check that the quotes state the answer as something already said.
extension LLMService {
    /// How the quoted lines stand to the question asked at a given moment.
    public enum AnswerRelation: String, Sendable, Equatable {
        /// They state the answer as something already said or done.
        case states
        /// They only announce, propose or prepare something that has not happened yet.
        case anticipates
        /// They only touch the topic.
        case related
    }

    /// Which guards of a live answer are on (the evaluation switches them).
    public func setAnswerGuards(_ guards: AnswerGuards) { answerGuards = guards }
    /// Forces which parts of Ask's request and retrieval are on (the evaluation); nil goes back to the release choice.
    func setAskHarness(_ harness: AskHarness?) { askHarnessOverride = harness }
    /// Forces bounded reasoning in a model server's Ask after the meeting on or off (the evaluation); nil goes back to `AskReasoningRelease`.
    func setServerAskReasoning(_ on: Bool?) { serverAskReasoningOverride = on }
    public func setAppleGuidedAsk(_ on: Bool) { appleGuidedAsk = on }

    /// The check gives up after this long.
    static let guardSeconds = 3.0

    /// The instruction of the check: the question, the moment it was asked, the answer and the quoted lines with their times.
    static func relationInstruction(question: String, askedAt: Double, answer: VerifiedAnswer, sent: [Int64: CitableSegment]) -> ChatMessage {
        let time = PromptText.clock(askedAt)
        var quotes: [String] = []
        for claim in answer.claims where claim.verified {
            for id in claim.citations.prefix(2) {
                guard let s = sent[id] else { continue }
                quotes.append("- [\(PromptText.clock(s.start))] \(PromptText.defang(PromptText.clip(SingleLineText.flatten(s.text), 300)))")
            }
        }
        return .user("""
            At \(time) someone asked the question below. Do the quoted lines state the answer as something already said or done by \(time) \
            (states), only announce, propose or prepare something that has not happened yet (anticipates), or only touch the topic (related)?
            <<<QUESTION
            \(PromptText.defang(PromptText.clip(question, 500)))
            >>>
            The answer given: \(PromptText.defang(PromptText.clip(SingleLineText.flatten(answer.answer), 600)))
            Quoted lines:
            \(quotes.joined(separator: "\n"))
            Reply with one JSON object: {"relation": "states" | "anticipates" | "related"}.
            """)
    }

    /// Runs the check on the meeting's kept prefix (a suffix-only call). nil when it could not decide: an error, or more than 3 seconds.
    func contrastiveRelation(chat: ChatProvider, prefix: [ChatMessage], question: String, answer: VerifiedAnswer, asked: Double,
                             sent: [Int64: CitableSegment], meetingID: Int64, slot: KeptSlot) async -> AnswerRelation? {
        guard chat.integrated else { return nil }
        setStage(.checkingAnswer)
        defer { setStage(nil) }
        let messages = prefix + [Self.relationInstruction(question: question, askedAt: asked, answer: answer, sent: sent)]
        let schema = OutputSchema.object([OutputSchema.Property("relation", .enumStrings(AnswerRelation.allCases.map(\.rawValue)))])
        let options = ChatOptions(model: .fast, maxTokens: 24, purpose: .ask, outputSchema: schema, reusePrefix: true, priority: .interactive,
                                  maxSeconds: Self.guardSeconds, slot: slot)
        let model = chat.model
        return await withTaskGroup(of: AnswerRelation?.self) { group in
            group.addTask {
                guard let result = try? await model.chat(messages, options, onProgress: nil), !Task.isCancelled else { return nil }
                return Self.parseRelation(result.content)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(Self.guardSeconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    static func parseRelation(_ content: String) -> AnswerRelation? {
        struct Wire: Decodable { let relation: String? }
        guard let wire = try? ModelOutput.decodeObject(Wire.self, from: content), let word = wire.relation?.lowercased() else { return nil }
        return AnswerRelation(rawValue: word)
    }
}

extension LLMService.AnswerRelation: CaseIterable {}

/// The guards of a live answer on the integrated model that can be turned on or off (the evaluation compares them; the app ships none).
public struct AnswerGuards: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    /// The three-way `found` ("yes", "not_yet", "no") of a live answer.
    public static let threeWay = AnswerGuards(rawValue: 1)
    /// The check of the quoted lines against the moment of the question.
    public static let contrastive = AnswerGuards(rawValue: 2)
    public static let all: AnswerGuards = [.threeWay, .contrastive]
    /// What ships: none. Neither guard passed its gate on its own (see docs/LANGUAGE_MODEL.md), so both stay behind the evaluation switch.
    public static let shipped: AnswerGuards = []

    /// "none", "g1", "g2" or "g1+g2" (also "all").
    public static func parse(_ text: String) -> AnswerGuards? {
        switch text.lowercased() {
        case "none", "g0": return []
        case "g1": return .threeWay
        case "g2": return .contrastive
        case "g1+g2", "all": return .all
        default: return nil
        }
    }

    public var names: String {
        isEmpty ? "none" : [contains(.threeWay) ? "g1" : nil, contains(.contrastive) ? "g2" : nil].compactMap { $0 }.joined(separator: "+")
    }
}

extension VerifiedAnswer {
    /// The answer after the check of a live answer.
    func applying(_ relation: LLMService.AnswerRelation) -> VerifiedAnswer {
        switch relation {
        case .states:
            return self
        case .anticipates:
            // "That hasn't come up yet": the model's text is kept aside and the quoted moments stay as what was said so far.
            return VerifiedAnswer(answer: "", claims: claims, found: false, withheld: answer, notYet: true)
        case .related:
            // The quotes are in the transcript, so the claims stay verified; the answer says on its own that the moments only touch the topic.
            return VerifiedAnswer(answer: answer, claims: claims, found: true, cutShort: cutShort, touchesOnly: true, unbackedFigures: unbackedFigures)
        }
    }
}
