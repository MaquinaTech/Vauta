// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Synchronization
internal import VautaMLX

/// The install operations behind `Vauta llm-install` (hidden, for testing and release checks): status, download, import,
/// verify and delete. The Settings card drives the same operations.
public enum LanguageModelInstaller {
    public static func status(store: LanguageModelStore) -> [String] {
        var lines: [String] = []
        let gpu = MLXRuntime.isSupported
        if let refusal = LanguageModelGate.refusal(gpuSupported: gpu) { lines.append("gate: not met (\(refusal))") } else { lines.append("gate: met (\(ProcessInfo.processInfo.physicalMemory >> 30) GB, \(MLXRuntime.deviceName))") }
        let spec = store.spec
        lines.append("model: \(spec.repository)@\(spec.revisionFolder) · download \(spec.downloadSize >> 20) MiB · installed size \(spec.installedSize >> 20) MiB")
        switch store.disk() {
        case .empty: lines.append("disk: not installed")
        case .partial: lines.append("disk: a download or import is waiting in staging/ (\(store.bytesOnDisk() >> 20) MiB)")
        case .installed(let r):
            let quick = LanguageModelVerifier.quickCheck(file: store.weightsURL, spec: spec)
            lines.append("disk: installed (\(r.source), \(r.installedAt.formatted(.iso8601))) · \(store.bytesOnDisk() >> 20) MiB · header \(quick ? "ok" : "MISMATCH")")
        }
        return lines
    }

    public static func verify(store: LanguageModelStore) -> (ok: Bool, line: String) {
        let t0 = Date()
        do {
            try LanguageModelVerifier.fullVerify(file: store.weightsURL, spec: store.spec)
            try LanguageModelVerifier.verifyTokenizer(file: store.tokenizerURL, spec: store.spec)
            return (true, String(format: "verified: all %d tensors, the assembled file and the tokenizer match the pinned hashes (%.1f s)", store.spec.outputs.count, Date().timeIntervalSince(t0)))
        } catch { return (false, "verification failed: \(error)") }
    }

    /// Writes `installed.json` for files already placed in the install folder (a developer adopting a file that this Mac already assembled).
    public static func adopt(store: LanguageModelStore, source: String = "import") throws {
        let v = verify(store: store)
        guard v.ok else { throw IntegratedModelError.mismatch }
        let spec = store.spec
        let record = LanguageModelInstallRecord(revision: spec.revision, assembledSHA256: spec.assembledSHA256, tokenizerSHA256: spec.tokenizerSHA256,
                                                source: source, installedAt: Date(), appBuild: LanguageModelStore.currentBuild, verifiedByBuild: LanguageModelStore.currentBuild)
        try store.updateRecord(record)
    }

    public static func download(store: LanguageModelStore, progress: @escaping @Sendable (String) -> Void) async throws {
        let downloader = LanguageModelDownloader(session: SearchModelDownloader.makeSession(), store: store)
        let last = ProgressThrottle()
        try await downloader.run(source: "download", progress: { p in
            if let line = last.line(for: p) { progress(line) }
        })
    }

    public static func importFiles(_ urls: [URL], store: LanguageModelStore, progress: @escaping @Sendable (String) -> Void) async throws -> LanguageModelImporter.Outcome {
        let last = ProgressThrottle()
        return try await LanguageModelImporter.importFiles(urls, store: store, progress: { f in
            if let line = last.line(fraction: f) { progress(line) }
        })
    }
}

/// Prints a progress line at most every 5 percent.
private final class ProgressThrottle: Sendable {
    private let step = Mutex(-1)
    func line(for p: LanguageModelProgress) -> String? { line(fraction: Double(p.received) / Double(max(p.total, 1)), phase: "\(p.phase)") }
    func line(fraction: Double, phase: String = "import") -> String? {
        let s = Int(fraction * 20)
        let moved = step.withLock { step in
            guard s != step else { return false }
            step = s
            return true
        }
        return moved ? "\(phase) \(s * 5)%" : nil
    }
}
