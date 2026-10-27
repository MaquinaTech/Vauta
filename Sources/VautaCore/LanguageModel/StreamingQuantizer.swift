// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Synchronization

/// Turns the verified bytes of the original file's language tower into the assembled 4-bit file, tensor by tensor, as they
/// arrive: the bf16 matrices are quantised (`AffineQuantizer`, row chunks of at most 16 MiB), norms and scalars are copied,
/// and the k/v projections of the layers that share keys and values are dropped. Each output goes to its pinned offset of the
/// preallocated file, so the order of the sorted output does not matter, and each output tensor is checked against its pinned
/// hash as soon as it is complete.
///
/// Feed bytes strictly in order, only after the block they belong to was verified. Not thread-safe: one owner.
public final class StreamingQuantizer {
    public static let defaultChunkBytes = 16 << 20
    public let chunkBytes: Int

    /// Where a resumed run must restart: the span offset of the first byte of the chunk that was not written yet.
    public struct Journal: Codable, Sendable, Equatable { public var resumeOffset: Int }

    private let spec: LanguageModelSpec
    private let fd: Int32
    private let base: Int
    private let outputIndex: [String: Int]
    private var tensorIndex = 0
    private var rowsDone = 0
    private var buffer: UnsafeMutableRawPointer
    private var filled = 0
    /// Span offset consumed so far.
    public private(set) var position = 0
    private let stopRequested = Mutex(false)

    /// Asks a running or later `feed` to stop at its next chunk with a `CancellationError` (callable from any thread). What it
    /// already wrote is covered by the journal, which only moves forward between blocks.
    public func cancel() { stopRequested.withLock { $0 = true } }

