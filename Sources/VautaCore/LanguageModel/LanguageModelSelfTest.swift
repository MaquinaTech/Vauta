// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import VautaMLX

/// `Vauta llm-selftest [--model] [--long]` and `Vauta llm-install …` (hidden commands): the language model's GPU kernels, and
/// with `--model` its files, tokenizer, chat template and logits against the mlx-lm goldens, in the binary as shipped. No
/// meeting store, no network (except `llm-install download`, which goes through the audited session).
public enum LanguageModelSelfTest {
    public struct Result: Sendable, Equatable {
        public var exitCode: Int32
        public var lines: [String]
    }

    public enum ExitCode {
        public static let pass: Int32 = 0
        public static let fail: Int32 = 1
        public static let unsupported: Int32 = 2
        public static let modelMissing: Int32 = 3
        public static let gateNotMet: Int32 = 4
        /// The files verified but no `--goldens` folder was given, so the parity checks against mlx-lm (tokenizer, template, logits,
        /// greedy ids, and with `--long` the 30k-token logits) did not run. Not a pass: a release check must not go green on it.
        public static let paritySkipped: Int32 = 5
    }

    /// `VAUTA_LLM_MODEL_DIR` names the install folder (the one holding `model.safetensors`); the store is two levels above it.
    public static func store(environment: [String: String] = ProcessInfo.processInfo.environment) -> LanguageModelStore {
        if let path = environment["VAUTA_LLM_MODEL_DIR"], !path.isEmpty {
            return LanguageModelStore(root: URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent())
        }
        return LanguageModelStore()
    }

    /// bf16 activations: logits near 25 move in steps of 0.125, and 42 layers of bf16 rounding differ with any change of operation
    /// order. mlx-lm itself gives 1.09 of difference between a 128-token and a 512-token prefill of the same 404-token prompt
    /// (tools/language-model, measured on this Mac), so the limit is 1.25; top-1 and the greedy ids must be identical.
    static let logitTolerance = 1.25

    struct TokenizerGolden: Decodable { let tag: String; let text: String; let ids: [Int32] }
    struct TemplateGolden: Decodable { let messages: [[String]]; let ids: [Int32] }
    struct LogitGolden: Decodable {
        let name: String
        let ids: [Int32]
        let greedy: [Int32]
        let finished: Bool
        let top20: [[Double]]
    }

