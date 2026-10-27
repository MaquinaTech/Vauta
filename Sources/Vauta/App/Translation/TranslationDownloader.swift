// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Observation
import SwiftUI
import Translation

/// Downloads a language pair through the system: Apple's own consent sheet
/// appears, the download runs in the system, and Vauta only learns that it
/// finished. The framework offers no progress value, so the interface shows
/// an indeterminate indicator while `running` is set.
///
/// A session that can request downloads only exists inside a SwiftUI
/// `.translationTask`, so a view hosts it (`TranslationDownloadHost`): the
/// captions panel and the Settings pane each host one (every `Requester` has
/// its host), and only the one that asked reacts.
@MainActor
@Observable
final class TranslationDownloader {
    enum Requester: Sendable, CaseIterable { case panel, settings }

    /// The pair being downloaded, if any.
    private(set) var running: TranslationPair?
    private(set) var failed = false
    private(set) var requester: Requester?
    private var configuration: TranslationSession.Configuration?

    /// Called on the main actor when a pair finished downloading.
    @ObservationIgnored var onFinished: (@MainActor (TranslationPair) -> Void)?
    /// Called on the main actor when the download did not finish (declined in Apple's sheet, or an error) or was cancelled.
    @ObservationIgnored var onStopped: (@MainActor (TranslationPair, _ failed: Bool) -> Void)?

    #if VAUTA_DIAGNOSTICS
    /// For the snapshot renderer only: a download is shown in progress, without asking the system for anything.
    func installSnapshotRunning(_ pair: TranslationPair) { running = pair }
    #endif

    func request(_ pair: TranslationPair, strategy: TranslationStrategy, from requester: Requester) {
        guard running == nil else { return }
        running = pair
        failed = false
        self.requester = requester
        if #available(macOS 26.4, *) {
            configuration = .init(source: pair.source, target: pair.target,
                                  preferredStrategy: strategy == .lowLatency ? .lowLatency : .highFidelity)
        } else {
            configuration = .init(source: pair.source, target: pair.target)
        }
    }

    /// Gives up: the system task is cancelled and nothing is reported as a failure.
    func cancel() {
        guard let pair = running else { return }
        running = nil
        requester = nil
        configuration = nil
        failed = false
        onStopped?(pair, false)
    }

    /// The configuration for the host of `requester`; nil for the other one.
    func configuration(for host: Requester) -> TranslationSession.Configuration? {
        requester == host ? configuration : nil
    }

    /// Runs inside `.translationTask`: shows the system sheet and waits for the download.
    nonisolated func perform(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            await finish(success: true)
        } catch {
            // Tapping Cancel in Apple's sheet, or the hosting view going away mid-download, is the person's choice
            // (or a closed window), not a failed download: back to "needs a one-time download", with no blame.
            if Self.isCancellation(error) { await cancel() } else { await finish(success: false) }
        }
    }

    /// Whether `error` is a cancellation (task, user or URL loading) rather than a failure of the download.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        let ns = error as NSError
        return (ns.domain == NSCocoaErrorDomain && ns.code == NSUserCancelledError)
            || (ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled)
    }

    private func finish(success: Bool) {
        guard let pair = running else { return }
        running = nil
        requester = nil
        configuration = nil
        failed = !success
        if success { onFinished?(pair) } else { onStopped?(pair, true) }
    }
}

/// Hosts the download session of `downloader` for one place in the interface.
struct TranslationDownloadHost: ViewModifier {
    let downloader: TranslationDownloader
    let host: TranslationDownloader.Requester

    func body(content: Content) -> some View {
        content.translationTask(downloader.configuration(for: host)) { @Sendable session in
            await downloader.perform(session)
        }
    }
}

extension View {
    func translationDownloads(_ downloader: TranslationDownloader, host: TranslationDownloader.Requester) -> some View {
        modifier(TranslationDownloadHost(downloader: downloader, host: host))
    }
}
