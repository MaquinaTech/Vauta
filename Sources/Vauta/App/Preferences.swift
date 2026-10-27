// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation
import Observation

/// App-wide preferences that are not tied to recording state, backed by
/// UserDefaults. Preferences that drive recording directly (audio source,
/// auto-stop, dictation, knowledge retention) live in `RecorderModel`.
@MainActor
@Observable
final class Preferences {
    /// How long "Meetings" stays unlocked after Touch ID / password.
    enum RelockPolicy: String, CaseIterable, Identifiable, Sendable {
        case oneMinute, fiveMinutes, fifteenMinutes, thirtyMinutes, untilScreenLocks
        var id: String { rawValue }
        /// nil = no timer (locks when the screen locks or the Mac sleeps).
        var interval: TimeInterval? {
            switch self {
            case .oneMinute: 60
            case .fiveMinutes: 5 * 60
            case .fifteenMinutes: 15 * 60
            case .thirtyMinutes: 30 * 60
            case .untilScreenLocks: nil
            }
        }
    }

    /// The language of the minutes, answers and summaries.
    enum OutputLanguage: Hashable, Sendable {
        /// The meeting's transcription language.
        case sameAsMeeting
        /// A fixed BCP-47 language (e.g. "en", "es", "pt-BR").
        case fixed(String)

        var storageValue: String {
            switch self {
            case .sameAsMeeting: "same"
            case .fixed(let id): id
            }
        }

        init(storageValue: String?) {
            guard let value = storageValue, !value.isEmpty, value != "same" else { self = .sameAsMeeting; return }
            self = .fixed(value)
        }
    }

    /// A global keyboard shortcut (Carbon virtual key code + Carbon modifier
    /// mask). Stored as JSON `{"keyCode":…,"modifiers":…}`.
    typealias HotKeySpec = HotKeyCombo

