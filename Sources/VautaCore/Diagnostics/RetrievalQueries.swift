// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension RetrievalEvaluation {
    /// One transcript to put in the store: `upto` nil = all of it.
    struct CorpusEntry: Sendable, Equatable {
        let base: String
        let meeting: String
        let upto: Int64?
    }

    enum Scope: Sendable { case thisMeeting, pastMeetings }

    /// A query of the evaluation sets, whatever file it came from.
    struct Query: Sendable {
        var id: String
        var set: String
        var text: String
        var language: String
        var meetingLanguage: String
        /// The query in the meeting's language, when the set has one (the constructed cross-language rows carry the original).
        var reference: String?
        var meeting: String
        var corpus: [CorpusEntry]
        /// A question typed by the person (`ask` path) or one heard in the meeting, whose own line is in the transcript (`live` path).
        var live: Bool
        var selfSegment: Int64?
        var scope: Scope
        var gold: Set<String>
        var answerable: Bool
        var split: String?
        var category: String?
        var direction: String?
        var constructed: Bool
        var condition: String?
        var answeredAloud: Bool?

        var meetingLocale: String { meetingLanguage == "es" ? "es-ES" : "en-US" }
        static func goldKey(_ meeting: String, _ id: Int64) -> String { "\(meeting)#\(id)" }
    }

    enum DataError: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String { if case .unreadable(let path) = self { "cannot read \(path)" } else { "" } }
    }

    private static func int(_ any: Any?) -> Int64? { (any as? NSNumber).map { $0.int64Value } }

    private static func corpus(_ any: Any?) -> [CorpusEntry] {
        let list = (any as? [[String: Any]]) ?? (any as? [String: Any]).map { [$0] } ?? []
        return list.compactMap { d in
            guard let meeting = d["meeting"] as? String else { return nil }
            return CorpusEntry(base: d["base"] as? String ?? "base", meeting: meeting, upto: int(d["upto_segment"]))
        }
    }

    /// Gold as `meeting#id` keys: a list of ids (the meeting is the row's) or of `{meeting, segment_id, in_corpus}` objects.
    private static func gold(_ any: Any?, meeting: String) -> Set<String> {
        var out = Set<String>()
        for item in (any as? [Any]) ?? [] {
            if let id = int(item) { out.insert(Query.goldKey(meeting, id)) }
            else if let d = item as? [String: Any], let id = int(d["segment_id"]), let m = d["meeting"] as? String, (d["in_corpus"] as? Bool) != false {
                out.insert(Query.goldKey(m, id))
            }
        }
        return out
    }

    /// Reads one JSON-lines file of the evaluation data (`w11_questions.jsonl`, `w11_questions_stress.jsonl`, `w10_information.jsonl`,
    /// `cross_language.jsonl`).
    static func loadQueries(file: URL, set: String) throws -> [Query] {
        guard let data = FileManager.default.contents(atPath: file.path) else { throw DataError.unreadable(file.path) }
        var out: [Query] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
            let corpus = corpus(row["corpus"])
            guard let meeting = row["meeting"] as? String, !corpus.isEmpty else { continue }
            var q = Query(id: "", set: set, text: "", language: "en", meetingLanguage: "en", reference: nil, meeting: meeting, corpus: corpus, live: false,
                          selfSegment: nil, scope: .thisMeeting, gold: gold(row["gold_segments"], meeting: meeting), answerable: true, split: row["split"] as? String,
                          category: row["category"] as? String, direction: nil, constructed: false, condition: row["condition"] as? String, answeredAloud: nil)
            switch set {
            case "w11", "w11-stress":
                q.id = row["qid"] as? String ?? ""
                q.text = row["question"] as? String ?? ""
                q.language = row["question_language"] as? String ?? "en"
                q.meetingLanguage = row["meeting_language"] as? String ?? "en"
                q.answerable = row["answerable"] as? Bool ?? true
            case "w10":
                q.id = row["id"] as? String ?? ""
                q.text = row["query"] as? String ?? ""
                q.language = row["query_language"] as? String ?? "en"
                q.meetingLanguage = row["language"] as? String ?? "en"
                q.live = true
                q.selfSegment = int(row["self_segment_id"])
                q.answeredAloud = row["answered_aloud_within_3_lines"] as? Bool
                q.scope = (row["answerable"] as? String) == "past_meeting" ? .pastMeetings : .thisMeeting
            case "cross":
                q.id = row["id"] as? String ?? ""
                q.text = row["query"] as? String ?? ""
                q.language = row["query_language"] as? String ?? "en"
                q.meetingLanguage = row["meeting_language"] as? String ?? "en"
                q.reference = row["original_query"] as? String
                q.direction = row["direction"] as? String
                q.constructed = row["constructed"] as? Bool ?? false
                // The rows made from W10 are heard questions with their line in the transcript; those from W11 are typed.
                q.live = (row["source"] as? String)?.hasPrefix("w10") == true
                q.selfSegment = q.live ? int(row["self_segment_id"]) : nil
                q.scope = (row["answerable_kind"] as? String) == "past_meeting" ? .pastMeetings : .thisMeeting
            default:
                continue
            }
            guard !q.id.isEmpty, !q.text.isEmpty else { continue }
            out.append(q)
        }
        return out
    }

    static func queryFile(for set: String) -> String? {
        ["w11": "w11_questions.jsonl", "w11-stress": "w11_questions_stress.jsonl", "w10": "w10_information.jsonl", "cross": "cross_language.jsonl"][set]
    }

    /// The transcripts of the data folder, decoded once. The cache is locked; two loads of the same file may both decode it.
    final class Transcripts: @unchecked Sendable {
        private let root: URL
        private let lock = NSLock()
        private var cache: [String: MinutesEvaluation.Transcript] = [:]
        init(root: URL) { self.root = root }

        func load(_ entry: CorpusEntry) throws -> MinutesEvaluation.Transcript {
            let key = entry.base + "/" + entry.meeting
            if let t = lock.withLock({ cache[key] }) { return t }
            let url = root.appendingPathComponent("meetings/\(key).json")
            guard let data = FileManager.default.contents(atPath: url.path), let t = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data) else {
                throw DataError.unreadable(url.path)
            }
            lock.withLock { cache[key] = t }
            return t
        }
    }
}
