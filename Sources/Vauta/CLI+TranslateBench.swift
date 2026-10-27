// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import AppKit
import Foundation
import SwiftUI

// `Vauta translate-bench [--from en] [--to es] [--strategy auto|low|high] [--count 8] [--wpm 150]`
//
// Measures Live Translation on this Mac with the language models that are
// already installed (it never downloads one, never records audio and never
// reads a meeting): the latency of translating one sentence, the latency of
// the whole pipeline with a replayed stream of partial and final segments,
// the CPU time it costs, and the main-thread cost of updating the captions
// panel. Diagnostics build only; the sentences are invented.

enum TranslateBench {
    static let corpora: [String: [String]] = [
        "en": [
            "Yes.", "Thank you very much.", "Let’s move the launch to the second week of March.",
            "Legal still needs to review the new contract before we can sign anything.",
            "Can everyone send me their estimates by Friday so we can plan the next sprint?",
            "I think the budget is fine, but the timeline is tight and we depend on the vendor.",
            "So what we agreed last week was that the design team would finish the mockups and share them with engineering.",
            "Could you share the slides after the meeting?", "We closed the last blocking bug yesterday.",
            "Let me check with the support team and get back to you tomorrow morning.",
        ],
        "es": [
            "Sí.", "Muchas gracias.", "Pasemos el lanzamiento a la segunda semana de marzo.",
            "Legal todavía tiene que revisar el nuevo contrato antes de que podamos firmar nada.",
            "¿Podéis enviarme vuestras estimaciones antes del viernes para planificar el próximo sprint?",
            "Creo que el presupuesto está bien, pero el plazo es ajustado y dependemos del proveedor.",
            "Lo que acordamos la semana pasada fue que el equipo de diseño terminaría las maquetas y las compartiría con ingeniería.",
            "¿Puedes compartir las diapositivas después de la reunión?", "Ayer cerramos el último error bloqueante.",
            "Lo consulto con el equipo de soporte y te respondo mañana por la mañana.",
        ],
    ]

