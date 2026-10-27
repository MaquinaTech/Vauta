// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
@testable import VautaCore

/// The meetings of the offline owner evaluation, first half. See `OwnerEvalCase`. The meeting is a Tuesday,
/// 2026-10-06, in every case.
extension OwnerEvalCase {
    static let all: [OwnerEvalCase] = firstHalf + secondHalf + hardCases

    private static let firstHalf: [OwnerEvalCase] = [english, spanish, french, german, italian, portuguese]

    static let english = OwnerEvalCase(
        id: "en launch checklist", locale: "en-US", people: ["Ana", "Bruno"],
        speakers: [me, remote("Ana"), remote("Bruno")],
        lines: [
            Line(1, 0.95, "Let's go through the launch checklist."),
            Line(0, 0.99, "Sure. The legal review still isn't done."),
            Line(2, 0.93, "I'll chase legal and get the review done by Thursday."),
            Line(1, 0.95, "Great. Someone has to update the pricing page."),
            Line(1, 0.92, "I'll update the pricing page tomorrow."),
            Line(0, 0.99, "And I'll send the invitations to the beta customers."),
            Line(2, 0.90, "Ana, can you also check the 40 pending invoices?"),
            Line(1, 0.92, "Sure, I'll check them."),
            Line(2, 0.90, "Also, the press release goes out on Friday."),
        ],
        gold: [Gold(line: 2, owner: "Bruno"), Gold(line: 4, owner: "Ana"), Gold(line: 5, owner: "Me"), Gold(line: 6, owner: "Ana")],
        baseline: [
            Output("Finish the legal review", line: 2, owner: "Ana", quote: "chase legal and get the review done", due: "2026-10-08"),
            Output("Update the pricing page", line: 4, owner: nil, quote: "update the pricing page tomorrow", due: "2026-10-07"),
            Output("Send the beta invitations", line: 5, owner: "Me", quote: "send the invitations to the beta customers"),
            Output("Check the 40 pending invoices", line: 6, owner: "Ana", quote: "check the 40 pending invoices"),
        ],
        withSpeakers: [
            Output("Finish the legal review", line: 2, owner: "Bruno", quote: "chase legal and get the review done", due: "2026-10-08"),
            Output("Update the pricing page", line: 4, owner: "Ana", quote: "update the pricing page tomorrow", due: "2026-10-07"),
            Output("Send the beta invitations", line: 5, owner: "Me", quote: "send the invitations to the beta customers"),
            Output("Check the 40 pending invoices", line: 6, owner: "Ana", quote: "check the 40 pending invoices"),
        ],
        planted: [Output("Publish the press release", line: 8, owner: nil, quote: "the press release goes out on Friday", due: "2026-10-19")])

    static let spanish = OwnerEvalCase(
        id: "es migración", locale: "es-ES", people: ["Lucía", "Mateo"],
        speakers: [me, remote("Lucía"), remote("Mateo")],
        lines: [
            Line(1, 0.94, "Vamos a repasar el plan de la migración de Kobaltix."),
            Line(2, 0.91, "Yo me encargo de la factura de Kobaltix esta semana."),
            Line(0, 0.99, "Perfecto. Yo preparo el informe para el cliente."),
            // The diarizer put Lucía on a line that was Mateo's, and was unsure about it.
            Line(2, 0.40, "Yo me ocupo de revisar los contratos pendientes.", labeled: 1),
            Line(2, 0.88, "Lucía, ¿puedes confirmar la fecha con el cliente?"),
            Line(1, 0.90, "Claro, lo confirmo."),
            Line(1, 0.90, "El presupuesto total es de 5000 euros."),
        ],
        gold: [Gold(line: 1, owner: "Mateo"), Gold(line: 2, owner: "Me"), Gold(line: 3, owner: "Mateo"), Gold(line: 4, owner: "Lucía")],
        baseline: [
            Output("Emitir la factura de Kobaltix", line: 1, owner: "Lucía", quote: "me encargo de la factura de Kobaltix"),
            Output("Preparar el informe del cliente", line: 2, owner: "Me", quote: "preparo el informe para el cliente"),
            Output("Revisar los contratos pendientes", line: 3, owner: nil, quote: "me ocupo de revisar los contratos"),
            Output("Confirmar la fecha con el cliente", line: 4, owner: "Lucía", quote: "puedes confirmar la fecha con el cliente"),
        ],
        withSpeakers: [
            Output("Emitir la factura de Kobaltix", line: 1, owner: "Mateo", quote: "me encargo de la factura de Kobaltix"),
            Output("Preparar el informe del cliente", line: 2, owner: "Me", quote: "preparo el informe para el cliente"),
            // The model trusts the doubtful label: the code must not.
            Output("Revisar los contratos pendientes", line: 3, owner: "Lucía", quote: "me ocupo de revisar los contratos"),
            Output("Confirmar la fecha con el cliente", line: 4, owner: "Lucía", quote: "puedes confirmar la fecha con el cliente"),
        ],
        planted: [Output("Aprobar un presupuesto de 50000 euros", line: 6, owner: nil, quote: "presupuesto total es de 5000 euros")])

