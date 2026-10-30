// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// A recording's start that waits on macOS can be given up, by the person or at a deadline, and then says which step waits.
@Suite("Capture: giving up a start that waits")
struct GiveUpTests {
    /// Work that finishes when `open` is set (or never).
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var given = false
        private(set) var lateResult: Int?
        func open() { lock.withLock { isOpen = true } }
        func giveUp() { lock.withLock { given = true } }
        var opened: Bool { lock.withLock { isOpen } }
        var givenUp: Bool { lock.withLock { given } }
        func late(_ value: Int) { lock.withLock { lateResult = value } }
        var late: Int? { lock.withLock { lateResult } }
        func work() async throws -> Int {
            while !opened { try await Task.sleep(for: .milliseconds(5)) }
            return 7
        }
    }

    @Test func workThatFinishesIsReturned() async throws {
        let gate = Gate()
        gate.open()
        let value = try await GiveUp.run(deadline: .seconds(600), abandoned: { gate.givenUp }) { try await gate.work() }
        #expect(value == 7)
    }

    /// Given up, it returns while the work still waits (the work only ends when the gate opens, the deadline is far): no clock
    /// is read, so a busy machine can't make it flaky.
    @Test func givingUpReturnsAtOnceAndTheWorkEndsLater() async throws {
        let gate = Gate()
        gate.giveUp()
        await #expect(throws: GiveUp.Reason.abandoned) {
            try await GiveUp.run(deadline: .seconds(600), poll: .milliseconds(10), abandoned: { gate.givenUp },
                                 late: { if case .success(let v) = $0 { gate.late(v) } }) { try await gate.work() }
        }
        #expect(gate.late == nil, "the work has not ended")
        gate.open()
        #expect(await eventually { gate.late == 7 }, "what the work ends with goes to `late`")
    }

    @Test func theDeadlineEndsTheWait() async throws {
        let gate = Gate()
        await #expect(throws: GiveUp.Reason.deadline) {
            try await GiveUp.run(deadline: .milliseconds(80), poll: .milliseconds(10), abandoned: { false }) { try await gate.work() }
        }
        gate.open()
    }

    @Test func aFailureOfTheWorkIsThrown() async throws {
        struct Broken: Error {}
        await #expect(throws: Broken.self) {
            try await GiveUp.run(deadline: .seconds(600), abandoned: { false }) { () async throws -> Int in throw Broken() }
        }
    }

    /// The error a stalled start shows says what it waits for, with the Settings pane that fixes it.
    @Test func aStalledStartSaysWhichStepWaits() {
        let steps: [(MeetingCapture.StartStage, CaptureError.Code)] = [
            (.models, .transcriptionStopped), (.microphonePermission, .microphonePermissionDenied), (.microphone, .microphoneStartFailed),
            (.systemAudio, .systemAudioStartFailed), (.analyzers, .transcriptionStopped),
        ]
        for (stage, code) in steps {
            #expect(MeetingCapture.stalledStartError(at: stage).code == code, "\(stage)")
        }
    }
}
