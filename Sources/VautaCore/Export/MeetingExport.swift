// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Everything an export of one meeting contains, already read from the store.
/// The renderers (Markdown, plain text, SRT, WebVTT, JSON) are pure functions
/// of this value and `MeetingExportOptions`, so they can be tested without a
/// store. PDF is rendered by the app from the same value.
public struct MeetingExport: Sendable, Equatable {
    /// A decision, note or other item, with the moment of the meeting it cites.
    public struct Item: Sendable, Equatable {
        public var text: String
        /// Seconds from the start of the meeting.
        public var time: Double?
        /// The model proposed it and the transcript does not back it (a name, date or figure that does not match the passage it cites, or an item the ranking left out of the main ones).
        public var unconfirmed: Bool

        public init(text: String, time: Double? = nil, unconfirmed: Bool = false) {
            self.text = text
            self.time = time
            self.unconfirmed = unconfirmed
        }
    }

    /// One of the user's own notes: their words first, then (when the model wrote one) what the transcript says about
    /// it. The user's text is never replaced by the expansion.
    public struct NoteEntry: Sendable, Equatable {
        public struct Sentence: Sendable, Equatable {
            public var text: String
            /// Seconds from the start of the meeting of each cited passage.
            public var times: [Double]
            public var segmentIDs: [Int64]
            public var unconfirmed: Bool
            /// The transcript says something different from the note.
            public var differs: Bool

            public init(text: String, times: [Double] = [], segmentIDs: [Int64] = [], unconfirmed: Bool = false, differs: Bool = false) {
                self.text = text; self.times = times; self.segmentIDs = segmentIDs; self.unconfirmed = unconfirmed; self.differs = differs
            }
        }

        /// The user's words.
        public var text: String
        public var time: Double?
        /// Empty when there is none, the user removed it, nothing was found or it is out of date.
        public var expansion: [Sentence]
        /// The user rewrote the expansion.
        public var editedByUser: Bool

        public init(text: String, time: Double? = nil, expansion: [Sentence] = [], editedByUser: Bool = false) {
            self.text = text; self.time = time; self.expansion = expansion; self.editedByUser = editedByUser
        }
    }

    public struct TaskEntry: Sendable, Equatable {
        public var text: String
        public var owner: String?
        public var due: Date?
        public var status: TaskItem.Status
        public var time: Double?
        /// The transcript does not back it: a name, date or figure does not match the passage the model cited, or the ranking left it out of the main items.
        public var unconfirmed: Bool
        /// Nothing in the cited passage or in the speaker labels confirms the owner.
        public var ownerUncertain: Bool

        public init(text: String, owner: String? = nil, due: Date? = nil, status: TaskItem.Status = .open, time: Double? = nil,
                    unconfirmed: Bool = false, ownerUncertain: Bool = false) {
            self.text = text
            self.owner = owner
            self.due = due
            self.status = status
            self.time = time
            self.unconfirmed = unconfirmed
            self.ownerUncertain = ownerUncertain
        }
    }

    /// One transcript segment.
    public struct Line: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var channel: Channel
        /// The person's name when it is known (the user's own name for `.me`,
        /// the people "Others" stands for). nil = only the channel is known.
        public var name: String?
        public var text: String
        /// The stored translation of the passage (nil = none). Only written when
        /// `MeetingExportOptions.includeTranslation` is on.
        public var translation: String?
        /// Who said it, when the meeting has speaker data (nil = none). JSON writes it as ids; the text formats,
        /// the subtitles and the PDF print the speaker's name with `MeetingExportOptions.SpeakerLabels.names`.
        public var speaker: SpeakerTag?
        /// The user corrected the words (`text` is the correction; what was transcribed is not exported).
        public var corrected: Bool

        public init(start: Double, end: Double, channel: Channel, name: String? = nil, text: String, translation: String? = nil,
                    speaker: SpeakerTag? = nil, corrected: Bool = false) {
            self.start = start
            self.end = end
            self.channel = channel
            self.name = name
            self.text = text
            self.translation = translation
            self.speaker = speaker
            self.corrected = corrected
        }

