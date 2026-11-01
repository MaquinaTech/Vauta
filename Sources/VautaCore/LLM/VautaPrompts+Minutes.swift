// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension VautaPrompts {
    /// One of the user's own notes as the minutes prompt gets it: their words, and (on a model with room) what the
    /// transcript says about it, already verified, with the segments it cites.
    public struct UserNoteHint: Sendable, Equatable {
        public var t: Double
        public var text: String
        /// The verified expansion with its `[S<id>]` citations; nil on a small window or when there is none.
        public var expansion: String?

        public init(t: Double, text: String, expansion: String? = nil) { self.t = t; self.text = text; self.expansion = expansion }

        /// "[05:12] "Q3 budget +10%" → Ana proposed… [S120]" as one defanged line.
        var line: String {
            let base = "[\(PromptText.clock(t))] \"\(PromptText.defang(PromptText.clip(SingleLineText.flatten(text), 300)))\""
            guard let expansion, !expansion.isEmpty else { return base }
            return base + " → " + PromptText.defang(PromptText.clip(SingleLineText.flatten(expansion), 900))
        }

        /// The short form for one block of a long meeting: time and the user's words only.
        var blockLine: String {
            "[\(PromptText.clock(t))] \"\(PromptText.defang(PromptText.clip(SingleLineText.flatten(text), 100)))\""
        }
    }

    /// What the minutes instruction needs besides the transcript.
    public struct MinutesRequest: Sendable {
        public var meetingDate: Date
        public var language: OutputLanguage
        public var template: MinutesTemplate
        /// A template the person wrote (`CustomMinutesTemplate`), already cut to the budget (`customTemplate(_:budget:)`): it
        /// takes the place of `template`'s instructions.
        public var customInstructions: String?
        /// The user's own notes: PRIORITY topics, in their words.
        public var priorityNotes: [UserNoteHint]
        /// Marks (and other short hints) the user took while recording.
        public var userNotes: [String]
        /// Notes the model took while recording (hints, never evidence).
        public var liveNotes: [String]
        public var timeZone: TimeZone
        /// The integrated model's wording (11b): decisions and tasks defined for recall, owners written as the speaker labels of the
        /// transcript, and `delta` (names given to speakers, new people) ahead of the instruction.
        public var recall = false
        public var delta = ""
        /// The wording of the decisions, tasks and owners (`MinutesExtraction.prompts`).
        public var wording = ItemWording.legacy

        public init(meetingDate: Date, language: OutputLanguage, template: MinutesTemplate = .general,
                    userNotes: [String] = [], liveNotes: [String] = [], priorityNotes: [UserNoteHint] = [],
                    timeZone: TimeZone = .current, recall: Bool = false, delta: String = "") {
            self.recall = recall
            self.delta = delta
            self.meetingDate = meetingDate
            self.language = language
            self.template = template
            self.userNotes = userNotes
            self.priorityNotes = priorityNotes
            self.liveNotes = liveNotes
            self.timeZone = timeZone
        }
    }

    /// The shapes show empty values and zeros, never sample text or numbers: a model (Apple's mostly) writes back what it is shown. What
    /// each field holds is said in words, in the rules next to the shape.
    static let minutesJSON = """
        {"title": "", "summary": "", "topics": [], "decisions": [{"text": "", "seg": 0, "quote": ""}], \
        "tasks": [{"text": "", "owner": null, "owner_id": null, "due": null, "seg": 0, "quote": ""}], \
        "entities": [{"mention": "", "id": 0, "seg": 0}], "open_questions": []}
        """

    /// The same keys with the decisions, tasks and open questions ahead of the summary (`MinutesHarness.itemsFirst`): the model lists what
    /// the meeting settled and then writes the summary from it. `OutputSchemas.minutes(_:itemsFirst:)` is the grammar of the same order.
    static let minutesJSONItemsFirst = """
        {"title": "", "topics": [], "decisions": [{"text": "", "seg": 0, "quote": ""}], \
        "tasks": [{"text": "", "owner": null, "owner_id": null, "due": null, "seg": 0, "quote": ""}], \
        "entities": [{"mention": "", "id": 0, "seg": 0}], "open_questions": [], "summary": ""}
        """

    static let minutesFields = """
        "title" is short and specific; "summary" has 5 to 10 sentences with the essentials; "topics" are 3 to 8 short topics of a few words; \
        "decisions" say what was decided; "tasks" say what has to be done, with "owner" the speaker label of who will do it as written in the \
        transcript (for example "Speaker 2" or a name), "Me" only if the line is labelled Me, else null, and "due" as YYYY-MM-DD or null; "open_questions" are questions or issues left unresolved.
        """

    static let minutesRules = """
        \(minutesFields)
        Rules: "seg" is the number of the [S…] segment that supports the item and "quote" a piece copied verbatim \
        from it (an item without a verbatim quote is dropped). "owner_id" only if the owner is a person in the list \
        (otherwise null). "entities": only people or projects from the \
        [E…] list that are named, with their id. Use empty lists when there is nothing.
        \(quoteRule)
        Inside text, write quotation marks as « » or ' '.
        """

    /// The integrated model's definitions (11b): what counts as a decision and a task, how many to expect, and the owner as the speaker
    /// label written in the transcript (Swift maps it to the speaker or the person). Measured on the development meetings.
    static let minutesFieldsRecall = """
        "title" is short and specific; "summary" has 5 to 10 sentences with the essentials; "topics" are 3 to 8 short topics of a few words; \
        "decisions": every point the group settled, small or procedural included: agreed, chose, approved, rejected, postponed or assigned. \
        A proposal nobody accepted is not a decision. "tasks": everything someone will do after this point, with "owner" the speaker label of \
        who will do it as written in the transcript (for example "Speaker 2" or a name), "Me" only if the line is labelled Me, else null, and \
        "due" as YYYY-MM-DD or null; "open_questions" are questions or issues left unresolved.
        """

    static let minutesRecallCue = """
        List each one separately, in the order they happen; a meeting of 30 minutes usually has several of each. Use an empty list only if \
        there really are none.
        """

    static let minutesRulesRecall = """
        \(minutesFieldsRecall)
        \(minutesRecallCue)
        Rules: "seg" is the number of the [S…] segment that supports the item and "quote" a piece copied verbatim \
        from it (an item without a verbatim quote is dropped). "owner_id" only if the owner is a person in the list \
        (otherwise null). "entities": only people or projects from the [E…] list that are named, with their id. Use empty lists when there is nothing.
        \(quoteRule)
        Inside text, write quotation marks as « » or ' '.
        """

    /// What went wrong in the quotes that were dropped (11a.1 analysis of the integrated model): a quote that joined the end of one
    /// segment with the start of the next, one with a word or a repeat "corrected", and a quote copied from a segment other than the
    /// one cited. All three are the model's errors, and the quote check is what catches them.
    static let quoteRule = """
        A "quote" comes from ONE segment, exactly as written there: keep repeated words and "uh"s, do not join the end of one segment \
        with the start of the next, do not correct or shorten the wording inside it. 4 to 15 words are enough. "seg" is the number of \
        that same segment.
        """

    static func languageRule(_ language: OutputLanguage) -> String {
        "\(language.instruction) JSON keys stay in English and quotes stay in the language of the transcript."
    }

    /// The title, summary, topics and open questions only: what the model writes on a small window, where Swift carries the decisions,
    /// tasks and mentions over from the block extracts (`MinutesDigest`).
    static let digestJSON = """
        {"title": "", "summary": "", "topics": [], "open_questions": []}
        """

    static let digestRules = """
        "title" is short and specific; "summary" has 5 to 8 sentences with the essentials; "topics" are 3 to 6 topics of a few words each; \
        "open_questions" are up to 5 questions or issues left unresolved, one sentence each.
        Rules: the decisions and tasks are collected separately: do not list them again, but name the important ones in the summary. \
        A topic is a few words, never a quote. Use empty lists when there is nothing.
        """

    /// The final instruction for the minutes of a meeting that fits whole.
    public static func minutesInstruction(_ request: MinutesRequest) -> ChatMessage {
        .user((request.delta.isEmpty ? "" : request.delta + "\n") + minutesHeader(request)
              + "\nReturn exactly this JSON:\n\(request.wording.itemsFirst ? minutesJSONItemsFirst : minutesJSON)\n\(rulesText(request.wording, recall: request.recall))\(expectedText(request.wording))\n\(languageRule(request.language))")
    }

    /// The final instruction when the model sees a digest of the blocks and writes only the language parts of the minutes.
    public static func digestInstruction(_ request: MinutesRequest, outcomes: Bool = false) -> ChatMessage {
        func rules(_ text: String) -> String { request.wording.openFromNotes ? openFromNotes(text) : text }
        if outcomes {
            return .user("Above are the results of the meeting and background notes on its consecutive parts.\n" + minutesHeader(request)
                         + "\nReturn exactly this JSON:\n\(digestJSON)\n\(rules(digestRulesOutcomes))\n\(languageRule(request.language))")
        }
        return .user("Above are notes on consecutive blocks of the meeting.\n" + minutesHeader(request)
              + "\nReturn exactly this JSON:\n\(digestJSON)\n\(rules(request.wording.outcomeSummary ? digestRulesResults : digestRules))\n\(languageRule(request.language))")
    }

    /// The digest rules with the open questions taken from the notes (`MinutesQuestions.digest`): the model wrote questions of its own
    /// ("How to…") that nobody asked.
    static func openFromNotes(_ rules: String) -> String {
        let rule = #""open_questions" are copied word for word from the "Open" lines of the notes, at most 3; never write one of your own, and use an empty list when the notes have no Open line."#
        return rules.replacingOccurrences(of: #""open_questions" are up to 5 questions or issues left unresolved, one sentence each."#, with: rule)
            .replacingOccurrences(of: #""open_questions" are up to 5 questions or issues the meeting left unresolved, one sentence each."#, with: rule)
    }

    /// The digest rules when the notes carry no outcomes list but the block summaries state results.
    static let digestRulesResults = """
        "title" is short and specific; "summary" has 5 to 8 sentences that say what was decided, rejected or left open, with the final figures \
        as the notes give them, not only what was discussed; "topics" are 3 to 6 topics of a few words each; \
        "open_questions" are up to 5 questions or issues left unresolved, one sentence each.
        Rules: the decisions and tasks are collected separately: do not list them again, but name the important ones in the summary. \
        A topic is a few words, never a quote. Do not mention block numbers, segment numbers, speaker labels or the date of the meeting. \
        Use empty lists when there is nothing.
        """

    /// The digest rules when the notes lead with the outcomes: the summary is written from them.
    static let digestRulesOutcomes = """
        "title" is short and specific; "summary" has 5 to 8 sentences. Begin with the results, in the order they were reached: say what was \
        agreed, rejected or assigned, with the final figures, dates and names exactly as the notes give them. A result labelled "Proposed \
        only" was just suggested: write it as a proposal in one short sentence, or leave out the weakest. Then add in a sentence or two what \
        else the background covers. "topics" are 3 to 6 topics of a few words each; "open_questions" are up to 5 questions or issues the \
        meeting left unresolved, one sentence each.
        Rules: never write that something was "discussed" without saying its result. Never repeat a result as an open question. A topic is a \
        few words, never a quote. Do not write the labels of the notes, and do not mention the notes, blocks, segment numbers, speaker labels \
        or the date of the meeting. Use empty lists when there is nothing.
        """

    static let itemsFields = """
        "decisions": every point the group settled, small or procedural included: agreed, chose, approved, rejected, postponed or assigned. \
        A proposal nobody accepted is not a decision. "tasks": everything someone will do after this point, with "owner" the speaker label of \
        who will do it as written in the transcript (for example "Speaker 2" or a name), "Me" only if the line is labelled Me, else null, and \
        "due" as YYYY-MM-DD or null.
        """

    static let itemsJSON = """
        {"decisions": [{"text": "", "seg": 0, "quote": ""}], \
        "tasks": [{"text": "", "owner": null, "owner_id": null, "due": null, "seg": 0, "quote": ""}]}
        """

    /// The second pass over one stretch of the meeting (segments `first` to `last`): the decisions and tasks of that stretch only,
    /// with what the first pass already kept there (`listed`, one line each).
    public static func itemsInstruction(_ request: MinutesRequest, first: Int64, last: Int64, listed: [String], closing: Bool = false) -> ChatMessage {
        var text = (request.delta.isEmpty ? "" : request.delta + "\n")
            + (closing
                ? "The meeting ends with segments S\(first) to S\(last) (the rest of the transcript is there for context). List what people agreed to do next "
                    + "(one task per person and action, with who and when as said) and what was settled at the end.\n"
                : "List the decisions and tasks of segments S\(first) to S\(last) only (the rest of the transcript is there for context).\n")
        text += "Meeting date: \(PromptText.day(request.meetingDate, timeZone: request.timeZone)); use it only to turn \"on Friday\", \"tomorrow\"… into YYYY-MM-DD dates.\n"
        if !listed.isEmpty {
            text += "Already listed from this stretch (do not repeat them):\n" + listed.map { "- \(PromptText.defang(PromptText.clip($0, 200)))" }.joined(separator: "\n") + "\n"
        }
        text += """
            Return exactly this JSON:
            \(itemsJSON)
            \(itemsFieldsText(request.wording))
            Add the ones that are not listed yet. At most \(closing ? "4 decisions and 6 tasks" : "8 decisions and 8 tasks"). "owner_id" only if the owner is a person in the list \
            (otherwise null). Use empty lists when there is nothing.
            \(quoteRule)
            \(languageRule(request.language))
            """
        return .user(text)
    }

    /// The part of the minutes instruction that is the same for every JSON shape: the date, the template and the user's notes.
    static func minutesHeader(_ request: MinutesRequest) -> String {
        var text = """
            Write the minutes of this meeting (date: \(PromptText.day(request.meetingDate, timeZone: request.timeZone)); \
            use it only to turn "on Friday", "tomorrow"… into YYYY-MM-DD dates; do not mention it in the title or the summary unless \
            the transcript does).
            \(request.customInstructions.map(customTemplateBlock) ?? request.template.promptInstructions)
            """
        if !request.priorityNotes.isEmpty {
            text += "\nThe user's own notes (PRIORITY: every one of these must be covered in the summary or the topics, using the "
                + "user's wording for the topic name\(request.priorityNotes.contains { $0.expansion != nil } ? "; the text after → was written from the transcript and checked" : "")):\n"
                + request.priorityNotes.map { "- \($0.line)" }.joined(separator: "\n")
        }
        if !request.userNotes.isEmpty {
            text += "\nNotes and marks the user took during the meeting (they show what matters):\n"
                + request.userNotes.map { "- \(PromptText.defang($0))" }.joined(separator: "\n")
        }
        if !request.liveNotes.isEmpty {
            text += "\nNotes taken automatically during the meeting (hints only; check everything against the transcript):\n"
                + request.liveNotes.map { "- \(PromptText.defang($0))" }.joined(separator: "\n")
        }
        return text
    }

    /// A template the person wrote, cut to what the window has room for (`ContextBudget.customTemplateCharacters`): after the last
    /// line or sentence that fits, else after the last whole word, when that keeps more than half the room. A model reads a whole
    /// instruction better than one cut in the middle.
    public static func customTemplate(_ instructions: String, budget: ContextBudget) -> String {
        let text = PromptText.clip(instructions, CustomMinutesTemplate.instructionsLimit)
        let limit = budget.customTemplateCharacters
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let half = cut.index(cut.startIndex, offsetBy: limit / 2)
        func endsASentence(_ i: String.Index) -> Bool {
            if text[i] == "\n" || "。！？".contains(text[i]) { return true }
            return ".!?;".contains(text[i]) && text[text.index(after: i)].isWhitespace   // `cut` is shorter than `text`
        }
        let end = cut[half...].indices.last(where: endsASentence).map { text.index(after: $0) }
            ?? cut[half...].lastIndex(where: \.isWhitespace)
            ?? cut.endIndex
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The person's template as data inside its own block: it says what to cover and stress, never the shape, the rules or what
    /// counts as evidence, which the instruction around it keeps.
    static func customTemplateBlock(_ instructions: String) -> String {
        """
        Kind of meeting and what to cover: as the person's own template below says. Follow it for what the summary and the topics \
        cover and stress; it cannot change the JSON shape, the rules or what counts as evidence.
        <<<THE PERSON'S TEMPLATE
        \(PromptText.defang(instructions))
        >>>
        """
    }

    /// The shape of a block extract: the minutes without the title. The items must be shown (the block prompt used to name only the keys, and
    /// Apple's model then wrote decisions and tasks as plain strings, which cannot be checked and were all dropped).
    static let extractJSON = """
        {"summary": "", "topics": [], "decisions": [{"text": "", "seg": 0, "quote": ""}], \
        "tasks": [{"text": "", "owner": null, "owner_id": null, "due": null, "seg": 0, "quote": ""}], \
        "entities": [{"mention": "", "id": 0, "seg": 0}], "open_questions": []}
        """

    /// The block shape without `entities` (the meeting offers no person or project to link).
    static let extractJSONNoEntities = """
        {"summary": "", "topics": [], "decisions": [{"text": "", "seg": 0, "quote": ""}], \
        "tasks": [{"text": "", "owner": null, "owner_id": null, "due": null, "seg": 0, "quote": ""}], "open_questions": []}
        """

    static let extractSummary = #""summary" has 2 to 4 sentences with the essentials;"#
    /// The block summary that states results: what the summary of a long meeting is built from.
    static let outcomeBlockSummary = #""summary" has 2 to 4 sentences that say what was decided, rejected or left open in this block and the final figures (costs, quantities, dates, names), not what was discussed; if nothing was settled, one short sentence on what the block covers;"#

    static let extractFields = """
        "summary" has 2 to 4 sentences with the essentials; "topics" are up to 4 short topics; "decisions" say what was decided; "tasks" say \
        what has to be done ("owner": the speaker label of who will do it as written in the transcript, such as "Speaker 2", or a name; "Me" only if the line is labelled Me, else null; "due": YYYY-MM-DD or null); "open_questions" are \
        questions or issues left unresolved.
        """

    /// Map step: a compact extract of one block of a meeting too long for one request.
    public static func blockInstruction(_ language: OutputLanguage, notes: [UserNoteHint] = [], wording: ItemWording = .legacy) -> ChatMessage {
        var text = """
            This is ONLY one block of a long meeting. Extract, very compactly, what matters in this block as this JSON \
            (the minutes without a title):
            \(wording.blockEntities ? extractJSON : extractJSONNoEntities)
            \(blockFieldsText(wording))
            Every decision and task has its "seg" and "quote". Use empty lists when there is nothing.
            \(quoteRule)
            """
        if !notes.isEmpty {
            text += "\nThe user noted these around here (PRIORITY: keep what they are about in the extract):\n"
                + notes.map { "- \($0.blockLine)" }.joined(separator: "\n")
        }
        return .user(text + "\n\(languageRule(language))")
    }

    /// Intermediate reduce step: several extracts into one compact extract
    /// (when all of them do not fit in one final request).
    public static func mergeInstruction(_ language: OutputLanguage) -> ChatMessage {
        .user("""
            Above are extracts of consecutive blocks of a long meeting. Combine them into ONE compact extract with the \
            same JSON shape:
            \(extractJSON)
            Keep "seg" and "quote" of every decision and task. A summary of 3 to 5 sentences.
            \(languageRule(language))
            """)
    }

    /// Final reduce step: the minutes from the block extracts.
    public static func reduceInstruction(_ request: MinutesRequest) -> ChatMessage {
        .user("Above are the extracts of each block of the meeting (with their citations). Combine them into a single set of minutes.\n"
              + minutesInstruction(request).content)
    }

    /// Extracts as delimited material (they come from the model but quote the transcript).
    public static func extractsMessage(_ extracts: [String]) -> ChatMessage {
        .user("<<<EXTRACTS\n" + extracts.enumerated().map { "Block \($0.offset + 1):\n\(PromptText.defang($0.element))" }
            .joined(separator: "\n\n") + "\n>>>")
    }

    /// Asks again for the JSON after an answer that could not be read.
    public static func repairInstruction() -> ChatMessage {
        .user("Your answer is not a valid JSON object. Repeat ONLY the JSON of the minutes.")
    }

    // MARK: Validation

    /// Minutes as the model writes them: English keys, or the legacy Spanish ones.
    struct RawMinutes: Decodable {
        struct Decision: Decodable {
            let text: String?, seg: Int64?, quote: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                text = c.text("text", "texto")
                seg = c.id("seg", "segment")
                quote = c.text("quote", "cita")
            }
        }
        struct Task: Decodable {
            let text: String?, owner: String?, ownerID: Int64?, due: String?, seg: Int64?, quote: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                text = c.text("text", "texto")
                owner = c.text("owner", "responsable")
                ownerID = c.id("owner_id", "responsable_id")
                due = c.text("due", "fecha")
                seg = c.id("seg", "segment")
                quote = c.text("quote", "cita")
            }
        }
        struct Mention: Decodable {
            let mention: String?, id: Int64?, seg: Int64?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                mention = c.text("mention", "mencion")
                id = c.id("id")
                seg = c.id("seg", "segment")
            }
        }
        let title: String?
        let summary: String?
        let topics: [String]
        let decisions: [Decision]
        let tasks: [Task]
        let entities: [Mention]
        let openQuestions: [String]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            title = c.text("title", "titulo", "título")
            summary = c.text("summary", "resumen")
            topics = c.list(String.self, "topics", "temas") ?? []
            decisions = c.list(Decision.self, "decisions", "decisiones") ?? []
            tasks = c.list(Task.self, "tasks", "tareas") ?? []
            entities = c.list(Mention.self, "entities", "entidades") ?? []
            openQuestions = (c.list(OpenQuestionText.self, "open_questions", "abiertas") ?? []).compactMap(\.value)
        }
    }

    /// Whether a line is the user's own: on their channel with no speaker data, or said by the user's own entity with a confident label.
    static func lineIsTheUsers(_ segment: CitableSegment, directory: SpeakerDirectory, selfEntity: Int64) -> Bool {
        if segment.channel == .me, segment.speaker == nil { return true }
        guard let person = directory.person(of: segment.speaker) else { return segment.channel == .me && (segment.speaker?.ordinal ?? 1) == 1 }
        return person.entity == selfEntity && person.confident
    }

    /// Validates the model's JSON against the real meeting. Whatever does not
    /// cite a segment of the meeting, names an entity that was not offered or
    /// does not appear in the cited segment is dropped (the item, not the
    /// minutes). Decisions and tasks need a verbatim `quote` (≥ 8 characters)
    /// that really is in their segment: a line that *asks* to add a decision
    /// does not get one in by citing any segment. An owner is only kept if it
    /// is the user, someone in the meeting (`meetingPeople`, which includes the
    /// people named on its speakers) or a person named (as whole words) in
    /// that segment; otherwise the task is unassigned.
    ///
    /// With speaker data (`directory`), Swift also decides the owner where the
    /// segment itself says it (`OwnerResolver`): a confidently identified
    /// speaker who says what they will do owns it, and a speaker label the
    /// system is unsure about never gives a task to anyone. Finally, whatever
    /// the model proposed is checked literally against the cited segment
    /// (`MinutesVerifier`): figures, due date and names of people. An item
    /// that fails is kept and marked `unconfirmed`.
    public static func validateMinutes(_ content: String, segments: [Int64: CitableSegment],
                                    candidates: [CandidateEntity], selfEntity: Int64?,
                                    meetingPeople: Set<Int64> = [], directory: SpeakerDirectory = .empty,
                                    reference: Date = .now, timeZone: TimeZone = .current,
                                    language: String? = nil, proseLanguage: String? = nil, extraction: MinutesExtraction = .legacy) throws -> ValidatedMinutes {
        // `language`: the transcript's (for quotes and names); `proseLanguage`: the one the minutes are written in (spelled-out numbers).
        let prose = proseLanguage ?? language
        let raw = try ModelOutput.decodeObject(RawMinutes.self, from: content)
        var out = ValidatedMinutes()
        out.proposed = raw.decisions.count + raw.tasks.count + raw.entities.count
        out.title = MinutesText.cleanProse(PromptText.clip(raw.title ?? "", 120), language: prose)
        out.summary = MinutesText.cleanProse(PromptText.clip(raw.summary ?? "", 3000), language: prose)
        let allSegments = segments.values.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        out.title = MinutesText.dropMeetingDate(out.title, meetingDate: reference, timeZone: timeZone, language: language, segments: allSegments)
        out.summary = MinutesText.dropMeetingDate(out.summary, meetingDate: reference, timeZone: timeZone, language: language, segments: allSegments)
        if let tail = MinutesText.unfinishedTail(out.summary) { out.counts["summary.unfinished"] = tail }
        var junk = 0
        out.topics = MinutesText.list(raw.topics, limit: 8, clip: 60, rejected: &junk, marker: true)
        if junk > 0 { out.drops["topic.junk", default: 0] += junk }
        junk = 0
        out.openQuestions = MinutesText.list(raw.openQuestions, limit: 10, clip: 300, rejected: &junk)
        if junk > 0 { out.drops["open_question.junk", default: 0] += junk }
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let people = candidates.filter { $0.kind == .person }
        // People whose names the text of an item may carry (the user is "Me", never a name to look for).
        let others = people.filter { $0.id != selfEntity }
        let selfNames = Set(selfEntity.flatMap { byID[$0] }.map { ([$0.name] + $0.aliases).map(TextKeys.norm) } ?? [])
        var seen = Set<String>()
        let ownerContext = OwnerContext(directory: directory, selfEntity: selfEntity, people: people, byID: byID, selfNames: selfNames,
                                        meetingPeople: meetingPeople, order: extraction.contains(.owners) || extraction.contains(.dueEvidence) ? SegmentOrder(allSegments) : nil,
                                        language: language, owners: extraction.contains(.owners))
        var lazyPool: QuoteAnchor.Pool?
        func pool() -> QuoteAnchor.Pool {
            if let lazyPool { return lazyPool }
            let built = QuoteAnchor.Pool(segments.values.sorted { ($0.start, $0.id) < ($1.start, $1.id) }, language: language)
            lazyPool = built
            return built
        }
        /// The segment that backs an item: the one cited when the quote is in it (word for word, or modulo case, punctuation, spacing
        /// and filler words), else the nearest segment of the meeting that holds it (the model cited the wrong number). The failure is
        /// why the item cannot be kept.
        func anchor(kind: String, seg: Int64?, quote: String?) -> (segment: CitableSegment?, failure: String?) {
            guard let seg else { return (nil, "noSegment") }
            guard TextKeys.norm(quote ?? "").count >= 8 else { return (nil, "quoteTooShort") }
            // A segment number that is not in the meeting at all is a made-up citation: dropped as before, never moved.
            guard let cited = segments[seg] else { return (nil, "unknownSegment") }
            var match = QuoteAnchor.resolve(quote: quote, cited: seg, citedText: cited.text, pool: nil, language: language)
            if match == nil { match = QuoteAnchor.resolve(quote: quote, cited: seg, citedText: cited.text, pool: pool(), language: language) }
            guard let match, let found = segments[match.segment] else { return (nil, "quoteNotFound") }
            switch match.how {
            case .exact: break
            case .modulo: out.counts["\(kind).modulo", default: 0] += 1
            case .reanchored: out.counts["\(kind).reanchored", default: 0] += 1
            }
            return (found, nil)
        }
        for d in raw.decisions {
            guard let text = d.text.map({ MinutesText.cleanProse(PromptText.clip($0, 600), language: prose) }), !text.isEmpty else { out.drop("decision", "emptyText"); continue }
            let backing = anchor(kind: "decision", seg: d.seg, quote: d.quote)
            if let why = backing.failure { out.drop("decision", why); continue }
            guard let seg = backing.segment else { continue }
            if let why = MinutesText.decisionProblem(text: text, quote: d.quote, segmentText: seg.text, language: language) { out.drop("decision", why); continue }
            guard seen.insert("d" + TextKeys.norm(text)).inserted else { out.drop("decision", "duplicate"); continue }
            let unconfirmed = !MinutesVerifier.figuresAreInSegment(item: text, segment: seg.text)
                || !MinutesVerifier.namedPeopleAreBacked(itemText: text, people: others, segment: seg.text,
                                                         speakerEntity: directory.person(of: seg.speaker).flatMap { $0.confident ? $0.entity : nil })
            out.decisions.append(.init(text: text, segment: seg.id, t: seg.start, unconfirmed: unconfirmed, doubt: unconfirmed ? "figures" : nil, quote: d.quote ?? ""))
        }
        for t in raw.tasks {
            guard let text = t.text.map({ MinutesText.cleanProse(PromptText.clip($0, 600), language: prose) }), !text.isEmpty else { out.drop("task", "emptyText"); continue }
            let backing = anchor(kind: "task", seg: t.seg, quote: t.quote)
            if let why = backing.failure { out.drop("task", why); continue }
            guard let seg = backing.segment else { continue }
            guard seen.insert("t" + TextKeys.norm(text)).inserted else { out.drop("task", "duplicate"); continue }
            let owner = taskOwner(t, segment: seg, context: ownerContext, counts: &out.counts)
            let verdict = owner.verdict, ownerSpeaker = owner.speaker
            let written = t.due.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty || $0.lowercased() == "null" ? nil : $0 }
            var due = written.flatMap { PromptText.parseDay($0, reference: reference, timeZone: timeZone) }
            if written != nil { out.dueGiven += 1 }
            if written != nil, due == nil { out.dueUnreadable += 1 }
            // A due date that is the meeting's day or the day after, with nothing in the segment that says so, is the model
            // copying the date it was given: the date is dropped (the task stays), not kept as "unconfirmed".
            if let d = due, MinutesVerifier.isMeetingDayOrNext(d, reference: reference, timeZone: timeZone),
               !MinutesVerifier.dueIsInSegment(d, segment: seg.text, reference: reference, timeZone: timeZone) {
                due = nil
                out.dueRuleViolations += 1
            }
            // A day before the meeting or more than a year after it is not a due day anyone said: dropped, the task stays.
            if let d = due, !DueDay.containing(d, in: timeZone).isPlausible(meetingDay: DueDay.containing(reference, in: timeZone)) {
                due = nil
                out.dueRuleViolations += 1
            }
            // A day the words around the quote do not back is not stored (the task stays): the model may have worked it out itself.
            // A day said in one of the next lines is backed as well: the task is not "to be confirmed" for it (see below).
            var dueWords = seg.text
            if extraction.contains(.dueEvidence), let d = due, let order = ownerContext.order {
                let window = ([seg] + order.following(seg.id)).map(\.text).joined(separator: " ")
                dueWords = window
                if !MinutesVerifier.dueIsInSegment(d, segment: window, reference: reference, timeZone: timeZone) {
                    due = nil
                    out.counts["task.dueUnbacked", default: 0] += 1
                }
            }
            let speaker = directory.person(of: seg.speaker)
            var unconfirmed = !MinutesVerifier.figuresAreInSegment(item: text, segment: seg.text, due: due, timeZone: timeZone)
                || !MinutesVerifier.namedPeopleAreBacked(itemText: text, people: others, segment: seg.text,
                                                         speakerEntity: speaker.flatMap { $0.confident ? $0.entity : nil })
            if let due, !MinutesVerifier.dueIsInSegment(due, segment: dueWords, reference: reference, timeZone: timeZone) { unconfirmed = true }
            out.tasks.append(.init(text: text, owner: verdict.owner, due: due, segment: seg.id, t: seg.start,
                                   unconfirmed: unconfirmed, doubt: unconfirmed ? "figures" : nil, ownerUncertain: verdict.uncertain, ownerSpeaker: verdict.owner == nil ? ownerSpeaker : nil,
                                   dueDay: due.map { DueDay(written ?? "") ?? DueDay.containing($0, in: timeZone) }, quote: t.quote ?? ""))
        }
        for e in raw.entities {
            // A mention is the name or an alias (≤ 40 characters), never a
            // sentence: `mentions.surface` outlives the purge of the text.
            guard let id = e.id else { out.drop("entity", "noID"); continue }
            guard let entity = byID[id] else { out.drop("entity", "unknownEntity"); continue }
            guard let surface = e.mention.map({ PromptText.clip($0, 40) }), !surface.isEmpty else { out.drop("entity", "emptyText"); continue }
            guard let seg = e.seg.flatMap({ segments[$0] }) else { out.drop("entity", "unknownSegment"); continue }
            guard PromptText.containsWords(seg.text, surface) else { out.drop("entity", "mentionNotInSegment"); continue }
            guard ([entity.name] + entity.aliases).contains(where: { TextKeys.norm($0) == TextKeys.norm(surface) }) else {
                out.drop("entity", "mentionNotAlias")
                continue
            }
            // The user's pronoun ("Yo", "Me") would match almost every sentence.
            guard !(id == selfEntity && MeetingStore.isSelfPronoun(TextKeys.norm(surface))) else { out.drop("entity", "selfPronoun"); continue }
            out.mentions.append(.init(entity: id, segment: seg.id, t: seg.start, surface: surface))
        }
        return out
    }
}
