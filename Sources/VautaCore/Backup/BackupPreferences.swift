// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The user's settings that travel inside a backup (inside the encrypted payload, never in the clear).
///
/// Only the keys in `allowed` are read, written and applied, each with the type it must have: a key that is
/// missing, of another type or too large is skipped, never an error. Everything else in UserDefaults stays out on
/// purpose:
///
/// - secrets: the server key, address, certificate authority and pins live in the Keychain and are never read here;
/// - what belongs to this Mac or this session: the window and caption panel frames, the last Settings pane, the
///   onboarding and preferences version markers, the calendar switch and chosen calendars (they need this Mac's
///   permission and identifiers), dismissed hints, the last export choices, the recording being recorded and the
///   speech-model reservations;
/// - what belongs to the server, which is not restored: the model chosen to refine translations is one of its models.
public struct BackupPreferences: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case string(String)
        case bool(Bool)
        case int(Int)
        case data(Data)
    }

    enum Kind { case string, bool, int, data }

    /// The keys of `Preferences.Keys`, `RecorderModel`, `ModelProviderSettings`, `SystemAudioScope` and `CalendarWatcher`
    /// that a backup carries. A new setting is added here on purpose, or it stays out.
    static let allowed: [String: Kind] = [
        // Languages, template and notifications
        "transcriptionLanguage": .string, "outputLanguage": .string, "minutesTemplate": .string,
        "notifyMinutesReady": .bool, "notifyProblems": .bool, "calendarTitleInNotifications": .bool,
        // Privacy
        "historyRelockPolicy": .string, "stopRecordingOnScreenLock": .bool, "copyProtection": .bool,
        "consentReminder": .string, "knowledgeRetentionDays": .int,
        // Shortcuts (JSON of the key code and modifiers)
        "recordHotKey": .data, "markHotKey": .data, "translationHotKey": .data, "noteHotKey": .data,
        "pauseHotKey": .data,
        // The notepad opens by itself when a recording starts
        "openNotepadOnStart": .bool,
        // The meeting companion opens with each recording, and shows its details
        "showsCompanion": .bool, "companionShowsDetails": .bool,
        // Live Translation
        "liveTranslationEnabled": .bool, "translationTarget": .string, "captionTextSize": .string,
        "captionShowOriginal": .bool, "showTranslationsInTranscript": .bool, "readCaptionsWithVoiceOver": .bool,
        // Not `translationModel`: it names a model of the server, which stays out with the server.
        "translationRefinementEnabled": .bool,
        // Recording
        "systemAudioScope": .string, "captureAllSystemAudio": .bool, "autoStopMinutes": .int,
        "dictationMe": .bool, "dictationOthers": .bool, "noSafariCallSuggestion": .bool,
        "separateSpeakers": .bool,
        // Live answers to the questions asked in the meeting (not the hint marker: it belongs to this Mac)
        "liveAnswersEnabled": .bool, "liveAnswersSources": .int, "liveAnswersSensitivity": .string, "liveAnswersSpeakers": .string,
        "liveAnswersHideAnsweredAloud": .bool, "liveAnswersKeepQuestions": .bool,
        // The pre-meeting brief (not the reminder switch and lists, nor the hint marker: they belong to this Mac's permission and identifiers)
        "briefEnabled": .bool, "briefLeadMinutes": .int, "briefInPersonEvents": .bool, "briefReadInvitationNotes": .bool,
        // After meetings: alert time, notes, the panel card and the email choices (not the list and calendar identifiers, nor the
        // notice marker: they belong to this Mac's accounts)
        "actionsAlertMinute": .int, "actionsIncludeMeetingName": .bool, "followUpCardEnabled": .bool, "followUpEmailMode": .string,
        "followUpEmailSummary": .bool, "followUpEmailOpenQuestions": .bool, "followUpEmailUnconfirmed": .bool,
        // Whether saved voices are used. The voices themselves are in the encrypted store and its backup, not here.
        "recognizeVoices": .bool,
        // Where the models run (not the server: its address, models and key are in the Keychain)
        "modelProviderChat": .string, "modelProviderEmbeddings": .string,
    ]

    private static let payloadVersion = 1
    private static let maximumTextBytes = 512
    private static let maximumDataBytes = 4096
    /// An encoded set of settings is a few KB; a bigger one is not read.
    static let maximumEncodedBytes = 256 * 1024

    public private(set) var values: [String: Value]

    public var isEmpty: Bool { values.isEmpty }

    public init(values: [String: Value] = [:]) {
        self.values = values.filter { Self.accepts($0.value, for: $0.key) }
    }

    /// The allowed settings that are set in `defaults` (an unset key is not included, so a restore leaves it alone).
    public init(from defaults: UserDefaults) {
        var found: [String: Value] = [:]
        for key in Self.allowed.keys {
            if let object = defaults.object(forKey: key), let value = Self.value(of: object, for: key) { found[key] = value }
        }
        values = found
    }

    /// Writes the settings to `defaults`; returns how many were applied.
    @discardableResult
    public func apply(to defaults: UserDefaults) -> Int {
        for (key, value) in values {
            switch value {
            case .string(let v): defaults.set(v, forKey: key)
            case .bool(let v): defaults.set(v, forKey: key)
            case .int(let v): defaults.set(v, forKey: key)
            case .data(let v): defaults.set(v, forKey: key)
            }
        }
        return values.count
    }

    // MARK: Encoding

    /// A binary property list: `{version, values: {key: value}}`. Nil when there is nothing to carry.
    public func encoded() -> Data? {
        guard !values.isEmpty else { return nil }
        let plain: [String: Any] = values.mapValues { value in
            switch value {
            case .string(let v): v as Any
            case .bool(let v): v as Any
            case .int(let v): v as Any
            case .data(let v): v as Any
            }
        }
        return try? PropertyListSerialization.data(fromPropertyList: ["version": Self.payloadVersion, "values": plain], format: .binary, options: 0)
    }

    /// Reads settings written by `encoded()`. A payload that can't be read gives no settings; a key that is unknown,
    /// of the wrong type or too large is skipped and the rest are kept.
    public init(decoding data: Data) {
        guard data.count <= Self.maximumEncodedBytes,
              let root = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any],
              let stored = root["values"] as? [String: Any] else {
            values = [:]
            return
        }
        var found: [String: Value] = [:]
        for (key, object) in stored {
            if let value = Self.value(of: object, for: key) { found[key] = value }
        }
        values = found
    }

    // MARK: Checks

    /// The value of a property-list object if `key` is allowed and the object has its type and a sane size.
    private static func value(of object: Any, for key: String) -> Value? {
        guard let kind = allowed[key] else { return nil }
        switch kind {
        case .string:
            guard let text = object as? String, text.utf8.count <= maximumTextBytes else { return nil }
            return .string(text)
        case .bool:
            // A number is not a Bool: only a real boolean counts.
            guard CFGetTypeID(object as AnyObject) == CFBooleanGetTypeID(), let flag = object as? Bool else { return nil }
            return .bool(flag)
        case .int:
            guard let value = object as? NSNumber, CFGetTypeID(value) == CFNumberGetTypeID(), !CFNumberIsFloatType(value),
                  let number = object as? Int else { return nil }
            return .int(number)
        case .data:
            guard let bytes = object as? Data, bytes.count <= maximumDataBytes else { return nil }
            return .data(bytes)
        }
    }

    private static func accepts(_ value: Value, for key: String) -> Bool {
        guard let kind = allowed[key] else { return false }
        switch (kind, value) {
        case (.string, .string(let v)): return v.utf8.count <= maximumTextBytes
        case (.bool, .bool), (.int, .int): return true
        case (.data, .data(let v)): return v.count <= maximumDataBytes
        default: return false
        }
    }
}
