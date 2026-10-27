// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What Settings shows about the integrated language model: a value pushed by `LanguageModelController`.
public struct LanguageModelStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case notInstalled
        /// This Mac does not meet the requirements (16 GB of memory, an Apple silicon GPU), with the reason.
        case unsupported(LanguageModelUnsupported)
        case downloading(received: Int, total: Int, phase: LanguageModelProgress.Phase)
        /// A paused download is going on again: the blocks already on disk are being read back and checked (about 4 s).
        case checkingPartial
        /// A recording is going on (or ended less than two minutes ago): the download continues by itself afterwards.
        case pausedForRecording(received: Int, total: Int)
        /// Stopped (paused, quit, or the network went away) with verified blocks on disk; Resume continues from them.
        case partial(verified: Int, total: Int)
        /// Google's original file is being converted on this Mac (a fraction of the 16 GB read).
        case importing(Double)
        /// One of the two files was imported (verified and staged); the other is still needed: chosen from a file or downloaded alone.
        case needsFile(MissingPart)
        /// The files are in place and being checked.
        case verifying
        /// First load: kernel self-test and weights (about 10 s).
        case preparing
        case ready
        /// Installed, but a file no longer matches what Vauta pinned: Repair fetches only the damaged part again.
        case damaged
        /// The damaged part is being fetched again and the file checked.
        case repairing(received: Int, total: Int)
        case failed(IntegratedModelError)
        case deleting
    }

    /// The part of the model a partial import still lacks.
    public enum MissingPart: Sendable, Equatable { case tokenizer, weights }

    public var state: State = .notInstalled
    /// Bytes per second over the last 5 seconds, while downloading.
    public var bytesPerSecond: Double?
    /// Whole seconds left, once the rate is known (after 3 s).
    public var secondsRemaining: Int?
    /// Bytes of the model on this Mac (installed files and staging).
    public var installedBytes = 0
    /// "download", "import" or "repair".
    public var source: String?
    /// Why a stopped download stopped (the network went away, a redirect was refused) while its verified blocks wait for Resume.
    public var lastError: IntegratedModelError?
    /// The work in progress can be cancelled.
    public var cancellable = false
    /// An import (state `.importing`) is waiting for a recording to end: it is the same import, not a download, and it continues by itself.
    public var importPaused = false

    public init() {}

    /// Fraction of the download done, for a determinate progress bar.
    public var fraction: Double? {
        switch state {
        case .downloading(let r, let t, _), .pausedForRecording(let r, let t), .repairing(let r, let t): t > 0 ? Double(r) / Double(t) : nil
        case .partial(let v, let t): t > 0 ? Double(v) / Double(t) : nil
        case .importing(let f): f
        default: nil
        }
    }

    /// The model is installed and chat can use it.
    public var isReady: Bool { state == .ready }
}

/// What the app does when the model is chosen, appears or goes away.
public struct LanguageModelHooks: Sendable {
    /// The person started the download or the import: the chat choice is now the integrated model, and the service reads its providers.
    public var chosen: @Sendable () async -> Void
    /// The model finished installing and is ready.
    public var installed: @Sendable () async -> Void
    /// The model is about to be deleted: whatever uses it lets go (the service reads its providers again once the files are gone).
    public var removed: @Sendable () async -> Void

    public init(chosen: @escaping @Sendable () async -> Void = {}, installed: @escaping @Sendable () async -> Void = {},
                removed: @escaping @Sendable () async -> Void = {}) {
        self.chosen = chosen
        self.installed = installed
        self.removed = removed
    }
}