        /// The translation to write, if there is one.
        public func translation(_ options: MeetingExportOptions) -> String? {
            guard options.includeTranslation, let translation, !translation.isEmpty else { return nil }
            return translation
        }
    }

    /// A speaker of the meeting. Never carries voice data.
    public struct Speaker: Sendable, Equatable {
        public var id: Int64
        public var channel: Channel
        /// "Speaker 2" (English, independent of the UI language); "Me" for the first speaker of the user's own channel, "Me 2" for a second one.
        public var label: String
        /// The person's name when the user named the speaker.
        public var name: String?
        public var talkSeconds: Double

        public init(id: Int64, channel: Channel, label: String, name: String? = nil, talkSeconds: Double = 0) {
            self.id = id
            self.channel = channel
            self.label = label
            self.name = name
            self.talkSeconds = talkSeconds
        }
    }

    /// A question heard in the meeting that the person kept, with its verified answer. Only kept ones are exported.
    public struct QuestionEntry: Sendable, Equatable {
        /// Seconds from the start of the meeting.
        public var time: Double
        public var channel: Channel
        /// The words that were transcribed.
        public var text: String
        public var answer: String
        /// Where the answer was verified, in words: "This meeting (12:03)", "Weekly sync, 2026-10-03 (04:10)", "Budget.xlsx · p. 4".
        public var sources: [String]

        public init(time: Double, channel: Channel, text: String, answer: String, sources: [String] = []) {
            self.time = time
            self.channel = channel
            self.text = text
            self.answer = answer
            self.sources = sources
        }
    }

    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    /// Transcription language (BCP-47); nil for meetings recorded before
    /// languages were stored.
    public var language: String?
    /// When the user marked the other participants as informed (consent helper); nil = not marked.
    public var participantsInformedAt: Date?
    public var attendees: [String]
    public var summary: String
    public var topics: [String]
    public var openQuestions: [String]
    public var decisions: [Item]
    public var tasks: [TaskEntry]
    /// The user's own notes taken during the meeting.
    public var notes: [NoteEntry]
    /// Empty when the transcript expired (retention) or nobody spoke.
    public var transcript: [Line]
    /// When the recording was paused: written with the transcript, where nothing was captured.
    public var pauses: [MeetingPause]
    /// The meeting's speakers; empty when it has no speaker data.
    public var speakers: [Speaker]
    /// The questions the person kept, in the order they were asked.
    public var questions: [QuestionEntry]

    public init(title: String, startedAt: Date, endedAt: Date? = nil, language: String? = nil, participantsInformedAt: Date? = nil,
                attendees: [String] = [],
                summary: String = "", topics: [String] = [], openQuestions: [String] = [], decisions: [Item] = [],
                tasks: [TaskEntry] = [], notes: [NoteEntry] = [], transcript: [Line] = [], pauses: [MeetingPause] = [], speakers: [Speaker] = [],
                questions: [QuestionEntry] = []) {
        self.questions = questions
        self.pauses = pauses
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.language = language
        self.participantsInformedAt = participantsInformedAt
        self.attendees = attendees
        self.summary = summary
        self.topics = topics
        self.openQuestions = openQuestions
        self.decisions = decisions
        self.tasks = tasks
        self.notes = notes
        self.transcript = transcript
        self.speakers = speakers
    }

    /// Whole minutes between start and end (at least 1), nil while recording.
    public var durationMinutes: Int? {
        endedAt.map { max(1, Int(($0.timeIntervalSince(startedAt) / 60).rounded())) }
    }

    /// True when there is nothing but the title and date to export.
    /// Some passage has a stored translation.
    public var hasTranslation: Bool { transcript.contains { $0.translation?.isEmpty == false } }

    public var hasMinutes: Bool {
        !summary.isEmpty || !topics.isEmpty || !openQuestions.isEmpty || !decisions.isEmpty || !tasks.isEmpty || !notes.isEmpty
    }
}

/// How an export is written.
public struct MeetingExportOptions: Sendable, Equatable {
    /// How transcript speakers are labelled.
    public enum SpeakerLabels: String, Sendable, CaseIterable, Identifiable {
        /// "Me" and "Others".
        case channels
        /// The person's name when known, otherwise "Me" / "Others". In a meeting with speaker data each line
        /// carries its own speaker: the name the user gave, else "Speaker 2" (and "(not sure)" after a guess).
        case names

        public var id: String { rawValue }
    }

