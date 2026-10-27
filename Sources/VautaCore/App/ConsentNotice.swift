// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// When Vauta reminds the user to tell the other participants that the meeting
/// is being transcribed. The reminder never blocks recording and nothing is
/// ever sent: the user pastes the notice into the meeting chat themselves.
public enum ConsentReminder: String, CaseIterable, Identifiable, Sendable {
    /// At the start of every recording.
    case always
    /// Only until the user has marked participants as informed for a meeting
    /// captured from the same app (Zoom, Teams, a browser…).
    case firstPerApp
    case never

    public var id: String { rawValue }

    public static let `default` = ConsentReminder.always

    /// - Parameter informedBefore: an earlier meeting from the same app was marked as informed.
    public func shouldRemind(informedBefore: Bool) -> Bool {
        switch self {
        case .always: true
        case .firstPerApp: !informedBefore
        case .never: false
        }
    }
}

/// The text the user pastes into the meeting chat, in the language of the meeting.
public enum ConsentNotice {
    /// Key of the notice in `Localizable.strings` (one translation per interface language).
    static let key = "consent.notice"

    /// The English source, used when no translation matches.
    private static let english = String(
        localized: "consent.notice",
        defaultValue: "I’m transcribing this meeting to take notes, with an app on my Mac. Nothing is sent to the internet. Tell me if you’d rather I didn’t.",
        comment: "Ready-to-paste message the user sends to the other participants of a meeting, in the user's own voice; it is shown in the language the meeting is spoken in")

    /// The notice and the language it is written in (a localization such as "es" or "pt-BR").
    public struct Resolved: Sendable, Equatable {
        public let text: String
        /// nil = the English source (no localization folder matched).
        public let language: String?
    }

    /// Key of the whole notice used while voice recognition is on: a complete message of its own (one closing request),
    /// not the base notice with a sentence stuck on.
    static let voicesKey = "consent.notice.voices"

    private static let englishVoices = String(
        localized: "consent.notice.voices",
        defaultValue: "I’m transcribing this meeting to take notes, with an app on my Mac. Nothing is sent to the internet. The app also tells voices apart on my Mac and may suggest who is speaking from voices I saved with permission; it keeps a voice summary of each speaker for up to 14 days, in case I later save the voice of someone who agrees. Tell me if you’d rather I didn’t.",
        comment: "Ready-to-paste message the user sends to the other participants of a meeting, in the user's own voice, used instead of the plain one only when the user turned on recognizing voices across meetings: it also says that voices may be used to suggest who is speaking; one closing request; it is shown in the language the meeting is spoken in")

    /// The notice in the meeting's transcription language (BCP-47, e.g. "es-ES"),
    /// or in the interface language when the app has no translation for it
    /// (or the language is unknown). `bundle` holds the `.lproj` folders. With `recognizesVoices` (the user turned on
    /// recognizing voices) the notice is the one that also says that voices may be used to suggest who is speaking.
    public static func resolve(meetingLocale: String?, recognizesVoices: Bool = false, bundle: Bundle = .main) -> Resolved {
        let (wanted, fallback) = recognizesVoices ? (voicesKey, englishVoices) : (Self.key, Self.english)
        let available = bundle.localizations.filter { $0 != "Base" }
        let chosen = meetingLocale.flatMap { bestLocalization(for: $0, among: available) }
            ?? bundle.preferredLocalizations.first
        guard let chosen, let table = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: chosen),
              let localized = Bundle(path: (table as NSString).deletingLastPathComponent) else {
            return Resolved(text: fallback, language: nil)
        }
        let text = localized.localizedString(forKey: wanted, value: fallback, table: nil)
        guard text != wanted else { return Resolved(text: fallback, language: nil) }
        return Resolved(text: text, language: chosen)
    }

    public static func text(meetingLocale: String?, recognizesVoices: Bool = false, bundle: Bundle = .main) -> String {
        resolve(meetingLocale: meetingLocale, recognizesVoices: recognizesVoices, bundle: bundle).text
    }

    /// The localization of `available` that speaks `identifier`'s language, if any.
    /// A language is never replaced by a different one, and Chinese keeps its script:
    /// Traditional Chinese does not get the Simplified text.
    static func bestLocalization(for identifier: String, among available: [String]) -> String? {
        let locale = Locale(identifier: identifier)
        guard let language = locale.language.languageCode?.identifier else { return nil }
        let region = locale.region?.identifier
        var script = locale.language.script?.identifier
        if language == "zh", script == nil {
            script = ["TW", "HK", "MO"].contains(region ?? "") ? "Hant" : "Hans"
        }
        let candidates = available.filter { code in
            let other = Locale(identifier: code.replacingOccurrences(of: "-", with: "_"))
            guard other.language.languageCode?.identifier == language else { return false }
            if language == "zh" { return (other.language.script?.identifier ?? "Hans") == script }
            return true
        }
        return candidates.first { Locale(identifier: $0).region?.identifier == region } ?? candidates.first
    }
}
