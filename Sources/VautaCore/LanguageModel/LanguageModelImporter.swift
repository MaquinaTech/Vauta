// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// Installs the model from files the person chose (no network): Google's original `model.safetensors` (16 GB; its language
/// tower is verified block by block and quantised on this Mac), a 4-bit file assembled earlier (about 4.2 GB, from another Mac)
/// or `tokenizer.json`. Files are recognised by size and verified with the same pinned hashes as a download.
public enum LanguageModelImporter {
    public enum Outcome: Sendable, Equatable {
        case installed
        case needsTokenizer
        case needsWeights
    }

    private enum Kind { case original, assembled, tokenizer }

    private static func kind(of url: URL, spec: LanguageModelSpec) -> Kind? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else { return nil }
        if size == spec.sourceSize { return .original }
        if size == spec.assembledSize { return .assembled }
        if size == spec.tokenizerSize { return .tokenizer }
        return nil
    }

    /// Symbolic links are resolved (the Hugging Face cache stores files as links to blobs).
    public static func importFiles(_ urls: [URL], store: LanguageModelStore, appBuild: String = LanguageModelStore.currentBuild,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in },
                                   beforeBlock: @escaping @Sendable () async throws -> Void = {}) async throws -> Outcome {
        let spec = store.spec
        let files = urls.map { $0.resolvingSymlinksInPath() }
        guard !files.isEmpty else { throw IntegratedModelError.importWrongFile }
        var kinds: [(URL, Kind)] = []
        for url in files {
            guard let k = kind(of: url, spec: spec) else { throw IntegratedModelError.importWrongFile }
            kinds.append((url, k))
        }
        try store.checkRoomToInstall()
        try store.createStaging()
        do {
            for (url, k) in kinds {
                try Task.checkCancellation()
                switch k {
                case .tokenizer: try importTokenizer(url, store: store)
                case .assembled: try importAssembled(url, store: store)
                case .original: try await importOriginal(url, store: store, progress: progress, beforeBlock: beforeBlock)
                }
            }
        } catch {
            if error is CancellationError { throw error }
            throw (error as? IntegratedModelError) ?? IntegratedModelError.ioError
        }
        let fm = FileManager.default
        let hasWeights = fm.fileExists(atPath: store.stagedWeights.path)
        let hasTokenizer = fm.fileExists(atPath: store.stagedTokenizer.path)
        guard hasWeights, hasTokenizer else { return hasWeights ? .needsTokenizer : .needsWeights }
        try store.install(LanguageModelInstallRecord(revision: spec.revision, assembledSHA256: spec.assembledSHA256, tokenizerSHA256: spec.tokenizerSHA256,
                                                     source: "import", installedAt: Date(), appBuild: appBuild, verifiedByBuild: appBuild))
        return .installed
    }

    private static func importTokenizer(_ url: URL, store: LanguageModelStore) throws {
        try LanguageModelVerifier.verifyTokenizer(file: url, spec: store.spec)
        let fm = FileManager.default
        try? fm.removeItem(at: store.stagedTokenizer)
        try fm.copyItem(at: url, to: store.stagedTokenizer)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.stagedTokenizer.path)
        do { try LanguageModelVerifier.verifyTokenizer(file: store.stagedTokenizer, spec: store.spec) } catch {
            try? fm.removeItem(at: store.stagedTokenizer)
            throw error
        }
    }

    private static func importAssembled(_ url: URL, store: LanguageModelStore) throws {
        try LanguageModelVerifier.fullVerify(file: url, spec: store.spec)
        let fm = FileManager.default
        try? fm.removeItem(at: store.stagedWeights)
        try fm.copyItem(at: url, to: store.stagedWeights)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.stagedWeights.path)
        do { try LanguageModelVerifier.fullVerify(file: store.stagedWeights, spec: store.spec) } catch {
            try? fm.removeItem(at: store.stagedWeights)
            throw error
        }
    }

    /// One pass over the original file: the whole file against the pinned SHA-256 and the language tower block by block, each
    /// block verified before `StreamingQuantizer` sees it. The assembled file is then verified (every tensor and the whole).
    private static func importOriginal(_ url: URL, store: LanguageModelStore, progress: @escaping @Sendable (Double) -> Void,
                                       beforeBlock: @escaping @Sendable () async throws -> Void) async throws {
        let spec = store.spec
        let fm = FileManager.default
        guard let input = try? FileHandle(forReadingFrom: url) else { throw IntegratedModelError.ioError }
        defer { try? input.close() }
        // The header: exact bytes of the original (its hash is pinned), so the tensor table is the one the manifest describes.
        guard let head = try input.read(upToCount: spec.sourceHeaderSize), head.count == spec.sourceHeaderSize,
              hex(SHA256.hash(data: head)) == spec.sourceHeaderSHA256 else { throw IntegratedModelError.importWrongFile }
        try input.seek(toOffset: 0)
        let part = store.stagedWeightsPart
        try? fm.removeItem(at: part)
        let quantizer = try StreamingQuantizer(spec: spec, output: part, fresh: true)
        var whole = SHA256()
        var block = SHA256()
        var position = 0, inBlock = 0, blockIndex = 0
        var blockData = Data()
        var waitedAt = -1
        func fail(_ error: Error) -> Error { try? fm.removeItem(at: part); return error }
        do {
            while position < spec.sourceSize {
                try Task.checkCancellation()
                // A recording pauses the conversion at every 64 MiB (and for two minutes after it).
                if position / spec.blockSize != waitedAt { waitedAt = position / spec.blockSize; try await beforeBlock() }
                guard let data = try input.read(upToCount: min(LanguageModelVerifier.readSize, spec.sourceSize - position)), !data.isEmpty
                else { throw IntegratedModelError.importWrongFile }
                whole.update(data: data)
                let lo = max(position, spec.spanStart), hi = min(position + data.count, spec.spanEnd)
                if lo < hi {
                    var piece = data.subdata(in: (lo - position)..<(hi - position))
                    while !piece.isEmpty {
                        let room = spec.blockLength(blockIndex) - inBlock
                        let taken = piece.prefix(room)
                        block.update(data: taken)
                        blockData.append(taken)
                        inBlock += taken.count
                        piece = piece.dropFirst(taken.count)
                        if inBlock == spec.blockLength(blockIndex) {
                            guard hex(block.finalize()) == spec.blocks[blockIndex] else { throw IntegratedModelError.mismatch }
                            try blockData.withUnsafeBytes { try quantizer.feed($0) }
                            blockData.removeAll(keepingCapacity: true)
                            block = SHA256()
                            inBlock = 0
                            blockIndex += 1
                        }
                    }
                }
                position += data.count
                progress(Double(position) / Double(spec.sourceSize))
            }
            guard blockIndex == spec.blocks.count, hex(whole.finalize()) == spec.sourceSHA256 else { throw IntegratedModelError.mismatch }
            try quantizer.finish()
        } catch {
            throw fail(error)
        }
        try? fm.removeItem(at: store.stagedWeights)
        try fm.moveItem(at: part, to: store.stagedWeights)
    }
}
