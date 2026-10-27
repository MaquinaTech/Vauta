// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreAudio
import Foundation

/// An error from audio capture or on-device transcription.
///
/// `code` is stable and safe to persist or branch on; the text is localized
/// when it is read. Interpolating the error (`"\(error)"`) yields the
/// description followed by the recovery suggestion.
public struct CaptureError: LocalizedError, CustomStringConvertible, Equatable, Sendable {
    public enum Code: String, Sendable, Codable, CaseIterable {
        case noMicrophone
        case microphonePermissionDenied
        case microphoneStartFailed
        case microphoneLost
        case noOutputDevice
        case audioDeviceQueryFailed
        case systemAudioTapFailed
        case systemAudioDeviceFailed
        case systemAudioStartFailed
        case systemAudioFormatUnavailable
        case systemAudioLost
        case speechUnavailable
        case localeUnsupported
        case speechModelMissing
        case dictationModelMissing
        case analyzerFormatUnavailable
        case languageLimitReached
        case transcriptionStopped
        case finishFailed
    }

    public let code: Code
    /// Core Audio status, when the failure came from a Core Audio call.
    public let status: OSStatus?
    /// BCP-47 identifier of the language involved, if any.
    public let localeIdentifier: String?
    /// Channels involved (for `finishFailed`).
    public let channels: [Channel]
    /// Description of an underlying error, for diagnostics.
    public let detail: String?

    public init(_ code: Code, status: OSStatus? = nil, localeIdentifier: String? = nil,
                channels: [Channel] = [], detail: String? = nil) {
        self.code = code
        self.status = status
        self.localeIdentifier = localeIdentifier
        self.channels = channels
        self.detail = detail
    }

    init(_ code: Code, locale: Locale) {
        self.init(code, localeIdentifier: locale.identifier(.bcp47))
    }

    /// The sentence for a microphone that is not allowed wherever no button sits next to it: Settings → Status, setup,
    /// the notification and the VoiceOver announcement. It names System Settings, because Vauta has a Settings pane
    /// called "Privacy & Security" too.
    public static var microphoneDeniedMessage: String {
        String(localized: "Vauta can’t hear you. Turn on Vauta in System Settings\u{00A0}→\u{00A0}Privacy & Security\u{00A0}→\u{00A0}Microphone.",
               comment: "Microphone not allowed, with the full path in System Settings")
    }

    /// The short form, only for the menu-bar panel banner, where the "Open System Settings" button is beside it.
    public static var microphoneDeniedPanelMessage: String {
        String(localized: "Vauta can’t hear you. Turn on Vauta in Privacy & Security\u{00A0}→\u{00A0}Microphone.", comment: "Status detail")
    }

    /// The recovery for a system-audio capture that failed, only for the menu-bar panel banner, where the
    /// "Open System Settings" button is beside it. Elsewhere `recoverySuggestion` names System Settings too.
    public static var systemAudioDeniedPanelMessage: String {
        String(localized: "Turn on Vauta in Privacy & Security\u{00A0}→\u{00A0}Screen & System Audio Recording.",
               comment: "Capture error recovery in the menu-bar panel, next to the Open System Settings button")
    }

