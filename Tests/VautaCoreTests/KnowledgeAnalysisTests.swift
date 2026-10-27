// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Deterministic name resolution: exact and context matches, ambiguity,
/// misrecognition hints, languages and scripts.
@Suite("Knowledge · analysis")
struct KnowledgeAnalysisTests {
    @Test func exactAndContextResolution() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        _ = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan García", aliases: ["Juan"]))
        let juanM = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan Martín", aliases: ["Juan", "Juanma"]))
        let kobaltix = try await s.saveEntity(EntityDraft(kind: .project, name: "Kobaltix", note: "Migración de pagos"))
        let telefonica = try await s.saveEntity(EntityDraft(kind: .client, name: "Telefónica"))
        try await s.addRelation(NodeRef(.entity, juanM), .worksOn, NodeRef(.entity, kobaltix))
        try await s.addRelation(NodeRef(.entity, kobaltix), .forClient, NodeRef(.entity, telefonica))

        let m1 = try await f.meeting(["Hoy revisamos Kobaltix con el equipo", "Vale, y Juan se encarga de la migración", "Telefónica quiere fecha"])
        let refs = try await s.refs(juanM)
        #expect(refs.count == 1 && refs[0].meeting.id == m1 && refs[0].t == 10 && refs[0].resolvedBy == "context")
        #expect(try await s.refs(kobaltix).first?.resolvedBy == "exact")
        #expect(try await s.refs(telefonica).count == 1)
    }

    @Test func ambiguousNamesAreNeverGuessedAndUserChoicesStick() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let juanG = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan García", aliases: ["Juan"]))
        let juanM = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan Martín", aliases: ["Juan"]))
        let m = try await f.meeting(["Mañana Juan dijo que lo mira"])
        let open = try await s.suggestions(m)
        #expect(open.count == 1 && open[0].kind == .ambiguous)
        #expect(Set(open[0].candidates.compactMap(\.entityID)) == [juanG, juanM])
        #expect(try await s.refs(juanG).isEmpty)

        try await s.resolveSuggestion(open[0].id, entity: juanG)
        #expect(try await s.refs(juanG).first?.resolvedBy == "user")
        #expect(try await s.suggestions(m).isEmpty)
        _ = try await s.analyze(m)
        #expect(try await s.suggestions(m).isEmpty)
        #expect(try await s.refs(juanG).count == 1)
        await #expect(throws: KnowledgeError.suggestionGone) { try await s.resolveSuggestion(open[0].id, entity: juanG) }
    }

    @Test func correctorSuggestsAndLearns() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let kobaltix = try await s.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        _ = try await s.saveGlossary(GlossaryTerm(term: "Nubelia", expansion: "plataforma de datos", pinned: true))
        let m = try await f.meeting(["Luego hablamos con Cobaltis sobre el plan", "Y Noelia revisa Nubelya"])
        let fixes = try await s.suggestions(m).filter { $0.kind == .correction }
        let cob = try #require(fixes.first { $0.surface == "Cobaltis" })
        #expect(cob.candidates.first?.entityID == kobaltix)
        #expect(fixes.contains { $0.surface == "Nubelya" && $0.candidates.first?.glossaryID != nil })
        #expect(!fixes.contains { $0.surface == "Noelia" })
        #expect(try await s.refs(kobaltix).isEmpty)

        try await s.resolveSuggestion(cob.id, entity: kobaltix)
        let next = try await f.meeting(["El lunes cerramos Cobaltis"])
        #expect(try await s.refs(kobaltix).contains { $0.meeting.id == next && $0.resolvedBy == "exact" })
    }

    @Test func deletingAGlossaryTermRemovesItFromOpenSuggestions() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let term = try await s.saveGlossary(GlossaryTerm(term: "Nubelia", expansion: "plataforma de datos", pinned: true))
        let m = try await f.meeting(["Y Noelia revisa Nubelya"])
        let before = try await s.suggestions(m)
        #expect(before.contains { $0.surface == "Nubelya" && $0.candidates.contains { $0.glossaryID == term } })
        try await s.deleteGlossary(term)
        #expect(try await s.suggestions(m).allSatisfy { $0.surface != "Nubelya" })
    }

    @Test func germanNounsDoNotFloodSuggestions() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        // Surnames one letter away from everyday nouns: "Bauer"/"Bauern", "Kunze"/"Kunde".
        _ = try await s.saveEntity(EntityDraft(kind: .person, name: "Bauer"))
        _ = try await s.saveEntity(EntityDraft(kind: .person, name: "Kunze"))
        let text = "Wir haben gestern die Bauern informiert, der Kunde wartet und das Projekt läuft."
        let m = try await f.meeting([text])
        // In Spanish rules every capitalized word is a name candidate…
        #expect(try await s.suggestions(m).contains { $0.kind == .correction })
        // …in German every noun is capitalized, so capitalization says nothing.
        let summary = try await s.analyze(m, locale: Locale(identifier: "de-DE"))
        #expect(summary.corrections == 0)
        #expect(try await s.suggestions(m).isEmpty)
    }

    @Test func hannahIsNotAnaInEnglish() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        // "Anna" and "Hannah" share the Spanish sound key ("ana").
        _ = try await s.saveEntity(EntityDraft(kind: .person, name: "Anna López", aliases: ["Anna"]))
        _ = try await s.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        let m = try await f.meeting(["Then Hannah said that Cobaltix ships in May"])
        let english = try await s.analyze(m, locale: Locale(identifier: "en-US"))
        let fixes = try await s.suggestions(m)
        #expect(english.corrections == 1)
        #expect(!fixes.contains { $0.surface == "Hannah" })
        #expect(fixes.contains { $0.surface == "Cobaltix" })
        // The Spanish rules (legacy meetings) still group them.
        _ = try await s.analyze(m, locale: Locale(identifier: "es-ES"))
        #expect(try await s.suggestions(m).contains { $0.surface == "Hannah" })
    }

    @Test func chineseNamesMatchWithoutSpaces() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let wang = try await s.saveEntity(EntityDraft(kind: .person, name: "王伟"))
        let tanaka = try await s.saveEntity(EntityDraft(kind: .person, name: "田中太郎", aliases: ["田中"]))
        let m = try await f.meeting(["我们今天和王伟讨论了项目", "明日田中さんが来ます"])
        _ = try await s.analyze(m, locale: Locale(identifier: "zh-Hans"))
        let refs = try await s.refs(wang)
        #expect(refs.count == 1 && refs[0].surface == "王伟")
        #expect(try await s.refs(tanaka).first?.surface == "田中")
        // The question parser uses the same matcher.
        #expect(try await s.entitiesNamed(in: "王伟说了什么?") == [wang])
    }

    @Test func thaiNamesMatchWithoutSpaces() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let somchai = try await s.saveEntity(EntityDraft(kind: .person, name: "สมชาย"))
        let m = try await f.meeting(["สมชายไปตลาดเมื่อวาน"])
        _ = try await s.analyze(m, locale: Locale(identifier: "th-TH"))
        #expect(try await s.refs(somchai).first?.surface == "สมชาย")
    }

    @Test func surfacesKeepTheOriginalText() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let jl = try await s.saveEntity(EntityDraft(kind: .person, name: "Jean-Luc Picard", aliases: ["Jean-Luc"]))
        let m = try await f.meeting(["Hier, Jean-Luc a validé le budget"])
        _ = try await s.analyze(m, locale: Locale(identifier: "fr-FR"))
        #expect(try await s.refs(jl).first?.surface == "Jean-Luc")
    }

    @Test func functionWordAliasesOnlyMatchAsNames() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let will = try await s.saveEntity(EntityDraft(kind: .person, name: "Will Smith", aliases: ["Will"]))
        let m = try await f.meeting(["We will ship it next week and I told Will about it"])
        _ = try await s.analyze(m, locale: Locale(identifier: "en-US"))
        let refs = try await s.refs(will)
        #expect(refs.count == 1 && refs[0].surface == "Will")
    }

    @Test func meetingLanguageIsReadFromTheStore() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["hola"])
        #expect(try await s.meetingLocale(m).identifier == "es-ES")
        try await s.setMeetingLocaleForTest(m, "de-DE")
        #expect(try await s.meetingLocale(m).identifier == "de-DE")
        try await s.setMeetingLocaleForTest(m, nil)
        #expect(try await s.meetingLocale(m).identifier == "es-ES")
    }

    /// Retention purges the transcript but keeps the meeting's knowledge;
    /// re-analysis must not wipe it (it has nothing left to re-derive).
    @Test func reanalysisKeepsKnowledgeOfPurgedMeetings() async throws {
        let f = try KnowledgeFixture(knowledgeRetentionDays: 365)
        let s = f.store!
        let kob = try await s.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        let old = try await f.meeting(["Revisamos Kobaltix con el cliente", "El presupuesto de Kobaltix sube"], at: .now - 91 * 86_400)
        try await s.saveCard(MeetingCard(summary: "Revisión de Kobaltix"), of: old)
        #expect(try await s.refs(kob).count == 2)
        try await s.purgeExpired()
        #expect(try await s.segments(of: old).isEmpty)
        #expect(try await s.analyzableMeetingIDs().isEmpty)

        let summary = try await s.analyze(old)
        #expect(summary.skipped)
        let refs = try await s.refs(kob)
        #expect(refs.count == 2 && refs.allSatisfy { $0.meeting.id == old && $0.surface == "Kobaltix" })
        #expect(try await s.meetingIDs(matching: MeetingFilter(entities: [kob])) == [old])
    }

    @Test func impactWalksTheGraphWithoutLooping() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let a = try await s.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        let b = try await s.saveEntity(EntityDraft(kind: .person, name: "Bea"))
        try await s.addRelation(NodeRef(.entity, a), .relatedTo, NodeRef(.entity, b))
        try await s.addRelation(NodeRef(.entity, b), .relatedTo, NodeRef(.entity, a))
        let cycle = try await s.impact(NodeRef(.entity, a), depth: 3)
        #expect(Set(cycle.map(\.ref)).count == cycle.count)
        #expect(!cycle.contains { $0.ref == NodeRef(.entity, a) })
        await #expect(throws: KnowledgeError.relationNeedsTwoNodes) {
            try await s.addRelation(NodeRef(.entity, a), .relatedTo, NodeRef(.entity, a))
        }

        let root = try await s.bulkGraphForTest(entities: 1000, edges: 10_000)
        var big: [GraphNode] = []
        let took = try await fastest(of: 3) { big = try await s.impact(NodeRef(.entity, root), depth: 3) }
        #expect(!big.isEmpty)
        #expect(took < .seconds(2))
    }
}
