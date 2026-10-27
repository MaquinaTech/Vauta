// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What Settings shows about the search model: a value pushed by `SearchModelController`, like `DocumentsSnapshot`.
public struct SearchModelStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case notInstalled
        /// No Apple silicon GPU, or the kernel self-test failed in this build.
        case unsupported(SearchModelUnavailableReason)
        case downloading(received: Int, total: Int, phase: SearchModelProgress.Phase)
        /// A recording is going on (or ended less than two minutes ago): the download continues by itself afterwards.
        case pausedForRecording(received: Int, total: Int)
        /// Stopped (cancelled, quit or failed) with verified blocks on disk; Resume continues from them.
        case partial(verified: Int, total: Int)
        /// One of the two files was imported (verified and staged); the other is still needed: chosen from a file or downloaded alone.
        case needsFile(missing: MissingPart)
        case verifying
        /// First load and kernel warm-up (about 2 s once per install or OS update).
        case preparing
        case ready
        /// Installed, but a file no longer matches what Vauta pinned (or the tokenizer cannot be read): the files on this Mac
        /// are damaged and the person deletes them (or downloads again).
        case damaged
        case failed(SearchModelError)
        case deleting
    }

    /// The part of the model a partial import still lacks.
    public enum MissingPart: Sendable, Equatable { case tokenizer, weights }

    public var state: State = .notInstalled
    /// Bytes per second over the last 5 seconds, while downloading.
    public var bytesPerSecond: Double?
    /// Whole seconds left, once the rate is known (after 3 s).
    public var secondsRemaining: Int?
    /// Bytes of the model on this Mac.
    public var installedBytes = 0
    /// The download was started or the model installed from a file the person chose ("download" or "import").
    public var source: String?
    /// Why a stopped download stopped (the network went away, a redirect was refused) while its verified blocks wait for Resume.
    public var lastError: SearchModelError?
    /// The work in progress can be cancelled (a download, or checking files the person chose).
    public var cancellable = false

    public init() {}

    /// Fraction of the download done, for a determinate progress bar.
    public var fraction: Double? {
        switch state {
        case .downloading(let r, let t, _), .pausedForRecording(let r, let t): t > 0 ? Double(r) / Double(t) : nil
        case .partial(let v, let t): t > 0 ? Double(v) / Double(t) : nil
        default: nil
        }
    }

    /// The model is installed and the features that need it can use it.
    public var isReady: Bool { state == .ready }
}

/// Smooths the download rate over a sliding window and throttles status updates (the search model's and the language model's).
final class DownloadProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(time: TimeInterval, bytes: Int)] = []
    private var lastEmit: TimeInterval = 0
    private var started: TimeInterval?
    let window: TimeInterval
    let interval: TimeInterval

    init(window: TimeInterval = 5, interval: TimeInterval = 0.25) {
        self.window = window
        self.interval = interval
    }

    /// Records `bytes` received in total at `time`. Returns the rate and the seconds left when an update is due (at most four
    /// a second), else nil. The remaining time is given after three seconds.
    func record(bytes: Int, total: Int, at time: TimeInterval) -> (rate: Double?, remaining: Int?)? {
        lock.withLock {
            if started == nil { started = time }
            samples.append((time, bytes))
            samples.removeAll { time - $0.time > window }
            guard time - lastEmit >= interval else { return nil }
            lastEmit = time
            var rate: Double?
            if let first = samples.first, time - first.time > 0.5 { rate = Double(bytes - first.bytes) / (time - first.time) }
            var remaining: Int?
            if let rate, rate > 0, time - (started ?? time) >= 3 { remaining = Int((Double(total - bytes) / rate).rounded(.up)) }
            return (rate, remaining)
        }
    }

    func reset() {
        lock.withLock {
            samples = []
            lastEmit = 0
            started = nil
        }
    }
}

typealias SearchModelProgressMeter = DownloadProgressMeter
