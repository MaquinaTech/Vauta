// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The evaluation tooling of `llm-eval`, `embed-loop` and the probe: what it records and what it reads of the Mac.
@Suite("Evaluation tooling: context, embedding loop, probe sources")
struct EvaluationToolingTests {
    static let root = PackagingTests.root

    @Test func theMemoryFiguresAreRealNumbers() {
        // `>>` binds tighter than `*` in Swift: with the parentheses missing both figures were always 0.
        let memory = LLMEvaluation.memory()
        #expect((memory.free ?? 0) > 0, "free + inactive pages of a running Mac are not zero")
        #expect(memory.compressed != nil && (memory.level ?? 0) > 0)
    }

    @Test func theContextLineHasWhatEveryRunRecordsAndCountsNoModelWork() async throws {
        let line = await LLMEvaluation.contextLine()
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["load1"] != nil && object["freeMemoryMB"] != nil)
        if TestHardware.hasGPUUtilisation {
            #expect(object["gpuUtilPct"] != nil)
        } else {
            // A virtual machine has no GPU counters: the reading is left out of the line, not recorded as a number.
            Issue.record("the GPU utilisation counter is not available on this Mac (no IOAccelerator statistics); checking the documented fallback",
                         severity: .warning)
            #expect(object["gpuUtilPct"] == nil)
        }
    }

    @Test func aTraceKeepsTheGPUFiguresOfTheRunAndOldTracesStillRead() throws {
        let json = """
            {"task":"minutes","provider":"integrated","item":"x","pair":0,"order":"AB","model":"m","startedAt":1,"endedAt":2,"wallSeconds":1,"loadAverage":[1,1,1],
             "loadBucket":"quiet","quietWaitedSeconds":0,"gpuUtilPct":0,"gpuUtilRunMeanPct":71.5,"gpuUtilRunMaxPct":99,"thermalStart":"nominal","thermalEnd":"nominal",
             "peakFootprintMB":1,"ownProcess":{"userSeconds":1,"systemSeconds":0,"energyJoules":1,"instructions":1,"cycles":1},"calls":[],"detail":{}}
            """
        let trace = try JSONDecoder().decode(LLMEvaluation.Trace.self, from: Data(json.utf8))
        #expect(trace.gpuUtilPct == 0 && trace.gpuUtilRunMeanPct == 71.5 && trace.gpuUtilRunMaxPct == 99)
        let old = json.replacingOccurrences(of: #""gpuUtilRunMeanPct":71.5,"gpuUtilRunMaxPct":99,"#, with: "")
        #expect(try JSONDecoder().decode(LLMEvaluation.Trace.self, from: Data(old.utf8)).gpuUtilRunMeanPct == nil)
    }

    @Test func aFailedRunKeepsTheCallsItMade() async throws {
        let failure = MinutesEvaluation.RunFailure(failure: .jobFailed("x"), calls: [])
        let carrying: any CallsCarrying = failure
        #expect(carrying.calls.isEmpty && "\(failure)".contains("x"))
        // The recording model notes a call that threw, with the budget it was given.
        struct Boom: ChatModel {
            var contextTokens: Int? { get async { nil } }
            func chat(_ messages: [ChatMessage], _ options: ChatOptions, onProgress: (@Sendable (Int) -> Void)?) async throws -> ChatResult { throw LLMError.outputTruncated }
        }
        let recording = RecordingChat(Boom())
        await #expect(throws: LLMError.self) { _ = try await recording.chat([.user("hello")], ChatOptions(model: .deep, maxTokens: 123), onProgress: nil) }
        let call = try #require(recording.records.first)
        #expect(call.finishReason == "error" && call.maxTokens == 123 && call.promptEstimate != nil && call.error != nil)
    }

    @Test func theEmbeddingLoopCutsTheTranscriptIntoWindowsAndNeedsTheModel() async throws {
        let json = #"{"passages": [{"id": 1, "text": "one"}, {"id": 2, "text": "two"}, {"id": 3, "text": "three"}, {"id": 4, "text": "four"}, {"id": 5, "text": "five"}]}"#
        let transcript = try JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: Data(json.utf8))
        #expect(EmbeddingLoop.windows(transcript, window: 2) == ["one two", "three four", "five"])
        #expect(EmbeddingLoop.windows(transcript, window: 99) == ["one two three four five"])
        // No search model in an empty store: it says so instead of running.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-embed-loop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        await #expect(throws: MinutesEvaluation.Failure.self) { _ = try await EmbeddingLoop.run(transcript: transcript, store: SearchModelStore(root: empty), passes: 1) }
    }

    @Test func theNewOptionsOfTheEvaluationCommandsParse() throws {
        let eval = try CommandInvocation(parsing: ["llm-eval", "--sets", "s", "--out", "o", "--with-embeddings", "t.json", "--print-context"])
        #expect(eval.values["--with-embeddings"] == "t.json" && eval.has("--print-context"))
        let loop = try CommandInvocation(parsing: ["embed-loop", "--transcript", "t.json", "--seconds", "30", "--passes", "2", "--batch", "4", "--out", "r.json"])
        #expect(loop.command == "embed-loop" && loop.values["--seconds"] == "30" && loop.values["--batch"] == "4")
    }

    // MARK: The Python tools (developer-side; their sources are checked, not run)

    @Test func theProbeLeavesTheProcessUnderTestOutOfTheForeignLoad() throws {
        let probe = try String(contentsOf: Self.root.appendingPathComponent("tools/llm-eval/probe.py"), encoding: .utf8)
        #expect(probe.contains("--watch-name") && probe.contains("watching.add(pid)"), "the process under test is found by name each interval")
        #expect(probe.contains("r[0] not in watching and r[0] != os.getpid()"), "neither the watched processes nor the probe itself are foreign")
        #expect(probe.contains("foreign_gpu_util_pct") && probe.contains("own_cpu < 5"), "the GPU load counts as foreign only while the process under test is idle")
        #expect(probe.contains("\"interval_s\""), "chip energy carries the interval it covers")
        #expect(probe.contains("if prev:"), "the first interval, which has no start, is not reported")
    }

    @Test func theAggregatorReportsChipGPUEnergyAsThePrimaryFigureAndRefusalsAsFoundFalse() throws {
        let aggregate = try String(contentsOf: Self.root.appendingPathComponent("tools/llm-eval/aggregate.py"), encoding: .utf8)
        #expect(aggregate.contains("PRIMARY for GPU work") && aggregate.contains("energy.json") && aggregate.contains("gpuJoulesNet"))
        #expect(aggregate.contains("ownProcessJoules"), "the per-process figure stays, as the secondary one")
        #expect(aggregate.contains("refused (found=false)") && aggregate.contains("found but unverified"), "an uncited answer is not a refusal")
        #expect(!aggregate.contains("refused (no claims)"))
    }
}