    /// Default transcription language (BCP-47). nil = the best supported
    /// language among the user's preferred languages (`SpeechLanguages`).
    var transcriptionLanguage: String? {
        didSet { defaults.set(transcriptionLanguage, forKey: Keys.transcriptionLanguage) }
    }
    var outputLanguage: OutputLanguage {
        didSet { defaults.set(outputLanguage.storageValue, forKey: Keys.outputLanguage) }
    }
    /// Default minutes template id (`MinutesTemplate.rawValue`).
    var minutesTemplate: MinutesTemplate {
        didSet { defaults.set(minutesTemplate.rawValue, forKey: Keys.minutesTemplate) }
    }
    var relockPolicy: RelockPolicy {
        didSet { defaults.set(relockPolicy.rawValue, forKey: Keys.relockPolicy) }
    }
    /// Stop the recording when the screen locks (0.1.0 always did). Sleep and
    /// switching to another user always stop it: capture can't go on then.
    var stopRecordingOnScreenLock: Bool {
        didSet { defaults.set(stopRecordingOnScreenLock, forKey: Keys.stopOnScreenLock) }
    }
    /// Block copy, drag and Services on meeting text (0.1.0 always did).
    var copyProtection: Bool {
        didSet { defaults.set(copyProtection, forKey: Keys.copyProtection) }
    }
    var notifyMinutesReady: Bool {
        didSet { defaults.set(notifyMinutesReady, forKey: Keys.notifyMinutesReady) }
    }
    var notifyProblems: Bool {
        didSet { defaults.set(notifyProblems, forKey: Keys.notifyProblems) }
    }
    var recordHotKey: HotKeySpec {
        didSet { save(recordHotKey, Keys.recordHotKey) }
    }
    var markHotKey: HotKeySpec {
        didSet { save(markHotKey, Keys.markHotKey) }
    }
    /// Opens the floating notepad while recording.
    var noteHotKey: HotKeySpec {
        didSet { save(noteHotKey, Keys.noteHotKey) }
    }
    /// The notepad opens by itself when a recording starts (off by default).
    var openNotepadOnStart: Bool {
        didSet { defaults.set(openNotepadOnStart, forKey: Keys.openNotepadOnStart) }
    }
    /// Live Translation of the other participants into the user's language.
    /// On means: it starts with every recording and shows the captions panel.
    var liveTranslationEnabled: Bool {
        didSet { defaults.set(liveTranslationEnabled, forKey: Keys.liveTranslation) }
    }
    /// The language captions are translated into (BCP-47). nil = the first
    /// preferred system language that differs from the meeting language.
    var translationTarget: String? {
        didSet { defaults.set(translationTarget, forKey: Keys.translationTarget) }
    }
    var captionTextSize: CaptionTextSize {
        didSet { defaults.set(captionTextSize.rawValue, forKey: Keys.captionTextSize) }
    }
    /// A small line with the original words under each caption.
    var captionShowOriginal: Bool {
        didSet { defaults.set(captionShowOriginal, forKey: Keys.captionShowOriginal) }
    }
    /// With VoiceOver on, every finished caption is announced (the panel never takes the keyboard, so it can't be navigated live).
    var readCaptionsWithVoiceOver: Bool {
        didSet { defaults.set(readCaptionsWithVoiceOver, forKey: Keys.readCaptionsWithVoiceOver) }
    }
    /// Meetings › Transcript shows the stored translations under the lines.
    var showTranslationsInTranscript: Bool {
        didSet { defaults.set(showTranslationsInTranscript, forKey: Keys.showTranslations) }
    }
    /// The model server translates finished sentences again and replaces Apple's caption when it is in time.
    /// On by default; it only does anything while a model server is set up.
    var translationRefinementEnabled: Bool {
        didSet { defaults.set(translationRefinementEnabled, forKey: Keys.translationRefinement) }
    }
    /// The server model that refines translations; empty = the server's fast model.
    var translationModel: String {
        didSet { defaults.set(translationModel, forKey: Keys.translationModel) }
    }
    var translationHotKey: HotKeySpec {
        didSet { save(translationHotKey, Keys.translationHotKey) }
    }
    /// Separate the voices of the other participants into "Speaker 1", "Speaker 2"… while recording and when importing
    /// (on this Mac, no audio kept). On by default; a meeting can opt out on its own (`MeetingStore.setSpeakersOff`).
    var separateSpeakers: Bool {
        didSet { defaults.set(separateSpeakers, forKey: Keys.separateSpeakers) }
    }
    /// Recognize saved voices across meetings. OFF by default and only the user turns it on. Turning it off stops
    /// matching and the keeping of voice summaries; the saved voices stay until the user deletes them.
    var recognizeVoices: Bool {
        didSet { defaults.set(recognizeVoices, forKey: Keys.recognizeVoices) }
    }
    /// Voice recognition is in force: the user turned it on AND speakers are separated (nothing is matched or kept
    /// without separated speakers). Every place that matches, keeps or mentions voices asks this, never `recognizeVoices`.
    var recognizesVoices: Bool { separateSpeakers && recognizeVoices }
    /// Until when the "voices not used for a year" reminder stays quiet after the user kept them (seconds since 1970; 0 = not snoozed).
    var voiceReminderSnoozedUntil: Double {
        didSet { defaults.set(voiceReminderSnoozedUntil, forKey: Keys.voiceReminderSnoozedUntil) }
    }
    /// When the panel reminds the user to tell the other participants that the
    /// meeting is being transcribed (see `ConsentNotice`). Never blocks recording.
    var consentReminder: ConsentReminder {
        didSet { defaults.set(consentReminder.rawValue, forKey: Keys.consentReminder) }
    }
    // MARK: Live answers. See `LiveAnswerSettings`.

