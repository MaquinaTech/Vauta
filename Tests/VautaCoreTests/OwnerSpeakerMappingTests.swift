// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Owners written as the speaker labels of the transcript, "Me" on a line that is not the user's, and the owner kept for a speaker
/// nobody has named.
@Suite("Minutes: owners as speakers")
struct OwnerSpeakerMappingTests {
    static let me: Int64 = 1
    static let ana: Int64 = 5
    static let people = [CandidateEntity(id: 1, kind: .person, name: "Yo", aliases: []), CandidateEntity(id: 5, kind: .person, name: "Ana Ruiz", aliases: ["Ana"])]

    static func speakers(named: Bool) -> [MeetingSpeaker] {
        [MeetingSpeaker(id: 100, meetingID: 1, channel: .me, ordinal: 1),
         MeetingSpeaker(id: 101, meetingID: 1, channel: .others, ordinal: 1, entityID: named ? 5 : nil, entityName: named ? "Ana Ruiz" : nil, source: named ? .user : .auto),
         MeetingSpeaker(id: 102, meetingID: 1, channel: .others, ordinal: 2)]
    }

    static func segments() -> [Int64: CitableSegment] {
        [1: CitableSegment(id: 1, channel: .others, start: 5, text: "I will send the final numbers to the board on Friday", speaker: SpeakerTag(id: 102, ordinal: 2)),
         2: CitableSegment(id: 2, channel: .others, start: 30, text: "Somebody should send the signed contract back to the vendor", speaker: SpeakerTag(id: 101, ordinal: 1)),
         3: CitableSegment(id: 3, channel: .me, start: 60, text: "I will review the draft of the contract tomorrow morning", speaker: SpeakerTag(id: 100, ordinal: 1))]
    }

    static func validate(_ task: String, named: Bool = false) throws -> ValidatedMinutes {
        let json = #"{"title":"T","summary":"S","topics":[],"decisions":[],"tasks":[\#(task)],"entities":[],"open_questions":[]}"#
        return try VautaPrompts.validateMinutes(json, segments: segments(), candidates: people, selfEntity: me, meetingPeople: [],
                                                directory: SpeakerDirectory(speakers: speakers(named: named), selfEntity: me), language: "en")
    }

