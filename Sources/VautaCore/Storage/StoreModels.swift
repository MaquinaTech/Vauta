// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension MeetingStore {
    public struct Meeting: Sendable, Identifiable, Hashable {
        /// Transcription language of meetings recorded before languages were
        /// stored (`locale` is NULL): the earlier version only transcribed Spanish. The one
        /// definition: speech, knowledge and storage code all refer to it.
        public static let legacyLocaleIdentifier = "es-ES"

        public let id: Int64
        public let startedAt: Date
        public let endedAt: Date?
        /// The title set by the user, the calendar or the model. nil means the
        /// automatic title: show `displayTitle`.
        public let title: String?
        /// Transcription language (BCP-47). nil = legacy meeting (`legacyLocaleIdentifier`).
        public let locale: String?
        /// Language of minutes and answers (BCP-47). nil = same as the transcription.
        public let outputLocale: String?
        /// App family the "others" channel was captured from. nil = legacy
        /// (Safari or all system audio) or not recorded.
        public let sourceApp: String?

        public init(id: Int64, startedAt: Date, endedAt: Date?, title: String?,
                    locale: String? = nil, outputLocale: String? = nil, sourceApp: String? = nil) {
            self.id = id
            self.startedAt = startedAt
            self.endedAt = endedAt
            self.title = title
            self.locale = locale
            self.outputLocale = outputLocale
            self.sourceApp = sourceApp
        }

        /// The title, or a localized automatic title from the start date.
        public var displayTitle: String { Self.displayTitle(title, startedAt: startedAt) }

        /// `title`, or the automatic "Meeting on …" title when it is nil or empty.
        public static func displayTitle(_ title: String?, startedAt: Date) -> String {
            if let title, !title.isEmpty { return title }
            let date = startedAt.formatted(.dateTime.day().month().hour().minute())
            return String(localized: "Meeting on \(date)", comment: "Automatic meeting title; the argument is the start date and time")
        }

        /// The language the meeting was transcribed in.
        public var transcriptionLocale: Locale { Locale(identifier: locale ?? Self.legacyLocaleIdentifier) }

        /// The language minutes and answers should be written in.
        public var minutesLocale: Locale { outputLocale.map(Locale.init(identifier:)) ?? transcriptionLocale }
    }

    public struct StoredSegment: Sendable, Identifiable, Hashable {
        public let id: Int64
        public let meetingID: Int64
        public let channel: Channel
        public let start: Double
        public let end: Double
        public let text: String
        /// Who said it; nil = no speaker data (the meeting predates speaker separation, or it was off).
        public let speaker: SpeakerTag?
        /// A Me line marked as the speakers' echo (the other participants' words, picked up by the microphone).
        public var isEcho = false

        public init(id: Int64, meetingID: Int64, channel: Channel, start: Double, end: Double, text: String, speaker: SpeakerTag? = nil) {
            self.id = id
            self.meetingID = meetingID
            self.channel = channel
            self.start = start
            self.end = end
            self.text = text
            self.speaker = speaker
        }
    }

    /// The translation of one segment into one language.
    public struct StoredTranslation: Sendable, Hashable {
        public let segmentID: Int64
        /// The target language (BCP-47, e.g. "es" or "zh-Hans").
        public let language: String
        public let text: String
    }

    public struct SearchHit: Sendable, Identifiable, Hashable {
        public var id: Int64 { segment.id }
        public let meeting: Meeting
        public let segment: StoredSegment
        /// Excerpt with each match between `SearchHighlight.start` and `SearchHighlight.end`.
        public let snippet: String
    }

    // MARK: Row mappers

    /// Meeting columns in the order `meeting(_:languageAt:)` expects (with `languageAt: 4`).
    static let meetingColumns = meetingColumns(alias: nil)

    /// `meetingColumns` qualified with a table alias (`mt.id, mt.started_at, …`),
    /// for joins. Map the row with `meeting(_:languageAt: 4)`.
    static func meetingColumns(alias: String?) -> String {
        let prefix = alias.map { "\($0)." } ?? ""
        return ["id", "started_at", "ended_at", "title", "locale", "output_locale", "source_app"]
            .map { prefix + $0 }.joined(separator: ", ")
    }

    /// Maps `id, started_at, ended_at, title` at columns 0–3 and
    /// `locale, output_locale, source_app` starting at column `index`.
    /// Every query that builds a `Meeting` selects all seven columns, so the
    /// language fields are never silently nil.
    static func meeting(_ row: Row, languageAt index: Int) -> Meeting {
        Meeting(id: row.int(0), startedAt: Date(timeIntervalSince1970: row.double(1)),
                endedAt: row.optionalDouble(2).map(Date.init(timeIntervalSince1970:)),
                title: row.optionalString(3),
                locale: row.optionalString(index),
                outputLocale: row.optionalString(index + 1),
                sourceApp: row.optionalString(index + 2))
    }

    /// Maps `id, meeting_id, speaker, start, end, text` at columns 0–5 and, when `speakerAt` is given,
    /// the `speakerColumns` starting there.
    static func segment(_ row: Row, speakerAt index: Int? = nil) -> StoredSegment {
        StoredSegment(id: row.int(0), meetingID: row.int(1), channel: Channel(storedSpeaker: row.string(2)),
                      start: row.double(3), end: row.double(4), text: row.string(5),
                      speaker: index.flatMap { speakerTag(row, at: $0) })
    }

    /// The speaker of a segment `s`, to append to a select list over `segments s` (with `speakerJoins`).
    /// Seven columns; `speakerTag(_:at:)` maps them. Only a speaker the user named
    /// is shown with a name.
    static let speakerColumns = """
        sp.id, sp.ordinal, CASE WHEN sp.source = 'user' THEN e.name END,
        e.id IS (SELECT v FROM store_meta WHERE k = 'self_entity'), s.speaker_confidence, s.overlap, sp.voice_spread
        """

    /// Columns `speakerColumns` adds to a select list.
    static let speakerColumnCount = 7

    static let speakerJoins = """
        LEFT JOIN meeting_speakers sp ON sp.id = s.speaker_id
        LEFT JOIN entities e ON e.id = sp.entity_id
        """

    /// nil when the segment has no speaker (the LEFT JOIN found no row, so `sp.id` is NULL).
    static func speakerTag(_ row: Row, at index: Int) -> SpeakerTag? {
        guard row.optionalInt(index) != nil else { return nil }
        return SpeakerTag(id: row.int(index), ordinal: Int(row.int(index + 1)),
                          name: row.optionalString(index + 2).map { displayName($0, isSelf: row.int(index + 3) != 0) },
                          confidence: row.optionalDouble(index + 4), overlap: row.int(index + 5) != 0,
                          isSelf: row.optionalString(index + 2) != nil && row.int(index + 3) != 0,
                          mixesVoices: row.optionalDouble(index + 6).map { $0 < Double(VoiceProfileThresholds.minimumSpread) } ?? false)
    }
}