    /// What the person chose for "Answer questions asked in the meeting"; nil = never chosen, and the default of the model that answers
    /// while recording applies (decision D1: on only for the backends that passed the evaluation, see `LiveAnswerDefaults`).
    var liveAnswersChoice: Bool? {
        didSet {
            liveAnswersChanged?()
            if let choice = liveAnswersChoice { defaults.set(choice, forKey: Keys.liveAnswersEnabled) } else { defaults.removeObject(forKey: Keys.liveAnswersEnabled) }
        }
    }
    /// Which model answers while recording (set by the recorder, which knows the model settings).
    @ObservationIgnored var liveAnswersBackend: () -> LiveAnswerBackendKind? = { nil }
    /// Bumped by the recorder whenever the backend that answers while recording may have changed (the closure above reads state SwiftUI
    /// cannot observe), so a view that read `liveAnswersOffered` draws again.
    var liveAnswersBackendTick = 0
    private func currentLiveBackend() -> LiveAnswerBackendKind? {
        _ = liveAnswersBackendTick
        return liveAnswersBackend()
    }
    /// Answer the questions asked in the meeting, from this meeting, the past ones and the documents.
    var liveAnswersEnabled: Bool {
        get { liveAnswersChoice ?? LiveAnswerDefaults.onByDefault(currentLiveBackend()) }
        set { liveAnswersChoice = newValue }
    }
    /// Whether the model that answers while recording offers live answers at all (decision D16: not Apple's on-device model). The
    /// stored choice is kept whatever this says, so it applies again when the person goes back to a model that offers them.
    var liveAnswersOffered: Bool { LiveAnswerDefaults.offered(currentLiveBackend()) }
    /// What a recording runs with: the person's choice, and only where live answers are offered.
    var liveAnswersActive: Bool { liveAnswersOffered && liveAnswersEnabled }
    /// Whether the person has not chosen and the feature starts on for this model: the only case with a first-run hint.
    var liveAnswersOnByDefaultUnchosen: Bool {
        liveAnswersOffered && liveAnswersChoice == nil && LiveAnswerDefaults.onByDefault(currentLiveBackend())
    }
    /// `LiveAnswerSources.rawValue`.
    var liveAnswersSources: LiveAnswerSources {
        didSet { defaults.set(liveAnswersSources.rawValue, forKey: Keys.liveAnswersSources) }
    }
    var liveAnswersSensitivity: QuestionSensitivity {
        didSet { defaults.set(liveAnswersSensitivity.rawValue, forKey: Keys.liveAnswersSensitivity) }
    }
    var liveAnswersSpeakers: LiveAnswerSpeakers {
        didSet { defaults.set(liveAnswersSpeakers.rawValue, forKey: Keys.liveAnswersSpeakers) }
    }
    var liveAnswersHideAnsweredAloud: Bool {
        didSet { defaults.set(liveAnswersHideAnsweredAloud, forKey: Keys.liveAnswersHideAnsweredAloud) }
    }
    var liveAnswersKeepQuestions: Bool {
        didSet {
            defaults.set(liveAnswersKeepQuestions, forKey: Keys.liveAnswersKeepQuestions)
            liveAnswersChanged?()
        }
    }
    /// Called when the switch or "Keep detected questions" changes by any path (Settings, a restored backup), so a recording that runs
    /// follows it. Set by the recorder.
    @ObservationIgnored var liveAnswersChanged: (() -> Void)?
    /// The recordings that still owe the removal of the questions the person did not keep (see `QuestionCleanupLedger`).
    var questionCleanup: QuestionCleanupLedger { QuestionCleanupLedger(defaults: defaults) }
    /// The first-run hint was answered (it appears once, at the first recording after the feature exists). Stays on this Mac.
    var liveAnswersHintSeen: Bool {
        didSet { defaults.set(liveAnswersHintSeen, forKey: Keys.liveAnswersHintSeen) }
    }

    /// The settings the detector reads at the start of a recording.
    var liveAnswerSettings: LiveAnswerSettings {
        var s = LiveAnswerSettings()
        s.enabled = liveAnswersActive
        s.sources = liveAnswersSources
        s.sensitivity = liveAnswersSensitivity
        s.speakers = liveAnswersSpeakers
        s.hideWhenAnsweredAloud = liveAnswersHideAnsweredAloud
        s.keepDetectedQuestions = liveAnswersKeepQuestions
        // Hidden (no control in Settings): `defaults write <bundle id> liveAnswersModelCheck -bool NO` turns the model check off.
        s.modelCheck = defaults.object(forKey: Keys.liveAnswersModelCheck) as? Bool ?? true
        return s
    }

    /// The onboarding version the user finished (0 = never).
    var onboardingCompletedVersion: Int {
        didSet { defaults.set(onboardingCompletedVersion, forKey: Keys.onboardingVersion) }
    }

    static let currentOnboardingVersion = 1
    var needsOnboarding: Bool { onboardingCompletedVersion < Self.currentOnboardingVersion }

    /// ⌃⌥R and ⌃⌥M on the ANSI layout (kVK_ANSI_R = 15, kVK_ANSI_M = 46;
    /// controlKey | optionKey = 0x1000 | 0x0800).
    static let defaultRecordHotKey = HotKeySpec(keyCode: 15, modifiers: 0x1800)
    static let defaultMarkHotKey = HotKeySpec(keyCode: 46, modifiers: 0x1800)
    /// ⌃⌥N on the ANSI layout (kVK_ANSI_N = 45).
    static let defaultNoteHotKey = HotKeySpec(keyCode: 45, modifiers: 0x1800)
    /// ⌃⌥T on the ANSI layout (kVK_ANSI_T = 17).
    static let defaultTranslationHotKey = HotKeySpec(keyCode: 17, modifiers: 0x1800)

