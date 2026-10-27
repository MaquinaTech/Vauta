// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// Connects the detector of a recording to the Answers card: what the detector says reaches the card through one stream, so the events
/// are applied in the order they happened, and the ✕ of a row that is still being worked on stops that row in the detector.
@MainActor
final class LiveAnswersBridge {
    private let model: LiveAnswersModel
    private let continuation: AsyncStream<LiveAnswerEvent>.Continuation
    private var consumer: Task<Void, Never>?
    /// Set once the detector exists (it is created with this bridge's `send`).
    var detector: QuestionDetector?

    /// `accepting` says whether live answers are active now: while they are not (Apple answers, or the switch is off), whatever the
    /// detector still yields (a pause from a check that ran, a late answer, working rows) is dropped, so no card comes back after the
    /// feature was turned off.
    init(model: LiveAnswersModel, accepting: @escaping @MainActor () -> Bool = { true }) {
        self.model = model
        let (events, continuation) = AsyncStream<LiveAnswerEvent>.makeStream()
        self.continuation = continuation
        consumer = Task { @MainActor [weak model] in
            for await event in events where accepting() { model?.apply(event) }
        }
        model.onStop = { [weak self] row in
            guard let detector = self?.detector else { return }
            Task { await detector.cancel(row: row) }
        }
    }

    /// The detector's event handler: callable from its actor.
    nonisolated var send: @Sendable (LiveAnswerEvent) -> Void {
        let continuation = continuation
        return { continuation.yield($0) }
    }

    /// The recording ended: whatever the detector still says is not shown, and the card is no longer wired to it.
    func finish() {
        continuation.finish()
        consumer?.cancel()
        consumer = nil
        detector = nil
        model.onStop = nil
    }
}
