// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Where live answers may look.
public struct LiveAnswerSources: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let thisMeeting = LiveAnswerSources(rawValue: 1)
    public static let pastMeetings = LiveAnswerSources(rawValue: 2)
    public static let documents = LiveAnswerSources(rawValue: 4)
    public static let all: LiveAnswerSources = [.thisMeeting, .pastMeetings, .documents]
}

/// Whose questions are answered.
public enum LiveAnswerSpeakers: String, Sendable, Codable, CaseIterable {
    case everyone, othersOnly
}

/// The settings of live answers (Settings, Recording), as the detector runs them: all three sources, standard sensitivity, everyone's
/// questions, questions answered aloud hidden, detected questions kept with the meeting (decisions D2, D5, D6). Whether the switch
/// starts on is decision D1 and depends on the model (`LiveAnswerDefaults`); `enabled` here is what the recording runs with, and starts off like every default: whoever builds the settings for a recording sets it.
public struct LiveAnswerSettings: Sendable, Equatable {
    public var enabled = false
    public var sources: LiveAnswerSources = .all
    public var sensitivity: QuestionSensitivity = .standard
    public var speakers: LiveAnswerSpeakers = .everyone
    /// D5: no card for a question someone answers aloud right away.
    public var hideWhenAnsweredAloud = true
    /// D6: the questions the model confirmed are stored with the meeting, encrypted, even when no answer is shown.
    public var keepDetectedQuestions = true
    /// D14: the small model check before the answer. Always on until the evaluation shows the variant without it (V0) is as precise;
    /// no control for it in Settings, the hidden preference `liveAnswersModelCheck` turns it off.
    public var modelCheck = true

    public init() {}

    /// What applies to a recording in Low Power Mode: fewer answers, and the past meetings are left out.
    public func effective(lowPowerMode: Bool) -> LiveAnswerSettings {
        guard lowPowerMode else { return self }
        var copy = self
        copy.sensitivity = .low
        copy.sources.remove(.pastMeetings)
        return copy
    }

    /// Whether anything can be answered at all (a source is on).
    public var hasSources: Bool { !sources.isEmpty }
}

/// What the Mac is doing that limits live answers, injected so tests and the evaluation can set it.
public struct LiveAnswerEnvironment: Sendable {
    public var lowPowerMode: Bool
    public var thermal: ProcessInfo.ThermalState
    /// The transcription of a channel is falling behind.
    public var transcriptionLagging: Bool

    public init(lowPowerMode: Bool = false, thermal: ProcessInfo.ThermalState = .nominal, transcriptionLagging: Bool = false) {
        self.lowPowerMode = lowPowerMode
        self.thermal = thermal
        self.transcriptionLagging = transcriptionLagging
    }

    /// Why live answers are paused now (nil = they run). The Low Power Mode and `fair` heat do not pause them: they change the
    /// settings and the caps.
    public func pauseReason(settings: LiveAnswerSettings) -> LiveAnswerPause? {
        if thermal == .critical { return .tooWarm }
        if thermal == .serious { return .tooWarm }
        if transcriptionLagging { return .transcriptBehind }
        if !settings.hasSources { return .noSources }
        return nil
    }
}

/// Why live answers are paused, for the line in the card and for VoiceOver.
public enum LiveAnswerPause: String, Sendable, Equatable {
    case modelUnavailable, tooWarm, transcriptBehind, noSources
}

/// One final line of the recording, as the detector sees it.
public struct QuestionLine: Sendable, Equatable {
    /// The row of the stored segment (nil while it is not saved yet).
    public var segmentID: Int64?
    public var channel: Channel
    public var start: Double
    public var end: Double
    public var text: String

    public init(segmentID: Int64? = nil, channel: Channel, start: Double, end: Double, text: String) {
        self.segmentID = segmentID
        self.channel = channel
        self.start = start
        self.end = end
        self.text = text
    }

    /// `[mm:ss · Me|Others] text`, as the model check reads it.
    func promptLine(maxCharacters: Int = 300) -> String {
        let who = channel == .me ? "Me" : "Others"
        return "[\(PromptText.clock(start)) · \(who)] \(PromptText.defang(PromptText.clip(SingleLineText.flatten(text), maxCharacters)))"
    }
}
