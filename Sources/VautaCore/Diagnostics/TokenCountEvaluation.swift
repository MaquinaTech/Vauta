// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import FoundationModels

/// `llm-eval --tasks token-count --sets <transcripts> --out <dir>`: how close `PromptText.tokens`, the estimate every budget is made with,
/// comes to the count of Apple's on-device model (`SystemLanguageModel.tokenCount(for:)`, macOS 26.4), whose window is the smallest
/// Vauta writes for. It counts the public transcripts given, in the lines the prompts print, in windows of 25, 50 and 100 lines, and the
/// system prompt; nothing is generated and no meeting of the person is read. Under 1 an estimate lets a request overflow Apple's window;
/// well over 1 it leaves part of it unused. Writes `token_count.tsv`, one row per window, and prints the ratios by window size.
enum TokenCountEvaluation {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let windows = [25, 50, 100]

    static func run(_ o: LLMEvaluation.Options, log: @escaping @Sendable (String) -> Void) async throws {
        guard #available(macOS 26.4, *) else { throw Failure(description: "Apple's token count needs macOS 26.4 or later") }
        let model = SystemLanguageModel.default
        guard model.isAvailable else { throw Failure(description: "Apple's on-device model is not available (Apple Intelligence off, or its model not downloaded)") }
        var files = LLMEvaluation.setFiles(o)
        if let m = o.maxItems { files = Array(files.prefix(m)) }
        try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
        var rows = ["meeting\tlanguage\tlines\twindow\tcharacters\testimate\tapple"]
        var ratios: [Int: [Double]] = [:]
        let system = VautaPrompts.system
        let systemCount = try await model.tokenCount(for: system)
        log("system prompt: estimate \(PromptText.tokens(system)), Apple \(systemCount)")
        for file in files {
            guard let (name, transcript, _) = LLMEvaluation.loadTranscript(file) else { continue }
            let lines = transcript.passages.map { p in
                VautaPrompts.line(CitableSegment(id: p.id, channel: .others, start: p.start ?? 0, text: (p.speaker.map { "\($0): " } ?? "") + p.text))
            }
            for size in windows {
                for (n, start) in stride(from: 0, to: lines.count - size + 1, by: size).enumerated() {
                    let text = lines[start..<(start + size)].joined(separator: "\n")
                    let estimate = PromptText.tokens(text)
                    let apple = try await model.tokenCount(for: text)
                    guard apple > 0 else { continue }
                    ratios[size, default: []].append(Double(estimate) / Double(apple))
                    rows.append("\(name)\t\(transcript.language ?? "")\t\(size)\t\(n)\t\(text.count)\t\(estimate)\t\(apple)")
                }
            }
            log("\(name): counted")
        }
        try (rows.joined(separator: "\n") + "\n").write(to: o.out.appendingPathComponent("token_count.tsv"), atomically: true, encoding: .utf8)
        for size in windows {
            let r = (ratios[size] ?? []).sorted()
            guard !r.isEmpty else { continue }
            let mean = r.reduce(0, +) / Double(r.count)
            func at(_ q: Double) -> Double { r[min(r.count - 1, Int(Double(r.count - 1) * q))] }
            log(String(format: "%3d lines: %d windows, estimate / Apple mean %.3f, min %.3f, p5 %.3f, p50 %.3f, p95 %.3f, max %.3f",
                       size, r.count, mean, r.first!, at(0.05), at(0.5), at(0.95), r.last!))
        }
    }
}
