// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The live notes' guardrails (`LiveHarness`): empty shapes, copies, repeats, the owner "Me", and a reply that is not JSON. No model.
@Suite("Live notes: harness")
struct LiveHarnessTests {
    static let line10 = "We should move the vendor contract review to the second week of March because legal is out until then"
    static let lines: [Int64: String] = [10: line10, 11: "Okay, I will send the budget to Ana tomorrow", 12: "Fine", 20: "Another topic entirely about the parking lot"]
    static let ids = Set(lines.keys)

    static func check(_ harness: LiveHarness = .shipped, mine: Set<Int64> = [], earlier: [LiveCheck.Earlier] = []) -> LiveCheck {
        LiveCheck(harness: harness, lines: lines, mine: mine, earlier: earlier)
    }

    static func validate(_ json: String, _ check: LiveCheck?) throws -> LiveNotesBatch {
        try VautaPrompts.validateLive(json, segments: ids, check: check)
    }

    @Test func parsesAndNamesTheSwitch() {
        #expect(LiveHarness.parse("old") == .legacy && LiveHarness.parse("new") == .shipped)
        #expect(LiveHarness.parse("copies,owners") == [.copies, .owners])
        #expect(LiveHarness.parse("nonsense") == nil)
        // Apple gets every part; the integrated model keeps its request and gets the checks.
        #expect(LiveHarness.parse("checks") == .checks && LiveHarness.shipped(integrated: false) == .shipped && LiveHarness.shipped(integrated: true) == .checks)
        #expect(!LiveHarness.checks.contains(.shape) && LiveHarness.checks.contains(.repair))
        #expect(LiveHarness.legacy.names == "legacy" && LiveHarness.shipped.names == "shape+copies+repeats+owners+repair")
        #expect(LiveHarnessRelease.harness(integrated: false) == .shipped && LiveHarnessRelease.harness(integrated: true) == .legacy)
    }

    @Test func theShapesAreEmptyAndNothingIsLeftToCopy() {
        let old = VautaPrompts.liveInstruction(sinceID: 5, previous: [], language: OutputLanguage(Locale(identifier: "en-US"))).content
        #expect(old.contains("…") && old.contains("Me | name | null"))
        let new = VautaPrompts.liveInstruction(sinceID: 5, previous: [], language: OutputLanguage(Locale(identifier: "en-US")), harness: .shape).content
        #expect(!new.contains("…") && !new.contains("Me | name | null") && !new.contains("| name |"))
        #expect(new.contains("ID > 5") && new.contains("\"owner\": null"))
    }

