// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import VautaCore

/// `minutes-file <transcript.json> --out <minutes.json>`: EVALUATION ONLY. Writes the minutes of a public transcript
/// (the AMI words of `eval/`) with Apple's on-device model and the app's own minutes code, and saves the items with
/// their citations to the one file named with `--out`. It forces no part of the minutes, so it measures what the app sends to
/// Apple's model (the release choice; the file's `choices` says which). It uses a throwaway store in a temporary folder: never
/// the user's store, never a model server, no audio. Run it on public transcripts only, never on a real meeting.
func minutesFile(_ invocation: CommandInvocation) async throws -> Int32 {
    guard let path = invocation.positional.first, let out = invocation.values["--out"] else { throw Usage() }
    guard let data = FileManager.default.contents(atPath: path),
          let transcript = try? JSONDecoder().decode(MinutesEvaluation.Transcript.self, from: data), !transcript.passages.isEmpty else {
        printError("\(path) is not a transcript file: {\"passages\": [{\"id\": 1, \"text\": \"…\", \"start\": 0}, …]}.")
        return 1
    }
    defer { MinutesEvaluation.removeEvaluationDefaults() }
    let t0 = Date()
    let result: MinutesEvaluation.Result
    do {
        result = try await MinutesEvaluation.run(transcript, language: Locale(identifier: invocation.values["--locale"] ?? "en-US"))
    } catch let failure as MinutesEvaluation.Failure {
        printError(failure.description)
        return 1
    } catch let failure as MinutesEvaluation.RunFailure {
        // The job's own message ("the model's answer was cut off…"), not the generic text of an error without one.
        printError(failure.description)
        return 1
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(result).write(to: URL(fileURLWithPath: out))
    print(String(format: "%d passages · %d model calls · %d proposed · %d kept · %d dropped · %.1f s",
                 transcript.passages.count, result.modelCalls, result.proposed, result.items.count, result.dropped, Date().timeIntervalSince(t0)))
    return 0
}
