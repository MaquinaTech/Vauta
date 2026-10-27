// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The JSON export: a stable, versioned schema for scripts and other tools.
///
/// Schema `vauta.meeting`, version 1. Keys are sorted, output is pretty-printed
/// UTF-8 and every key below is always present (`null` when unknown):
///
/// ```
/// {
///   "format": "vauta.meeting",          // constant
///   "version": 1,                      // bumped only for incompatible changes
///   "title": String,
///   "startedAt": String,               // ISO 8601, UTC ("2026-10-07T08:00:00Z")
///   "endedAt": String | null,          // null while recording
///   "durationSeconds": Number | null,
///   "language": String | null,         // BCP-47 transcription language
///   "participantsInformedAt": String | null,   // ISO 8601, UTC: when the user marked the participants as informed
///   "attendees": [String],
///   "summary": String,                 // "" when there is none
///   "topics": [String],
///   "openQuestions": [String],
///   "decisions": [{ "text": String, "time": Number | null }],   // + optional "unconfirmed" (below)
///   "tasks": [{ "text": String, "owner": String | null, "due": String | null,   // "YYYY-MM-DD"
///               "status": "open" | "done" | "dropped", "time": Number | null }],   // + optional keys (below)
///   "notes": [{ "text": String, "time": Number | null,       // the user's own words, never rewritten
///               "expansion": { "sentences": [{ "text": String, "times": [Number], "segmentIds": [Number],
///                                              "unconfirmed": Bool, "differs": Bool }],
///                              "editedByUser": Bool } | null }],   // what the model wrote from the transcript, or null
///   "transcript": [{ "start": Number, "end": Number, "channel": "me" | "others",
///                    "speaker": String,  // as labelled in the export options
///                    "name": String | null, "text": String,
///                    "translation": String | null }] | null   // "translation" only with includeTranslation;
///                                                              // the array is null when not included
/// }
/// ```
///
/// Speaker data is optional and only written when the meeting has it and the transcript is
/// included (the speakers label the transcript: without it no names or talk time leave), so a
/// meeting without speakers exports exactly as before:
///
/// ```
///   "speakers": [{ "id": Number,           // matches transcript[].speakerId
///                  "label": String,        // "Speaker 2" ("Me", "Me 2" on the user's channel); English
///                  "name": String | null,  // set only when the user named them
///                  "channel": "me" | "others", "talkSeconds": Number }],
///   // and in each transcript line that has a speaker:
///   "speakerId": Number, "confidence": Number,   // 0...1, only when the assignment was scored
///   "overlap": Bool                              // true inside crosstalk, where the speaker is unsure (the name on that line is a guess)
/// ```
///
/// Items the transcript does not back carry optional keys, written only when true (an item without a mark has
/// exactly the keys above):
///
/// ```
///   decisions[].unconfirmed, tasks[].unconfirmed: true   // a name, date or figure does not match the cited passage
///   tasks[].ownerUncertain: true                          // nothing confirms the owner: the owner-name part of "unconfirmed"
/// ```
///
/// The owner is checked against the cited passage in every meeting, with or without speaker data: an owner who is not the
/// user on their own channel, not a confidently labeled speaker and not named in the words sets `ownerUncertain`. It is a
/// separate key from `unconfirmed` (name, date and figures of the item's text), so a doubtful owner does not hide a wrong figure.
///
/// `transcript[].speaker` is a display string ("Ana", "Speaker 2", "Me") in the language of the Mac that exported. It never
/// carries a note about doubt: the machine-readable fields are `speakerId`, `confidence` and `overlap`.
///
/// Questions heard in the meeting that the person kept are written only when there are some (an optional key, version 1):
///
/// ```
///   "questions": [{ "t": Number, "by": "me" | "others", "text": String,   // the words that were transcribed
///                   "answer": String, "sources": [String] }]               // where the answer was verified
/// ```
///
/// Voice data (embeddings, profiles) is never exported.
///
/// Times (`time`, `start`, `end`) are seconds from the start of the meeting,
/// rounded to milliseconds. New optional keys may be added in version 1;
/// consumers should ignore keys they don't know.
public enum MeetingExportJSON {
    public static let format = "vauta.meeting"
    public static let version = 1

