// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The language and engines of a recording, decided before capture starts.
public struct RecordingLanguagePlan: Equatable, Sendable {
    public let language: SpeechLanguage
    /// The engine of each channel.
    public let engines: [Channel: SpeechEngineKind]

    /// Engines this plan uses whose model isn't installed for the language.
    public var missingEngines: [SpeechEngineKind] {
        Set(engines.values).subtracting(language.installed).sorted { $0.rawValue < $1.rawValue }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// Neither engine supports the language on this Mac.
        case unsupported(String)
    }

    /// - Parameters:
    ///   - preferred: the chosen language (BCP-47), nil = automatic.
    ///   - dictationMe/dictationOthers: use DictationTranscriber (custom
    ///     vocabulary) on that channel when the language supports it.
    public static func make(preferred: String?, catalog: SpeechLanguageCatalog,
                            preferredLanguages: [String] = Locale.preferredLanguages,
                            dictationMe: Bool, dictationOthers: Bool) -> Result<RecordingLanguagePlan, Failure> {
        let language: SpeechLanguage?
        if let preferred {
            language = catalog.language(matching: preferred)
        } else {
            language = catalog.defaultLanguage(preferredLanguages: preferredLanguages)
        }
        guard let language else { return .failure(.unsupported(preferred ?? SpeechLanguages.fallbackIdentifier)) }
        func engine(dictation: Bool) -> SpeechEngineKind {
            if !language.engines.contains(.speech) { return .dictation }
            return dictation && language.engines.contains(.dictation) ? .dictation : .speech
        }
        return .success(RecordingLanguagePlan(language: language,
                                              engines: [.me: engine(dictation: dictationMe), .others: engine(dictation: dictationOthers)]))
    }
}

/// The audio-source choices of the menu-bar panel.
extension SystemAudioScope {
    /// Whether the scope captures `family` by name (`.apps` only).
    public func includes(_ family: MeetingAppFamily) -> Bool {
        if case .apps(let families) = self { return families.contains(family) }
        return false
    }

    /// Ticks or unticks one family. Unticking the last one goes back to `.auto`.
    public func toggling(_ family: MeetingAppFamily) -> SystemAudioScope {
        guard case .apps(var families) = self else { return .apps([family]) }
        if families.contains(family) { families.remove(family) } else { families.insert(family) }
        return families.isEmpty ? .auto : .apps(families)
    }

    /// A short name for the menu label.
    public var summary: String {
        switch self {
        case .auto:
            return String(localized: "Automatic", comment: "Audio source: follow the app in the call")
        case .allSystem:
            return String(localized: "All system audio", comment: "Audio source")
        case .apps(let families):
            let ordered = MeetingAppFamily.allCases.filter(families.contains)
            if ordered.count == 1, let family = ordered.first { return family.shortName }
            return ListFormatter.localizedString(byJoining: ordered.map(\.shortName))
        }
    }

    /// The meeting app recorded as the meeting's source (`meetings.source_app`):
    /// the app holding the microphone when the scope captures it, else the
    /// scope's only family.
    public func sourceApp(callFamily: MeetingAppFamily?) -> MeetingAppFamily? {
        switch self {
        case .auto, .allSystem:
            return callFamily
        case .apps(let families):
            if let callFamily, families.contains(callFamily) { return callFamily }
            return families.count == 1 ? families.first : nil
        }
    }
}

extension MeetingAppFamily {
    /// A compact name for chips and menu labels ("Chrome" rather than the
    /// whole family description).
    public var shortName: String {
        switch self {
        case .webkit: "Safari"
        case .chromium: "Chrome"
        case .firefox: "Firefox"
        default: displayName
        }
    }
}

/// Elapsed time and positions in a meeting as shown across the app (panel, Meetings, VoiceOver). Exports use `ExportTimestamp`.
public enum ElapsedTime {
    /// "05:03", or "1:02:03" from one hour on.
    public static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// "5:03", or "1:02:03" from one hour on: the minutes without a leading zero. Every time shown in the menu-bar
    /// panel (the timer, the countdown, the time of a note or a passage) uses this one form.
    public static func stamp(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The same, for a position in a meeting kept as seconds.
    public static func stamp(_ seconds: Double) -> String { stamp(Int(max(0, seconds))) }

    /// Spoken form for VoiceOver ("5 minutes, 3 seconds").
    public static func spoken(_ seconds: Int) -> String {
        Duration.seconds(max(0, seconds)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}