    static func lines<T: Decodable>(_ url: URL, as: T.Type) -> [T] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONDecoder().decode(T.self, from: Data($0.utf8)) }
    }

    /// Kernel checks (`--model` absent) or the full model check.
    public static func run(includeModel: Bool, long: Bool, goldens: URL?, store: LanguageModelStore = store()) async -> Result {
        guard MLXRuntime.isSupported else {
            return Result(exitCode: ExitCode.unsupported, lines: ["llm-selftest: this Mac has no Apple silicon GPU (Apple7 family or later) that MLX can use."])
        }
        if let refusal = LanguageModelGate.refusal(gpuSupported: true) {
            return Result(exitCode: ExitCode.gateNotMet, lines: ["llm-selftest: gate not met: \(refusal)"])
        }
        let report = KernelSelfTest.run(.llm)
        var out = ["llm-selftest: \(report.passed)/\(report.total) kernel checks passed · \(report.deviceName) · first compile "
                   + String(format: "%.1f s", report.firstCheckSeconds) + String(format: " · %.1f s total", report.seconds)]
        guard report.ok else {
            out.append("llm-selftest: failed: " + report.failed.joined(separator: ", "))
            return Result(exitCode: ExitCode.fail, lines: out)
        }
        guard includeModel else { return Result(exitCode: ExitCode.pass, lines: out) }
        guard case .installed = store.disk() else {
            out.append("llm-selftest: the language model is not installed.")
            return Result(exitCode: ExitCode.modelMissing, lines: out)
        }
        var failures = 0
        var skipped = false
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            out.append("llm-selftest: \(ok ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : " · " + detail)")
            if !ok { failures += 1 }
        }
        let t0 = Date()
        do {
            try LanguageModelVerifier.fullVerify(file: store.weightsURL, spec: store.spec)
            check("files: size, header, \(store.spec.outputs.count) tensors and the assembled file match the pinned hashes", true,
                  String(format: "%.1f s", Date().timeIntervalSince(t0)))
        } catch { check("files match the pinned hashes", false); return Result(exitCode: ExitCode.fail, lines: out) }
        let engine = LanguageModelEngine(store: store)
        do {
            let tok = try await engine.loadedTokenizer()
            if goldens == nil {
                skipped = true
                out.append("llm-selftest: parity: SKIPPED · no --goldens folder, so the tokenizer, chat template, logit and greedy checks against mlx-lm did not run"
                           + (long ? " (nor the 30k-token logit check of --long)" : "") + "; exit code \(ExitCode.paritySkipped) is not a pass")
            }
            if let goldens {
                let tg = lines(goldens.appendingPathComponent("tokenizer_goldens.jsonl"), as: TokenizerGolden.self)
                let bad = tg.filter { tok.encodeBody($0.text) != $0.ids }
                check("tokenizer goldens (\(tg.count) strings against Hugging Face)", !tg.isEmpty && bad.isEmpty, bad.isEmpty ? "" : "\(bad.count) differ, first: \(bad[0].tag)")
                let template = GemmaChatTemplate(tokenizer: tok)
                let cg = lines(goldens.appendingPathComponent("chat_template_goldens.jsonl"), as: TemplateGolden.self)
                let badT = cg.filter { g in template.ids(g.messages.map { ChatMessage($0[0], $0[1]) }).ids != g.ids }
                check("chat template goldens (\(cg.count) message lists against the pinned template)", !cg.isEmpty && badT.isEmpty, badT.isEmpty ? "" : "\(badT.count) differ")
                let lg = lines(goldens.appendingPathComponent("logit_goldens.jsonl"), as: LogitGolden.self)
                // 1. The same chunking as the goldens (512 tokens): the implementation against mlx-lm, tokens and logits.
                await engine.setPrefillChunk(512)
                var worst = 0.0, matchedGreedy = 0, top1 = 0
                for g in lg {
                    let logits = try await engine.lastLogits(g.ids)
                    let ids = g.top20.map { Int($0[0]) }
                    if let first = ids.first, logits.indices.contains(first), logits.enumerated().max(by: { $0.element < $1.element })?.offset == first { top1 += 1 }
                    var promptWorst = 0.0
                    for pair in g.top20 where logits.indices.contains(Int(pair[0])) { promptWorst = max(promptWorst, abs(Double(logits[Int(pair[0])]) - pair[1])) }
                    worst = max(worst, promptWorst)
                    out.append("llm-selftest:      \(g.name): \(g.ids.count) tokens, top-20 largest |Δ| \(String(format: "%.4f", promptWorst)), top-1 logit \(String(format: "%.3f", g.top20.first?[1] ?? 0))")
                    let gen = try await generateGreedy(engine, ids: g.ids, count: max(1, min(32, g.greedy.count)))
                    if gen == Array(g.greedy.prefix(gen.count)) && gen.count >= min(32, g.greedy.count) { matchedGreedy += 1 }
                }
                check("logits (512-token chunks, as the goldens): top-1 matches mlx-lm on \(top1)/\(lg.count) prompts", !lg.isEmpty && top1 == lg.count)
                check("logits: largest |Δ| over the top-20 is \(String(format: "%.4f", worst)) (limit \(logitTolerance); mlx-lm differs from itself by up to 1.09 when its prefill chunk changes from 512 to 128 tokens)", worst <= logitTolerance)
                check("greedy: the first 32 tokens equal mlx-lm on \(matchedGreedy)/\(lg.count) prompts", !lg.isEmpty && matchedGreedy == lg.count)
                // 2. The chunking the app uses (128 tokens): the logits move by rounding only; top-1 must still agree.
                // A greedy text may leave mlx-lm's at a near tie, so its agreement is reported, not required.
                await engine.setPrefillChunk(nil)
                var appWorst = 0.0, appTop1 = 0, appGreedy = 0
                for g in lg {
                    let logits = try await engine.lastLogits(g.ids)
                    if let first = g.top20.first.map({ Int($0[0]) }), logits.enumerated().max(by: { $0.element < $1.element })?.offset == first { appTop1 += 1 }
                    for pair in g.top20 where logits.indices.contains(Int(pair[0])) { appWorst = max(appWorst, abs(Double(logits[Int(pair[0])]) - pair[1])) }
                    let gen = try await generateGreedy(engine, ids: g.ids, count: max(1, min(32, g.greedy.count)))
                    if gen == Array(g.greedy.prefix(gen.count)) && gen.count >= min(32, g.greedy.count) { appGreedy += 1 }
                }
                check("logits with the app's 128-token chunks: top-1 matches on \(appTop1)/\(lg.count) prompts, largest |Δ| \(String(format: "%.4f", appWorst)) (limit \(logitTolerance))", !lg.isEmpty && appTop1 == lg.count && appWorst <= logitTolerance)
                out.append("llm-selftest:      greedy with the app's chunks: the first 32 tokens equal mlx-lm on \(appGreedy)/\(lg.count) prompts (informational: a near tie can flip with rounding)")
            }
        } catch { check("model run", false, "\(error)") }
        if long, let goldens {
            // 30k tokens against mlx-lm: the many-chunk growth of the full-attention caches and the windowed masks past the 8.5k tokens
            // of the other goldens. Same chunking as the golden (512), same tolerance as the other logit checks.
            let long30 = lines(goldens.appendingPathComponent("logit_goldens_long.jsonl"), as: LogitGolden.self)
            if let g = long30.first {
                await engine.setPrefillChunk(512)
                do {
                    let t = Date()
                    let logits = try await engine.lastLogits(g.ids)
                    var worst = 0.0
                    for pair in g.top20 where logits.indices.contains(Int(pair[0])) { worst = max(worst, abs(Double(logits[Int(pair[0])]) - pair[1])) }
                    let best = logits.enumerated().max(by: { $0.element < $1.element })?.offset
                    check("long parity: \(g.ids.count) tokens, top-1 matches mlx-lm (\(best.map(String.init) ?? "none") against \(g.top20.first.map { String(Int($0[0])) } ?? "none"))",
                          best != nil && best == g.top20.first.map { Int($0[0]) })
                    check("long parity: largest |Δ| over the top-20 is \(String(format: "%.4f", worst)) (limit \(logitTolerance))", worst <= logitTolerance,
                          String(format: "%.0f s", Date().timeIntervalSince(t)))
                } catch { check("long parity", false, "\(error)") }
                await engine.setPrefillChunk(nil)
            } else {
                check("long parity golden (logit_goldens_long.jsonl) is in the goldens folder", false)
            }
            // Speed and memory on prompts of 2k, 8k and 30k tokens built by repeating public meeting text (the golden 8k prompt).
            let lg = lines(goldens.appendingPathComponent("logit_goldens.jsonl"), as: LogitGolden.self)
            if let base = lg.first(where: { $0.name == "ami_8k" })?.ids {
                let body = Array(base.dropFirst(2).dropLast(8))
                for target in [2_000, 8_000, 30_000] {
                    var ids: [Int32] = [GemmaChatTemplate.bos, GemmaChatTemplate.turnStart]
                    while ids.count < target { ids += body }
                    ids = Array(ids.prefix(target)) + [GemmaChatTemplate.turnEnd, GemmaChatTemplate.turnStart]
                    ids += (try? await engine.loadedTokenizer().encodeLiteral("model\n")) ?? []
                    let before = MLXRuntime.physFootprintMB()
                    do {
                        let r = try await engine.generateTimed(ids, maxTokens: 32)
                        out.append("llm-selftest: long \(ids.count) tokens: prefill \(String(format: "%.1f", r.prefillSeconds)) s (\(Int(Double(ids.count) / max(r.prefillSeconds, 0.001))) tok/s), first token \(String(format: "%.1f", r.firstTokenSeconds)) s, decode \(String(format: "%.1f", Double(max(r.tokens.count - 1, 1)) / max(r.decodeSeconds, 0.001))) tok/s, footprint \(before) MB before, peak \(r.peakFootprintMB) MB, resident weights \(await engine.residentWeightBytes() >> 20) MB, GPU held at most \(String(format: "%.2f", r.longestChunkSeconds)) s per chunk and \(String(format: "%.2f", r.longestBurstSeconds)) s per burst")
                    } catch { check("long prompt of \(target) tokens", false, "\(error)") }
                }
            }
        }
        if long, goldens == nil { skipped = true }
        return Result(exitCode: exitCode(failures: failures, paritySkipped: skipped), lines: out)
    }

    /// A failure is a failure; a clean run that skipped the parity checks is not a pass either.
    static func exitCode(failures: Int, paritySkipped: Bool) -> Int32 {
        failures > 0 ? ExitCode.fail : (paritySkipped ? ExitCode.paritySkipped : ExitCode.pass)
    }

    private static func generateGreedy(_ engine: LanguageModelEngine, ids: [Int32], count: Int) async throws -> [Int32] {
        try await engine.generateIDs(ids, maxTokens: count)
    }
}