    @Test func aSpeakerKeyOfAnUnnamedSpeakerIsKeptAsTheSpeaker() throws {
        let m = try Self.validate(#"{"text":"Send the final numbers to the board","owner":"Speaker 2","owner_id":null,"due":null,"seg":1,"quote":"send the final numbers to the board on Friday"}"#)
        #expect(m.tasks.count == 1 && m.tasks[0].owner == nil && m.tasks[0].ownerSpeaker == 102 && !m.tasks[0].ownerUncertain, "the speaker said it and is confident")
        let withSuffix = try Self.validate(#"{"text":"Send the final numbers to the board","owner":"Speaker 2 (remote)","owner_id":null,"due":null,"seg":1,"quote":"send the final numbers to the board on Friday"}"#)
        #expect(withSuffix.tasks[0].ownerSpeaker == 102)
    }

    @Test func aSpeakerNamedByTheUserGivesTheirPerson() throws {
        let m = try Self.validate(#"{"text":"Send the signed contract back","owner":"Speaker 1","owner_id":null,"due":null,"seg":2,"quote":"send the signed contract back to the vendor"}"#, named: true)
        #expect(m.tasks[0].owner == Self.ana && m.tasks[0].ownerSpeaker == nil)
    }

    @Test func aTaskSaidBySomeoneElseIsMarkedUncertain() throws {
        let m = try Self.validate(#"{"text":"Send the signed contract back","owner":"Speaker 2","owner_id":null,"due":null,"seg":2,"quote":"send the signed contract back to the vendor"}"#)
        #expect(m.tasks[0].ownerSpeaker == 102 && m.tasks[0].ownerUncertain, "speaker 2 did not say this line")
    }

    @Test func meOnALineThatIsNotTheUsersBecomesTheSpeakerWhoCommits() throws {
        // The speaker of the line commits in the first person: the owner is that speaker.
        let committed = try Self.validate(#"{"text":"Send the final numbers","owner":"Me","owner_id":null,"due":null,"seg":1,"quote":"send the final numbers to the board on Friday"}"#)
        #expect(committed.tasks[0].owner == nil && committed.tasks[0].ownerSpeaker == 102 && committed.counts["task.ownerMeUnbacked"] == nil)
        // No first-person commitment: nobody owns it, and it is counted.
        let unbacked = try Self.validate(#"{"text":"Send the signed contract back","owner":"Me","owner_id":null,"due":null,"seg":2,"quote":"send the signed contract back to the vendor"}"#)
        #expect(unbacked.tasks.count == 1 && unbacked.tasks[0].owner == nil && unbacked.tasks[0].ownerSpeaker == nil && unbacked.counts["task.ownerMeUnbacked"] == 1)
        // The user's own line: "Me" stays.
        let mine = try Self.validate(#"{"text":"Review the draft","owner":"Me","owner_id":null,"due":null,"seg":3,"quote":"review the draft of the contract tomorrow morning"}"#)
        #expect(mine.tasks[0].owner == Self.me && mine.counts["task.ownerMeUnbacked"] == nil)
    }

    @Test func namesAndNullStayAsBefore() throws {
        let named = try Self.validate(#"{"text":"Send the numbers","owner":"Ana","owner_id":null,"due":null,"seg":1,"quote":"send the final numbers to the board on Friday"}"#)
        #expect(named.tasks[0].ownerSpeaker == nil)
        let none = try Self.validate(#"{"text":"Send the numbers","owner":null,"owner_id":null,"due":null,"seg":2,"quote":"send the signed contract back to the vendor"}"#)
        #expect(none.tasks[0].owner == nil && none.tasks[0].ownerSpeaker == nil)
    }

    @Test func namingTheSpeakerLaterGivesTheTaskItsPerson() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["I will send the final numbers to the board on Friday"], locale: "en-US", outputLocale: "en-US")
        let seg = try await f.store.citableSegments(id)[0]
        try await f.store.finalizeSpeakers(meetingID: id, speakers: [SpeakerDraft(channel: .others, ordinal: 2)],
                                           assignments: [SegmentSpeakerAssignment(segmentID: seg.id, channel: .others, ordinal: 2)])
        let speaker = try #require(try await f.store.speakers(of: id).first { $0.ordinal == 2 })
        var minutes = ValidatedMinutes()
        minutes.tasks = [.init(text: "Send the final numbers", owner: nil, due: nil, segment: seg.id, t: seg.start, ownerSpeaker: speaker.id)]
        try await f.store.applyMinutes(minutes, to: id)
        var task = try #require(try await f.store.tasks(id).first)
        #expect(task.ownerID == nil && task.ownerSpeakerID == speaker.id && task.ownerName == "Speaker 2")
        let ana = try await f.store.saveEntity(EntityDraft(kind: .person, name: "Ana Ruiz"))
        _ = try await f.store.assignSpeaker(speaker.id, toEntity: ana)
        task = try #require(try await f.store.tasks(id).first)
        #expect(task.ownerID == ana && task.ownerSpeakerID == nil && task.ownerName?.contains("Ana") == true)
    }

    @Test func clearingTheNameOrUndoingItGivesTheTaskBackToItsSpeaker() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["I will send the final numbers to the board on Friday"], locale: "en-US", outputLocale: "en-US")
        let seg = try await f.store.citableSegments(id)[0]
        try await f.store.finalizeSpeakers(meetingID: id, speakers: [SpeakerDraft(channel: .others, ordinal: 2)],
                                           assignments: [SegmentSpeakerAssignment(segmentID: seg.id, channel: .others, ordinal: 2)])
        let speaker = try #require(try await f.store.speakers(of: id).first { $0.ordinal == 2 })
        var minutes = ValidatedMinutes()
        minutes.tasks = [.init(text: "Send the final numbers", owner: nil, due: nil, segment: seg.id, t: seg.start, ownerSpeaker: speaker.id)]
        try await f.store.applyMinutes(minutes, to: id)
        let ana = try await f.store.saveEntity(EntityDraft(kind: .person, name: "Ana Ruiz"))
        let named = try await f.store.assignSpeaker(speaker.id, toEntity: ana)
        var task = try #require(try await f.store.tasks(id).first)
        #expect(task.ownerID == ana && task.ownerSpeakerID == nil)
        // Undo of the naming: the task is the speaker's again.
        try await f.store.undo(named)
        task = try #require(try await f.store.tasks(id).first)
        #expect(task.ownerID == nil && task.ownerSpeakerID == speaker.id && task.ownerName == "Speaker 2", "\(task)")
        // Naming, then clearing the name (unlinking): back to the speaker.
        _ = try await f.store.assignSpeaker(speaker.id, toEntity: ana)
        _ = try await f.store.assignSpeaker(speaker.id, toEntity: nil)
        task = try #require(try await f.store.tasks(id).first)
        #expect(task.ownerID == nil && task.ownerSpeakerID == speaker.id)
        // A task whose owner the user set by hand to somebody else stays theirs when the name is cleared.
        _ = try await f.store.assignSpeaker(speaker.id, toEntity: ana)
        let bea = try await f.store.saveEntity(EntityDraft(kind: .person, name: "Bea Soto"))
        var edited = try #require(try await f.store.tasks(id).first)
        edited.ownerID = bea
        try await f.store.updateTask(edited)
        _ = try await f.store.assignSpeaker(speaker.id, toEntity: nil)
        task = try #require(try await f.store.tasks(id).first)
        #expect(task.ownerID == bea && task.ownerSpeakerID == nil)
    }

    @Test func theMigrationAddsTheColumnWithoutTouchingOlderRows() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We keep the budget as it is"], locale: "en-US", outputLocale: "en-US")
        _ = try await f.store.addTask(id, text: "Old task")
        let task = try #require(try await f.store.tasks(id).first)
        #expect(task.ownerSpeakerID == nil)
        #expect(Schema.migrations.contains { $0.version == 25 })
    }

    @Test func anUncertainSpeakerLabelOwnerIsMarkedInTheExportAndTheEmailInput() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["Can you send the final numbers to the board on Friday? Yeah."], locale: "en-US", outputLocale: "en-US")
        let seg = try await f.store.citableSegments(id)[0]
        try await f.store.finalizeSpeakers(meetingID: id, speakers: [SpeakerDraft(channel: .others, ordinal: 2)],
                                           assignments: [SegmentSpeakerAssignment(segmentID: seg.id, channel: .others, ordinal: 2)])
        let speaker = try #require(try await f.store.speakers(of: id).first { $0.ordinal == 2 })
        var minutes = ValidatedMinutes()
        minutes.tasks = [.init(text: "Send the final numbers", owner: nil, due: nil, segment: seg.id, t: seg.start, ownerUncertain: true, ownerSpeaker: speaker.id)]
        try await f.store.applyMinutes(minutes, to: id)
        let export = try #require(try await f.store.meetingExport(id))
        let entry = try #require(export.tasks.first)
        #expect(entry.owner == "Speaker 2" && entry.ownerUncertain, "the label is shown with the 'owner not confirmed' mark")
        #expect(MeetingExportRenderer.taskDetails(entry, options: MeetingExportOptions()).contains(MeetingExportRenderer.Labels.ownerUnconfirmed))
        let email = try #require(try await f.store.followUpEmailInput(id))
        #expect(email.tasks.first?.ownerUncertain == true && email.tasks.first?.ownerName == nil)
    }
}
