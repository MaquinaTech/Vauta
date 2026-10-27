// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Faithful tasks written the way people say them, run through the real validation: none may be marked "unconfirmed".
/// The owner evaluation's "0 false alarms" only covers its own 56 tasks; these are the phrasings that tripped the
/// checks before (a weekday of next week, "in two weeks", names that are also everyday words, numerals in kanji).
@Suite("Minutes: faithful phrasings are not marked")
struct FaithfulPhrasingTests {
    private let utc = TimeZone(identifier: "UTC")!
    private var meeting: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 10))!   // a Tuesday
    }

    struct Case: Sendable, CustomStringConvertible {
        let segment: String, text: String, quote: String, due: String?
        var description: String { text }
        init(_ segment: String, _ text: String, _ quote: String, due: String? = nil) {
            self.segment = segment; self.text = text; self.quote = quote; self.due = due
        }
    }

    static let faithful: [Case] = [
        Case("I'll have the contract signed by next Friday.", "Get the contract signed", "have the contract signed", due: "2026-10-16"),
        Case("Lo cierro el próximo viernes sin falta.", "Cerrar el acuerdo", "Lo cierro el próximo viernes", due: "2026-10-16"),
        Case("Je t'envoie le devis vendredi prochain.", "Envoyer le devis", "t'envoie le devis", due: "2026-10-16"),
        Case("Ich schicke das Angebot nächsten Freitag.", "Das Angebot schicken", "schicke das Angebot", due: "2026-10-16"),
        Case("Te mando il preventivo venerdì prossimo.", "Mandare il preventivo", "mando il preventivo", due: "2026-10-16"),
        Case("We will have the prototype ready in two weeks.", "Finish the prototype", "have the prototype ready", due: "2026-10-20"),
        Case("Lo tendremos listo en dos semanas.", "Dejar listo el informe", "Lo tendremos listo", due: "2026-10-20"),
        Case("两周后我把方案交给你。", "交付方案", "两周后我把方案交给你", due: "2026-10-20"),
        // Names that are also everyday words, in sentences that do not name the person.
        Case("Then we can mark the invoices as paid next week.", "Then mark the invoices as paid", "mark the invoices as paid"),
        Case("Voy a enviar al cliente el informe de ventas.", "Enviar al cliente el informe", "enviar al cliente el informe"),
        Case("We will send the invoices in may, once it is signed.", "Send the invoices in May once signed", "send the invoices in may"),
        Case("We should get the invoices marked as paid.", "Mark the invoices as paid", "get the invoices marked as paid"),
        Case("Le mandaremos el informe a la clienta.", "Al cliente le enviamos el informe", "Le mandaremos el informe"),
        Case("我会给客户发邮件。", "给客户发邮件一次", "我会给客户发邮件"),
        Case("資料を確認します。", "資料を一回確認する", "資料を確認します"),
        // Numerals in kanji and digits are the same figure.
        Case("我们联系五十家供应商。", "联系50家供应商", "我们联系五十家供应商"),
        Case("予算は三百万円です。", "予算300万円を確保する", "予算は三百万円です"),
    ]

    @Test(arguments: faithful) func aFaithfulTaskIsNotMarked(_ item: Case) throws {
        let segments: [Int64: CitableSegment] = [10: CitableSegment(id: 10, channel: .others, start: 5, text: item.segment)]
        let candidates = [CandidateEntity(id: 1, kind: .person, name: "Me", aliases: []),
                          CandidateEntity(id: 5, kind: .person, name: "Mark", aliases: []),
                          CandidateEntity(id: 6, kind: .person, name: "Alejandro", aliases: ["Al"]),
                          CandidateEntity(id: 7, kind: .person, name: "Will", aliases: []),
                          CandidateEntity(id: 8, kind: .person, name: "May", aliases: [])]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: [
            "tasks": [["text": item.text, "seg": 10, "quote": item.quote, "due": item.due ?? NSNull()] as [String: Any]],
            "decisions": [Any](), "entities": [Any](),
        ] as [String: Any]), as: UTF8.self)
        let minutes = try VautaPrompts.validateMinutes(json, segments: segments, candidates: candidates, selfEntity: 1,
                                                       meetingPeople: [5, 6, 7, 8], reference: meeting, timeZone: utc)
        let task = try #require(minutes.tasks.first, "\(item.text) was dropped")
        #expect(!task.unconfirmed, "\(item.text)")
    }
}
