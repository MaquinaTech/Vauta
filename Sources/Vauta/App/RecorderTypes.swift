// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// "Transcribe this meeting?": a call in progress and, if any, its calendar event.
struct RecordingSuggestion: Equatable {
    let event: CalendarEventMatch?
    let call: CallDescription
    /// The person asked for it in the brief's notification ("Record at Start"): the event is starting, no call was detected.
    var scheduled = false
    var title: String { event?.meeting.title ?? "" }

    /// What the banner and the notification say for a suggestion nobody detected a call for.
    static var scheduledSentence: String {
        String(localized: "You asked to be reminded to record it.", comment: "Panel banner and notification text: the person pressed Record at Start in the brief notification and the meeting is starting; Vauta only asks, it does not record by itself")
    }
}

/// A speech model a recording needs and that isn't installed.
struct MissingSpeechModel: Equatable {
    let language: SpeechLanguage
    let engines: [SpeechEngineKind]
}

/// A System Settings privacy pane the user must visit to grant a permission.
enum SystemPrivacyPane: Equatable {
    case microphone
    case systemAudio

    init?(for error: Error) {
        guard let capture = error as? CaptureError else { return nil }
        switch capture.code {
        case .microphonePermissionDenied: self = .microphone
        case .systemAudioTapFailed, .systemAudioStartFailed: self = .systemAudio
        default: return nil
        }
    }

    var url: URL {
        switch self {
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .systemAudio: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

/// Windows the diarizer has analysed and the recorder has not queued for the store yet. The diarizer adds from its
/// own queue; the recorder takes on the main actor.
final class WindowSpool: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [Diarizer.SinkWindow] = []

    func add(_ batch: [Diarizer.SinkWindow]) { lock.withLock { windows += batch } }

    func take() -> [Diarizer.SinkWindow] {
        lock.withLock {
            defer { windows = [] }
            return windows
        }
    }
}