    public static func encode(_ e: MeetingExport, options: MeetingExportOptions) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Document(e, options: options))
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    struct Document: Encodable {
        struct Item: Encodable {
            let text: String
            let time: Double?
            var unconfirmed = false
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(text, forKey: .text)
                try c.encode(time, forKey: .time)
                if unconfirmed { try c.encode(true, forKey: .unconfirmed) }
            }
            enum CodingKeys: String, CodingKey { case text, time, unconfirmed }
        }
        struct Note: Encodable {
            struct Sentence: Encodable {
                let text: String
                let times: [Double]
                let segmentIds: [Int64]
                let unconfirmed: Bool
                let differs: Bool
            }
            struct Expansion: Encodable {
                let sentences: [Sentence]
                let editedByUser: Bool
            }
            let text: String
            let time: Double?
            let expansion: Expansion?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(text, forKey: .text)
                try c.encode(time, forKey: .time)
                try c.encode(expansion, forKey: .expansion)
            }
            enum CodingKeys: String, CodingKey { case text, time, expansion }
        }
        struct TaskEntry: Encodable {
            let text: String
            let owner: String?
            let due: String?
            let status: String
            let time: Double?
            var unconfirmed = false
            var ownerUncertain = false
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(text, forKey: .text)
                try c.encode(owner, forKey: .owner)
                try c.encode(due, forKey: .due)
                try c.encode(status, forKey: .status)
                try c.encode(time, forKey: .time)
                if unconfirmed { try c.encode(true, forKey: .unconfirmed) }
                if ownerUncertain, owner != nil { try c.encode(true, forKey: .ownerUncertain) }
            }
            enum CodingKeys: String, CodingKey { case text, owner, due, status, time, unconfirmed, ownerUncertain }
        }
        struct Line: Encodable {
            let start: Double
            let end: Double
            let channel: String
            let speaker: String
            let name: String?
            let text: String
            /// Only present when the export includes translations.
            let translation: String??
            /// Only present when the line has a speaker.
            let tag: SpeakerTag?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(start, forKey: .start)
                try c.encode(end, forKey: .end)
                try c.encode(channel, forKey: .channel)
                try c.encode(speaker, forKey: .speaker)
                try c.encode(name, forKey: .name)
                try c.encode(text, forKey: .text)
                if let translation { try c.encode(translation, forKey: .translation) }
                if let tag, let id = tag.id {
                    try c.encode(id, forKey: .speakerId)
                    try c.encodeIfPresent(tag.confidence.map(Document.round), forKey: .confidence)
                    try c.encode(tag.overlap, forKey: .overlap)
                }
            }
            enum CodingKeys: String, CodingKey { case start, end, channel, speaker, name, text, translation, speakerId, confidence, overlap }
        }
        struct Speaker: Encodable {
            let id: Int64
            let label: String
            let name: String?
            let channel: String
            let talkSeconds: Double
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(label, forKey: .label)
                try c.encode(name, forKey: .name)
                try c.encode(channel, forKey: .channel)
                try c.encode(talkSeconds, forKey: .talkSeconds)
            }
            enum CodingKeys: String, CodingKey { case id, label, name, channel, talkSeconds }
        }

        struct Question: Encodable {
            let t: Double
            let by: String
            let text: String
            let answer: String
            let sources: [String]
        }

        let title: String
        let startedAt: Date
        let endedAt: Date?
        let durationSeconds: Double?
        let language: String?
        let participantsInformedAt: Date?
        let attendees: [String]
        let summary: String
        let topics: [String]
        let openQuestions: [String]
        let decisions: [Item]
        let tasks: [TaskEntry]
        let notes: [Note]
        let transcript: [Line]?
        /// Empty = not written.
        let speakers: [Speaker]
        /// The questions the person kept; empty = not written.
        let questions: [Question]

        init(_ e: MeetingExport, options: MeetingExportOptions) {
            title = e.title
            startedAt = e.startedAt
            endedAt = e.endedAt
            durationSeconds = e.endedAt.map { Self.round($0.timeIntervalSince(e.startedAt)) }
            language = e.language
            participantsInformedAt = e.participantsInformedAt
            attendees = e.attendees
            summary = e.summary
            topics = e.topics
            openQuestions = e.openQuestions
            decisions = e.decisions.map { Item(text: $0.text, time: $0.time.map(Self.round), unconfirmed: $0.unconfirmed) }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = options.timeZone
            tasks = e.tasks.map { t in
                TaskEntry(text: t.text, owner: t.owner, due: t.due.map { Self.day($0, calendar) }, status: t.status.rawValue,
                          time: t.time.map(Self.round), unconfirmed: t.unconfirmed, ownerUncertain: t.ownerUncertain)
            }
            notes = e.notes.map { n in
                Note(text: n.text, time: n.time.map(Self.round),
                     expansion: n.expansion.isEmpty ? nil : .init(sentences: n.expansion.map {
                         .init(text: $0.text, times: $0.times.map(Self.round), segmentIds: $0.segmentIDs, unconfirmed: $0.unconfirmed, differs: $0.differs)
                     }, editedByUser: n.editedByUser))
            }
            transcript = options.includeTranscript
                ? e.transcript.map { l in
                    Line(start: Self.round(l.start), end: Self.round(l.end), channel: l.channel.rawValue,
                         speaker: options.speaker(of: l, marksDoubt: false), name: l.name, text: l.text,
                         translation: options.includeTranslation ? .some(l.translation) : nil, tag: l.speaker)
                }
                : nil
            // Speakers are listed with the transcript they label: without it, no names or talk time leave.
            speakers = !options.includeTranscript ? [] : e.speakers.map {
                Speaker(id: $0.id, label: $0.label, name: $0.name, channel: $0.channel.rawValue, talkSeconds: Self.round($0.talkSeconds))
            }
            questions = e.questions.map { Question(t: Self.round($0.time), by: $0.channel.rawValue, text: $0.text, answer: $0.answer, sources: $0.sources) }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(MeetingExportJSON.format, forKey: .format)
            try c.encode(MeetingExportJSON.version, forKey: .version)
            try c.encode(title, forKey: .title)
            try c.encode(startedAt, forKey: .startedAt)
            try c.encode(endedAt, forKey: .endedAt)
            try c.encode(durationSeconds, forKey: .durationSeconds)
            try c.encode(language, forKey: .language)
            try c.encode(participantsInformedAt, forKey: .participantsInformedAt)
            try c.encode(attendees, forKey: .attendees)
            try c.encode(summary, forKey: .summary)
            try c.encode(topics, forKey: .topics)
            try c.encode(openQuestions, forKey: .openQuestions)
            try c.encode(decisions, forKey: .decisions)
            try c.encode(tasks, forKey: .tasks)
            try c.encode(notes, forKey: .notes)
            try c.encode(transcript, forKey: .transcript)
            if !speakers.isEmpty { try c.encode(speakers, forKey: .speakers) }
            if !questions.isEmpty { try c.encode(questions, forKey: .questions) }
        }

        enum CodingKeys: String, CodingKey {
            case format, version, title, startedAt, endedAt, durationSeconds, language, participantsInformedAt, attendees, summary, topics,
                 openQuestions, decisions, tasks, notes, transcript, speakers, questions
        }

        static func round(_ t: Double) -> Double { (t * 1000).rounded() / 1000 }

        static func day(_ date: Date, _ calendar: Calendar) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
    }
}