    public var errorDescription: String? {
        let language = languageName
        switch code {
        case .noMicrophone:
            return String(localized: "No microphone is available.", comment: "Capture error")
        case .microphonePermissionDenied:
            return String(localized: "Vauta doesn’t have permission to use the microphone.", comment: "Capture error")
        case .microphoneStartFailed:
            return String(localized: "The microphone couldn’t be started.", comment: "Capture error")
        case .microphoneLost:
            return String(localized: "The microphone isn’t responding.", comment: "Capture error while recording")
        case .noOutputDevice:
            return String(localized: "There is no audio output device.", comment: "Capture error")
        case .audioDeviceQueryFailed:
            return String(localized: "The audio devices couldn’t be read.", comment: "Capture error")
        case .systemAudioTapFailed:
            return String(localized: "System audio capture couldn’t be created.", comment: "Capture error")
        case .systemAudioDeviceFailed:
            return String(localized: "The system audio capture device couldn’t be set up.", comment: "Capture error")
        case .systemAudioStartFailed:
            return String(localized: "System audio capture couldn’t be started.", comment: "Capture error")
        case .systemAudioFormatUnavailable:
            return String(localized: "The system audio format couldn’t be read.", comment: "Capture error")
        case .systemAudioLost:
            return String(localized: "No system audio is arriving.", comment: "Capture error while recording")
        case .speechUnavailable:
            return String(localized: "On-device speech recognition isn’t available on this Mac.", comment: "Capture error")
        case .localeUnsupported:
            return String(localized: "Speech recognition doesn’t support \(language) on this Mac.",
                          comment: "Capture error; the argument is a language name")
        case .speechModelMissing:
            return String(localized: "The speech model for \(language) isn’t installed.",
                          comment: "Capture error; the argument is a language name")
        case .dictationModelMissing:
            return String(localized: "The dictation model for \(language) isn’t installed.",
                          comment: "Capture error; the argument is a language name")
        case .analyzerFormatUnavailable:
            return String(localized: "The speech recognizer offers no audio format for \(language).",
                          comment: "Capture error; the argument is a language name")
        case .languageLimitReached:
            return String(localized: "No more transcription languages can be kept ready, so \(language) can’t be added.",
                          comment: "Capture error; the argument is a language name")
        case .transcriptionStopped:
            return String(localized: "Transcription stopped unexpectedly.", comment: "Capture error while recording")
        case .finishFailed:
            let names = ListFormatter.localizedString(byJoining: channels.map(\.displayName))
            return String(localized: "The end of the transcript for \(names) may be missing.",
                          comment: "Capture error at stop; the argument is a list of channel names")
        }
    }

    public var failureReason: String? {
        if let status {
            return String(localized: "Core Audio error \(Int(status)).", comment: "Technical detail of a capture error")
        }
        return detail
    }

    public var recoverySuggestion: String? {
        switch code {
        case .noMicrophone:
            String(localized: "Connect a microphone or open the laptop lid.", comment: "Capture error recovery")
        case .microphonePermissionDenied:
            String(localized: "Turn on Vauta in System Settings\u{00A0}→\u{00A0}Privacy & Security\u{00A0}→\u{00A0}Microphone.", comment: "Capture error recovery")
        case .microphoneLost, .microphoneStartFailed:
            String(localized: "Check the audio input in System Settings\u{00A0}→\u{00A0}Sound.", comment: "Capture error recovery")
        case .noOutputDevice, .systemAudioLost, .systemAudioDeviceFailed:
            String(localized: "Check the audio output in System Settings\u{00A0}→\u{00A0}Sound.", comment: "Capture error recovery")
        case .systemAudioTapFailed, .systemAudioStartFailed:
            String(localized: "Turn on Vauta in System Settings\u{00A0}→\u{00A0}Privacy & Security\u{00A0}→\u{00A0}Screen & System Audio Recording.",
                   comment: "Capture error recovery, with the full path in System Settings")
        case .speechModelMissing, .dictationModelMissing:
            String(localized: "Download it in Vauta’s settings. It downloads once from Apple.", comment: "Capture error recovery")
        case .localeUnsupported:
            String(localized: "Choose another transcription language.", comment: "Capture error recovery")
        case .languageLimitReached:
            String(localized: "Remove a language you no longer use, then try again.", comment: "Capture error recovery")
        default:
            nil
        }
    }

    public var description: String {
        [errorDescription, recoverySuggestion].compactMap { $0 }.joinedAsSentences()
    }

    private var languageName: String {
        guard let id = localeIdentifier else { return "" }
        return Locale.current.localizedString(forIdentifier: id) ?? id
    }
}

/// Throws `CaptureError(code, status:)` when a Core Audio call fails.
func check(_ status: OSStatus, _ code: CaptureError.Code) throws {
    guard status == noErr else { throw CaptureError(code, status: status) }
}
