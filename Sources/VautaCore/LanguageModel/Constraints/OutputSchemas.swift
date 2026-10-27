// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The formal schemas of every JSON output Vauta asks of a model, written from the shapes in `VautaPrompts*` (same keys, same
/// key order, English keys only) and the length caps of the validators (`validateMinutes`: title 120, summary 3000, item text
/// 600, topic 60). `ids` build the per-call constraint from what the validator will accept: the segment numbers actually sent,
/// the people and projects offered, the document excerpts sent.
public enum OutputSchemas {
    /// The numbers of what was offered in the prompt, to restrict citations and ids to them. nil = any integer.
    public struct Offered: Sendable, Equatable {
        public var segments: Set<Int>?
        public var entities: Set<Int>?
        public var documents: Set<Int>?
        public init(segments: Set<Int>? = nil, entities: Set<Int>? = nil, documents: Set<Int>? = nil) {
            self.segments = segments
            self.entities = entities
            self.documents = documents
        }
    }

    typealias P = OutputSchema.Property

    /// A closed set of integers; any integer when the set is absent or empty (an empty set would leave no token to write, and the
    /// validators drop numbers that were not offered anyway).
    static func ints(_ set: Set<Int>?) -> OutputSchema {
        guard let set, !set.isEmpty else { return .anyInteger(maxDigits: 9) }
        return .integers(set)
    }

    static func seg(_ o: Offered) -> OutputSchema { ints(o.segments) }
    static func text(_ n: Int = 600) -> OutputSchema { .string(maxBytes: n * 2) }

    /// Texts are capped in bytes: a Spanish or Japanese character takes up to 3 bytes, so the caps leave room for it.
    static func entityID(_ o: Offered) -> OutputSchema { .nullable(ints(o.entities)) }

    static func decision(_ o: Offered) -> OutputSchema {
        .object([P("text", text()), P("seg", seg(o)), P("quote", text())])
    }

    static func task(_ o: Offered) -> OutputSchema {
        .object([P("text", text()), P("owner", .nullable(.string(maxBytes: 160))), P("owner_id", entityID(o)), P("due", .nullable(.date)),
                 P("seg", seg(o)), P("quote", text())])
    }

    /// `{"title", "summary", "topics", "decisions", "tasks", "entities", "open_questions"}`.
    ///
    /// `itemsFirst`: the same keys with the summary last, after the topics, decisions, tasks, entities and open questions
    /// (`MinutesHarness.itemsFirst`); the model has listed what the meeting settled when it writes the summary.
    /// `atLeast`: the fewest decisions and tasks the lists may hold (`MinutesHarness.count`).
    public static func minutes(_ o: Offered = Offered(), itemsFirst: Bool = false, atLeast: (decisions: Int, tasks: Int) = (0, 0)) -> OutputSchema {
        let summary = P("summary", .string(maxBytes: 6000))
        return itemsFirst ? .object([P("title", .string(maxBytes: 360))] + minutesBody(o, atLeast: atLeast) + [summary])
            : .object([P("title", .string(maxBytes: 360)), summary] + minutesBody(o, atLeast: atLeast))
    }

    /// The same without the title: the extract of one block, and the merge of extracts.
    public static func minutesExtract(_ o: Offered = Offered(), entities: Bool = true) -> OutputSchema {
        .object([P("summary", .string(maxBytes: 6000))] + minutesBody(o, entities: entities))
    }

    static func minutesBody(_ o: Offered, entities: Bool = true, atLeast: (decisions: Int, tasks: Int) = (0, 0)) -> [P] {
        [P("topics", .array(.string(maxBytes: 180), min: 0, max: 8)),
         P("decisions", .array(decision(o), min: atLeast.decisions, max: 30)),
         P("tasks", .array(task(o), min: atLeast.tasks, max: 40))]
            // A mention without a person or project of the list is of no use (it cannot be linked and is dropped): the id is one of the
            // offered ones, never null, so the model does not fill the list with names it cannot link. A block extract of a meeting that
            // offers none leaves the key out.
            + (entities ? [P("entities", .array(.object([P("mention", .string(maxBytes: 160)), P("id", ints(o.entities)), P("seg", seg(o))]), min: 0, max: 40))] : [])
            + [P("open_questions", .array(.string(maxBytes: 600), min: 0, max: 10))]
    }

    /// `{"decisions": [{"text", "seg", "quote"}], "tasks": [{…}]}`: the decisions and tasks of one stretch of the meeting. `seg` is one of
    /// the segments of that stretch, which forces attention to every part of the meeting; at most `maxEach` of each.
    public static func items(segments: Set<Int>, entities: Set<Int>? = nil, maxEach: Int = 8) -> OutputSchema {
        let o = Offered(segments: segments, entities: entities)
        return .object([P("decisions", .array(decision(o), min: 0, max: maxEach)), P("tasks", .array(task(o), min: 0, max: maxEach))])
    }

    /// `{"points": [{"text", "seg"}], "decisions": [{"text", "seg"}], "tasks": [{"text", "owner", "seg"}]}` (live notes).
    public static func liveNotes(_ o: Offered = Offered()) -> OutputSchema {
        let point = OutputSchema.object([P("text", .string(maxBytes: 600)), P("seg", seg(o))])
        let task = OutputSchema.object([P("text", .string(maxBytes: 600)), P("owner", .nullable(.string(maxBytes: 160))), P("seg", seg(o))])
        return .object([P("points", .array(point, min: 0, max: 12)), P("decisions", .array(point, min: 0, max: 12)), P("tasks", .array(task, min: 0, max: 12))])
    }

