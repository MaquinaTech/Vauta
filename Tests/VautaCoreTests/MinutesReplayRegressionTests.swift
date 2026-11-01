// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The minutes of three invented meetings, replayed from the replies that Apple's on-device model and the integrated Gemma 4 E4B
/// gave when they were recorded (`Fixtures/MinutesReplay`): the same replies must give the same minutes. The replay runs everything
/// after the model (reading the replies, the citation check, the evidence checks, the ranking, the owners, the dates) with what the
/// app sends to each backend, so a change there that alters what the minutes keep shows up here, on real replies of both models,
/// with no model and no network.
///
/// - `<meeting>.json`: the transcript, invented for these fixtures (no real person, company or corpus text): a short meeting in
///   English and one in Spanish, and a longer English one that Apple's model writes block by block;
/// - `<meeting>.<provider>.replies.json`: the replies of the recording, the finish reason of each call, the context and the
///   diagnostics of the run (no prompt);
/// - `<meeting>.<provider>.minutes.json`: what the replay gave when the replies were recorded.
///
/// An intended change writes the expected minutes again (`VAUTA_WRITE_MINUTES_REPLAY=1 swift test --filter MinutesReplayRegression`);
/// the diff of the `.minutes.json` files is then the change to review. A change in what the minutes ask the model (another request,
/// another block size) needs new replies: record them with `Vauta llm-eval --tasks minutes --sets <this folder> --providers
/// apple,integrated --extraction release --summary release --harness release --open-questions release --out <run>`, then run the
/// writer with `VAUTA_MINUTES_REPLAY_FROM=<run>/minutes` as well.
@Suite("Minutes: recorded replies of both models give the same minutes")
struct MinutesReplayRegressionTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true).appendingPathComponent("MinutesReplay", isDirectory: true)
    static let meetings = ["replay-en-launch", "replay-en-weekly", "replay-es-fiestas"]
    static let providers = ["apple", "integrated"]

    /// What the minutes kept, in a form that compares as a whole (items sorted, nothing that varies between runs).
    struct Minutes: Codable, Equatable {
        struct Item: Codable, Equatable {
            var kind: String
            var text: String
            var citations: [Int64]
            var unconfirmed: Bool
            var reason: String?
            var owner: String?
            var ownerKind: String?
            var ownerUncertain: Bool
            var due: String?
        }
        var summary: String
        var topics: [String]
        var openQuestions: [String]
        var modelCalls: Int
        var proposed: Int
        var dropped: Int
        var items: [Item]
    }

    static func replay(_ meeting: String, _ provider: String) async throws -> Minutes {
        let transcript = try JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: Data(contentsOf: folder.appendingPathComponent("\(meeting).json")))
        let recorded = try Data(contentsOf: folder.appendingPathComponent("\(meeting).\(provider).replies.json"))
        let replies = try #require(ReplayedReplies(resultFile: recorded), "\(meeting).\(provider).replies.json holds no minutes reply")
        let integrated = provider == "integrated"
        let result = try await MinutesEvaluation.run(transcript, language: Locale(identifier: transcript.language == "es" ? "es-ES" : "en-US"),
                                                     model: .replay(kind: provider, replies: replies),
                                                     extraction: MinutesRelease.extraction(integrated: integrated),
                                                     summary: MinutesSummaryRelease.summary(integrated: integrated),
                                                     harness: MinutesHarnessRelease.harness(integrated: integrated),
                                                     questions: MinutesQuestionsRelease.questions(integrated: integrated))
        let items = result.items.map {
            Minutes.Item(kind: $0.kind, text: $0.text, citations: $0.citations, unconfirmed: $0.unconfirmed, reason: $0.reason,
                         owner: $0.owner, ownerKind: $0.ownerKind, ownerUncertain: $0.ownerUncertain, due: $0.due)
        }
        return Minutes(summary: result.summary, topics: result.topics, openQuestions: result.openQuestions, modelCalls: result.modelCalls,
                       proposed: result.proposed, dropped: result.dropped,
                       items: items.sorted { ($0.kind, $0.text, $0.citations.first ?? 0) < ($1.kind, $1.text, $1.citations.first ?? 0) })
    }

    static func encoded(_ minutes: Minutes) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(minutes) + Data("\n".utf8)
    }

    @Test(arguments: meetings) func theRecordedRepliesGiveTheSameMinutes(meeting: String) async throws {
        for provider in Self.providers {
            let expected = try JSONDecoder().decode(Minutes.self, from: Data(contentsOf: Self.folder.appendingPathComponent("\(meeting).\(provider).minutes.json")))
            let got = try await Self.replay(meeting, provider)
            let now = String(decoding: try Self.encoded(got), as: UTF8.self)
            #expect(got == expected, """
                \(meeting) on \(provider): the minutes changed. If the change is intended, write them again (see the suite's comment) \
                and review the diff. Now:
                \(now)
                """)
        }
    }

    /// The recordings are worth keeping only if they exercise the paths that matter: decisions and tasks kept on both models, a task
    /// owned by the speaker who committed to it, and on Apple's model a meeting written block by block.
    @Test func theRecordingsCoverWhatTheyAreFor() throws {
        var blocks = false, ownedTasks = 0, kept: [String: Int] = [:]
        for meeting in Self.meetings {
            for provider in Self.providers {
                let minutes = try JSONDecoder().decode(Minutes.self, from: Data(contentsOf: Self.folder.appendingPathComponent("\(meeting).\(provider).minutes.json")))
                kept[provider, default: 0] += minutes.items.count
                ownedTasks += minutes.items.filter { $0.kind == "task" && $0.ownerKind == "speaker" }.count
                let replies = try #require(ReplayedReplies(resultFile: Data(contentsOf: Self.folder.appendingPathComponent("\(meeting).\(provider).replies.json"))))
                if provider == "apple" && !replies.blocks.isEmpty { blocks = true }
            }
        }
        #expect(kept["apple", default: 0] >= 6 && kept["integrated", default: 0] >= 6, "\(kept)")
        #expect(ownedTasks >= 2)
        #expect(blocks, "no recording of Apple's model went block by block")
    }

    /// Writes the expected minutes from the replies in the folder, after copying new replies from `VAUTA_MINUTES_REPLAY_FROM`
    /// (the `minutes` folder of an `llm-eval --tasks minutes` run) when it is set. Off unless `VAUTA_WRITE_MINUTES_REPLAY` is 1.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VAUTA_WRITE_MINUTES_REPLAY"] == "1"))
    func writeTheExpectedMinutes() async throws {
        if let from = ProcessInfo.processInfo.environment["VAUTA_MINUTES_REPLAY_FROM"] {
            for meeting in Self.meetings {
                for provider in Self.providers {
                    let run = URL(fileURLWithPath: from).appendingPathComponent("\(meeting).\(provider).json")
                    let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: run)) as? [String: Any])
                    let calls = (object["calls"] as? [[String: Any]] ?? []).map { ["finishReason": $0["finishReason"] ?? ""] }
                    var kept: [String: Any] = ["calls": calls, "replies": object["replies"] ?? [], "contextTokens": object["contextTokens"] ?? 0]
                    if let diagnostics = object["diagnostics"] { kept["diagnostics"] = diagnostics }
                    let data = try JSONSerialization.data(withJSONObject: kept, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                    try (data + Data("\n".utf8)).write(to: Self.folder.appendingPathComponent("\(meeting).\(provider).replies.json"))
                }
            }
        }
        for meeting in Self.meetings {
            for provider in Self.providers {
                try Self.encoded(try await Self.replay(meeting, provider)).write(to: Self.folder.appendingPathComponent("\(meeting).\(provider).minutes.json"))
            }
        }
    }
}
