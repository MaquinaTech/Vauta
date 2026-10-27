// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// System Settings panes Vauta links to.
public enum SystemSettingsPane: String, CaseIterable, Sendable {
    case microphone
    case systemAudio
    case calendars
    case reminders
    case notifications
    case localNetwork
    case loginItems
    case appleIntelligence
    case sound
    case storage

    public var url: URL {
        let raw = switch self {
        case .microphone: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .systemAudio: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        case .calendars: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
        case .reminders: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders"
        case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .localNetwork: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"
        case .loginItems: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        case .appleIntelligence: "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        case .sound: "x-apple.systempreferences:com.apple.Sound-Settings.extension"
        case .storage: "x-apple.systempreferences:com.apple.settings.Storage"
        }
        return URL(string: raw)!
    }
}

/// A permission as Settings and the setup show it.
public enum PermissionState: String, Sendable {
    case granted
    case denied
    /// Not asked yet.
    case notDetermined
    /// macOS does not let apps read it (system audio recording).
    case unknown
}

/// The state of a speech model, without comparing display strings.
public enum SpeechModelState: String, Sendable {
    case installed
    case downloading
    case notInstalled
    case unsupported
}

/// Languages offered for minutes and answers: the common ones, the current
/// choice and the transcription languages, sorted by their localized name.
public enum OutputLanguageOptions {
    public static let common = [
        "en", "es", "fr", "de", "it", "pt-BR", "pt-PT", "nl", "sv", "da", "nb", "fi", "pl", "cs", "tr", "ru", "uk",
        "el", "ar", "he", "hi", "id", "th", "vi", "ja", "ko", "zh-Hans", "zh-Hant",
    ]

    public static func identifiers(including extra: [String] = [], locale: Locale = .current) -> [String] {
        var seen = Set<String>()
        let all = (common + extra).filter { !$0.isEmpty && seen.insert($0).inserted }
        return all.sorted {
            LanguageNameSort.precedes(displayName($0, locale: locale), displayName($1, locale: locale), locale: locale)
        }
    }

    public static func displayName(_ identifier: String, locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: identifier) ?? identifier
    }
}

extension SpeechLanguageCatalog {
    /// Languages with a model on this Mac first, then by localized name.
    public func sortedForDisplay(locale: Locale = .current) -> [SpeechLanguage] {
        languages.sorted { a, b in
            if a.isInstalled != b.isInstalled { return a.isInstalled }
            let na = locale.localizedString(forIdentifier: a.id) ?? a.id
            let nb = locale.localizedString(forIdentifier: b.id) ?? b.id
            return LanguageNameSort.precedes(na, nb, locale: locale)
        }
    }
}

/// A plain-text summary for support requests. It holds versions, states and
/// counts only: never meeting titles, text, names, keys or addresses.
public struct DiagnosticsReport: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let label: String
        public let value: String

        public init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    public var appVersion: String
    public var build: String
    public var system: String
    public var entries: [Entry]

    public init(appVersion: String, build: String, system: String, entries: [Entry]) {
        self.appVersion = appVersion
        self.build = build
        self.system = system
        self.entries = entries
    }

    /// One line per entry; values are flattened to a single short line.
    public var text: String {
        var lines = ["Vauta \(appVersion) (\(build))", system]
        for entry in entries {
            let value = entry.value.split(whereSeparator: \.isNewline).joined(separator: " ")
            lines.append("- \(entry.label): \(value.prefix(Self.maxValueLength))")
        }
        return lines.joined(separator: "\n")
    }

    static let maxValueLength = 160
}
