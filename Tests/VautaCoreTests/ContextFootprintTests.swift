// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// What the context editor reads before a merge or delete: the footprint
/// must match what the store then moves or removes.
@Suite("Context · footprint")
struct ContextFootprintTests {
    @Test func footprintCountsEverythingThatHangsFromAnEntity() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let juan = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan García", note: "Payments", email: "juan@example.com",
                                                      aliases: ["Juanito"]))
        let kob = try await s.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        try await s.addRelation(NodeRef(.entity, juan), .worksOn, NodeRef(.entity, kob))
        _ = try await s.saveGlossary(GlossaryTerm(term: "KBX", entityID: juan))
        _ = try await s.saveSeries(MeetingSeries(titlePattern: "Daily", defaultEntities: [juan, kob]))
        let m = try await f.meeting(["Juanito revisa Kobaltix", "Luego Juanito llama"])
        _ = try await s.addTask(m, text: "Send the report", ownerID: juan)

        let fp = try #require(try await s.footprint(of: juan))
        #expect(fp.aliases == [EntityAlias(text: "Juanito", origin: .user)])
        #expect(fp.mentions == 2 && fp.meetings == 1)
        #expect(fp.tasks == 1 && fp.openTasks == 1)
        // The hand-made relation and the task's owner edge.
        #expect(fp.relations == 2)
        #expect(fp.glossaryTerms == 1)
        #expect(fp.series == 1)
        #expect(fp.mergedEntries == 0)
        #expect(fp.hasNote && fp.email == "juan@example.com")
        #expect(try await s.footprint(of: 9_999) == nil)
    }

    @Test func footprintCountsSpeakersAndVoiceProfiles() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let ana = try await s.saveEntity(EntityDraft(kind: .person, name: "Ana"))
        let m = try await f.meeting(["Hola"])
        try await s.finalizeSpeakers(meetingID: m, speakers: [SpeakerDraft(channel: .others, ordinal: 1)])
        let speaker = try #require(try await s.speakers(of: m).first)
        try await s.assignSpeaker(speaker.id, toEntity: ana)
        try await s.addVoiceProfile(entityID: ana, modelID: "m", embedding: Data([1, 2, 3]), consentRecordedAt: .now)
        let fp = try #require(try await s.footprint(of: ana))
        #expect(fp.namedSpeakers == 1 && fp.voiceProfiles == 1 && fp.meetings == 1)
    }

    @Test func learnedAliasesAreReportedAsLearned() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let kob = try await s.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        let m = try await f.meeting(["Luego hablamos con Cobaltis sobre el plan"])
        let fix = try #require(try await s.suggestions(m).first { $0.surface == "Cobaltis" })
        try await s.resolveSuggestion(fix.id, entity: kob)
        let fp = try #require(try await s.footprint(of: kob))
        #expect(fp.aliases.contains(EntityAlias(text: "Cobaltis", origin: .learned)))
    }

    @Test func mergeSummaryMatchesWhatTheMergeDoes() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let jm = try await s.saveEntity(EntityDraft(kind: .person, name: "Juanma", aliases: ["Juan M."]))
        let juan = try await s.saveEntity(EntityDraft(kind: .person, name: "Juan Manuel", aliases: ["juan m."]))
        let m = try await f.meeting(["Juanma lo revisa"])
        _ = try await s.addTask(m, text: "Call the client", ownerID: jm)
        let source = try #require(try await s.entity(jm))
        let target = try #require(try await s.entity(juan))
        let summary = MergeSummary(source: source, footprint: try #require(try await s.footprint(of: jm)), target: target)
        #expect(summary.newAliases == ["Juanma"] && summary.mentions == 1 && summary.tasks == 1)

        try await s.mergeEntity(jm, into: juan)
        let after = try #require(try await s.footprint(of: juan))
        #expect(Set(after.aliases.map(\.text)) == ["Juan M.", "Juanma"] || Set(after.aliases.map(\.text)) == ["juan m.", "Juanma"])
        #expect(after.mentions == 1 && after.tasks == 1 && after.mergedEntries == 1)
        // Deleting the target also removes the entry merged into it.
        #expect(DeletionSummary(footprint: after).mergedEntries == 1)
    }

    @Test func seriesMeetingCounts() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let daily = try await s.saveSeries(MeetingSeries(titlePattern: "Daily"))
        let m = try await f.meeting(["Hola"])
        try await s.setSeries(daily, of: m)
        #expect(try await s.meetingCountsBySeries() == [daily: 1])
    }

    /// The editor's "Reanalyze all" visits only these meetings; purged ones
    /// are never touched.
    @Test func reanalyzeAllSkipsPurgedMeetings() async throws {
        let f = try KnowledgeFixture(knowledgeRetentionDays: 365)
        let s = f.store!
        _ = try await s.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        let old = try await f.meeting(["Revisamos Kobaltix"], at: .now - 91 * 86_400)
        let recent = try await f.meeting(["Kobaltix sigue"])
        // A meeting with minutes loses its transcript after the retention period.
        try await s.saveCard(MeetingCard(summary: "Kobaltix"), of: old)
        try await s.purgeExpired()
        let ids = try await s.analyzableMeetingIDs()
        #expect(ids == [recent])
        var progress = ReanalysisProgress()
        progress.start(total: ids.count)
        for id in ids { progress.record(try await s.analyze(id)) }
        progress.finish()
        #expect(progress.analyzed == 1)
        #expect(progress.found.mentions == 1)
        #expect(progress.state == .finished)
    }
}
