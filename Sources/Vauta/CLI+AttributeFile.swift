// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import VautaCore

/// `attribute-file <audio> --out <words.jsonl> --show-text`: EVALUATION ONLY, on public audio. Transcribes the file and separates
/// its speakers as an imported recording is (`RecordingTranscriber` with word times, `OfflineDiarization`, `SpeakerAligner`),
/// splits the lines where the speaker changes as the store does, and writes every word with its time and speaker to the one
/// file named with `--out` (JSON lines: speaker, start, end, text), for the attributed error rates of `eval/` (cpWER, tcpWER,
/// WDER). The text is in clear, so it takes `--show-text` (and `--i-understand` without a terminal). No store, no audio is
/// written, no model server. Never use it on a real meeting.
func attributeFile(_ invocation: CommandInvocation) async throws -> Int32 {
    guard let path = invocation.positional.first, let out = invocation.values["--out"] else { throw Usage() }
    guard try textOutputAllowed(invocation) else { throw Usage() }
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.isReadableFile(atPath: url.path) else {
        printError("Can't read \(path). The sandboxed app can only open files you pick; run .build/release/Vauta from a source build.")
        return 1
    }
    let locale = try await speechLocale(invocation, engine: .speech)
    let t0 = Date()
    let lines = try await RecordingTranscriber.transcribe(url, locale: locale, engine: .speech, collectWords: true) { _ in }
    let transcribed = Date().timeIntervalSince(t0)
    let diarization = try await OfflineDiarization.diarize(url: url, config: DiarizationConfig())
    let segments = lines.enumerated().map { index, line in
        AlignableSegment(id: Int64(index), start: line.start, end: line.end, text: line.text, runs: line.words)
    }
    let words = SpeakerAttribution.words(of: segments, alignments: SpeakerAligner(turns: diarization.turns).align(segments))
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let rows = try words.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
    try (rows.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    print(String(format: "%d lines · %d words · %d speakers · %.1f s to transcribe · %.1f s in all", lines.count, words.count,
                 Set(words.compactMap(\.speaker)).count, transcribed, Date().timeIntervalSince(t0)))
    return 0
}
