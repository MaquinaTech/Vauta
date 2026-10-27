// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// Installs the model from files the person chose (no network): the original `model.safetensors` (1.49 GB), the assembled text
/// tower (542 MB) or `tokenizer.json`. Files are recognised by size and verified with the same pinned hashes as a download.
enum SearchModelImporter {
    enum Outcome: Sendable, Equatable {
        case installed
        /// The weights are verified and staged; the tokenizer is still needed.
        case needsTokenizer
        /// The tokenizer is staged; the weights are still needed.
        case needsWeights
    }

    private enum Kind { case original, assembled, tokenizer }

    private static func kind(of url: URL, spec: SearchModelSpec) -> Kind? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else { return nil }
        if size == spec.sourceSize { return .original }
        if size == spec.assembledSize { return .assembled }
        if size == spec.tokenizerSize { return .tokenizer }
        return nil
    }

    /// Verifies the files and installs the model when both its parts are present (in `urls` or already staged).
    /// Symbolic links are resolved (the Hugging Face cache stores files as links to blobs).
    static func importFiles(_ urls: [URL], store: SearchModelStore, appBuild: String = SearchModelDownloader.currentBuild,
                            progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Outcome {
        let spec = store.spec
        let files = urls.map { $0.resolvingSymlinksInPath() }
        guard !files.isEmpty else { throw SearchModelError.importWrongFile }
        var kinds: [(URL, Kind)] = []
        for url in files {
            guard let k = kind(of: url, spec: spec) else { throw SearchModelError.importWrongFile }
            kinds.append((url, k))
        }
        if let free = store.availableCapacity(), free < spec.installedSize + SearchModelDownloader.headroom {
            throw SearchModelError.diskFull(needed: spec.installedSize + SearchModelDownloader.headroom)
        }
        try store.createStaging()
        do {
            for (url, k) in kinds {
                try Task.checkCancellation()
                switch k {
                case .tokenizer: try importTokenizer(url, store: store)
                case .assembled: try importAssembled(url, store: store)
                case .original: try importOriginal(url, store: store, progress: progress)
                }
            }
        } catch {
            if error is CancellationError { throw error }
            throw (error as? SearchModelError) ?? SearchModelError.ioError
        }
        let fm = FileManager.default
        let hasWeights = fm.fileExists(atPath: store.stagedWeights.path)
        let hasTokenizer = fm.fileExists(atPath: store.stagedTokenizer.path)
        guard hasWeights, hasTokenizer else { return hasWeights ? .needsTokenizer : .needsWeights }
        try store.install(SearchModelInstallRecord(revision: spec.revision, assembledSHA256: spec.assembledSHA256, tokenizerSHA256: spec.tokenizerSHA256,
                                                   source: "import", installedAt: Date(), appBuild: appBuild, verifiedByBuild: appBuild))
        return .installed
    }

    private static func importTokenizer(_ url: URL, store: SearchModelStore) throws {
        try SearchModelVerifier.verifyTokenizer(file: url, spec: store.spec)
        let fm = FileManager.default
        try? fm.removeItem(at: store.stagedTokenizer)
        try fm.copyItem(at: url, to: store.stagedTokenizer)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.stagedTokenizer.path)
        // What was copied is verified again: the source could have changed between the check and the copy.
        do { try SearchModelVerifier.verifyTokenizer(file: store.stagedTokenizer, spec: store.spec) } catch {
            try? fm.removeItem(at: store.stagedTokenizer)
            throw error
        }
    }

    private static func importAssembled(_ url: URL, store: SearchModelStore) throws {
        try SearchModelVerifier.fullVerify(file: url, spec: store.spec)
        let fm = FileManager.default
        try? fm.removeItem(at: store.stagedWeights)
        try fm.copyItem(at: url, to: store.stagedWeights)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.stagedWeights.path)
        // What was copied is verified again: the source could have changed while it was being read.
        do { try SearchModelVerifier.fullVerify(file: store.stagedWeights, spec: store.spec) } catch {
            try? fm.removeItem(at: store.stagedWeights)
            throw error
        }
    }

    /// One pass over the original file: the whole file against the pinned SHA-256 and the text-tower span, block by block, into a
    /// new assembled file (header + span), which is then verified tensor by tensor.
    private static func importOriginal(_ url: URL, store: SearchModelStore, progress: @escaping @Sendable (Double) -> Void) throws {
        let spec = store.spec
        let fm = FileManager.default
        guard let input = try? FileHandle(forReadingFrom: url) else { throw SearchModelError.ioError }
        defer { try? input.close() }
        let part = store.stagedWeightsPart
        try? fm.removeItem(at: part)
        fm.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: part)
        var closed = false
        defer { if !closed { try? output.close() } }
        try output.write(contentsOf: spec.headerBytes())
        var whole = SHA256()
        var block = SHA256()
        var position = 0
        var inBlock = 0
        var blockIndex = 0
        let chunk = SearchModelVerifier.readSize
        func fail(_ error: Error) -> Error { try? fm.removeItem(at: part); return error }
        do {
            while position < spec.sourceSize {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: min(chunk, spec.sourceSize - position)), !data.isEmpty else { throw SearchModelError.importWrongFile }
                whole.update(data: data)
                // The part of this read that lies inside the span.
                let lo = max(position, spec.spanStart), hi = min(position + data.count, spec.spanEnd)
                if lo < hi {
                    var piece = data.subdata(in: (lo - position)..<(hi - position))
                    while !piece.isEmpty {
                        let room = spec.blockLength(blockIndex) - inBlock
                        let part1 = piece.prefix(room)
                        block.update(data: part1)
                        try output.write(contentsOf: part1)
                        inBlock += part1.count
                        piece = piece.dropFirst(part1.count)
                        if inBlock == spec.blockLength(blockIndex) {
                            guard hex(block.finalize()) == spec.blocks[blockIndex] else { throw SearchModelError.mismatch }
                            block = SHA256()
                            inBlock = 0
                            blockIndex += 1
                        }
                    }
                }
                position += data.count
                progress(Double(position) / Double(spec.sourceSize))
            }
            guard blockIndex == spec.blocks.count, hex(whole.finalize()) == spec.sourceSHA256 else { throw SearchModelError.mismatch }
            try output.synchronize()
            try output.close()
            closed = true
            try SearchModelVerifier.fullVerify(file: part, spec: spec)
        } catch {
            throw fail(error)
        }
        try? fm.removeItem(at: store.stagedWeights)
        try fm.moveItem(at: part, to: store.stagedWeights)
    }
}
