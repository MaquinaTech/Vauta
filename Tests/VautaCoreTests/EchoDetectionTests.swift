// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// `EchoDetection`: the remote voice that the microphone picked up is found in the Me channel, and what the user really said,
/// even about the same thing or with the same words, is not.
@Suite("Transcription: echo of the speakers in the microphone")
struct EchoDetectionTests {
    private func me(_ id: Int64, _ start: Double, _ end: Double, _ text: String) -> EchoDetection.Line {
        EchoDetection.Line(id: id, channel: .me, start: start, end: end, text: text)
    }

    private func others(_ id: Int64, _ start: Double, _ end: Double, _ text: String) -> EchoDetection.Line {
        EchoDetection.Line(id: id, channel: .others, start: start, end: end, text: text)
    }

    private func echoes(_ lines: [EchoDetection.Line], locale: String = "en-US") -> [Int64] {
        EchoDetection.echoes(lines, locale: locale)
    }

    @Test func theRemoteVoiceHeardALittleLaterIsAnEcho() {
        let said = "We should move the launch to the second week of March"
        #expect(echoes([others(1, 10, 14, said), me(2, 10.3, 14.2, said)]) == [2])
        // Over Bluetooth the microphone hears it later still.
        #expect(echoes([others(1, 10, 14, said), me(2, 10.5, 14.5, said)]) == [2])
    }

    @Test func anEchoTranscribedWorseIsStillAnEcho() {
        #expect(echoes([others(1, 10, 14, "We should move the launch to the second week of March"),
                        me(2, 10.3, 14.2, "we should move the lunch to the second week in March")]) == [2])
    }

    /// The transcriber cuts the two channels differently: an echo of half of a long Others line, or one Others line per
    /// sentence against one Me line.
    @Test func anEchoIsFoundWhereverTheLinesAreCut() {
        let monologue = "The supplier confirmed the new shell material yesterday. We will order two hundred units for the pilot in April."
        #expect(echoes([others(1, 0, 20, monologue), me(2, 10.4, 20.3, "we will order two hundred units for the pilot in April")]) == [2])
        #expect(echoes([others(1, 0, 6, "The supplier confirmed the new shell material yesterday."),
                        others(2, 6.2, 12, "We will order two hundred units for the pilot in April."),
                        me(3, 0.3, 12.3, "the supplier confirmed the new shell material yesterday we will order two hundred units for the pilot in April")]) == [3])
    }

    @Test func anInterjectionDuringAMonologueIsTheUsers() {
        let monologue = "The budget for the pilot is forty thousand euros and the number of units depends on the supplier and on the budget review."
        #expect(echoes([others(1, 0, 20, monologue), me(2, 8, 10, "sorry, can you repeat the budget number")]).isEmpty)
    }

    @Test func shortRepliesAreNeverMarked() {
        #expect(echoes([others(1, 5, 6, "Okay, perfect."), me(2, 5.2, 6.1, "Okay, perfect.")]).isEmpty)
        #expect(echoes([others(1, 5, 6, "Yes, exactly."), me(2, 5.2, 6.1, "yes exactly")]).isEmpty)
    }

    @Test func repeatingWhatWasJustSaidIsTheUsers() {
        // The user repeats the figure back after the other person finished.
        #expect(echoes([others(1, 5, 8, "The budget is forty thousand euros"), me(2, 8.9, 11.5, "The budget is forty thousand euros?")]).isEmpty)
    }

    /// A participant on speakers whose call app doesn't cancel the echo sends the user's voice back into Others: there the Others
    /// line is the echo, and it starts after the user's.
    @Test func theFarSideSendingTheUserBackIsTheUsers() {
        let said = "We should move the launch to the second week of March"
        #expect(echoes([me(1, 10, 14, said), others(2, 10.35, 14.4, said)]).isEmpty)
        // Even right after the other person stopped talking.
        #expect(echoes([others(1, 7, 9.8, "So what do you suggest for the launch"), me(2, 10, 14, said), others(3, 10.35, 14.4, said)]).isEmpty)
        // An echo the transcriber starts a little early is still an echo.
        #expect(echoes([others(1, 10, 14, said), me(2, 9.9, 14.1, said)]) == [2])
    }

    @Test func speakingOverTheOtherPersonIsTheUsers() {
        #expect(echoes([others(1, 0, 6, "We will order two hundred units for the pilot in April"),
                        me(2, 2, 7, "I think April is too early for the pilot order")]).isEmpty)
    }

    @Test func otherLanguagesAndScripts() {
        let es = "Tenemos que mover el lanzamiento a la segunda semana de marzo"
        #expect(echoes([others(1, 10, 14, es), me(2, 10.3, 14.2, "tenemos que mover el lanzamiento a la segunda semana de marzo")], locale: "es-ES") == [2])
        let ja = "来週の会議で予算の見直しについて話し合いましょう"
        #expect(echoes([others(1, 10, 14, ja), me(2, 10.3, 14.2, ja)], locale: "ja-JP") == [2])
    }

    @Test func withoutTheOtherChannelNothingIsAnEcho() {
        let said = "We should move the launch to the second week of March"
        #expect(echoes([me(1, 10, 14, said), me(2, 20, 24, said)]).isEmpty)
    }

    @Test func coverageCountsOverlappingSpansOnce() {
        let line = me(1, 10, 20, "")
        #expect(EchoDetection.coverage(of: line, by: [(8, 15), (12, 16), (18, 30)]) == 0.8)
        #expect(EchoDetection.coverage(of: line, by: []) == 0)
        #expect(EchoDetection.coverage(of: me(1, 5, 5, ""), by: [(4, 6)]) == 1)
    }
}