    /// What Vauta does after a meeting: default list and calendar, the alert, the card in the panel and the email choices.
    let actions: ActionsPreferences

    @ObservationIgnored private let defaults: UserDefaults

    /// - Parameter legacyInstall: an encrypted store from the earlier version existed
    ///   before these preferences were first written. Existing users keep the
    ///   0.1 behaviour (Spanish transcription, copy protection on, no onboarding).
    init(defaults: UserDefaults = .standard, legacyInstall: Bool) {
        self.defaults = defaults
        actions = ActionsPreferences(defaults: defaults)
        // 0 = never written (0.1 or a new install); 1 = development builds
        // that didn't pin the transcription language yet.
        let version = defaults.integer(forKey: Keys.preferencesVersion)
        if version == 0, legacyInstall {
            defaults.set(true, forKey: Keys.copyProtection)
            defaults.set(Self.currentOnboardingVersion, forKey: Keys.onboardingVersion)
        }
        if version < 2, legacyInstall, defaults.string(forKey: Keys.transcriptionLanguage) == nil {
            // 0.1 always transcribed in Spanish: keep it explicit (and
            // changeable) instead of switching to the system language.
            defaults.set(MeetingStore.Meeting.legacyLocaleIdentifier, forKey: Keys.transcriptionLanguage)
        }
        if version < 2 { defaults.set(2, forKey: Keys.preferencesVersion) }
        transcriptionLanguage = defaults.string(forKey: Keys.transcriptionLanguage)
        outputLanguage = OutputLanguage(storageValue: defaults.string(forKey: Keys.outputLanguage))
        minutesTemplate = defaults.string(forKey: Keys.minutesTemplate).flatMap(MinutesTemplate.init(rawValue:)) ?? .general
        relockPolicy = defaults.string(forKey: Keys.relockPolicy).flatMap(RelockPolicy.init(rawValue:)) ?? .fiveMinutes
        stopRecordingOnScreenLock = defaults.object(forKey: Keys.stopOnScreenLock) as? Bool ?? true
        copyProtection = defaults.bool(forKey: Keys.copyProtection)
        notifyMinutesReady = defaults.object(forKey: Keys.notifyMinutesReady) as? Bool ?? true
        notifyProblems = defaults.object(forKey: Keys.notifyProblems) as? Bool ?? true
        recordHotKey = Self.load(defaults, Keys.recordHotKey) ?? Self.defaultRecordHotKey
        markHotKey = Self.load(defaults, Keys.markHotKey) ?? Self.defaultMarkHotKey
        noteHotKey = Self.load(defaults, Keys.noteHotKey) ?? Self.defaultNoteHotKey
        openNotepadOnStart = defaults.bool(forKey: Keys.openNotepadOnStart)
        liveTranslationEnabled = defaults.bool(forKey: Keys.liveTranslation)
        translationTarget = defaults.string(forKey: Keys.translationTarget)
        captionTextSize = defaults.string(forKey: Keys.captionTextSize).flatMap(CaptionTextSize.init(rawValue:)) ?? .medium
        captionShowOriginal = defaults.bool(forKey: Keys.captionShowOriginal)
        readCaptionsWithVoiceOver = defaults.object(forKey: Keys.readCaptionsWithVoiceOver) as? Bool ?? true
        showTranslationsInTranscript = defaults.object(forKey: Keys.showTranslations) as? Bool ?? true
        translationRefinementEnabled = defaults.object(forKey: Keys.translationRefinement) as? Bool ?? true
        translationModel = defaults.string(forKey: Keys.translationModel) ?? ""
        translationHotKey = Self.load(defaults, Keys.translationHotKey) ?? Self.defaultTranslationHotKey
        separateSpeakers = defaults.object(forKey: Keys.separateSpeakers) as? Bool ?? true
        recognizeVoices = defaults.object(forKey: Keys.recognizeVoices) as? Bool ?? false
        voiceReminderSnoozedUntil = defaults.double(forKey: Keys.voiceReminderSnoozedUntil)
        consentReminder = defaults.string(forKey: Keys.consentReminder).flatMap(ConsentReminder.init(rawValue:)) ?? .default
        onboardingCompletedVersion = defaults.integer(forKey: Keys.onboardingVersion)
        let defaultAnswers = LiveAnswerSettings()
        liveAnswersChoice = defaults.object(forKey: Keys.liveAnswersEnabled) as? Bool
        liveAnswersSources = Self.sources(defaults.object(forKey: Keys.liveAnswersSources) as? Int, default: defaultAnswers.sources)
        liveAnswersSensitivity = defaults.string(forKey: Keys.liveAnswersSensitivity).flatMap(QuestionSensitivity.init(rawValue:)) ?? defaultAnswers.sensitivity
        liveAnswersSpeakers = defaults.string(forKey: Keys.liveAnswersSpeakers).flatMap(LiveAnswerSpeakers.init(rawValue:)) ?? defaultAnswers.speakers
        liveAnswersHideAnsweredAloud = defaults.object(forKey: Keys.liveAnswersHideAnsweredAloud) as? Bool ?? defaultAnswers.hideWhenAnsweredAloud
        liveAnswersKeepQuestions = defaults.object(forKey: Keys.liveAnswersKeepQuestions) as? Bool ?? defaultAnswers.keepDetectedQuestions
        liveAnswersHintSeen = defaults.bool(forKey: Keys.liveAnswersHintSeen)
    }