    public var includeTranscript: Bool
    /// Write the stored translation under each translated passage (off by default).
    public var includeTranslation: Bool
    public var speakerLabels: SpeakerLabels
    /// Locale and time zone for dates written for people (Markdown, text, PDF).
    /// JSON always uses ISO 8601.
    public var locale: Locale
    public var timeZone: TimeZone
    /// Write when the user marked the participants as informed of the recording, if they did (on by default: it is the
    /// meeting's record of consent; JSON writes null when it is off).
    public var includeParticipantsInformed: Bool

    public init(includeTranscript: Bool = true, includeTranslation: Bool = false, speakerLabels: SpeakerLabels = .channels,
                locale: Locale = .current, timeZone: TimeZone = .current, includeParticipantsInformed: Bool = true) {
        self.includeTranscript = includeTranscript
        self.includeTranslation = includeTranslation
        self.speakerLabels = speakerLabels
        self.locale = locale
        self.timeZone = timeZone
        self.includeParticipantsInformed = includeParticipantsInformed
    }

    /// The label shown for a transcript line. A line without speaker data is labelled exactly as before speakers existed.
    /// `marksDoubt: false` leaves out the "(not sure)" note, for formats that carry the confidence as data.
    public func speaker(of line: MeetingExport.Line) -> String { speaker(of: line, marksDoubt: true) }

    public func speaker(of line: MeetingExport.Line, marksDoubt: Bool) -> String {
        switch speakerLabels {
        case .channels:
            return line.channel.displayName
        case .names:
            guard let tag = line.speaker else { return line.name.flatMap { $0.isEmpty ? nil : $0 } ?? line.channel.displayName }
            // The user's first voice is "Me" unless they have a name of their own.
            let own = tag.name ?? (line.channel == .me && tag.ordinal == 1 ? line.name.flatMap { $0.isEmpty ? nil : $0 } : nil)
            let name = own ?? tag.displayName(channel: line.channel)
            // A guess is never printed as fact: the app's own transcript marks it the same way.
            return tag.isDoubtful && marksDoubt
                ? String(localized: "\(name) (not sure)", comment: "A speaker’s name followed by a note that the app is not sure who said the line, in an export or an Ask citation")
                : name
        }
    }
}

/// The export file formats.
public enum MeetingExportFormat: String, Sendable, CaseIterable, Identifiable {
    case markdown, plainText, pdf, srt, webVTT, json

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .plainText: "txt"
        case .pdf: "pdf"
        case .srt: "srt"
        case .webVTT: "vtt"
        case .json: "json"
        }
    }

    /// Uniform Type Identifier of the file (for the save panel).
    public var typeIdentifier: String {
        switch self {
        case .markdown: "net.daringfireball.markdown"
        case .plainText: "public.plain-text"
        case .pdf: "com.adobe.pdf"
        case .srt: "public.srt"
        case .webVTT: "org.w3.webvtt"
        case .json: "public.json"
        }
    }

    public var displayName: String {
        switch self {
        case .markdown: String(localized: "Markdown", comment: "Export format name")
        case .plainText: String(localized: "Plain text", comment: "Export format name")
        case .pdf: String(localized: "PDF", comment: "Export format name")
        case .srt: String(localized: "Subtitles (SRT)", comment: "Export format name")
        case .webVTT: String(localized: "Subtitles (WebVTT)", comment: "Export format name")
        case .json: String(localized: "JSON", comment: "Export format name")
        }
    }

    /// Subtitle formats only contain the transcript.
    public var isTranscriptOnly: Bool { self == .srt || self == .webVTT }

    /// Renders a text format. nil for PDF, which the app renders.
    public func render(_ export: MeetingExport, options: MeetingExportOptions) -> String? {
        switch self {
        case .markdown: MeetingExportRenderer.markdown(export, options: options)
        case .plainText: MeetingExportRenderer.plainText(export, options: options)
        case .srt: SubtitleRenderer.srt(export.transcript, options: options)
        case .webVTT: SubtitleRenderer.webVTT(export.transcript, options: options)
        case .json: try? MeetingExportJSON.encode(export, options: options)
        case .pdf: nil
        }
    }
}

/// Timestamps written into exports.
public enum ExportTimestamp {
    /// "05:07" under an hour, "1:02:03" from an hour on (as in the app).
    public static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// "01:02:03,450" (SRT) or "01:02:03.450" (WebVTT).
    public static func subtitle(_ seconds: Double, separator: Character) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return String(format: "%02d:%02d:%02d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60)
            + String(separator) + String(format: "%03d", ms % 1000)
    }
}
