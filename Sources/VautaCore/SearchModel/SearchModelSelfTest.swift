// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Security
internal import VautaMLX

/// `Vauta mlx-selftest [--model]`: proves that the GPU kernels and the search model work in the binary as it is shipped
/// (sandboxed, hardened, notarised). It opens no store, records nothing and uses no network; it prints counts, timings and the
/// device name, never content.
public enum SearchModelSelfTest {
    public struct Result: Sendable, Equatable {
        public var exitCode: Int32
        public var lines: [String]
    }

    public enum ExitCode {
        public static let pass: Int32 = 0
        public static let fail: Int32 = 1
        public static let unsupported: Int32 = 2
        public static let modelMissing: Int32 = 3
    }

    /// `VAUTA_SEARCH_MODEL_DIR` (tests and tools) names the install folder itself (the one holding `model.safetensors`); the store is
    /// the two levels above it (`<root>/embeddinggemma-2/<revision>`). Without it, the default store.
    public static func store(environment: [String: String] = ProcessInfo.processInfo.environment) -> SearchModelStore {
        if let path = environment["VAUTA_SEARCH_MODEL_DIR"], !path.isEmpty {
            return SearchModelStore(root: URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent())
        }
        return SearchModelStore()
    }

    /// One line for `Vauta doctor`: whether this Mac can run the search model and what is installed. Reads the disk only (no network,
    /// no loading of the model). `ok` is false only when a model is installed but cannot be used.
    public static func describe(store: SearchModelStore = store()) -> (ok: Bool?, text: String) {
        guard MLXRuntime.isSupported else { return (nil, "This Mac has no Apple silicon GPU the search model can use; search by meaning is off.") }
        switch store.disk() {
        case .empty: return (nil, "Not installed (a download of about 575 MB, started from Settings › Models).")
        case .partial: return (nil, "A download was stopped; resume or discard it in Settings › Models.")
        case .installed:
            let ok = SearchModelVerifier.quickCheck(file: store.weightsURL, spec: store.spec)
            return (ok, ok ? "Installed (\(store.bytesOnDisk() >> 20) MB on this Mac) on \(MLXRuntime.deviceName)." : "Installed, but the files do not match the pinned size and header.")
        }
    }

    /// `mlx-selftest --download` (release check only): fetches the pinned text tower into the folder named by
    /// `VAUTA_SEARCH_MODEL_DIR` through the audited session. Refuses to touch the app's real store.
    public static func download(environment: [String: String] = ProcessInfo.processInfo.environment) async -> Result {
        guard let path = environment["VAUTA_SEARCH_MODEL_DIR"], !path.isEmpty else {
            return Result(exitCode: ExitCode.fail, lines: ["mlx-selftest: --download needs VAUTA_SEARCH_MODEL_DIR (it never writes to the app’s own store)."])
        }
        let store = store(environment: environment)
        do {
            try store.prepare()
            let downloader = SearchModelDownloader(session: SearchModelDownloader.makeSession(), store: store)
            let started = Date()
            try await downloader.run(source: "selftest", progress: { _ in })
            return Result(exitCode: ExitCode.pass, lines: ["mlx-selftest: downloaded and verified \(store.bytesOnDisk() >> 20) MB in " + String(format: "%.0f s", Date().timeIntervalSince(started))])
        } catch {
            return Result(exitCode: ExitCode.fail, lines: ["mlx-selftest: download failed (\(error))."])
        }
    }

