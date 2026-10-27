// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What the Mac is doing, as far as indexing cares.
public struct IndexerEnvironment: Sendable, Equatable {
    public var isRecording = false
    /// When the last recording stopped (indexing waits two minutes after it).
    public var recordingStoppedAt: Date?
    public var lowPowerMode = false
    public var thermalState: ProcessInfo.ThermalState = .nominal
    public var onBattery = false

    public init(isRecording: Bool = false, recordingStoppedAt: Date? = nil, lowPowerMode: Bool = false,
                thermalState: ProcessInfo.ThermalState = .nominal, onBattery: Bool = false) {
        self.isRecording = isRecording
        self.recordingStoppedAt = recordingStoppedAt
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
        self.onBattery = onBattery
    }
}

/// When indexing may run, as a pure rule.
///
/// 1. Never while a meeting is recorded (capture and transcription come first), and not for two minutes after it stops.
/// 2. Not in Low Power Mode, and not when the Mac is hot (thermal state serious or worse).
/// 3. On battery only the reading of text goes on; OCR and embeddings wait for the charger, and so do sources on network volumes.
public struct IndexerPolicy: Sendable, Equatable {
    public enum PauseReason: String, Sendable, Equatable {
        case recording, lowPower, thermal
    }

    public var text = true
    public var ocr = true
    public var embeddings = true
    /// Sources on a network volume (SMB, AFP) are scanned and read.
    public var network = true
    public var pause: PauseReason?

    public static let resumeDelay: TimeInterval = 120

    public static func decide(_ env: IndexerEnvironment, now: Date = .now) -> IndexerPolicy {
        var policy = IndexerPolicy()
        func stop(_ reason: PauseReason) -> IndexerPolicy {
            policy.text = false; policy.ocr = false; policy.embeddings = false; policy.network = false; policy.pause = reason
            return policy
        }
        if env.isRecording { return stop(.recording) }
        if let stopped = env.recordingStoppedAt, now.timeIntervalSince(stopped) < resumeDelay { return stop(.recording) }
        if env.lowPowerMode { return stop(.lowPower) }
        if env.thermalState == .serious || env.thermalState == .critical { return stop(.thermal) }
        if env.onBattery { policy.ocr = false; policy.embeddings = false; policy.network = false }
        return policy
    }
}