    @MainActor
    static func run(_ invocation: CommandInvocation) async -> Int32 {
        let source = Locale.Language(identifier: invocation.values["--from"] ?? "en")
        let sourceCode = source.languageCode?.identifier ?? "en"
        guard let corpus = corpora[sourceCode] else {
            printError("No sample sentences for \(sourceCode). Use --from en or --from es.")
            return 2
        }
        let target = invocation.values["--to"].map(Locale.Language.init(identifier:))
            ?? TranslationPair.automaticTarget(source: source) ?? Locale.Language(identifier: sourceCode == "en" ? "es" : "en")
        let count = min(max(Int(invocation.values["--count"] ?? "") ?? 8, 1), 40)
        let wpm = min(max(Double(invocation.values["--wpm"] ?? "") ?? 150, 60), 600)
        let backend = AppleTranslationBackend()
        let pair = TranslationPair(source: source, target: target)

        print("Pair \(pair.id)")
        let availability = await backend.availability(from: source, to: target)
        print("Models: \(await backend.describeStatuses(from: source, to: target))")
        guard availability == .installed else {
            print("Not installed (\(availability)). Nothing was downloaded. Install the language in System Settings > General > Language & Region > Translation Languages, or from Vauta Settings > Translation.")
            return 0
        }
        let strategy: TranslationStrategy?
        switch invocation.values["--strategy"] ?? "auto" {
        case "low": strategy = .lowLatency
        case "high": strategy = .highFidelity
        default: strategy = nil
        }

        // 1. Single sentences.
        let made = ContinuousClock.now
        let translator: any Translator
        do {
            if let strategy {
                translator = try await backend.makeTranslator(from: source, to: target, strategy: strategy)
            } else {
                translator = try await backend.makeTranslator(from: source, to: target)
            }
        } catch {
            printError("Couldn’t create the translator (\(error.localizedDescription)). The \(strategy.map { "\($0)" } ?? "default") models may not be installed.")
            return 1
        }
        print("Translator created in \(ms(ContinuousClock.now - made)) ms (strategy: \(strategy.map { "\($0)" } ?? "installed one"))")
        let warm = ContinuousClock.now
        _ = try? await translator.translate(corpus[2])
        print("First translation (cold): \(ms(ContinuousClock.now - warm)) ms")
        var samples: [Double] = []
        let cpuStart = ResourceUsage.now()
        for _ in 0..<3 {
            for sentence in corpus {
                let start = ContinuousClock.now
                _ = try? await translator.translate(sentence)
                samples.append(ms(ContinuousClock.now - start))
            }
        }
        let cpu1 = ResourceUsage.now().cpuSeconds - cpuStart.cpuSeconds
        print("Single sentence (\(samples.count) runs): \(summary(samples)); CPU in this process \(String(format: "%.2f", cpu1)) s")
        let words = corpus.map { $0.split(separator: " ").count }
        print("  by length: " + corpus.indices.map { "\(words[$0])w=\(String(format: "%.0f", samples[$0 + corpus.count]))ms" }.joined(separator: " "))

        // 2. The whole pipeline with a replayed stream (real time, no audio).
        let recorder = BenchRecorder()
        let live = LiveTranslator(backend: backend) { final in await recorder.finalDone(final) }
        let preferences = Preferences(defaults: UserDefaults(suiteName: "local.vauta.bench") ?? .standard, legacyInstall: false)
        defer { UserDefaults(suiteName: "local.vauta.bench")?.removePersistentDomain(forName: "local.vauta.bench") }
        let model = LiveTranslationModel(snapshotPreferences: preferences, snapshot: CaptionSnapshot(pair: pair, status: .listening))
        let host = NSHostingView(rootView: CaptionsView(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: preferences.captionTextSize.panelHeight(showOriginal: false)),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.alphaValue = 0
        window.orderFrontRegardless()
        let watcher = Task { @MainActor in
            for await snapshot in live.snapshots {
                let begin = ContinuousClock.now
                model.benchApply(snapshot)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                recorder.snapshotShown(snapshot, mainThread: ms(ContinuousClock.now - begin))
            }
        }
        await live.configure(source: source, target: target)
        let sentences = (0..<count).map { corpus[3 + $0 % (corpus.count - 3)] }
        let cpu0 = ResourceUsage.now()
        let wall0 = ContinuousClock.now
        let wordGap = Duration.milliseconds(60_000 / wpm)
        for (index, sentence) in sentences.enumerated() {
            let tokens = sentence.split(separator: " ").map(String.init)
            for k in 1...tokens.count {
                let text = tokens.prefix(k).joined(separator: " ")
                if k == tokens.count {
                    try? await Task.sleep(for: .milliseconds(300))
                    recorder.submitted(text)
                    live.submit(Segment(channel: .others, start: 0, end: 1, text: text, isFinal: true), key: index)
                } else {
                    live.submit(Segment(channel: .others, start: 0, end: 1, text: text, isFinal: false), key: -1)
                    try? await Task.sleep(for: wordGap)
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
        await live.finish(maxWait: .seconds(5))
        _ = await watcher.value
        let wall = ms(ContinuousClock.now - wall0) / 1000
        let cpu2 = ResourceUsage.now().cpuSeconds - cpu0.cpuSeconds
        let result = recorder.result()
        print("Pipeline: \(sentences.count) sentences at \(Int(wpm)) wpm, \(String(format: "%.0f", wall)) s of replayed speech")
        print("  final translated (submit → stored): \(summary(result.translated))")
        print("  final on screen (submit → caption final): \(summary(result.shown))")
        print("  snapshots published: \(result.snapshots) (\(String(format: "%.1f", Double(result.snapshots) / wall)) per second)")
        print("  CPU: \(String(format: "%.2f", cpu2)) s over \(String(format: "%.0f", wall)) s (\(String(format: "%.1f", cpu2 / wall * 100)) % of one core, includes the replay and the offscreen panel)")
        print("Main thread, caption update + layout + draw (\(result.mainThread.count) updates): \(summary(result.mainThread))")
        model.benchStop()
        return 0
    }

    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    static func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "no data" }
        let sorted = values.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        return String(format: "p50 %.1f ms, p95 %.1f ms, max %.1f ms", pct(0.5), pct(0.95), sorted.last!)
    }
}

/// Collects timings from several tasks.
private final class BenchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var submittedAt: [String: ContinuousClock.Instant] = [:]
    private var translatedMs: [Double] = []
    private var shownMs: [Double] = []
    private var shownTexts: Set<String> = []
    private var mainMs: [Double] = []
    private var snapshots = 0
    private var originals: [Int: String] = [:]

    func submitted(_ text: String) { lock.withLock { submittedAt[text] = .now } }

    func finalDone(_ final: FinalTranslation) async {
        lock.withLock {
            // The key is the sentence index; match by the oldest unmatched submission.
            if let (text, at) = submittedAt.filter({ !shownTexts.contains($0.key) && !originals.values.contains($0.key) }).min(by: { $0.value < $1.value }) {
                originals[final.key] = text
                translatedMs.append(TranslateBench.ms(.now - at))
            }
        }
    }

    func snapshotShown(_ snapshot: CaptionSnapshot, mainThread: Double) {
        lock.withLock {
            snapshots += 1
            mainMs.append(mainThread)
            for line in snapshot.lines where line.state == .final {
                if let at = submittedAt[line.original], shownTexts.insert(line.original).inserted {
                    shownMs.append(TranslateBench.ms(.now - at))
                }
            }
        }
    }

    func result() -> (translated: [Double], shown: [Double], snapshots: Int, mainThread: [Double]) {
        lock.withLock { (translatedMs, shownMs, snapshots, mainMs) }
    }
}
#endif
