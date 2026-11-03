// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// Brings an install of an earlier conversion (`LanguageModelSpec.earlier`) to the pinned one without the 15 GB download: every tensor
/// whose name, type and shape did not change is copied from the installed file, and only the original tensors of the ones that did are
/// fetched (Range requests of the pinned file, each checked against its pinned SHA-256) and quantised again. For the all-4-bit
/// conversion that is the per-layer path and the attention projections, now at 8 bits: 1.3 GB. Each output is compared with its pinned
/// hash as it is written, and the assembled file with its own before it replaces the installed one.
public struct LanguageModelUpdate: Sendable, Equatable {
    /// An output copied from the installed file: its index in `spec.outputs` and its offset in the installed file's data.
    struct Copy: Sendable, Equatable { let output: Int; let from: Int }

    let copies: [Copy]
    /// The source tensors fetched again, in span order.
    let fetches: [LanguageModelSpec.SourceTensor]
    /// Where the installed file's data starts (its header size).
    let installedDataStart: Int

    /// Bytes the update downloads.
    public var downloadBytes: Int { fetches.reduce(0) { $0 + $1.size } }

    /// The largest tensor fetched in one request: each is held in memory until its hash is checked.
    static let maxFetch = 64 << 20

    /// The update for the installed files, or nil when they are not an earlier conversion, their header does not match it, or a
    /// tensor that changed is too large to fetch in one piece (then only a full download brings the install up to date).
    public static func plan(_ store: LanguageModelStore) -> LanguageModelUpdate? {
        guard let conversion = store.installedEarlierConversion, LanguageModelVerifier.quickCheck(file: store.weightsURL, conversion: conversion),
              let fh = try? FileHandle(forReadingFrom: store.weightsURL) else { return nil }
        defer { try? fh.close() }
        guard let head = try? fh.read(upToCount: conversion.headerSize), head.count == conversion.headerSize, head.count > 8,
              let json = try? JSONSerialization.jsonObject(with: head.subdata(in: 8..<head.count)) as? [String: Any] else { return nil }
        return plan(spec: store.spec, installedHeader: json, installedDataStart: conversion.headerSize)
    }

    static func plan(spec: LanguageModelSpec, installedHeader: [String: Any], installedDataStart: Int) -> LanguageModelUpdate? {
        var copies: [Copy] = []
        var changed = Set<String>()
        for (i, o) in spec.outputs.enumerated() {
            if let entry = installedHeader[o.name] as? [String: Any], entry["dtype"] as? String == o.dtype, entry["shape"] as? [Int] == o.shape,
               let offsets = entry["data_offsets"] as? [Int], offsets.count == 2, offsets[1] - offsets[0] == o.size {
                copies.append(Copy(output: i, from: offsets[0]))
            } else {
                changed.insert(o.name)
            }
        }
        var fetches: [LanguageModelSpec.SourceTensor] = []
        var covered = Set<String>()
        for t in spec.sources {
            let names: [String]
            switch t.action {
            case .drop: continue
            case .copy: names = [t.outputName]
            case .quantize: names = [t.outputStem + ".weight", t.outputStem + ".scales", t.outputStem + ".biases"]
            }
            guard names.contains(where: changed.contains) else { continue }
            guard t.size <= maxFetch else { return nil }
            fetches.append(t)
            covered.formUnion(names)
        }
        // Every output is either copied or made again from a fetched tensor.
        guard changed.isSubset(of: covered), !fetches.isEmpty else { return nil }
        let fetched = Set(covered)
        return LanguageModelUpdate(copies: copies.filter { !fetched.contains(spec.outputs[$0.output].name) }, fetches: fetches,
                                   installedDataStart: installedDataStart)
    }
}

extension LanguageModelDownloader {
    /// Assembles the pinned conversion in staging from the installed file and the fetched tensors, checks it, and installs it in place
    /// of the installed files (the tokenizer is kept). Stopping or failing leaves the installed files as they were.
    func update(_ plan: LanguageModelUpdate, progress: @escaping @Sendable (LanguageModelProgress) -> Void,
                beforeBlock: @escaping @Sendable () async throws -> Void = {}) async throws {
        let fm = FileManager.default
        // The new file is written beside the installed one.
        let needed = spec.assembledSize + LanguageModelStore.headroom
        if let free = store.availableCapacity(), free < needed { throw IntegratedModelError.diskFull(needed: needed) }
        try store.createStaging()
        let part = store.stagedWeightsPart
        try? fm.removeItem(at: part)
        guard fm.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw IntegratedModelError.ioError }
        do {
            let quantizer = try StreamingQuantizer(spec: spec, output: part, fresh: true)
            let total = plan.downloadBytes
            var received = 0
            progress(.init(phase: .downloading, received: 0, total: total))
            // 1. The tensors that did not change, straight from the installed file, each checked against its pinned hash.
            try await beforeBlock()
            try copyUnchanged(plan, into: part)
            // 2. The tensors that changed: their original bytes, checked, then quantised at their new bits.
            for t in plan.fetches {
                let data = try await fetchRange(from: spec.spanStart + t.offset, count: t.size, sha256: t.sha256, beforeBlock: beforeBlock)
                try data.withUnsafeBytes { try quantizer.convert(t, raw: $0) }
                received += t.size
                progress(.init(phase: .downloading, received: received, total: total))
            }
            try await beforeBlock()
            progress(.init(phase: .finishing, received: total, total: total))
            try quantizer.finishAssembled()
            try? fm.removeItem(at: store.stagedWeights)
            try fm.moveItem(at: part, to: store.stagedWeights)
            try fm.copyItem(at: store.tokenizerURL, to: store.stagedTokenizer)
            try LanguageModelVerifier.verifyTokenizer(file: store.stagedTokenizer, spec: spec)
            let record = LanguageModelInstallRecord(revision: spec.revision, assembledSHA256: spec.assembledSHA256, tokenizerSHA256: spec.tokenizerSHA256,
                                                    source: "update", installedAt: Date(), appBuild: appBuild, verifiedByBuild: appBuild)
            try store.install(record)
        } catch {
            store.discardStaging()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw Self.map(error)
        }
    }

    /// Copies the unchanged outputs from the installed file into the new one, 8 MiB at a time, hashing each.
    private func copyUnchanged(_ plan: LanguageModelUpdate, into part: URL) throws {
        let source = try FileHandle(forReadingFrom: store.weightsURL)
        defer { try? source.close() }
        let out = try FileHandle(forWritingTo: part)
        defer { try? out.close() }
        let base = spec.headerSize
        for c in plan.copies {
            try Task.checkCancellation()
            let o = spec.outputs[c.output]
            try source.seek(toOffset: UInt64(plan.installedDataStart + c.from))
            try out.seek(toOffset: UInt64(base + o.offset))
            var h = SHA256()
            var left = o.size
            while left > 0 {
                guard let d = try source.read(upToCount: min(left, LanguageModelVerifier.readSize)), !d.isEmpty else { throw IntegratedModelError.mismatch }
                h.update(data: d)
                try out.write(contentsOf: d)
                left -= d.count
            }
            guard hex(h.finalize()) == o.sha256 else { throw IntegratedModelError.mismatch }
        }
    }
}