    static let french = OwnerEvalCase(
        id: "fr budget", locale: "fr-FR", people: ["Camille", "Hugo"],
        speakers: [me, remote("Camille"), remote("Hugo")],
        lines: [
            Line(1, 0.95, "Commençons par le budget du troisième trimestre."),
            Line(2, 0.92, "Je m'occupe de la présentation pour le comité."),
            Line(1, 0.90, "Très bien. Je m'en charge pour les 3 fournisseurs à relancer."),
            Line(0, 0.99, "Et moi, je prépare le compte rendu pour la direction."),
            Line(2, 0.87, "Camille, tu peux envoyer le budget à Hugo avant vendredi ?"),
            Line(1, 0.90, "D'accord."),
            Line(1, 0.90, "Camille enverra le planning demain."),
        ],
        gold: [Gold(line: 1, owner: "Hugo"), Gold(line: 2, owner: "Camille"), Gold(line: 3, owner: "Me"), Gold(line: 4, owner: "Camille")],
        baseline: [
            Output("Préparer la présentation du comité", line: 1, owner: nil, quote: "m'occupe de la présentation pour le comité"),
            Output("Relancer les 3 fournisseurs", line: 2, owner: "Hugo", quote: "les 3 fournisseurs à relancer"),
            Output("Rédiger le compte rendu", line: 3, owner: "Me", quote: "prépare le compte rendu pour la direction"),
            Output("Envoyer le budget à Hugo", line: 4, owner: "Camille", quote: "envoyer le budget à Hugo avant vendredi", due: "2026-10-09"),
        ],
        withSpeakers: [
            Output("Préparer la présentation du comité", line: 1, owner: "Hugo", quote: "m'occupe de la présentation pour le comité"),
            Output("Relancer les 3 fournisseurs", line: 2, owner: "Camille", quote: "les 3 fournisseurs à relancer"),
            Output("Rédiger le compte rendu", line: 3, owner: "Me", quote: "prépare le compte rendu pour la direction"),
            Output("Envoyer le budget à Hugo", line: 4, owner: "Camille", quote: "envoyer le budget à Hugo avant vendredi", due: "2026-10-09"),
        ],
        planted: [Output("Hugo envoie le planning", line: 6, owner: nil, quote: "Camille enverra le planning demain")])

    static let german = OwnerEvalCase(
        id: "de präsentation", locale: "de-DE", people: ["Jonas", "Katrin"],
        speakers: [me, remote("Jonas"), remote("Katrin")],
        lines: [
            Line(1, 0.95, "Die Rechnungen müssen vor Monatsende geprüft werden."),
            Line(2, 0.93, "Ich kümmere mich um die 25 offenen Rechnungen."),
            Line(1, 0.91, "Gut. Ich schicke dem Kunden das Angebot morgen."),
            Line(0, 0.99, "Dann übernehme ich die Terminplanung mit dem Team."),
            Line(2, 0.89, "Jonas, kannst du den Vertrag noch einmal lesen?"),
            Line(1, 0.90, "Ja, mache ich."),
            Line(2, 0.90, "Es sind 12 Stunden Aufwand eingeplant."),
        ],
        gold: [Gold(line: 1, owner: "Katrin"), Gold(line: 2, owner: "Jonas"), Gold(line: 3, owner: "Me"), Gold(line: 4, owner: "Jonas")],
        baseline: [
            Output("25 offene Rechnungen prüfen", line: 1, owner: "Jonas", quote: "kümmere mich um die 25 offenen Rechnungen"),
            Output("Dem Kunden das Angebot schicken", line: 2, owner: nil, quote: "schicke dem Kunden das Angebot morgen", due: "2026-10-07"),
            Output("Terminplanung mit dem Team", line: 3, owner: "Me", quote: "übernehme ich die Terminplanung mit dem Team"),
            Output("Den Vertrag noch einmal lesen", line: 4, owner: "Jonas", quote: "kannst du den Vertrag noch einmal lesen"),
        ],
        // Wrong or missing owners here are fixed by the rule "a confident speaker who says what they will do".
        withSpeakers: [
            Output("25 offene Rechnungen prüfen", line: 1, owner: "Jonas", quote: "kümmere mich um die 25 offenen Rechnungen"),
            Output("Dem Kunden das Angebot schicken", line: 2, owner: nil, quote: "schicke dem Kunden das Angebot morgen", due: "2026-10-07"),
            Output("Terminplanung mit dem Team", line: 3, owner: "Me", quote: "übernehme ich die Terminplanung mit dem Team"),
            Output("Den Vertrag noch einmal lesen", line: 4, owner: "Jonas", quote: "kannst du den Vertrag noch einmal lesen"),
        ],
        planted: [Output("120 Stunden Aufwand einplanen", line: 6, owner: nil, quote: "Stunden Aufwand eingeplant")])