    private static func sources(_ raw: Int?, default fallback: LiveAnswerSources) -> LiveAnswerSources {
        guard let raw else { return fallback }
        return LiveAnswerSources(rawValue: raw).intersection(.all)
    }

    /// Reads every preference from UserDefaults again, after a restore wrote the settings of a backup there. Only what
    /// changed is assigned, so the observers (shortcuts, relock) run once and only for what is different. The onboarding
    /// marker is this Mac's own and stays as it is.
    func reloadFromDefaults() {
        func update<T: Equatable>(_ path: ReferenceWritableKeyPath<Preferences, T>, _ value: T) {
            if self[keyPath: path] != value { self[keyPath: path] = value }
        }
        update(\.transcriptionLanguage, defaults.string(forKey: Keys.transcriptionLanguage))
        update(\.outputLanguage, OutputLanguage(storageValue: defaults.string(forKey: Keys.outputLanguage)))
        update(\.minutesTemplate, defaults.string(forKey: Keys.minutesTemplate).flatMap(MinutesTemplate.init(rawValue:)) ?? .general)
        update(\.relockPolicy, defaults.string(forKey: Keys.relockPolicy).flatMap(RelockPolicy.init(rawValue:)) ?? .fiveMinutes)
        update(\.stopRecordingOnScreenLock, defaults.object(forKey: Keys.stopOnScreenLock) as? Bool ?? true)
        update(\.copyProtection, defaults.bool(forKey: Keys.copyProtection))
        update(\.notifyMinutesReady, defaults.object(forKey: Keys.notifyMinutesReady) as? Bool ?? true)
        update(\.notifyProblems, defaults.object(forKey: Keys.notifyProblems) as? Bool ?? true)
        update(\.recordHotKey, Self.load(defaults, Keys.recordHotKey) ?? Self.defaultRecordHotKey)
        update(\.markHotKey, Self.load(defaults, Keys.markHotKey) ?? Self.defaultMarkHotKey)
        update(\.noteHotKey, Self.load(defaults, Keys.noteHotKey) ?? Self.defaultNoteHotKey)
        update(\.openNotepadOnStart, defaults.bool(forKey: Keys.openNotepadOnStart))
        update(\.liveTranslationEnabled, defaults.bool(forKey: Keys.liveTranslation))
        update(\.translationTarget, defaults.string(forKey: Keys.translationTarget))
        update(\.captionTextSize, defaults.string(forKey: Keys.captionTextSize).flatMap(CaptionTextSize.init(rawValue:)) ?? .medium)
        update(\.captionShowOriginal, defaults.bool(forKey: Keys.captionShowOriginal))
        update(\.readCaptionsWithVoiceOver, defaults.object(forKey: Keys.readCaptionsWithVoiceOver) as? Bool ?? true)
        update(\.showTranslationsInTranscript, defaults.object(forKey: Keys.showTranslations) as? Bool ?? true)
        update(\.translationRefinementEnabled, defaults.object(forKey: Keys.translationRefinement) as? Bool ?? true)
        update(\.translationModel, defaults.string(forKey: Keys.translationModel) ?? "")
        update(\.translationHotKey, Self.load(defaults, Keys.translationHotKey) ?? Self.defaultTranslationHotKey)
        update(\.separateSpeakers, defaults.object(forKey: Keys.separateSpeakers) as? Bool ?? true)
        update(\.recognizeVoices, defaults.object(forKey: Keys.recognizeVoices) as? Bool ?? false)
        update(\.voiceReminderSnoozedUntil, defaults.double(forKey: Keys.voiceReminderSnoozedUntil))
        update(\.consentReminder, defaults.string(forKey: Keys.consentReminder).flatMap(ConsentReminder.init(rawValue:)) ?? .default)
        let defaultAnswers = LiveAnswerSettings()
        update(\.liveAnswersChoice, defaults.object(forKey: Keys.liveAnswersEnabled) as? Bool)
        update(\.liveAnswersSources, Self.sources(defaults.object(forKey: Keys.liveAnswersSources) as? Int, default: defaultAnswers.sources))
        update(\.liveAnswersSensitivity, defaults.string(forKey: Keys.liveAnswersSensitivity).flatMap(QuestionSensitivity.init(rawValue:)) ?? defaultAnswers.sensitivity)
        update(\.liveAnswersSpeakers, defaults.string(forKey: Keys.liveAnswersSpeakers).flatMap(LiveAnswerSpeakers.init(rawValue:)) ?? defaultAnswers.speakers)
        update(\.liveAnswersHideAnsweredAloud, defaults.object(forKey: Keys.liveAnswersHideAnsweredAloud) as? Bool ?? defaultAnswers.hideWhenAnsweredAloud)
        update(\.liveAnswersKeepQuestions, defaults.object(forKey: Keys.liveAnswersKeepQuestions) as? Bool ?? defaultAnswers.keepDetectedQuestions)
        actions.reload()
    }

