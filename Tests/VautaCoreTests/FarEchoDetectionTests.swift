// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `EchoDetection.farEchoes`: the user's voice that a participant on speakers sends back into Others is found there, and the others'
/// own words, even the ones the user's speakers echo into Me, are not.
@Suite("Transcription: the far side's echo of the user")
struct FarEchoDetectionTests {
    private func me(_ id: Int64, _ start: Double, _ end: Double, _ text: String) -> EchoDetection.Line {
        EchoDetection.Line(id: id, channel: .me, start: start, end: end, text: text)
    }

    private func others(_ id: Int64, _ start: Double, _ end: Double, _ text: String) -> EchoDetection.Line {
        EchoDetection.Line(id: id, channel: .others, start: start, end: end, text: text)
    }

    private func far(_ lines: [EchoDetection.Line], locale: String = "en-US") -> [Int64] {
        EchoDetection.farEchoes(lines, locale: locale)
    }

    static let said = "We should move the launch to the second week of March"

    @Test func theUserSentBackACallsRoundTripLaterIsAnEcho() {
        #expect(far([me(1, 10, 14, Self.said), others(2, 10.35, 14.4, Self.said)]) == [2])
        #expect(far([me(1, 10, 14, Self.said), others(2, 10.7, 14.8, "we should move the lunch to the second week in March")]) == [2],
                "transcribed worse and later still")
        // The two detectors never mark both lines of one pair.
        let pair = [me(1, 10, 14, Self.said), others(2, 10.35, 14.4, Self.said)]
        #expect(EchoDetection.echoes(pair, locale: "en-US").isEmpty)
    }

    @Test func theOriginalThatTheSpeakersEchoIsTheOthers() {
        // The others said it; the user's microphone heard it from the speakers a little later.
        #expect(far([others(1, 10, 14, Self.said), me(2, 10.3, 14.2, Self.said)]).isEmpty)
        #expect(far([others(1, 10, 14, Self.said), me(2, 10.05, 14.05, Self.said)]).isEmpty, "the Mac's own speakers, almost at once")
        #expect(EchoDetection.echoes([others(1, 10, 14, Self.said), me(2, 10.3, 14.2, Self.said)], locale: "en-US") == [2])
    }

    @Test func repeatingWhatTheUserSaidIsTheOthers() {
        // A participant reads the figure back after the user finished: their own words.
        #expect(far([me(1, 5, 8, "The budget is forty thousand euros"), others(2, 8.9, 11.5, "The budget is forty thousand euros?")]).isEmpty)
        // Or agrees in a few words while the user talks.
        #expect(far([me(1, 0, 20, "The budget for the pilot is forty thousand euros and the number of units depends on the supplier"),
                     others(2, 8, 10, "forty thousand, right")]).isEmpty)
    }

    @Test func shortRepliesAreNeverMarked() {
        #expect(far([me(1, 5, 6, "Okay, perfect."), others(2, 5.4, 6.4, "Okay, perfect.")]).isEmpty)
    }

    @Test func tooLateIsNotTheCall() {
        #expect(far([me(1, 10, 14, Self.said), others(2, 12, 16, Self.said)]).isEmpty, "two seconds is not a round trip")
    }
}
