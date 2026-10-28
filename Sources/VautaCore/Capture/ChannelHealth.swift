// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// State of one channel while recording, for warnings in the UI.
public enum ChannelHealth: Sendable, Equatable {
    case ok
    /// Transcription fell behind and some audio was dropped.
    case lagging
    /// The audio device changed or stalled; capture is being rebuilt.
    case reconnecting
    /// Capture gave up after repeated attempts (a later device change retries; the microphone also keeps trying
    /// every few seconds).
    case lost(CaptureError)
    /// The analyzer failed: the channel no longer transcribes.
    case failed(CaptureError)

    /// Higher is worse; used to merge the device and transcriber states.
    var severity: Int {
        switch self {
        case .ok: 0
        case .lagging: 1
        case .reconnecting: 2
        case .lost: 3
        case .failed: 4
        }
    }

    /// Localized warning for `channel`, or nil when healthy.
    public func message(for channel: Channel) -> String? {
        let name = channel.displayName
        switch self {
        case .ok:
            return nil
        case .lagging:
            return String(localized: "Transcription of “\(name)” is lagging and some audio was lost.",
                          comment: "Channel warning while recording; the argument is the channel name")
        case .reconnecting:
            return switch channel {
            case .me: String(localized: "Reconnecting the microphone…", comment: "Channel warning while recording")
            case .others: String(localized: "Reconnecting system audio…", comment: "Channel warning while recording")
            }
        case .lost(let error):
            return error.description
        case .failed(let error):
            let reason = error.failureReason ?? error.errorDescription ?? ""
            return String(localized: "The “\(name)” channel stopped transcribing (\(reason)).",
                          comment: "Channel warning while recording; arguments are the channel name and the technical reason")
        }
    }
}

/// Merges the health reported by a channel's audio device and by its
/// transcriber, and reports only changes of the combined (worst) state.
/// Without this, a transcriber recovering from a lag would clear a device
/// warning that is still current, and vice versa.
struct ChannelHealthTracker {
    enum Source: Hashable { case device, transcriber }

    private var states: [Channel: [Source: ChannelHealth]] = [:]
    private var published: [Channel: ChannelHealth] = [:]

    /// Returns the new combined state of `channel` if it changed.
    mutating func update(_ health: ChannelHealth, for channel: Channel, from source: Source) -> ChannelHealth? {
        states[channel, default: [:]][source] = health
        let combined = states[channel, default: [:]].values.max { $0.severity < $1.severity } ?? .ok
        guard combined != published[channel, default: .ok] else { return nil }
        published[channel] = combined
        return combined
    }
}