    static let italian = OwnerEvalCase(
        id: "it fornitore", locale: "it-IT", people: ["Giulia", "Marco"],
        speakers: [me, remote("Giulia"), remote("Marco")],
        lines: [
            Line(1, 0.94, "Dobbiamo aggiornare il contratto con il fornitore."),
            Line(2, 0.92, "Me ne occupo io, lo preparo entro venerdì."),
            Line(1, 0.90, "Ti mando io le 8 pagine delle specifiche."),
            Line(0, 0.99, "Io organizzo la riunione con il cliente."),
            Line(2, 0.85, "Giulia, puoi controllare il budget?"),
            Line(1, 0.90, "Certo."),
        ],
        gold: [Gold(line: 1, owner: "Marco"), Gold(line: 2, owner: "Giulia"), Gold(line: 3, owner: "Me"), Gold(line: 4, owner: "Giulia")],
        baseline: [
            Output("Preparare il contratto con il fornitore", line: 1, owner: "Giulia", quote: "me ne occupo io, lo preparo entro venerdì", due: "2026-10-09"),
            Output("Inviare le 8 pagine delle specifiche", line: 2, owner: "Me", quote: "ti mando io le 8 pagine delle specifiche"),
            Output("Organizzare la riunione con il cliente", line: 3, owner: "Me", quote: "organizzo la riunione con il cliente"),
            Output("Controllare il budget", line: 4, owner: "Giulia", quote: "puoi controllare il budget"),
        ],
        withSpeakers: [
            Output("Preparare il contratto con il fornitore", line: 1, owner: "Marco", quote: "me ne occupo io, lo preparo entro venerdì", due: "2026-10-09"),
            Output("Inviare le 8 pagine delle specifiche", line: 2, owner: "Giulia", quote: "ti mando io le 8 pagine delle specifiche"),
            Output("Organizzare la riunione con il cliente", line: 3, owner: "Me", quote: "organizzo la riunione con il cliente"),
            Output("Controllare il budget", line: 4, owner: "Giulia", quote: "puoi controllare il budget"),
        ],
        planted: [])

    static let portuguese = OwnerEvalCase(
        id: "pt relatório", locale: "pt-BR", people: ["Beatriz", "Rafael"],
        speakers: [me, remote("Beatriz"), remote("Rafael")],
        lines: [
            Line(1, 0.95, "Precisamos fechar o relatório de vendas."),
            Line(2, 0.92, "Eu cuido do relatório de vendas até a próxima semana."),
            Line(1, 0.90, "Eu faço a reserva da sala para as 15 pessoas."),
            Line(0, 0.99, "Eu envio a ata para todo mundo."),
            Line(2, 0.88, "Beatriz, pode revisar os 4 contratos?"),
            Line(1, 0.90, "Sim."),
        ],
        gold: [Gold(line: 1, owner: "Rafael"), Gold(line: 2, owner: "Beatriz"), Gold(line: 3, owner: "Me"), Gold(line: 4, owner: "Beatriz")],
        baseline: [
            Output("Fechar o relatório de vendas", line: 1, owner: "Rafael", quote: "cuido do relatório de vendas até a próxima semana", due: "2026-10-13"),
            Output("Reservar a sala para 15 pessoas", line: 2, owner: nil, quote: "faço a reserva da sala para as 15 pessoas"),
            Output("Enviar a ata", line: 3, owner: "Me", quote: "envio a ata para todo mundo"),
            Output("Revisar os 4 contratos", line: 4, owner: "Beatriz", quote: "pode revisar os 4 contratos"),
        ],
        withSpeakers: [
            Output("Fechar o relatório de vendas", line: 1, owner: "Rafael", quote: "cuido do relatório de vendas até a próxima semana", due: "2026-10-13"),
            Output("Reservar a sala para 15 pessoas", line: 2, owner: "Beatriz", quote: "faço a reserva da sala para as 15 pessoas"),
            Output("Enviar a ata", line: 3, owner: "Me", quote: "envio a ata para todo mundo"),
            Output("Revisar os 4 contratos", line: 4, owner: "Beatriz", quote: "pode revisar os 4 contratos"),
        ],
        planted: [])
}