    @Test func aNoteThatCopiesItsCitedLineIsDropped() throws {
        let copy = Self.line10
        let json = #"{"points": [{"text": "\#(copy)", "seg": 10}, {"text": "Contract review moves to March", "seg": 10}], "decisions": [{"text": "\#(copy).", "seg": 10}], "tasks": []}"#
        let off = try Self.validate(json, nil)
        #expect(off.points.count == 2 && off.decisions.count == 1)
        let on = try Self.validate(json, Self.check())
        #expect(on.points.map(\.text) == ["Contract review moves to March"] && on.decisions.isEmpty)
        // A short line repeated whole is not "over 40 characters": it stays.
        let short = try Self.validate(#"{"points": [{"text": "Fine", "seg": 12}], "decisions": [], "tasks": []}"#, Self.check())
        #expect(short.points.count == 1)
        // Only the part that is switched on runs.
        #expect(try Self.validate(json, Self.check([.owners])).points.count == 2)
    }

    @Test func aNoteWithNoWordInItIsDropped() throws {
        let json = #"{"points": [{"text": "…", "seg": 10}, {"text": "-", "seg": 10}, {"text": "Budget sent", "seg": 11}], "decisions": [], "tasks": []}"#
        #expect(try Self.validate(json, Self.check()).points.map(\.text) == ["Budget sent"])
        #expect(try Self.validate(json, nil).points.count == 3)
    }

    @Test func aRepeatOfAnEarlierNoteIsDroppedUnlessItIsFarAndDifferent() throws {
        let earlier = [LiveCheck.Earlier(kind: .task, text: "Send the budget to Ana tomorrow", segment: 11),
                       LiveCheck.Earlier(kind: .decision, text: "Move the vendor contract review to March", segment: 10)]
        let json = """
            {"points": [], "decisions": [{"text": "The vendor contract review moves to March", "seg": 10}, {"text": "Move the vendor contract review to March", "seg": 20}],
             "tasks": [{"text": "Send the budget to Ana tomorrow", "owner": null, "seg": 11}, {"text": "Send the budget to Ana tomorrow", "owner": null, "seg": 20},
                       {"text": "Book the parking lot cleaning", "owner": null, "seg": 20}]}
            """
        let on = try Self.validate(json, Self.check(earlier: earlier))
        // Near the earlier note and the same words: dropped. The identical text far away is a repeat too; a different task stays.
        #expect(on.decisions.isEmpty)
        #expect(on.tasks.map(\.text) == ["Book the parking lot cleaning"])
        #expect(try Self.validate(json, Self.check([.copies], earlier: earlier)).tasks.count == 3)
        // The same words about another stretch (over 5 segments away) are an update, not a repeat.
        let moved = try Self.validate(#"{"points": [], "decisions": [], "tasks": [{"text": "Send the budget to Ana and Luis tomorrow", "owner": null, "seg": 20}]}"#,
                                      Self.check(earlier: earlier))
        #expect(moved.tasks.count == 1)
        // A repeat inside one reply counts too, and a different kind does not.
        let twice = try Self.validate(#"{"points": [{"text": "Parking lot topic raised", "seg": 20}, {"text": "Parking lot topic raised", "seg": 20}], "decisions": [{"text": "Parking lot topic raised", "seg": 20}], "tasks": []}"#,
                                      Self.check())
        #expect(twice.points.count == 1 && twice.decisions.count == 1)
    }

    @Test func meIsAnOwnerOnlyOnTheUsersOwnLine() throws {
        let json = #"{"points": [], "decisions": [], "tasks": [{"text": "Send the budget to Ana", "owner": "Me", "seg": 11}, {"text": "Review the contract", "owner": "Me", "seg": 10}, {"text": "Call legal", "owner": "Me | name | null", "seg": 10}, {"text": "Ana prints it", "owner": "Ana", "seg": 10}]}"#
        let on = try Self.validate(json, Self.check(mine: [11]))
        #expect(on.tasks.map(\.owner) == ["Me", nil, nil, "Ana"])
        let off = try Self.validate(json, nil)
        #expect(off.tasks.map(\.owner) == ["Me", "Me", "Me | name | null", "Ana"])
    }

    @Test func aCutReplyIsClosedAtItsLastFinishedNote() throws {
        let cut = #"{"points": [{"text": "Contract review moves to March", "seg": 10}, {"text": "Budget goes to Ana", "seg": 11}], "decisions": [{"text": "Move the vend"#
        #expect((try? Self.validate(cut, nil)) == nil)
        let closed = try #require(ModelOutput.closingTruncatedJSON(cut))
        let notes = try Self.validate(closed, Self.check())
        #expect(notes.points.count == 2 && notes.decisions.isEmpty)
        // Segment tags the small model copies from the transcript become numbers.
        let tagged = #"{"points": [{"text": "Budget goes to Ana", "seg": S11}], "decisions": [], "tasks": []}"#
        #expect((try? Self.validate(tagged, nil)) == nil)
        #expect(try Self.validate(NoteReply.repaired(tagged), nil).points.first?.segment == 11)
    }
}

/// The service takes the repair and the checks into the tick, with no extra call.
@Suite("Live notes: harness in the service")
struct LiveHarnessServiceTests {
    @Test func aCutReplyIsReadAsItIsWithOneCallAndAnEarlierNoteIsNotTakenAgain() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We agreed the vendor contract review moves to the second week of March", "Okay, I will send the budget to Ana tomorrow morning"])
        let first = try await f.store.citableSegments(id).map(\.id)
        let seg0 = first[0], seg1 = first[1]
        let chat = ScriptedChat { _, options, call in
            if call == 1 {
                // Cut inside the second note.
                return ScriptedChat.reply(#"{"points": [{"text": "Vendor review moves to March", "seg": \#(seg0)}], "decisions": [], "tasks": [{"text": "Send the budget to Ana tomorrow", "owner": "Me", "seg": \#(seg1)}, {"text": "Ca"#, finish: .length)
            }
            return ScriptedChat.reply(#"{"points": [{"text": "Vendor review moves to March", "seg": \#(seg0)}], "decisions": [], "tasks": []}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        await service.setLiveHarness(.shipped)
        await service.setRecording(true, meetingID: id)
        let notes = try #require(try await service.liveNotes(meetingID: id, at: 10))
        #expect(chat.calls.filter { $0.options.purpose == .liveNotes }.count == 1, "salvaged, not asked again")
        #expect(notes.points.count == 1 && notes.tasks.count == 1)
        // The second line (odd index) is the user's own microphone: "Me" is backed there.
        #expect(notes.tasks[0].owner == "Me")
        // The same note on a later tick (the model repeats itself) is dropped; nothing new comes back.
        _ = try await f.store.append(Segment(channel: .others, start: 30, end: 38, text: "Next the parking lot", isFinal: true), to: id)
        let again = try await service.liveNotes(meetingID: id, at: 20)
        #expect(again == nil)
    }

    @Test func aTickThatWaitedForAnotherStartsFromTheNotesTheOtherTook() async throws {
        final class Hook: @unchecked Sendable { var overlap: (@Sendable () async -> Void)? }
        let hook = Hook()
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We agreed the vendor contract review moves to the second week of March"])
        let seg = try await f.store.citableSegments(id)[0].id
        let chat = ScriptedChat { _, _, call in
            if call == 1 { await hook.overlap?() }
            return ScriptedChat.reply(#"{"points": [{"text": "Vendor review moves to March", "seg": \#(seg)}], "decisions": [], "tasks": []}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        await service.setLiveHarness(.shipped)
        await service.setRecording(true, meetingID: id)
        final class Box: @unchecked Sendable { var second: Task<LiveNotesBatch?, Error>? }
        let box = Box()
        hook.overlap = {
            // A second tick starts while the first waits for the model: it queues for the lane with the session as it was.
            _ = try? await f.store.append(Segment(channel: .others, start: 30, end: 38, text: "Next the parking lot", isFinal: true), to: id)
            box.second = Task { try await service.liveNotes(meetingID: id, at: 20) }
            try? await Task.sleep(for: .milliseconds(300))
        }
        let first = try await service.liveNotes(meetingID: id, at: 10)
        #expect(first?.points.count == 1)
        let second = try await box.second?.value
        #expect(second == nil, "the first tick's note is known to the second, which does not store it again")
        let session = await service.live
        #expect(session?.taken.count == 1, "\(session?.taken.count ?? -1)")
    }

    @Test func aTickThatEndsAfterAnotherMeetingStartedLeavesTheNewSessionAlone() async throws {
        final class Hook: @unchecked Sendable { var switchMeeting: (@Sendable () async -> Void)? }
        let hook = Hook()
        let f = try KnowledgeFixture()
        let first = try await f.meeting(["We agreed the vendor contract review moves to the second week of March", "Okay, I will send the budget to Ana tomorrow morning"])
        let second = try await f.meeting(["Welcome everyone to the new meeting about the parking lot"])
        let seg = try await f.store.citableSegments(first)[0].id
        let chat = ScriptedChat { _, _, _ in
            await hook.switchMeeting?()
            return ScriptedChat.reply(#"{"points": [{"text": "Vendor review moves to March", "seg": \#(seg)}], "decisions": [], "tasks": []}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 4_096, onDevice: true))
        await service.setLiveHarness(.shipped)
        await service.setRecording(true, meetingID: first)
        hook.switchMeeting = { await service.setRecording(true, meetingID: second) }
        let notes = try await service.liveNotes(meetingID: first, at: 10)
        #expect(notes?.points.count == 1, "the notes of the first meeting are still stored and returned")
        let session = await service.live
        #expect(session?.meetingID == second)
        #expect(session?.texts.isEmpty == true && session?.mine.isEmpty == true && session?.taken.isEmpty == true && session?.previous.isEmpty == true,
                "nothing of the first meeting is written into the second one's session")
    }

    @Test func aBackendWithoutTheChecksKeepsNoSegmentTexts() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We agreed the vendor contract review moves to the second week of March"])
        let seg = try await f.store.citableSegments(id)[0].id
        let chat = ScriptedChat { _, _, _ in
            ScriptedChat.reply(#"{"points": [{"text": "Vendor review moves to March", "seg": \#(seg)}], "decisions": [], "tasks": []}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 32_000, onDevice: true))
        await service.setRecording(true, meetingID: id)
        _ = try await service.liveNotes(meetingID: id, at: 10)
        let session = await service.live
        #expect(session?.texts.isEmpty == true && session?.mine.isEmpty == true)
    }

    @Test func aModelServerKeepsTheLiveNotesItHad() async throws {
        let f = try KnowledgeFixture()
        let id = try await f.meeting(["We agreed the vendor contract review moves to the second week of March"])
        let seg = try await f.store.citableSegments(id)[0].id
        let chat = ScriptedChat { _, _, _ in
            ScriptedChat.reply(#"{"points": [], "decisions": [], "tasks": [{"text": "Review the vendor contract", "owner": "Me", "seg": \#(seg)}]}"#)
        }
        let service = LLMService(store: f.store, providers: TestProviders(chat: chat, contextTokens: 32_000, onDevice: true))
        await service.setRecording(true, meetingID: id)
        let notes = try #require(try await service.liveNotes(meetingID: id, at: 10))
        #expect(notes.tasks.first?.owner == "Me")
        #expect(!(chat.calls.first?.text.contains("Shape:") ?? true))
    }
}