    /// `tight` (the small window with the notepad harness): a sentence of at most 500 bytes, a quote of at most 300 (4 to 15 words are about 120),
    /// three sentences, so a reply fits the output limit.
    static func sentences(_ o: Offered, tight: Bool = false) -> OutputSchema {
        .array(.object([P("text", .string(maxBytes: tight ? 500 : 800)), P("seg", .array(seg(o), min: 1, max: tight ? 3 : 6)),
                        P("quote", .string(maxBytes: tight ? 300 : 600)), P("differs", .boolean)]), min: 0, max: tight ? 3 : 8)
    }

    /// `{"sentences": [{"text", "seg": [..], "quote", "differs"}]}`: the expansion of one note.
    public static func noteSingle(_ o: Offered = Offered(), tight: Bool = false) -> OutputSchema { .object([P("sentences", sentences(o, tight: tight))]) }

    /// `{"notes": [{"n", "sentences": [..]}]}`: several notes at once; `count` is the number of notes asked.
    public static func noteBatch(count: Int, _ o: Offered = Offered()) -> OutputSchema {
        .object([P("notes", .array(.object([P("n", ints(Set(1...max(1, count)))), P("sentences", sentences(o))]), min: 0, max: max(1, count)))])
    }

    static func citation(_ o: Offered, documents: Bool) -> OutputSchema {
        guard documents else { return seg(o) }
        let sid = (o.segments ?? []).map { "S\($0)" }
        let did = (o.documents ?? []).map { "D\($0)" }
        let all = sid + did
        return all.isEmpty ? .anyInteger(maxDigits: 9) : .enumStrings(all)
    }

    /// The cap of the answer's sentence in the grammar (bytes), live and otherwise.
    public static let liveAnswerBytes = 500, answerBytes = 3000

    /// `{"found", "answer", "claims": [{"text", "citations": [..], "quote"}]}`. With `documents`, citations are `"S123"` / `"D2"` strings.
    /// `found` comes first and decides the rest: `true` needs at least one claim and each claim at least one citation (an answer
    /// that cannot be checked is not an answer); `false` is a refusal with no claims.
    ///
    /// `laterGuard` (a live answer about the meeting being recorded): three words for `found`, `"yes"`, `"not_yet"` and `"no"`, so a
    /// question about something that has not happened yet is not forced into one of the others; the other answers keep the boolean.
    ///
    /// `live`: the bounds of a live answer on the integrated model, which has a token and a time cap: an answer of at most 500 bytes
    /// and three claims of at most 240 bytes each (so a full answer fits the cap and the claims, which are what can be checked, are
    /// written before it runs out).
    public static func answer(_ o: Offered = Offered(), documents: Bool = false, citationSchema: OutputSchema? = nil, live: Bool = false,
                              laterGuard: Bool = false, maxClaims: Int? = nil, answerBytes cap: Int? = nil) -> OutputSchema {
        let answerBytes = cap ?? (live ? liveAnswerBytes : Self.answerBytes), claimBytes = live ? 240 : 800, quoteBytes = live ? 240 : 600, claimCount = maxClaims ?? (live ? 3 : 12)
        func claims(min: Int, max: Int) -> OutputSchema {
            // A claim has a sentence and a quote: neither can be empty (a quote of fewer than 8 bytes cannot be verified anyway), so the
            // model cannot close a claim with nothing in it. The citation comes between them and cannot be left out.
            .array(.object([P("text", .text(minBytes: minClaimBytes, maxBytes: claimBytes)),
                            P("citations", .array(citationSchema ?? citation(o, documents: documents), min: 1, max: 6)),
                            P("quote", .text(minBytes: minQuoteBytes, maxBytes: quoteBytes))]), min: min, max: max)
        }
        let none = P("claims", .array(.string(maxBytes: 1), min: 0, max: 0))
        // A live answer has three words for `found` (11b): "yes" needs claims, "not_yet" (the question is about something that has not
        // happened yet) and "no" have none. Any other answer keeps the boolean.
        if laterGuard {
            return .tagged(key: "found", cases: [
                .init("\"yes\"", [P("answer", .string(maxBytes: answerBytes)), P("claims", claims(min: 1, max: claimCount))]),
                .init("\"not_yet\"", [P("answer", .string(maxBytes: answerBytes)), none]),
                .init("\"no\"", [P("answer", .string(maxBytes: answerBytes)), none]),
            ])
        }
        return .tagged(key: "found", cases: [
            .init("true", [P("answer", .string(maxBytes: answerBytes)), P("claims", claims(min: 1, max: claimCount))]),
            .init("false", [P("answer", .string(maxBytes: answerBytes)), none]),
        ])
    }

    /// The same shape for a model server's `response_format`: nothing in it depends on what was sent (a long enumeration of
    /// segment numbers would only slow the server's grammar down); the app checks the citations itself.
    ///
    /// It is a flat object, not a conditional one: `found` first, `answer`, and `claims` (any number up to 12). A root-level `anyOf`
    /// is not understood by every server's structured-output backend, and the rule "found is true only with a claim" is the app's own
    /// to check (`VautaPrompts.verifyAnswer` rejects the reply and the service asks again), so the schema asks for less and works on more.
    public static func answerForServer(documents: Bool, maxClaims: Int? = nil) -> OutputSchema {
        let citation: OutputSchema = documents ? .string(maxBytes: 16) : .anyInteger(maxDigits: 9)
        return .object([P("found", .boolean), P("answer", .string(maxBytes: 3000)),
                        P("claims", .array(.object([P("text", .string(maxBytes: 800)), P("citations", .array(citation, min: 0, max: 6)),
                                                   P("quote", .string(maxBytes: 600))]), min: 0, max: maxClaims ?? 12))])
    }

    /// The least a claim's sentence and quote may be (in bytes) in the grammar of the integrated model.
    static let minClaimBytes = 3, minQuoteBytes = 8
}
