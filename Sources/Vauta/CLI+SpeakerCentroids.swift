// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import Foundation
import VautaCore

/// `speaker-centroids <audio> --out <json>`: EVALUATION ONLY, never used by the app at runtime. Runs the engine
/// offline over one file and writes, for each final speaker, the centroid embedding and the turns, to the one JSON
/// file named with `--out`. The file holds voice vectors (not audio, not text): keep it out of version control and
/// delete it when the calibration is done. It exists to calibrate the voice-profile thresholds, so it is compiled only
/// into the diagnostics build, never into the app people run: the shipped binary has no way to write voice vectors to a file.
func speakerCentroids(_ invocation: CommandInvocation) async throws -> Int32 {
    guard let path = invocation.positional.first, let out = invocation.values["--out"] else { throw Usage() }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.isReadableFile(atPath: url.path) else {
        printError("Can't read \(path).")
        return 1
    }
    let config = DiarizationConfig()
    let run = try await OfflineDiarization.analyze(url: url, config: config)
    let result = Reconstruction.diarize(records: run.records, totalSamples: run.totalSamples, config: config)
    let centroids = result.centroids
    let speakers: [[String: Any]] = centroids.map {
        ["speaker": $0.speaker, "embeddings": $0.embeddingCount, "usableSeconds": $0.usableSeconds, "speechSeconds": $0.speechSeconds, "overlapShare": $0.overlapShare, "spread": Double($0.spread), "centroid": $0.vector.map { Double($0) }]
    }
    let turns: [[Any]] = result.turns.map { [$0.start, $0.end, $0.speaker] }
    let object: [String: Any] = ["file": url.deletingPathExtension().lastPathComponent, "model": DiarizationModels.embeddingModelID,
                                 "speakers": speakers, "turns": turns]
    try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: out))
    printError("\(speakers.count) speaker centroids written")
    return 0
}
#endif