    private func save(_ spec: HotKeySpec, _ key: String) {
        defaults.set(try? JSONEncoder().encode(spec), forKey: key)
    }

    private static func load(_ defaults: UserDefaults, _ key: String) -> HotKeySpec? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(HotKeySpec.self, from: $0) }
    }

    /// The keys a backup carries are listed in `BackupPreferences.allowed` (VautaCore): add a key there too if it
    /// should travel to another Mac.
    enum Keys {
        static let preferencesVersion = "preferencesVersion"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let outputLanguage = "outputLanguage"
        static let minutesTemplate = "minutesTemplate"
        static let relockPolicy = "historyRelockPolicy"
        static let stopOnScreenLock = "stopRecordingOnScreenLock"
        static let copyProtection = "copyProtection"
        static let notifyMinutesReady = "notifyMinutesReady"
        static let notifyProblems = "notifyProblems"
        static let recordHotKey = "recordHotKey"
        static let markHotKey = "markHotKey"
        static let noteHotKey = "noteHotKey"
        static let openNotepadOnStart = "openNotepadOnStart"
        static let onboardingVersion = "onboardingCompletedVersion"
        static let liveTranslation = "liveTranslationEnabled"
        static let translationTarget = "translationTarget"
        static let captionTextSize = "captionTextSize"
        static let captionShowOriginal = "captionShowOriginal"
        static let showTranslations = "showTranslationsInTranscript"
        static let readCaptionsWithVoiceOver = "readCaptionsWithVoiceOver"
        static let translationRefinement = "translationRefinementEnabled"
        static let translationModel = "translationModel"
        static let translationHotKey = "translationHotKey"
        static let consentReminder = "consentReminder"
        static let separateSpeakers = "separateSpeakers"
        static let recognizeVoices = "recognizeVoices"
        static let voiceReminderSnoozedUntil = "voiceReminderSnoozedUntil"
        static let liveAnswersEnabled = "liveAnswersEnabled"
        static let liveAnswersSources = "liveAnswersSources"
        static let liveAnswersSensitivity = "liveAnswersSensitivity"
        static let liveAnswersSpeakers = "liveAnswersSpeakers"
        static let liveAnswersHideAnsweredAloud = "liveAnswersHideAnsweredAloud"
        static let liveAnswersKeepQuestions = "liveAnswersKeepQuestions"
        static let liveAnswersHintSeen = "liveAnswersHintSeen"
        static let liveAnswersModelCheck = "liveAnswersModelCheck"
    }
}
