// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension VautaPrompts {
    /// How the decisions, tasks and owners are worded in one minutes request (`MinutesExtraction.prompts`).
    public struct ItemWording: Sendable, Equatable {
        /// The definitions with exclusions, the owner rule and the due rule below; off = the wording before this phase.
        public var definitions = false
        /// The transcript has at least one line of the user's own channel: only then is "Me" a label the owner may use.
        public var hasMeLines = true
        /// The integrated model (streaming layout): it cannot see who spoke a line, so it names an owner only when the words do.
        public var integrated = false
        /// The block extracts of a long meeting ask for at most 3 decisions and 3 tasks (off only in the evaluation).
        public var capped = true
        /// The block extracts of a long meeting use the definitions too (`MinutesExtraction.blockPrompts`).
        public var blockDefinitions = false
        /// The block summaries say what was decided, rejected or left open and the final figures (`MinutesSummary.wording`).
        public var outcomeSummary = false
        /// The block extracts list `entities` (off when the meeting offers no person or project: `MinutesExtraction.blockShape`).
        public var blockEntities = true
        /// The decisions, tasks and open questions come before the summary in the JSON shape (`MinutesHarness.itemsFirst`).
        public var itemsFirst = false
        /// The summary ends with the outcomes (`MinutesHarness.outcomeRule`).
        public var outcomeRule = false
        /// How many decisions and tasks a meeting of this length usually has (`MinutesHarness.count`), said in the instruction.
        public var expected: MinutesHarness.ExpectedItems?
        /// The digest of a long meeting writes open questions only from the blocks' "Open" lines, at most 3 (`MinutesQuestions.digest`).
        public var openFromNotes = false

        public init(definitions: Bool = false, hasMeLines: Bool = true, integrated: Bool = false, capped: Bool = true, blockDefinitions: Bool = false,
                    outcomeSummary: Bool = false, blockEntities: Bool = true, itemsFirst: Bool = false, outcomeRule: Bool = false,
                    expected: MinutesHarness.ExpectedItems? = nil, openFromNotes: Bool = false) {
            self.openFromNotes = openFromNotes
            self.expected = expected
            self.itemsFirst = itemsFirst
            self.outcomeRule = outcomeRule
            self.blockEntities = blockEntities
            self.outcomeSummary = outcomeSummary
            self.blockDefinitions = blockDefinitions
            self.definitions = definitions
            self.hasMeLines = hasMeLines
            self.integrated = integrated
            self.capped = capped
        }

        public static let legacy = ItemWording()
    }

    static let decisionDefinition = """
        "decisions": what the group settled (agreed, chose, approved, rejected, voted or postponed). Not a decision: a question, an opinion or a \
        rating, a proposal nobody took up, what someone only reports, or what was decided at an earlier meeting and is read out again.
        """

    static let taskDefinition = """
        "tasks": one action that one person or the group will do after the meeting. Not a task: something already done, a suggestion nobody \
        accepted, a question, text being read out. When several people get tasks in one sentence, list one task each and keep the role in the \
        text (for example "Industrial Designer: components concept").
        """

    /// The short forms for a small window (the block extracts of a long meeting and the closing request).
    static let decisionShort = """
        "decisions": what the group settled (agreed, chose, approved, rejected, voted); not a question, an opinion, a proposal nobody took up, or \
        something read out from earlier minutes.
        """

    static let taskShort = """
        "tasks": one action someone will do after the meeting; not something already done, a suggestion nobody accepted or a question; one task per \
        person, with the role in the text.
        """

    /// The owner and due rules, per wording.
    static func ownerAndDue(_ w: ItemWording) -> String {
        let owner: String
        if w.integrated {
            owner = "\"owner\": a person's name, only when the words say who will do it; otherwise null. Do not write speaker labels or Me."
        } else if w.hasMeLines {
            owner = "\"owner\": who will do it (who was asked or offered, not the asker), as named or as \"Speaker 2\"; \"Me\" only for a line labelled Me; null if unclear."
        } else {
            owner = "\"owner\": who will do it (who was asked or offered, not the asker), as named or as \"Speaker 2\"; null if unclear."
        }
        return owner + " \"due\": YYYY-MM-DD only if the words say when, else null."
    }

    /// The fields of a full minutes request.
    static func fieldsText(_ w: ItemWording, recall: Bool) -> String {
        guard w.definitions else { return summaryRule(w, recall ? minutesFieldsRecall : minutesFields) }
        return summaryRule(w, """
            "title" is short and specific; "summary" has 5 to 10 sentences with the essentials; "topics" are 3 to 8 short topics of a few words; \
            \(decisionDefinition) \(taskDefinition) \(ownerAndDue(w)) "open_questions" are questions or issues left unresolved.\(recall ? "\n" + minutesRecallCue : "")
            """)
    }

    /// The summary clause of a full request: the essentials, or (`MinutesHarness.outcomeRule`) the outcomes at the end.
    static func summaryRule(_ w: ItemWording, _ fields: String) -> String {
        guard w.outcomeRule else { return fields }
        return fields.replacingOccurrences(of: summaryEssentials, with: w.itemsFirst ? summaryOutcomesAfterItems : summaryOutcomes)
    }

    static let summaryEssentials = #""summary" has 5 to 10 sentences with the essentials;"#

    static let summaryOutcomes = """
        "summary" has 5 to 10 sentences: what the meeting covered, ending with the outcomes: for each decision you list, what was approved \
        or rejected (with the vote if it was said), and the final figures and dates exactly as said. Write what was settled as settled, \
        never as "suggested", and a point nobody accepted as a proposal. Never write that nothing was decided, or that a point is open or \
        unresolved, unless the speakers said so. Say when something was read from the previous session's minutes instead of decided in \
        this meeting. Never end with a vague line such as "agreed on several next steps": name them;
        """

    static let summaryOutcomesAfterItems = """
        "summary" has 5 to 10 sentences, written after the lists above: what the meeting covered, ending with the outcomes: for each decision \
        listed above, what was approved or rejected (with the vote if it was said), and the final figures and dates exactly as said. Write \
        what was settled as settled, never as "suggested", and a point nobody accepted as a proposal. Never write that nothing was decided, \
        or that a point is open or unresolved, unless the speakers said so. Say when something was read from the previous session's minutes \
        instead of decided in this meeting. Never end with a vague line such as "agreed on several next steps": name them;
        """

    /// The sentence that says how many items this meeting usually has (`MinutesHarness.count`), or nothing.
    static func expectedText(_ w: ItemWording) -> String {
        guard let e = w.expected else { return "" }
        return "\nA meeting of this length usually has about \(e.decisions) decisions and \(e.tasks) tasks: look for them in the whole transcript, not only in the first half."
    }

    static func rulesText(_ w: ItemWording, recall: Bool) -> String {
        guard w.definitions else { return summaryRule(w, recall ? minutesRulesRecall : minutesRules) }
        return """
            \(fieldsText(w, recall: recall))
            Rules: "seg" is the number of the [S…] segment that supports the item and "quote" a piece copied verbatim \
            from it (an item without a verbatim quote is dropped). "owner_id" only if the owner is a person in the list \
            (otherwise null). "entities": only people or projects from the [E…] list that are named, with their id. Use empty lists when there is nothing.
            \(quoteRule)
            Inside text, write quotation marks as « » or ' '.
            """
    }

    /// The fields of one block extract of a long meeting (Apple's map step): few, definite items.
    static func blockFieldsText(_ w: ItemWording) -> String {
        guard w.definitions, w.blockDefinitions else { return w.outcomeSummary ? extractFields.replacingOccurrences(of: extractSummary, with: outcomeBlockSummary) : extractFields }
        return """
            \(w.outcomeSummary ? outcomeBlockSummary : extractSummary) "topics" are up to 4 short topics; \(decisionShort) \(taskShort) \
            \(w.capped ? "At most 3 decisions and 3 tasks; an empty list is normal." : "An empty list is normal.") \(ownerAndDue(w)) "open_questions" are questions or issues left unresolved.
            """
    }

    static func itemsFieldsText(_ w: ItemWording) -> String {
        guard w.definitions else { return itemsFields }
        return "\(decisionDefinition) \(taskDefinition) \(ownerAndDue(w))"
    }

    /// The closing request over the last stretch of the meeting (any provider on the map-reduce path): what was agreed to do next.
    public static func closingInstruction(_ request: MinutesRequest) -> ChatMessage {
        let owner = request.wording.hasMeLines
            ? "\"owner\": who will do it (asked or offered, not the asker), as named or \"Speaker 2\"; \"Me\" only for a line labelled Me; else null."
            : "\"owner\": who will do it (asked or offered, not the asker), as named or \"Speaker 2\"; else null."
        return .user("""
            This is the end of the meeting. List what people agreed to do next (one task per person and action) and what was settled at the end. \
            Meeting date: \(PromptText.day(request.meetingDate, timeZone: request.timeZone)).
            Return exactly this JSON:
            \(itemsJSON)
            At most 6 tasks and 4 decisions. \(owner) "due": YYYY-MM-DD only if the words say when. "owner_id" only for a person in the list. \
            \(quoteRule)
            \(languageRule(request.language))
            """)
    }
}
