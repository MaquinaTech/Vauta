// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The actions evaluation seeds what the app stores: the "to be confirmed" mark, the uncertain owner and the cited segments, so the
/// judged email is the one the default settings draft and the detector reads each backend's tasks.
@Suite("Actions: the evaluation seeds the flags the app stores")
struct ActionsEvaluationFlagsTests {
    static let minutes = """
        {"case": "m1", "summary": "The team discussed the supplier change.",
         "decisions": [{"text": "Keep the C-shaped shell", "unconfirmed": false, "citations": [1]}, {"text": "Move the launch to March", "unconfirmed": true, "citations": [2]}],
         "tasks": [{"text": "Send the revised budget", "owner": "Speaker 2", "due": "2026-10-16", "unconfirmed": false, "owner_uncertain": true, "owner_kind": "speaker", "citations": [3]},
                   {"text": "Book the factory visit", "owner": "Speaker 4", "due": "", "unconfirmed": true, "owner_uncertain": false, "owner_kind": "speaker", "citations": [5]},
                   {"text": "Review the supplier contract", "owner": "", "due": "", "unconfirmed": false, "owner_uncertain": false, "owner_kind": "none", "citations": [6]}],
         "open_questions": []}
        """

    static func seeded(_ directory: URL, minutes: String = Self.minutes, nameSpeakers: Bool = true) async throws -> ActionsEvaluation.Seeded {
        let transcript = try JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: Data(ActionsEvaluationTests.transcript.utf8))
        let stored = try JSONDecoder().decode(BriefEvaluation.StoredMinutes.self, from: Data(minutes.utf8))
        let fixture = try JSONDecoder().decode(ActionsEvaluation.Fixture.self, from: Data(ActionsEvaluationTests.fixture.utf8))
        return try await ActionsEvaluation.seed(name: "m1", transcript: transcript, fixture: fixture, minutes: stored, directory: directory, nameSpeakers: nameSpeakers)
    }

    @Test func aSpeakerLabelOwnerIsUnnamedUnlessTheRunAsksForTheFixturesPeople() async throws {
        let folder = try BriefEvaluationTests.Folder()
        let seeded = try await Self.seeded(folder.url, nameSpeakers: false)
        let send = try #require(seeded.tasks.first { $0.text.hasPrefix("Send the revised") })
        #expect(send.ownerID == nil, "the app has no person for a speaker nobody named")
        #expect(send.ownerSpeakerID != nil && send.ownerMarked, "it stores the unnamed speaker, with the owner marked as the app does")
    }

    @Test func theSeedCarriesTheFlagsAndTheCitedSegments() async throws {
        let folder = try BriefEvaluationTests.Folder()
        let seeded = try await Self.seeded(folder.url)
        let tasks = seeded.tasks
        #expect(tasks.count == 3 && tasks.allSatisfy { $0.segmentID != nil })
        let send = try #require(tasks.first { $0.text.hasPrefix("Send") })
        #expect(send.ownerUncertain && !send.unconfirmed && send.ownerName == "Ana López" && send.dueDay?.string == "2026-10-16")
        #expect(try #require(tasks.first { $0.text.hasPrefix("Book") }).unconfirmed)
        let decisions = try await seeded.store.decisions(seeded.meetingID)
        #expect(decisions.count == 2 && decisions.first { $0.text.hasPrefix("Move") }?.unconfirmed == true && decisions.allSatisfy { $0.segmentID != nil })
    }

    @Test func theDefaultEmailLeavesOutWhatTheAppLeavesOut() async throws {
        let folder = try BriefEvaluationTests.Folder()
        let seeded = try await Self.seeded(folder.url)
        let input = try #require(try await seeded.store.followUpEmailInput(seeded.meetingID))
        let drafts = FollowUpEmail.drafts(input, options: FollowUpEmailOptions(locale: seeded.locale, mode: .one, includeSummary: false))
        let text = drafts.map(\.plainText).joined(separator: "\n")
        #expect(text.contains("Send the revised budget") && text.contains("Review the supplier contract") && text.contains("Keep the C-shaped shell"))
        #expect(!text.contains("Book the factory visit") && !text.contains("Move the launch to March"), "items to be confirmed are not in the default email")
        let send = text.split(separator: "\n").first { $0.contains("Send the revised budget") }.map(String.init) ?? ""
        #expect(!send.contains("Ana"), "an uncertain owner is not named: \(send)")
    }

    @Test func minutesWithoutCitationsStillSeedLikeBefore() async throws {
        let folder = try BriefEvaluationTests.Folder()
        let seeded = try await Self.seeded(folder.url, minutes: ActionsEvaluationTests.minutes)
        #expect(seeded.tasks.count == 3 && seeded.tasks.allSatisfy { !$0.unconfirmed && !$0.ownerUncertain })
    }

    @Test func theDetectorIsRunPerBackendWithTheStoredTasks() async throws {
        #expect(ActionsEvaluation.Kind.fd.usesMinutes && ActionsEvaluation.Kind.fdx.usesMinutes && !ActionsEvaluation.Kind.fbl.usesMinutes)
        func minutes(withTask: Bool) -> String {
            let task = withTask ? #",{"text": "Hold the follow-up meeting to review the budget", "owner": "", "due": "2026-10-30", "unconfirmed": false, "owner_uncertain": false, "owner_kind": "none", "citations": [3]}"# : ""
            return #"{"case": "m1", "summary": "S.", "decisions": [], "tasks": [{"text": "Send the revised budget", "owner": "", "due": "", "citations": [3]}\#(task)], "open_questions": []}"#
        }
        let with = try BriefEvaluationTests.Folder(), without = try BriefEvaluationTests.Folder()
        let seededWith = try await Self.seeded(with.url, minutes: minutes(withTask: true))
        let seededWithout = try await Self.seeded(without.url, minutes: minutes(withTask: false))
        let days = try await seededWith.store.detectFollowUps(seededWith.meetingID).compactMap(\.day?.string)
        let base = try await seededWithout.store.detectFollowUps(seededWithout.meetingID).compactMap(\.day?.string)
        #expect(days.contains("2026-10-30") && !base.contains("2026-10-30"), "the stored tasks and their cited segments reach the detector: \(days) / \(base)")
    }

    @Test func oneItemWithoutACitationDoesNotCostTheOthersTheirFlags() async throws {
        let mixed = #"""
            {"case": "m1", "summary": "S.", "decisions": [],
             "tasks": [{"text": "Send the revised budget", "owner": "Speaker 2", "due": "", "unconfirmed": false, "owner_uncertain": true, "owner_kind": "speaker", "citations": [3]},
                       {"text": "Book the factory visit", "owner": "Luis Pérez", "due": "", "unconfirmed": true, "owner_uncertain": false, "owner_kind": "person", "citations": []}],
             "open_questions": []}
            """#
        let folder = try BriefEvaluationTests.Folder()
        let seeded = try await Self.seeded(folder.url, minutes: mixed)
        #expect(seeded.unmapped == 1)
        let send = try #require(seeded.tasks.first { $0.text.hasPrefix("Send") })
        #expect(send.ownerUncertain && send.segmentID != nil)
        let book = try #require(seeded.tasks.first { $0.text.hasPrefix("Book") })
        #expect(book.unconfirmed && book.ownerName == "Luis Pérez", "a person named in the transcript is mapped by name, and the flag survives without a segment")
    }
}
