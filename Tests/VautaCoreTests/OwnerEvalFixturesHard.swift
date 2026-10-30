// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
@testable import VautaCore

/// Meetings where the evaluation can fail: the diarizer is confidently wrong (a label at or above the confidence
/// threshold on the wrong person), and a request to somebody mixed with a commitment of the speaker. The recorded
/// answers follow the labels the model is shown, as a model would.
extension OwnerEvalCase {
    static let hardCases: [OwnerEvalCase] = [englishConfidentMislabel, spanishConfidentMislabel, japaneseRequestAndCommitment]

    /// The spread of a cluster that took a second voice: below `VoiceProfileThresholds.minimumSpread`.
    static let mixedSpread: Float = 0.52

    /// Bruno's commitment is labeled Ana at 0.85. The line cannot tell, but Ana's cluster holds Bruno's voice and its spread
    /// shows it: the owner is wrong and marked, and so is the owner of Ana's own line.
    static let englishConfidentMislabel = OwnerEvalCase(
        id: "en confidently wrong label", locale: "en-US", people: ["Ana", "Bruno"],
        speakers: [me, remote("Ana", voiceSpread: mixedSpread), remote("Bruno")],
        lines: [
            Line(1, 0.95, "Let's close the vendor contract today."),
            Line(2, 0.85, "I'll send the contract to legal.", labeled: 1),
            Line(1, 0.92, "I'll book the meeting room for Thursday."),
            Line(1, 0.93, "Bruno, send the deck to the board and I'll review it."),
        ],
        gold: [Gold(line: 1, owner: "Bruno"), Gold(line: 2, owner: "Ana"), Gold(line: 3, owner: "Bruno")],
        baseline: [
            // Nothing in the words says who: without labels the model leaves it open.
            Output("Send the contract to legal", line: 1, owner: nil, quote: "send the contract to legal"),
            Output("Book the meeting room", line: 2, owner: nil, quote: "book the meeting room for Thursday", due: "2026-10-08"),
            Output("Send the deck to the board", line: 3, owner: "Bruno", quote: "send the deck to the board"),
        ],
        withSpeakers: [
            // The model trusts the label it was shown, as it should.
            Output("Send the contract to legal", line: 1, owner: "Ana", quote: "send the contract to legal"),
            Output("Book the meeting room", line: 2, owner: "Ana", quote: "book the meeting room for Thursday", due: "2026-10-08"),
            Output("Send the deck to the board", line: 3, owner: "Bruno", quote: "send the deck to the board"),
        ],
        planted: [])

    static let spanishConfidentMislabel = OwnerEvalCase(
        id: "es confidently wrong label", locale: "es-ES", people: ["Lucía", "Mateo"],
        speakers: [me, remote("Lucía", voiceSpread: mixedSpread), remote("Mateo")],
        lines: [
            Line(1, 0.94, "Tenemos que cerrar el contrato con el proveedor."),
            Line(2, 0.88, "Yo me encargo del contrato con el proveedor.", labeled: 1),
            Line(1, 0.91, "Yo reservo la sala para el jueves."),
        ],
        gold: [Gold(line: 1, owner: "Mateo"), Gold(line: 2, owner: "Lucía")],
        baseline: [
            Output("Cerrar el contrato con el proveedor", line: 1, owner: nil, quote: "me encargo del contrato con el proveedor"),
            Output("Reservar la sala", line: 2, owner: nil, quote: "reservo la sala para el jueves"),
        ],
        withSpeakers: [
            Output("Cerrar el contrato con el proveedor", line: 1, owner: "Lucía", quote: "me encargo del contrato con el proveedor"),
            Output("Reservar la sala", line: 2, owner: "Lucía", quote: "reservo la sala para el jueves"),
        ],
        planted: [])

    /// A request to Sato (not a commitment of the speaker, whatever the verb ending) and the speaker's own commitment.
    static let japaneseRequestAndCommitment = OwnerEvalCase(
        id: "ja request and commitment", locale: "ja-JP", people: ["田中", "佐藤"],
        speakers: [me, remote("田中"), remote("佐藤")],
        lines: [
            Line(1, 0.94, "佐藤さん、資料の送付をお願いします。"),
            Line(1, 0.92, "レビューは私が担当します。"),
            Line(2, 0.90, "分かりました。見積書の確認は私がやります。"),
        ],
        gold: [Gold(line: 0, owner: "佐藤"), Gold(line: 1, owner: "田中"), Gold(line: 2, owner: "佐藤")],
        baseline: [
            Output("資料を送付する", line: 0, owner: "佐藤", quote: "資料の送付をお願いします"),
            Output("レビューを担当する", line: 1, owner: nil, quote: "レビューは私が担当します"),
            Output("見積書を確認する", line: 2, owner: nil, quote: "見積書の確認は私がやります"),
        ],
        withSpeakers: [
            Output("資料を送付する", line: 0, owner: "佐藤", quote: "資料の送付をお願いします"),
            Output("レビューを担当する", line: 1, owner: "田中", quote: "レビューは私が担当します"),
            Output("見積書を確認する", line: 2, owner: "佐藤", quote: "見積書の確認は私がやります"),
        ],
        planted: [])
}
