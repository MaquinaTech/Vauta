// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Others silence detector")
struct OthersSilenceDetectorTests {
    /// Runs one observation per second from `start` to `end` (inclusive) and returns the seconds at which it fired.
    private func run(_ detector: inout OthersSilenceDetector, from start: Int, to end: Int,
                     holds: Bool = true, silentFor: (Int) -> TimeInterval?) -> [Int] {
        (start...end).filter { t in
            detector.observe(now: TimeInterval(t), appHoldsMicrophone: holds, othersSilentFor: silentFor(t))
        }
    }

    @Test("Fires after 60 s of an app holding the microphone with Others silent, and only once")
    func firesOnce() {
        var detector = OthersSilenceDetector()
        let fired = run(&detector, from: 0, to: 300) { TimeInterval($0) }
        #expect(fired == [60])
        #expect(detector.hasRaised)
    }

    @Test("Does not fire before 60 s")
    func notBeforeThreshold() {
        var detector = OthersSilenceDetector()
        #expect(run(&detector, from: 0, to: 59) { TimeInterval($0) }.isEmpty)
        #expect(!detector.hasRaised)
    }

    @Test("Never fires when no known meeting app holds the microphone")
    func needsMeetingApp() {
        var detector = OthersSilenceDetector()
        #expect(run(&detector, from: 0, to: 600, holds: false) { TimeInterval($0) }.isEmpty)
    }

    @Test("Never fires while Others carries sound")
    func othersHeard() {
        var detector = OthersSilenceDetector()
        // Sound every 30 s: the silence never reaches 60 s.
        #expect(run(&detector, from: 0, to: 600) { TimeInterval($0 % 30) }.isEmpty)
        // Sound right now (nil): not silent.
        var heard = OthersSilenceDetector()
        #expect(run(&heard, from: 0, to: 120) { _ in nil }.isEmpty)
    }

    @Test("The app must hold the microphone without a break: releasing it restarts the 60 s")
    func releaseRestartsCount() {
        var detector = OthersSilenceDetector()
        #expect(run(&detector, from: 0, to: 40) { TimeInterval($0) }.isEmpty)
        #expect(run(&detector, from: 41, to: 45, holds: false) { TimeInterval($0) }.isEmpty)
        // Back at 46: the app has held the microphone for 60 s at 106.
        let fired = run(&detector, from: 46, to: 200) { TimeInterval($0) }
        #expect(fired == [106])
    }

    @Test("A call that starts late in a long silent recording waits its own 60 s")
    func lateCall() {
        var detector = OthersSilenceDetector()
        // Others silent for the whole 10 minutes, the app takes the microphone at 600.
        #expect(run(&detector, from: 0, to: 599, holds: false) { TimeInterval($0) }.isEmpty)
        let fired = run(&detector, from: 600, to: 700) { TimeInterval($0) }
        #expect(fired == [660])
    }

    @Test("One brief sound (a chime, a click) does not re-arm the alert or clear the silence it covers")
    func briefSoundIsIgnored() {
        var detector = OthersSilenceDetector()
        #expect(run(&detector, from: 0, to: 70) { TimeInterval($0) } == [60])
        // A chime at 71: silent for 0 s, then 1 s, 2 s... Others is "heard" for about 5 s only.
        #expect(run(&detector, from: 71, to: 400) { TimeInterval(($0 - 71) % 400) }.isEmpty)
        #expect(detector.hasRaised)
        #expect(detector.coversCurrentSilence)
    }

    @Test("Once raised it stays quiet until sound returns for good; then a new silent minute raises it again")
    func rearmsAfterSoundReturns() {
        var detector = OthersSilenceDetector()
        #expect(run(&detector, from: 0, to: 70) { TimeInterval($0) } == [60])
        // Sound for 10 s without a gap.
        #expect(run(&detector, from: 71, to: 80) { _ in nil }.isEmpty)
        #expect(!detector.coversCurrentSilence)
        // Silent again: not before its own 60 s.
        #expect(run(&detector, from: 81, to: 400) { TimeInterval($0 - 80) } == [140])
    }

    @Test("The alert covers the silence only until sound returns, so a later loss of Others is not left unreported")
    func coversOnlyTheCurrentSilence() {
        var detector = OthersSilenceDetector()
        #expect(!detector.coversCurrentSilence)
        #expect(run(&detector, from: 0, to: 70) { TimeInterval($0) } == [60])
        #expect(detector.coversCurrentSilence)
        // Still silent later: still covered.
        #expect(run(&detector, from: 71, to: 90) { TimeInterval($0) }.isEmpty)
        #expect(detector.coversCurrentSilence)
        // Sound returns.
        #expect(run(&detector, from: 91, to: 100) { _ in nil }.isEmpty)
        #expect(!detector.coversCurrentSilence)
        // Others drops again: the alert may come back after its own 60 s, and until then the silence banner is not suppressed.
        #expect(run(&detector, from: 101, to: 150) { TimeInterval($0 - 100) }.isEmpty)
        #expect(!detector.coversCurrentSilence)
    }
}
