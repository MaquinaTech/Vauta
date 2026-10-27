// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Turning an audio recording into a new meeting: dating it, naming it and
/// cleaning the transcription before it is stored.
///
/// A recording has a single channel, so every segment is stored as `.others`
/// (the people in the recording); the user can rename speakers afterwards
/// only through the context, as for live meetings.
public struct RecordingImportPlan: Sendable, Equatable {
    /// nil = the automatic "Meeting on …" title.
    public let title: String?
    public let startedAt: Date
    public let endedAt: Date
    /// The recording date was not used because the transcript would expire
    /// at once (older than the retention period) or it was in the future.
    public let redated: Bool

    /// Days of margin before retention: a recording dated closer than this to
    /// the retention limit is dated now, so its text is not purged right away.
    public static let retentionMargin = 7

    /// - Parameters:
    ///   - fileName: the file's name; its stem becomes the title.
    ///   - recordedAt: when the recording started (file metadata), if known.
    ///   - duration: length of the audio in seconds.
    public init(fileName: String, recordedAt: Date?, duration: Double, now: Date = .now,
                retentionDays: Int = MeetingStore.retentionDays) {
        let stem = (fileName as NSString).deletingPathExtension
        let clean = SingleLineText.flatten(stem).trimmingCharacters(in: .whitespacesAndNewlines)
        title = clean.isEmpty ? nil : String(clean.prefix(200))
        let length = max(0, duration.isFinite ? duration : 0)
        let oldest = now.addingTimeInterval(-Double(max(0, retentionDays - Self.retentionMargin)) * 86_400)
        if let recordedAt, recordedAt >= oldest, recordedAt.addingTimeInterval(length) <= now.addingTimeInterval(60) {
            startedAt = recordedAt
            redated = false
        } else {
            // Unknown, too old or in the future: it ends now.
            startedAt = now.addingTimeInterval(-length)
            redated = recordedAt != nil
        }
        endedAt = startedAt.addingTimeInterval(length)
    }

    /// Final, non-empty segments in time order, as `.others`, with times
    /// clamped to the recording (`duration`, when known).
    public static func transcript(from raw: [Segment], duration: Double? = nil) -> [Segment] {
        raw.filter(\.isFinal)
            .compactMap { s -> Segment? in
                let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, s.start.isFinite, s.end.isFinite else { return nil }
                var start = max(0, s.start)
                var end = max(start, s.end)
                if let duration, duration > 0 {
                    start = min(start, duration)
                    end = min(end, duration)
                }
                return Segment(channel: .others, start: start, end: end, text: text, isFinal: true, words: s.words)
            }
            .sorted { $0.start < $1.start }
    }
}

/// Why an import could not finish.
public struct RecordingImportError: LocalizedError, Equatable, Sendable {
    public enum Code: String, Sendable {
        /// The file has no audio track (or none AVFoundation can read).
        case noAudio
        /// The file could not be opened or decoded.
        case unreadable
        /// Transcription produced no text.
        case noSpeech
    }

    public let code: Code
    public var detail: String?

    public init(_ code: Code, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    public var errorDescription: String? {
        switch code {
        case .noAudio: String(localized: "This file has no audio Vauta can read.", comment: "Import error")
        case .unreadable: String(localized: "The recording couldn’t be read.", comment: "Import error")
        case .noSpeech: String(localized: "No speech was found in this recording.", comment: "Import error")
        }
    }

    public var recoverySuggestion: String? {
        switch code {
        case .noAudio, .unreadable:
            String(localized: "Choose an audio or video file such as M4A, MP3, WAV, AIFF, MP4 or MOV.", comment: "Import error recovery")
        case .noSpeech:
            String(localized: "Check that the recording has voices and that you chose the language that is spoken in it.",
                   comment: "Import error recovery")
        }
    }
}

extension MeetingStore {
    /// Stores an imported recording as a new, finished meeting and analyzes
    /// it against the context, like a meeting that just ended. It does not
    /// become the active meeting, so it can be imported while recording.
    ///
    /// With a `diarization` of the recording, its speakers are written before the meeting is analyzed (see
    /// `SpeakerFinalizer` for why the order matters). A failure there keeps the meeting without speakers.
    ///
    /// - Throws: `RecordingImportError(.noSpeech)` when there are no segments.
    @discardableResult
    public func importMeeting(_ plan: RecordingImportPlan, segments: [Segment], locale: Locale?,
                              outputLocale: Locale? = nil, diarization: Diarization? = nil,
                              recognizeVoices: Bool = false) async throws -> Int64 {
        guard !segments.isEmpty else { throw RecordingImportError(.noSpeech) }
        if needsNewKey { try rotateKey() }
        var rows: [Int64] = []
        let id: Int64 = try transaction {
            try run("INSERT INTO meetings(started_at, ended_at, title, locale, output_locale, imported, time_zone) VALUES (?, ?, ?, ?, ?, 1, ?)",
                    [.real(plan.startedAt.timeIntervalSince1970), .real(plan.endedAt.timeIntervalSince1970),
                     plan.title.map { .text(Self.clean($0, max: 200)) }, locale.map { .text($0.identifier(.bcp47)) },
                     outputLocale.map { .text($0.identifier(.bcp47)) }, .text(TimeZone.current.identifier)])
            let id = db.lastInsertRowID
            for s in segments {
                try run("INSERT INTO segments(meeting_id, speaker, start, end, text) VALUES (?, ?, ?, ?, ?)",
                        [.integer(id), .text(s.channel.storedCode), .real(s.start), .real(s.end), .text(s.text)])
                rows.append(db.lastInsertRowID)
            }
            return id
        }
        if let diarization {
            let words = Dictionary(zip(rows, segments.map(\.words)).filter { !$0.1.isEmpty }, uniquingKeysWith: { first, _ in first })
            _ = try? await applyDiarization(diarization, to: id, wordRuns: words, recognizeVoices: recognizeVoices, ownVoice: true)
        }
        // Context mentions, as for a meeting that just ended; a failure keeps
        // the meeting (it can be re-analyzed from the review screen).
        _ = try? transaction { try analyzeInTransaction(id) }
        try await commitEdit()
        return id
    }
}
