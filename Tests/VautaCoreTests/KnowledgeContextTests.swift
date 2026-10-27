// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The user's context: entities, merge/delete, self entity, calendar, series,
/// glossary, privacy of edits and persisted-format compatibility.
@Suite("Knowledge · context")
struct KnowledgeContextTests {
    @Test func nameSearchByTrigramAndPrefix() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let juanG = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan García", aliases: ["Juan"]))
        let juanM = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan Martín", aliases: ["Juanma"]))
        _ = try await s.saveEntity(EntityDraft(kind: .client, name: "Telefónica"))
        _ = try await s.saveGlossary(GlossaryTerm(term: "Nubelia"))
        #expect(try await s.searchNames("telef").first?.text == "Telefónica")
        #expect(Set(try await s.searchNames("ju").map(\.target)) == [.entity(juanG), .entity(juanM)])
        #expect(try await s.searchNames("nube").first?.target == .glossary(1))
        #expect(try await s.searchNames("\" OR 1=1 --").isEmpty)
    }

    @Test func listsUseLocaleAwareOrder() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        for name in ["Zoe", "Álvaro", "émile", "Bea"] { _ = try await s.saveEntity(EntityDraft(kind: .person, name: name)) }
        #expect(try await s.entities(.person).map(\.name) == ["Álvaro", "Bea", "émile", "Zoe"])
        for term in ["Zeta", "Órbita", "alfa"] { _ = try await s.saveGlossary(GlossaryTerm(term: term)) }
        _ = try await s.saveGlossary(GlossaryTerm(term: "Pinned", pinned: true))
        #expect(try await s.glossary().map(\.term) == ["Pinned", "alfa", "Órbita", "Zeta"])
    }

    @Test func renamingKeepsTheOldNameAsAlias() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let id = try await s.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        _ = try await s.saveEntity(EntityDraft(id: id, kind: .project, name: "Kobalt Pay"))
        #expect(try await s.entity(id)?.aliases == ["Kobaltix"])
        let m = try await f.meeting(["Seguimos con Kobaltix"])
        #expect(try await s.refs(id).first?.meeting.id == m)
    }

    @Test func emailsBelongToOnePerson() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        _ = try await s.saveEntity(EntityDraft(kind: .person, name: "Ana", email: "ana@example.com"))
        await #expect(throws: KnowledgeError.emailInUse("ana@example.com")) {
            try await s.saveEntity(EntityDraft(kind: .person, name: "Ana B", email: "ANA@example.com"))
        }
        await #expect(throws: KnowledgeError.emptyName) { try await s.saveEntity(EntityDraft(kind: .person, name: " \u{202E} ")) }
    }

    @Test func selfEntityHasNoAutomaticAliasAndALocalizedName() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let me = try await s.selfEntity()
        #expect(try await s.selfEntity() == me)
        let stored = try #require(try await s.entity(me))
        #expect(stored.name == MeetingStore.legacySelfName && stored.isSelf && stored.aliases.isEmpty)
        #expect(stored.displayName == String(localized: "Me", comment: "The user of the app, as a person in the context and as a task owner"))
        // Saving it from the context editor never turns the pronoun into an alias.
        _ = try await s.saveEntity(EntityDraft(stored))
        #expect(try await s.intsForTest("SELECT COUNT(*) FROM aliases WHERE entity_id = ?", [.integer(me)]) == [0])
        let m = try await f.meeting(["Yo creo que yo lo hago", "Vale, tú lo haces"])
        #expect(try await s.refs(me).isEmpty)
        // A task owned by the user shows the localized name.
        try await s.addTask(m, text: "Enviar el informe", ownerID: me)
        #expect(try await s.tasks(m).first?.ownerName == stored.displayName)
    }

    @Test func selfEntityWithARealNameMatchesIt() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let me = try await s.selfEntity()
        // Stores written by 0.1.0 may have the alias "yo" on the self entity: saving drops it.
        try await s.executeForTest("INSERT INTO aliases(alias_norm, alias, entity_id, source) VALUES ('yo', 'Yo', ?, 'user')", [.integer(me)])
        var draft = EntityDraft(try #require(try await s.entity(me)))
        draft.name = "Mayté"
        draft.aliases.append("May")
        _ = try await s.saveEntity(draft)
        let aliases = try await s.stringsForTest("SELECT alias_norm FROM aliases WHERE entity_id = ? ORDER BY alias_norm", [.integer(me)])
        #expect(aliases == ["may", "mayte"])
        let stored = try #require(try await s.entity(me))
        #expect(stored.isSelf && stored.displayName == "Mayté")
        let m = try await f.meeting(["Se lo pasamos a Mayté mañana", "Yo creo que sí"])
        #expect(try await s.refs(me).filter { $0.meeting.id == m }.map(\.surface) == ["Mayté"])
    }

    @Test func userCardThatCannotBeReadIsNeverReplaced() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["Hablamos del presupuesto"])
        try await s.executeForTest(#"UPDATE meetings SET card = '{"resumen": 5}', card_source = 'user' WHERE id = ?"#, [.integer(m)])
        try await s.applyMinutes(ValidatedMinutes(), to: m)
        #expect(try await s.stringsForTest("SELECT card || '|' || card_source FROM meetings WHERE id = ?", [.integer(m)]) == [#"{"resumen": 5}|user"#])
    }

    @Test func legacySelfAliasDoesNotFloodMentions() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let me = try await s.selfEntity()
        // Stores written by 0.1.0 may have the alias "yo" on the self entity.
        try await s.executeForTest("INSERT INTO aliases(alias_norm, alias, entity_id, source) VALUES ('yo', 'Yo', ?, 'user')", [.integer(me)])
        _ = try await f.meeting(["Yo creo que yo lo hago mañana"])
        #expect(try await s.refs(me).isEmpty)
    }

    @Test func mergeUpdatesEveryReference() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let juanG = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan García", aliases: ["Juan"]))
        let juanM = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan Martín", aliases: ["Juan"]))
        let other = try await s.saveEntity(EntityDraft(kind: .person, name: "Otro", email: "otro@example.com"))
        let series = try await s.saveSeries(MeetingSeries(titlePattern: "Daily", defaultEntities: [juanG, other, juanM]))
        let me = try await s.selfEntity()
        let m = try await f.meeting(["Mañana Juan dijo que lo mira"])
        let suggestion = try #require(try await s.suggestions(m).first)
        #expect(suggestion.candidates.count == 2)

        try await s.mergeEntity(juanG, into: juanM)
        #expect(try await s.series().first { $0.id == series }?.defaultEntities == [juanM, other])
        let merged = try #require(try await s.suggestions(m).first)
        #expect(merged.candidates.map(\.entityID) == [juanM] && merged.candidates[0].label == "Juan Martín")
        #expect(try await s.entities(.person).filter { $0.name.hasPrefix("Juan") }.map(\.id) == [juanM])
        #expect(try await s.entity(juanM)?.aliases.contains("Juan García") == true)
        try await s.resolveSuggestion(merged.id, entity: juanG)   // a stale id follows the merge
        #expect(try await s.refs(juanM).contains { $0.meeting.id == m && $0.resolvedBy == "user" })

        // Merging the self entity moves the reference too; merging into a merged entity follows it.
        try await s.mergeEntity(me, into: other)
        #expect(try await s.selfEntityID() == other)
        #expect(try await s.selfEntity() == other)
        let extra = try await s.saveEntity(EntityDraft(kind: .person, name: "Extra"))
        try await s.mergeEntity(extra, into: me)
        #expect(try await s.intsForTest("SELECT merged_into FROM entities WHERE id = ?", [.integer(extra)]) == [other])
        #expect(try await s.entity(other)?.email == "otro@example.com")
    }

    @Test func deleteRemovesEveryReference() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let juanG = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan García", aliases: ["Juan"]))
        let juanM = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan Martín", aliases: ["Juan"]))
        let series = try await s.saveSeries(MeetingSeries(titlePattern: "Daily", defaultEntities: [juanG, juanM]))
        let m = try await f.meeting(["Mañana Juan dijo que lo mira"])
        let suggestion = try #require(try await s.suggestions(m).first)

        try await s.deleteEntity(juanG)
        #expect(try await s.series().first { $0.id == series }?.defaultEntities == [juanM])
        #expect(try await s.suggestions(m).first?.candidates.map(\.entityID) == [juanM])
        await #expect(throws: KnowledgeError.entityGone) { try await s.resolveSuggestion(suggestion.id, entity: juanG) }
        try await s.deleteEntity(juanM)
        #expect(try await s.suggestions(m).isEmpty)
        #expect(try await s.series().first { $0.id == series }?.defaultEntities == [])

        let me = try await s.selfEntity()
        try await s.deleteEntity(me)
        #expect(try await s.selfEntityID() == nil)
        let newMe = try await s.selfEntity()
        #expect(try await s.entity(newMe)?.isSelf == true)

        // Deleting a merge target does not resurrect the merged entity.
        let x = try await s.saveEntity(EntityDraft(kind: .person, name: "Zz Origen", email: "origen@zz.example"))
        let y = try await s.saveEntity(EntityDraft(kind: .person, name: "Zz Destino"))
        try await s.mergeEntity(x, into: y)
        #expect(try await s.entity(y)?.email == "origen@zz.example")
        try await s.deleteEntity(y)
        #expect(try await s.entities().filter { $0.name.hasPrefix("Zz ") }.isEmpty)
    }

    @Test(arguments: [("García, Ana", "Ana"), ("Dr. John Smith", "John"), ("Prof. Dr. Hans Müller", "Hans"), ("Mr. Bo Chen", "Bo"),
                      ("José", nil), ("王伟", nil), ("田中 太郎", nil), ("김민수", nil), ("ana@example.com", nil)] as [(String, String?)])
    func calendarGivenNames(_ full: String, _ given: String?) {
        #expect(MeetingStore.givenName(of: full) == given)
    }

    @Test func calendarAttendeesBecomePendingPeopleAndAreCleanedUp() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let id = try await s.startMeeting(at: .now)
        try await s.append(Segment(channel: .me, start: 0, end: 1, text: "hola", isFinal: true), to: id)
        let attendees = try await s.applyCalendar(CalendarMeeting(title: "Daily zzcalxq", attendees: [
            .init(name: "García, Ana", email: "ana@zzcal.example", isCurrentUser: false),
            .init(name: "王伟", email: nil, isCurrentUser: false),
            .init(name: "Yo", email: nil, isCurrentUser: true),
        ], seriesKey: "serie-zzcal"), to: id)
        try await s.endMeeting(id, at: .now)
        #expect(attendees.count == 2)
        #expect(try await s.meetings().first { $0.id == id }?.title == "Daily zzcalxq")
        let pending = try await s.entities(.person).filter { !$0.confirmed }
        #expect(Set(pending.map(\.name)) == ["García, Ana", "王伟"])
        #expect(pending.first { $0.name == "García, Ana" }?.aliases == ["Ana"])
        #expect(pending.first { $0.name == "王伟" }?.aliases == [])
        #expect(try await s.series().first?.defaultEntities.count == 2)

        try await s.deleteMeeting(id)
        #expect(try await s.entities(.person).isEmpty)
        #expect(try await s.series().isEmpty)
        #expect(!(try await s.imageContains("zzcal")))
    }

    @Test func calendarLinksKnownPeopleInsteadOfDuplicating() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let ana = try await s.saveEntity(EntityDraft(kind: .person, name: "Ana López"))
        func record(_ attendees: [CalendarMeeting.Attendee]) async throws -> [Int64] {
            let id = try await s.startMeeting(at: .now)
            try await s.append(Segment(channel: .me, start: 0, end: 1, text: "hola", isFinal: true), to: id)
            let ids = try await s.applyCalendar(CalendarMeeting(title: "Sync", attendees: attendees, seriesKey: nil), to: id)
            try await s.endMeeting(id, at: .now)
            return ids
        }
        #expect(try await record([.init(name: "Ana López", email: "ana@example.com", isCurrentUser: false)]) == [ana])
        #expect(try await s.entity(ana)?.email == "ana@example.com")
        // A pending calendar person without email is reused, not duplicated.
        let first = try await record([.init(name: "Luis Pérez", email: nil, isCurrentUser: false)])
        let second = try await record([.init(name: "Luis Pérez", email: nil, isCurrentUser: false)])
        #expect(first == second)
        // Someone else with the same name but another address stays separate.
        let other = try await record([.init(name: "Ana López", email: "ana.lopez@other.example", isCurrentUser: false)])
        #expect(other != [ana])
        #expect(try await s.entities(.person).count == 3)
    }

    @Test func mostSpecificSeriesWins() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let daily = try await s.saveSeries(MeetingSeries(titlePattern: "Daily"))
        let payments = try await s.saveSeries(MeetingSeries(titlePattern: "Daily pagos"))
        let sync = try await s.saveSeries(MeetingSeries(titlePattern: "Sync"))
        #expect(try await s.seriesMatching(title: "Daily de equipo")?.id == daily)
        #expect(try await s.seriesMatching(title: "Daily pagos — sprint 4")?.id == payments)
        #expect(try await s.seriesMatching(title: "Weekly sync")?.id == sync)
        #expect(try await s.seriesMatching(title: "Async review") == nil)
    }

    @Test func editsLeaveNoPlaintextBehind() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let tmp = try await s.saveEntity(EntityDraft(kind: .topic, name: "Tema temporal", note: "zznotaviejaxq", aliases: ["zzaliasviejoxq"]))
        try await s.saveEntity(EntityDraft(id: tmp, kind: .topic, name: "Tema temporal", note: "otra cosa", aliases: []))
        #expect(!(try await s.imageContains("zznotaviejaxq")))
        #expect(!(try await s.imageContains("zzaliasviejoxq")))
    }

    @Test func contextSurvivesReopening() async throws {
        let f = try KnowledgeFixture()
        _ = try await f.store.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        _ = try await f.store.saveGlossary(GlossaryTerm(term: "Nubelia"))
        try await f.reopen()
        #expect(try await f.store.entities().map(\.name) == ["Ana"])
        #expect(try await f.store.glossary().count == 1)
    }

    /// Stores written with the previous `norm` keep matching after the
    /// recompute step; aliases that now collide are merged, never lost.
    @Test func aliasNormalizationRecompute() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let person = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan García"))
        // Rows as 0.1.0 wrote them: "Łukasz" kept the ł, and a learned "Lukasz" is a separate row.
        try await s.executeForTest("INSERT INTO aliases(alias_norm, alias, entity_id, source, weight) VALUES ('łukasz', 'Łukasz', ?, 'user', 1)", [.integer(person)])
        try await s.executeForTest("INSERT INTO aliases(alias_norm, alias, entity_id, source, weight) VALUES ('lukasz', 'Lukasz', ?, 'learned', 2.5)", [.integer(person)])
        try await s.executeForTest("INSERT INTO aliases(alias_norm, alias, entity_id, source, weight) VALUES ('مُحَمَّد', 'مُحَمَّد', ?, 'calendar', 1)", [.integer(person)])
        try await s.recomputeAliasNormalizationForTest()
        let sql = "SELECT alias_norm || '|' || alias || '|' || source || '|' || weight FROM aliases WHERE entity_id = ? ORDER BY alias_norm"
        let rows = try await s.stringsForTest(sql, [.integer(person)])
        #expect(rows == ["juan garcia|Juan García|user|1.0", "lukasz|Łukasz|user|2.5", "محمد|مُحَمَّد|calendar|1.0"])
        try await s.recomputeAliasNormalizationForTest()
        #expect(try await s.stringsForTest(sql, [.integer(person)]) == rows, "idempotent")
        let m = try await f.meeting(["Hablé con Lukasz y con محمد"])
        #expect(try await s.refs(person).filter { $0.meeting.id == m }.count == 2)
    }

    @Test func errorsAreLocalized() {
        let errors: [KnowledgeError] = [.emptyName, .emptyTerm, .emptySeriesTitle, .emptyNote, .emptyDecision, .emptyTask,
                                        .relationNeedsTwoNodes, .suggestionGone, .entityGone, .emailInUse("a@b.c")]
        for e in errors {
            #expect(!(e.errorDescription ?? "").isEmpty)
            #expect("\(e)" == e.errorDescription)
        }
    }
}