    /// Opens (or creates) the preallocated output file. `fresh` truncates it and writes the header.
    public init(spec: LanguageModelSpec, output: URL, fresh: Bool, chunkBytes: Int = StreamingQuantizer.defaultChunkBytes) throws {
        self.spec = spec
        self.chunkBytes = chunkBytes
        let header = spec.headerBytes()
        base = header.count
        outputIndex = spec.outputIndex
        let flags = O_RDWR | O_CREAT | (fresh ? O_TRUNC : 0)
        fd = open(output.path, flags, 0o600)
        guard fd >= 0 else { throw IntegratedModelError.ioError }
        // Room for the biggest piece that is processed at once: a chunk, one row, or a whole 1-D tensor.
        let largestPiece = spec.sources.map { $0.shape.count == 2 ? $0.shape[1] * 2 : $0.size }.max() ?? 0
        buffer = UnsafeMutableRawPointer.allocate(byteCount: max(chunkBytes, largestPiece, 16), alignment: 16)
        if fresh {
            guard ftruncate(fd, off_t(spec.assembledSize)) == 0 else { close(fd); buffer.deallocate(); throw Self.ioError(errno) }
            let ok = header.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) == $0.count }
            guard ok else { close(fd); buffer.deallocate(); throw Self.ioError(errno) }
        }
    }

    deinit {
        close(fd)
        buffer.deallocate()
    }

    static func ioError(_ code: Int32) -> IntegratedModelError {
        code == ENOSPC ? .diskFull(needed: 0) : .ioError
    }

    /// Rows per chunk of a tensor of this shape: at most `chunkBytes`, at least one row.
    public func chunkRows(shape: [Int]) -> Int {
        guard shape.count == 2 else { return 1 }
        return max(1, min(shape[0], chunkBytes / (shape[1] * 2)))
    }

    /// Restarts at a journal position (bytes before `resumeOffset + skip` are not fed again by the caller; the caller feeds
    /// from `resumeOffset`, which is a chunk start). The output tensors that were completed before that position are read back
    /// and compared with their pinned hashes (about 4 s for the 4.2 GB file): a torn write or a flipped bit in the partial file
    /// moves the restart back to the first damaged tensor, so only its source bytes are fetched again, not the whole 15 GB.
    /// A tensor that was in progress is checked when it completes. Returns where the caller must feed from.
    @discardableResult
    public func resume(from journal: Journal) -> Journal {
        position = journal.resumeOffset
        filled = 0
        var cursor = 0
        tensorIndex = 0
        rowsDone = 0
        for (i, t) in spec.sources.enumerated() {
            if journal.resumeOffset < cursor + t.size || i == spec.sources.count - 1 {
                tensorIndex = i
                let rowBytes = t.shape.count == 2 ? t.shape[1] * 2 : t.size
                rowsDone = t.shape.count == 2 ? (journal.resumeOffset - cursor) / rowBytes : 0
                break
            }
            cursor += t.size
        }
        if journal.resumeOffset >= spec.spanSize { tensorIndex = spec.sources.count }
        for i in 0..<min(tensorIndex, spec.sources.count) where !outputsMatch(spec.sources[i]) {
            tensorIndex = i
            rowsDone = 0
            position = spec.sources[i].offset
            return Journal(resumeOffset: spec.sources[i].offset)
        }
        return journal
    }

    /// Whether every output of a completed source tensor is on disk with its pinned hash.
    private func outputsMatch(_ t: LanguageModelSpec.SourceTensor) -> Bool {
        let names: [String]
        switch t.action {
        case .drop: return true
        case .copy: names = [t.outputName]
        case .quantize: names = [t.outputStem + ".weight", t.outputStem + ".scales", t.outputStem + ".biases"]
        }
        for n in names {
            guard let i = outputIndex[n] else { return false }
            let o = spec.outputs[i]
            guard let h = try? hashRange(base + o.offset, o.size), h == o.sha256 else { return false }
        }
        return true
    }

    /// The journal for the current state: where to restart if the process stops now.
    public var journal: Journal {
        guard tensorIndex < spec.sources.count else { return Journal(resumeOffset: spec.spanSize) }
        let t = spec.sources[tensorIndex]
        let rowBytes = t.shape.count == 2 ? t.shape[1] * 2 : t.size
        return Journal(resumeOffset: t.offset + (t.shape.count == 2 ? rowsDone * rowBytes : 0))
    }

    public var isComplete: Bool { tensorIndex >= spec.sources.count && filled == 0 }

    /// Consumes the next bytes of the span.
    public func feed(_ data: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < data.count {
            guard tensorIndex < spec.sources.count else { throw IntegratedModelError.unexpectedResponse }
            if stopRequested.withLock({ $0 }) { throw CancellationError() }
            let t = spec.sources[tensorIndex]
            let rowBytes = t.shape.count == 2 ? t.shape[1] * 2 : t.size
            let rowsInChunk = min(chunkRows(shape: t.shape), t.rows - rowsDone)
            let chunkLen = t.shape.count == 2 ? rowsInChunk * rowBytes : t.size
            let take = min(data.count - offset, chunkLen - filled)
            memcpy(buffer + filled, data.baseAddress! + offset, take)
            filled += take
            offset += take
            position += take
            if filled == chunkLen {
                try process(t, rows: rowsInChunk, bytes: chunkLen)
                filled = 0
                rowsDone += rowsInChunk
                if rowsDone >= t.rows || t.shape.count != 2 {
                    try finishTensor(t)
                    tensorIndex += 1
                    rowsDone = 0
                }
            }
        }
    }

    private func process(_ t: LanguageModelSpec.SourceTensor, rows: Int, bytes: Int) throws {
        switch t.action {
        case .drop: return
        case .copy:
            guard let i = outputIndex[t.outputName] else { throw IntegratedModelError.mismatch }
            let o = spec.outputs[i]
            let rowBytes = t.shape.count == 2 ? t.shape[1] * 2 : 0
            try write(buffer, bytes, at: base + o.offset + rowsDone * rowBytes)
        case .quantize:
            guard let o = spec.outputs(forStem: t.outputStem) else { throw IntegratedModelError.mismatch }
            let cols = t.cols
            let words = rows * cols / 8, groups = rows * cols / AffineQuantizer.groupSize
            let w = UnsafeMutablePointer<UInt32>.allocate(capacity: words)
            let s = UnsafeMutablePointer<UInt16>.allocate(capacity: groups)
            let b = UnsafeMutablePointer<UInt16>.allocate(capacity: groups)
            defer { w.deallocate(); s.deallocate(); b.deallocate() }
            do {
                try AffineQuantizer.quantize(rows: rows, cols: cols, source: buffer.assumingMemoryBound(to: UInt16.self), weights: w, scales: s, biases: b)
            } catch AffineQuantizerError.nonFinite {
                throw IntegratedModelError.nonFiniteWeights
            }
            try write(w, words * 4, at: base + o.weight.offset + rowsDone * (cols / 8) * 4)
            try write(s, groups * 2, at: base + o.scales.offset + rowsDone * (cols / 64) * 2)
            try write(b, groups * 2, at: base + o.biases.offset + rowsDone * (cols / 64) * 2)
        }
    }

    private func write(_ p: UnsafeRawPointer, _ n: Int, at offset: Int) throws {
        var done = 0
        while done < n {
            let w = pwrite(fd, p + done, n - done, off_t(offset + done))
            guard w > 0 else { throw Self.ioError(errno) }
            done += w
        }
    }

    /// A tensor is complete: its outputs are read back and compared with the pinned hashes.
    private func finishTensor(_ t: LanguageModelSpec.SourceTensor) throws {
        let names: [String]
        switch t.action {
        case .drop: return
        case .copy: names = [t.outputName]
        case .quantize: names = [t.outputStem + ".weight", t.outputStem + ".scales", t.outputStem + ".biases"]
        }
        for n in names {
            guard let i = outputIndex[n] else { throw IntegratedModelError.mismatch }
            let o = spec.outputs[i]
            guard try hashRange(base + o.offset, o.size) == o.sha256 else { throw IntegratedModelError.mismatch }
        }
    }

    private func hashRange(_ offset: Int, _ length: Int) throws -> String {
        var h = SHA256()
        let step = 8 << 20
        let tmp = UnsafeMutableRawPointer.allocate(byteCount: min(step, max(length, 1)), alignment: 16)
        defer { tmp.deallocate() }
        var done = 0
        while done < length {
            let n = min(step, length - done)
            let r = pread(fd, tmp, n, off_t(offset + done))
            guard r == n else { throw IntegratedModelError.ioError }
            h.update(bufferPointer: UnsafeRawBufferPointer(start: tmp, count: n))
            done += n
        }
        return hex(h.finalize())
    }

    /// All span bytes were fed: flush to disk and check the whole assembled file against its pinned hash.
    public func finish() throws {
        guard isComplete else { throw IntegratedModelError.mismatch }
        guard fsync(fd) == 0 else { throw Self.ioError(errno) }
        guard try hashRange(0, spec.assembledSize) == spec.assembledSHA256 else { throw IntegratedModelError.mismatch }
    }
}
