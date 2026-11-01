// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The sound keys of English, French, Italian and Portuguese: spellings of one sound that a transcriber mixes up come out
/// alike, names that sound different stay apart, and the corrector suggests the name the Context knows.
@Suite("Knowledge · sound keys beyond Spanish")
struct PhoneticKeysTests {
    private func same(_ pairs: [(String, String)], _ language: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for (a, b) in pairs {
            let ka = PhoneticKeys.key(a, language: language), kb = PhoneticKeys.key(b, language: language)
            #expect(ka != nil && ka == kb, "\(language): \(a) (\(ka ?? "nil")) and \(b) (\(kb ?? "nil"))", sourceLocation: sourceLocation)
        }
    }

    private func apart(_ pairs: [(String, String)], _ language: String, sourceLocation: SourceLocation = #_sourceLocation) {
        for (a, b) in pairs {
            #expect(PhoneticKeys.key(a, language: language) != PhoneticKeys.key(b, language: language), "\(language): \(a) and \(b)",
                    sourceLocation: sourceLocation)
        }
    }

    @Test func english() {
        same([("Kobaltix", "Cobaltics"), ("Kubernetes", "Cubernetes"), ("Philip", "Phillip"), ("Philip", "Filip"),
              ("Thomas", "Tomas"), ("Elizabeth", "Elisabeth"), ("Catherine", "Katherine"), ("Brian", "Bryan"),
              ("Eric", "Erick"), ("Erik", "Eric"), ("Sarah", "Sara"), ("Matthew", "Mathew"), ("Megan", "Meghan"),
              ("Christine", "Kristine"), ("Carla", "Karla"), ("Qualcomm", "Kwalkom"), ("Aaron", "Aron"),
              ("Mohammed", "Mohamed"), ("Kelly", "Kelli"), ("Knowles", "Nowles")], "en")
        apart([("Hannah", "Anna"), ("Peter", "Petra"), ("Mark", "Mike"), ("Laura", "Lara"), ("Simon", "Simone"),
               ("Daniel", "Daniela"), ("Martin", "Martina"), ("Kobaltix", "Kobalt")], "en")
    }

    @Test func french() {
        same([("Thibaut", "Tibo"), ("Gauthier", "Gautier"), ("Arnaud", "Arnaut"), ("Laurent", "Lauran"), ("Renaud", "Reno"),
              ("Philippe", "Filipe"), ("Mathieu", "Matthieu"), ("Jacques", "Jack"), ("Claire", "Clair"), ("Rose", "Roze"),
              ("Michel", "Michelle"), ("Thierry", "Tierry"), ("Gérard", "Gerar"), ("Hélène", "Elene"),
              ("Benoît", "Benoit"), ("Raphaël", "Rafael"), ("Sylvain", "Silvin"), ("Kobaltix", "Cobaltix"),
              ("Vincent", "Vinsan"), ("Clément", "Clemant"), ("Étienne", "Etiene"), ("Emmanuel", "Emanuel"),
              ("Thibault", "Thibaut"), ("Renault", "Renaud"), ("Philip", "Philippe"), ("Maurice", "Morisse"), ("Brice", "Bryce"),
              ("Gauthier", "Gautié"), ("Roger", "Rogé"), ("René", "Renée"), ("Chloé", "Kloé"), ("Christophe", "Kristof"),
              ("Dupont", "Dupond"), ("Florent", "Floran")], "fr")
        // A vowel and n or m sound nasal only before another consonant or at the end.
        apart([("Paul", "Paula"), ("Louis", "Lucie"), ("Marie", "Mario"), ("Anne", "Anna"), ("Nicolas", "Nicole"),
               ("Julien", "Julie"), ("Jean", "Jeanne"), ("Simon", "Simone"), ("Martin", "Martine"), ("Adrien", "Adrienne"),
               ("Germain", "Germaine"), ("Louis", "Louise"), ("Yann", "Yan"), ("Bastien", "Bastian"), ("Carmen", "Carman"),
               // Final letters French does say: the e of -et, a d after a vowel, an x after one other than u, a z.
               ("Jacquet", "Jacques"), ("David", "Davi"), ("Félix", "Feli"), ("Lopez", "Lope"), ("Gauthier", "Gauti"),
               // Accents: a said é, a vowel apart after a diaeresis, a hard g before é.
               ("René", "Rennes"), ("Anaïs", "Anne"), ("Guérin", "Gérin")], "fr")
    }

    @Test func italian() {
        same([("Chiara", "Kiara"), ("Giovanni", "Giovani"), ("Alessandro", "Alesandro"), ("Federico", "Federiko"),
              ("Michele", "Mikele"), ("Jacopo", "Iacopo"), ("Matteo", "Mateo"), ("Cecilia", "Cecillia"),
              ("Kobaltix", "Cobaltix"), ("Sophia", "Sofia"), ("Thomas", "Tomas"), ("Christopher", "Cristofer"),
              ("Raffaele", "Rafaele"), ("Massimo", "Masimo"), ("Gianni", "Giani"), ("Cristina", "Christina"),
              ("Caterina", "Katerina"), ("Ilaria", "Hilaria"), ("Enrico", "Henrico"), ("Walter", "Valter"), ("Yuri", "Iuri"),
              ("Xenia", "Ksenia"), ("Schiavone", "Skiavone"), ("Gianluca", "Gianluka")], "it")
        // A hard g before i is written gh; j reads as i, so "Jorjo" is "Iorio", not "Giorgio".
        apart([("Marco", "Marta"), ("Luca", "Lucia"), ("Paolo", "Paola"), ("Carlo", "Cecilia"), ("Gino", "Gina"),
               ("Ghiberti", "Giberti"), ("Giorgio", "Jorjo")], "it")
    }

    @Test func portuguese() {
        same([("Joaquim", "Joakin"), ("Luiz", "Luis"), ("Teresa", "Tereza"), ("Thiago", "Tiago"), ("Raphael", "Rafael"),
              ("Matheus", "Mateus"), ("Henrique", "Enrique"), ("Wellington", "Welington"), ("Xavier", "Chavier"),
              ("Brasil", "Brazil"), ("Luíza", "Luísa"), ("Thaís", "Taís"), ("Kauã", "Cauã"), ("Cecília", "Secilia"),
              ("Kobaltix", "Cobaltix"), ("Gonçalves", "Gonsalves"), ("Isabela", "Izabela"), ("Neusa", "Neuza"),
              ("Sueli", "Suely"), ("Yasmin", "Iasmin"), ("Cristiano", "Christiano"), ("Kátia", "Cátia"), ("Mônica", "Monika"),
              ("Érica", "Erika"), ("Hélio", "Elio"), ("Sílvia", "Sylvia"), ("Natália", "Nathalia")], "pt")
        // lh is a sound of its own, not an l.
        apart([("Rafael", "Rafaela"), ("João", "Joana"), ("Pedro", "Paulo"), ("Maria", "Mario"), ("Lucas", "Luiza"),
               ("Guilherme", "Guilerme")], "pt")
    }

    @Test func codesNeverSoundAlike() {
        #expect(PhoneticKeys.key("2024", language: "en") == "2024")
        #expect(PhoneticKeys.key("2024", language: "en") != PhoneticKeys.key("1999", language: "en"))
        #expect(PhoneticKeys.key("…", language: "fr") == nil, "no letters: no key")
    }

    // MARK: The corrector

    @Test func theCorrectorSuggestsWhatTheContextKnowsBySound() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let kobaltix = try await s.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        let chiara = try await s.saveEntity(EntityDraft(kind: .person, name: "Chiara Rossi", aliases: ["Chiara"]))
        let joaquim = try await s.saveEntity(EntityDraft(kind: .person, name: "Joaquim Silva", aliases: ["Joaquim"]))
        let thibaut = try await s.saveEntity(EntityDraft(kind: .person, name: "Thibaut Martin", aliases: ["Thibaut"]))
        // Three letters away from what the Context knows: beyond the spelling distance the corrector allows, the same sound.
        let cases: [(text: String, surface: String, locale: String, entity: Int64)] = [
            ("Then we asked Cobaltics about the launch", "Cobaltics", "en-US", kobaltix),
            ("Poi abbiamo sentito Kiara sul piano", "Kiara", "it-IT", chiara),
            ("Depois falamos com Joakin sobre o plano", "Joakin", "pt-BR", joaquim),
            ("Ensuite nous avons appelé Tibo pour le plan", "Tibo", "fr-FR", thibaut),
        ]
        for c in cases {
            let m = try await f.meeting([c.text])
            _ = try await s.analyze(m, locale: Locale(identifier: c.locale))
            let fix = try await s.suggestions(m).first { $0.kind == .correction && $0.surface == c.surface }
            #expect(fix?.candidates.first?.entityID == c.entity, "\(c.locale): \(c.surface)")
        }
    }

    @Test func theCorrectorHearsTheWordAsWritten() async throws {
        // Folded to "rene", the é would read as a silent e and "René" would sound like "Rennes".
        let f = try KnowledgeFixture()
        let s = f.store!
        _ = try await s.saveEntity(EntityDraft(kind: .project, name: "Rennes"))
        let m = try await f.meeting(["Hier nous avons vu René pour le plan"])
        _ = try await s.analyze(m, locale: Locale(identifier: "fr-FR"))
        #expect(try await s.suggestions(m).filter { $0.kind == .correction }.isEmpty)
    }
}
