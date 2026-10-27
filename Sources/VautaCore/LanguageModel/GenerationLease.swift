// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization

/// How a job reacts to the Mac's thermal state. Minutes and bulk work step aside when the Mac is hot, live notes slow down
/// first and stop when it is critical, an answer to a question heard (optional work) gives up as soon as the heat is serious instead of
/// holding the model until the Mac cools down, and an interactive answer is only slowed down at critical.
public enum ThermalPolicy {
    public enum Action: Sendable, Equatable {
        case run
        /// Go on after a short pause between steps (a lower duty cycle).
        case slow
        /// Give the GPU up and wait until the Mac has cooled down.
        case wait
        /// Optional work: end now with `GenerationTooWarm` and let go of the GPU.
        case giveUp
    }

    public static func action(for priority: MLXWorkGate.Priority, _ state: ProcessInfo.ThermalState) -> Action {
        switch (priority, state) {
        case (_, .nominal), (_, .fair): return .run
        case (.bulk, _), (.warm, _), (.minutes, _), (.brief, _): return .wait
        case (.live, .serious): return .slow
        case (.live, _): return .wait
        case (.autoAnswer, _): return .giveUp
        case (.interactive, .critical): return .slow
        case (.interactive, _): return .run
        @unknown default: return .run
        }
    }
}

/// A generation of optional work (an answer to a question heard) ended because the Mac got too warm.
public struct GenerationTooWarm: Error, Sendable {}

/// Where the thermal state comes from, so tests can inject one.
public struct ThermalSource: Sendable {
    public var state: @Sendable () -> ProcessInfo.ThermalState
    /// How often a waiting job looks again.
    public var poll: Duration
    /// The pause a slowed job makes between steps.
    public var slowPause: Duration

    public init(state: @escaping @Sendable () -> ProcessInfo.ThermalState, poll: Duration = .seconds(2), slowPause: Duration = .milliseconds(250)) {
        self.state = state
        self.poll = poll
        self.slowPause = slowPause
    }

    public static let system = ThermalSource(state: { ProcessInfo.processInfo.thermalState })
}

/// One generation's hold on the `MLXWorkGate`. Taken for a prefill chunk or a decode burst at a time: at every checkpoint the job
/// gives the gate to a waiter of higher priority (an interactive search embedding, a live answer), and a minutes job waits out a
/// hot Mac without holding it. Not for use from two tasks at once.
public final class GenerationLease: @unchecked Sendable {
    private let gate: MLXWorkGate
    private let priority: MLXWorkGate.Priority
    private let thermal: ThermalSource
    private let held = Mutex(false)
    /// Times the lease gave way to a more urgent job or to heat (for tests and the evaluation).
    private let yields = Mutex((urgent: 0, thermal: 0))

    public init(gate: MLXWorkGate, priority: MLXWorkGate.Priority, thermal: ThermalSource = .system) {
        self.gate = gate
        self.priority = priority
        self.thermal = thermal
    }

    public var yielded: (urgent: Int, thermal: Int) { yields.withLock { $0 } }

    public func begin() async throws {
        try await gate.acquire(priority)
        held.withLock { $0 = true }
    }

    public func end() {
        let was = held.withLock { let h = $0; $0 = false; return h }
        if was { gate.release() }
    }

    private func give() { end() }

    /// Called between prefill chunks and decode bursts: cancellation, heat, then a waiter of higher priority.
    public func checkpoint() async throws {
        try Task.checkCancellation()
        var gaveUpForHeat = false
        while true {
            switch ThermalPolicy.action(for: priority, thermal.state()) {
            case .run: break
            case .slow:
                give()
                gaveUpForHeat = true
                try await Task.sleep(for: thermal.slowPause)
            case .wait:
                give()
                gaveUpForHeat = true
                try await Task.sleep(for: thermal.poll)
                continue
            case .giveUp:
                give()
                yields.withLock { $0.thermal += 1 }
                throw GenerationTooWarm()
            }
            break
        }
        if gaveUpForHeat { yields.withLock { $0.thermal += 1 } }
        if !held.withLock({ $0 }) {
            try await begin()
        } else if gate.hasWaiter(above: priority) {
            give()
            yields.withLock { $0.urgent += 1 }
            try await begin()
        }
    }
}
