// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// Checks files of the search model against the pinned values. Everything streams through a `FileHandle` in 8 MB reads.
enum SearchModelVerifier {
    static let readSize = 8 << 20

    /// Size and exact header bytes of an assembled file: 0.5 ms. Run on every load.
    static func quickCheck(file: URL, spec: SearchModelSpec) -> Bool {
        guard let fh = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? fh.close() }
        let header = spec.headerBytes()
        guard let size = try? fh.seekToEnd(), Int(size) == header.count + spec.spanSize, (try? fh.seek(toOffset: 0)) != nil else { return false }
        return (try? fh.read(upToCount: header.count)) == header
    }

    /// Size of the tokenizer file: 0.1 ms. The full check (SHA-256) runs when the tokenizer is loaded.
    static func quickCheckTokenizer(file: URL, spec: SearchModelSpec) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int == spec.tokenizerSize
    }

    /// The header, each tensor and the whole assembled file in one pass (about 0.5 s with a warm page cache). Checks for
    /// cancellation between reads.
    static func fullVerify(file: URL, spec: SearchModelSpec) throws {
        guard let fh = try? FileHandle(forReadingFrom: file) else { throw SearchModelError.ioError }
        defer { try? fh.close() }
        try fullVerify(handle: fh, spec: spec)
    }

    static func fullVerify(handle fh: FileHandle, spec: SearchModelSpec) throws {
        let header = spec.headerBytes()
        guard let size = try? fh.seekToEnd(), Int(size) == header.count + spec.spanSize, (try? fh.seek(toOffset: 0)) != nil else {
            throw SearchModelError.mismatch
        }
        var all = SHA256()
        guard let head = try? fh.read(upToCount: header.count), head == header else { throw SearchModelError.mismatch }
        all.update(data: head)
        for t in spec.tensors {
            try Task.checkCancellation()
            var h = SHA256()
            var left = t.size
            while left > 0 {
                guard let d = try? fh.read(upToCount: min(left, readSize)), !d.isEmpty else { throw SearchModelError.mismatch }
                h.update(data: d)
                all.update(data: d)
                left -= d.count
            }
            guard hex(h.finalize()) == t.sha256 else { throw SearchModelError.mismatch }
        }
        guard hex(all.finalize()) == spec.assembledSHA256 else { throw SearchModelError.mismatch }
    }

    /// Whether a file is the tokenizer: size and SHA-256.
    static func verifyTokenizer(file: URL, spec: SearchModelSpec) throws {
        guard let fh = try? FileHandle(forReadingFrom: file) else { throw SearchModelError.ioError }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), Int(size) == spec.tokenizerSize, (try? fh.seek(toOffset: 0)) != nil else { throw SearchModelError.mismatch }
        var h = SHA256()
        while let d = try? fh.read(upToCount: readSize), !d.isEmpty {
            try Task.checkCancellation()
            h.update(data: d)
        }
        guard hex(h.finalize()) == spec.tokenizerSHA256 else { throw SearchModelError.mismatch }
    }

    /// The number of leading blocks of an in-progress assembled file (`.part`) that are present and match their hash. The
    /// header must match too, otherwise nothing is kept.
    static func verifiedBlocks(partial fh: FileHandle, spec: SearchModelSpec) throws -> Int {
        let header = spec.headerBytes()
        try fh.seek(toOffset: 0)
        guard let head = try fh.read(upToCount: header.count), head == header else { return 0 }
        var good = 0
        while good < spec.blocks.count {
            try Task.checkCancellation()
            let n = spec.blockLength(good)
            try fh.seek(toOffset: UInt64(header.count + good * spec.blockSize))
            var h = SHA256()
            var left = n
            while left > 0 {
                guard let d = try fh.read(upToCount: min(left, readSize)), !d.isEmpty else { return good }
                h.update(data: d)
                left -= d.count
            }
            guard hex(h.finalize()) == spec.blocks[good] else { return good }
            good += 1
        }
        return good
    }
}
