// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// Checks files of the language model against the pinned values. Everything streams through a `FileHandle` in 8 MB reads.
enum LanguageModelVerifier {
    static let readSize = 8 << 20

    /// Size and exact header bytes of an assembled file. Run on every load.
    static func quickCheck(file: URL, spec: LanguageModelSpec) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? fh.close() }
        let header = spec.headerBytes()
        guard let size = try? fh.seekToEnd(), Int(size) == spec.assembledSize, (try? fh.seek(toOffset: 0)) != nil else { return false }
        return (try? fh.read(upToCount: header.count)) == header
    }

    static func quickCheckTokenizer(file: URL, spec: LanguageModelSpec) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int == spec.tokenizerSize
    }

    /// The header, each output tensor and the whole assembled file in one pass. Checks for cancellation between reads.
    static func fullVerify(file: URL, spec: LanguageModelSpec) throws {
        guard let fh = try? FileHandle(forReadingFrom: file) else { throw IntegratedModelError.ioError }
        defer { try? fh.close() }
        let header = spec.headerBytes()
        guard let size = try? fh.seekToEnd(), Int(size) == spec.assembledSize, (try? fh.seek(toOffset: 0)) != nil else { throw IntegratedModelError.mismatch }
        var all = SHA256()
        guard let head = try? fh.read(upToCount: header.count), head == header else { throw IntegratedModelError.mismatch }
        all.update(data: head)
        for t in spec.outputs {
            try Task.checkCancellation()
            var h = SHA256()
            var left = t.size
            while left > 0 {
                guard let d = try? fh.read(upToCount: min(left, readSize)), !d.isEmpty else { throw IntegratedModelError.mismatch }
                h.update(data: d)
                all.update(data: d)
                left -= d.count
            }
            guard hex(h.finalize()) == t.sha256 else { throw IntegratedModelError.mismatch }
        }
        guard hex(all.finalize()) == spec.assembledSHA256 else { throw IntegratedModelError.mismatch }
    }

    /// Size and header hash of a file of an earlier conversion.
    static func quickCheck(file: URL, conversion c: LanguageModelSpec.Conversion) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), Int(size) == c.assembledSize, (try? fh.seek(toOffset: 0)) != nil,
              let head = try? fh.read(upToCount: c.headerSize), head.count == c.headerSize else { return false }
        return hex(SHA256.hash(data: head)) == c.headerSHA256
    }

    /// The whole file of an earlier conversion against its hash.
    static func fullVerify(file: URL, conversion c: LanguageModelSpec.Conversion) throws {
        guard let fh = try? FileHandle(forReadingFrom: file) else { throw IntegratedModelError.ioError }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), Int(size) == c.assembledSize, (try? fh.seek(toOffset: 0)) != nil else { throw IntegratedModelError.mismatch }
        var all = SHA256()
        while let d = try? fh.read(upToCount: readSize), !d.isEmpty {
            try Task.checkCancellation()
            all.update(data: d)
        }
        guard hex(all.finalize()) == c.assembledSHA256 else { throw IntegratedModelError.mismatch }
    }

    /// The installed weights against what their record says they are: the pinned conversion, or an earlier one still waiting for its
    /// update. A record of any other conversion fails.
    static func quickCheckInstalled(_ store: LanguageModelStore) -> Bool {
        if let c = store.installedEarlierConversion { return quickCheck(file: store.weightsURL, conversion: c) }
        return quickCheck(file: store.weightsURL, spec: store.spec)
    }

    static func fullVerifyInstalled(_ store: LanguageModelStore) throws {
        if let c = store.installedEarlierConversion { return try fullVerify(file: store.weightsURL, conversion: c) }
        try fullVerify(file: store.weightsURL, spec: store.spec)
    }

    static func verifyTokenizer(file: URL, spec: LanguageModelSpec) throws {
        guard let fh = try? FileHandle(forReadingFrom: file) else { throw IntegratedModelError.ioError }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), Int(size) == spec.tokenizerSize, (try? fh.seek(toOffset: 0)) != nil else { throw IntegratedModelError.mismatch }
        var h = SHA256()
        while let d = try? fh.read(upToCount: readSize), !d.isEmpty {
            try Task.checkCancellation()
            h.update(data: d)
        }
        guard hex(h.finalize()) == spec.tokenizerSHA256 else { throw IntegratedModelError.mismatch }
    }
}
