// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The audio channel a transcript segment came from. Channels tell the user
/// from everyone else: the microphone is the user, the captured system/app
/// audio is everyone else. The speakers inside Others come from speaker
/// separation (`SpeakerTag`).
///
/// Logic and UI compare channels, never labels.
public enum Channel: String, Sendable, CaseIterable, Codable, Hashable {
    /// The microphone: the user.
    case me
    /// Captured system or meeting-app audio: the other participants.
    case others

    /// Maps the value stored in `segments.speaker`. Current rows hold the stored
    /// code (`"me"`, `"others"`); stores written by 0.1.0 hold the old Spanish
    /// labels (`"Yo"`, `"Otros"`). Anything unknown is treated as `.others`.
    public init(storedSpeaker: String) {
        switch storedSpeaker {
        case "me", "Yo": self = .me
        default: self = .others
        }
    }

    /// The value persisted in `segments.speaker`.
    public var storedCode: String { rawValue }

    /// Localized name shown in the UI.
    public var displayName: String {
        switch self {
        case .me: String(localized: "Me", comment: "Transcript channel: the user's microphone")
        case .others: String(localized: "Others", comment: "Transcript channel: the other meeting participants (system audio)")
        }
    }

    /// Label used in model prompt lines and in the text of embedding chunks.
    /// English, like the prompts, whatever the UI or meeting language.
    public var promptLabel: String {
        switch self {
        case .me: "Me"
        case .others: "Others"
        }
    }
}
