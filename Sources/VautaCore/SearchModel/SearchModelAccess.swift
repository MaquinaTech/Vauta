// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization

/// Why an installed search model cannot be used.
public enum SearchModelUnavailableReason: String, Sendable, Equatable {
    /// No Apple silicon GPU.
    case unsupportedHardware
    /// The kernel self-test failed in this build.
    case selfTestFailed
    /// A file no longer matches the pinned hashes.
    case verificationFailed
}

/// What the rest of the app may ask about the search model, synchronously and from any thread: is it installed and usable, and
/// the embedding model to use. The controller keeps it up to date. Reading it never touches the disk or the network.
public final class SearchModelAccess: Sendable {
    public enum Availability: Sendable, Equatable {
        case notInstalled
        case unavailable(SearchModelUnavailableReason)
        /// Installed and verified at the last check; the files are loaded on first use.
        case installed
    }

    private struct State {
        var availability = Availability.notInstalled
        var model: GemmaEmbeddingModel?
        var environment: @Sendable () -> IndexerEnvironment = { IndexerEnvironment() }
        var preloader: @Sendable () -> Void = {}
    }

    private let state = Mutex(State())

    public static let shared = SearchModelAccess()

    public init() {}

    public var availability: Availability { state.withLock { $0.availability } }
    /// The embedding model, only while installed and usable.
    public var model: GemmaEmbeddingModel? { state.withLock { $0.model } }

    /// What the Mac is doing, as bulk embedding work sees it (recording, power, heat).
    public var environment: IndexerEnvironment { state.withLock { $0.environment }() }

    public func setEnvironment(_ provider: @escaping @Sendable () -> IndexerEnvironment) {
        state.withLock { $0.environment = provider }
    }

    /// Asks for the model to be loaded in the background (the sidebar search starts: its first question should not wait). The
    /// controller decides whether it does anything.
    public func requestPreload() { state.withLock { $0.preloader } () }

    func setPreloader(_ preloader: @escaping @Sendable () -> Void) { state.withLock { $0.preloader = preloader } }

    func set(_ availability: Availability, model: GemmaEmbeddingModel?) {
        state.withLock {
            $0.availability = availability
            $0.model = availability == .installed ? model : nil
        }
    }
}