    public static func run(includeModel: Bool, store: SearchModelStore = store(),
                           environment: [String: String] = ProcessInfo.processInfo.environment) async -> Result {
        guard MLXRuntime.isSupported else {
            return Result(exitCode: ExitCode.unsupported, lines: ["mlx-selftest: this Mac has no Apple silicon GPU (Apple7 family or later) that MLX can use."])
        }
        let report = KernelSelfTest.run(.full)
        var lines = ["mlx-selftest: \(report.passed)/\(report.total) kernel checks passed · \(report.deviceName) · first compile "
                     + String(format: "%.1f s", report.firstCheckSeconds) + " · sandbox: \(Signing.isSandboxed ? "yes" : "no") · hardened runtime: \(Signing.isHardened ? "yes" : "no")"]
        guard report.ok else {
            lines.append("mlx-selftest: failed: " + report.failed.joined(separator: ", "))
            return Result(exitCode: ExitCode.fail, lines: lines)
        }
        guard includeModel else { return Result(exitCode: ExitCode.pass, lines: lines) }
        guard case .installed = store.disk() else {
            lines.append("mlx-selftest: the search model is not installed.")
            return Result(exitCode: ExitCode.modelMissing, lines: lines)
        }
        let started = Date()
        do {
            try SearchModelVerifier.fullVerify(file: store.weightsURL, spec: store.spec)
        } catch {
            lines.append("mlx-selftest: the model files do not match the pinned hashes.")
            return Result(exitCode: ExitCode.fail, lines: lines)
        }
        lines.append("mlx-selftest: model files verified (413 tensors and the assembled file) in " + String(format: "%.1f s", Date().timeIntervalSince(started)))
        guard let goldens = SearchModelGoldens.vectors else {
            lines.append("mlx-selftest: this build has no golden vectors to compare with.")
            return Result(exitCode: ExitCode.fail, lines: lines)
        }
        let engine = SearchModelEngine(store: store)
        do {
            let vectors = try await engine.embed(SearchModelGoldens.strings, purpose: .document)
            var worst: Float = 1
            for (v, g) in zip(vectors, goldens) { worst = min(worst, SearchModelGoldens.cosine(v, g)) }
            let verdict = goldenVerdict(worst: worst, reference: SearchModelGoldens.reference, releaseBuild: Self.isReleaseBuild)
            lines.append("mlx-selftest: \(vectors.count) golden sentences, lowest cosine " + String(format: "%.5f", worst))
            lines.append("mlx-selftest: " + verdict.message)
            await engine.unload()
            guard verdict.pass else { return Result(exitCode: ExitCode.fail, lines: lines) }
        } catch {
            lines.append("mlx-selftest: the model could not run (\(error)).")
            return Result(exitCode: ExitCode.fail, lines: lines)
        }
        return Result(exitCode: ExitCode.pass, lines: lines)
    }

    static var isReleaseBuild: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    /// Whether the comparison with the golden vectors passes. Goldens made by Vauta's own encoder only show that fp16 agrees with fp32:
    /// a mistake both share (pooling, prompt, Matryoshka cut, tokenizer edge case) would pass. So a release build fails the check
    /// until the goldens are Hugging Face's (`tools/search-model/make-goldens.py`, `reference = true`).
    static func goldenVerdict(worst: Float, reference: Bool, releaseBuild: Bool) -> (pass: Bool, message: String) {
        guard worst >= 0.999 else { return (false, "the vectors differ from the golden ones (needs cosine 0.999 or more).") }
        if reference { return (true, "the vectors match Hugging Face's reference.") }
        if releaseBuild {
            return (false, "the golden vectors were made by Vauta's own encoder, not by Hugging Face, so this check cannot pass in a release build. "
                           + "Generate them with tools/search-model/make-goldens.py and set SearchModelGoldens.reference to true (docs/RELEASING.md).")
        }
        return (true, "the vectors match Vauta's own fp32 encoder (not yet a Hugging Face reference; a release build fails here).")
    }

    /// The process's own code-signing state.
    enum Signing {
        static var isSandboxed: Bool {
            guard let task = SecTaskCreateFromSelf(nil),
                  let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) else { return false }
            return (value as? Bool) == true
        }

        static var isHardened: Bool {
            var code: SecCode?
            guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
            var staticCode: SecStaticCode?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
            var info: CFDictionary?
            guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
                  let dict = info as? [String: Any], let flags = dict[kSecCodeInfoFlags as String] as? UInt32 else { return false }
            return flags & 0x10000 != 0   // kSecCodeSignatureRuntime
        }
    }
}
