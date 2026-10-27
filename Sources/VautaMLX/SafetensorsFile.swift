// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import MLX

public enum SafetensorsError: Error, Equatable, Sendable {
    case unreadable
    case tooSmall
    case headerTooLarge
    case headerOutOfRange
    case badHeader
    case badEntry(String)
    case offsetsOutOfRange(String)
    case unsupportedDType(String)
    case missingTensor(String)
    case shapeMismatch(String)
    case tokenOutOfRange(Int32)
    case emptySequence
}

/// A memory-mapped safetensors file. The header is parsed with the byte-exact, bounds-checked JSON parser and every entry
/// is validated against the file size before it is used. Tensors are copied into MLX arrays on demand; the 268 MB
/// embedding table is never copied: rows are gathered straight from the mapping.
public final class SafetensorsFile {
    public struct Entry: Sendable, Equatable {
        public let dtype: String
        public let shape: [Int]
        public let start: Int
        public let end: Int
    }

    /// A header larger than this is not a safetensors header of this model (the real one is 44,960 bytes).
    public static let maxHeaderBytes = 8 << 20

    private let data: Data
    private let fd: Int32
    public private(set) var entries: [String: Entry] = [:]

    deinit { close(fd) }

    public init(url: URL) throws {
        do { data = try Data(contentsOf: url, options: .alwaysMapped) } catch { throw SafetensorsError.unreadable }
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw SafetensorsError.unreadable }
        do { entries = try Self.parseHeader(data) } catch { close(fd); throw error }
    }

    /// Parses and validates a header (exposed for tests and fuzzing).
    public static func parseHeader(_ data: Data) throws -> [String: Entry] {
        guard data.count > 8 else { throw SafetensorsError.tooSmall }
        let n64 = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        guard n64 <= UInt64(maxHeaderBytes) else { throw SafetensorsError.headerTooLarge }
        let n = Int(n64)
        let base = 8 + n
        guard base <= data.count else { throw SafetensorsError.headerOutOfRange }
        let header: JV
        do {
            header = try data.withUnsafeBytes { raw in
                try ByteJSON.parse(UnsafeBufferPointer(rebasing: raw.bindMemory(to: UInt8.self)[8..<base]))
            }
        } catch { throw SafetensorsError.badHeader }
        guard case .obj(let o) = header else { throw SafetensorsError.badHeader }
        var out: [String: Entry] = [:]
        for (k, v) in o {
            let name = String(decoding: k, as: UTF8.self)
            if name == "__metadata__" { continue }
            guard let dtype = v.get("dtype")?.string, let shape = v.get("shape")?.array, let off = v.get("data_offsets")?.array,
                  off.count == 2, let a = off[0].int, let b = off[1].int, a >= 0, b >= a,
                  shape.count <= 8, shape.allSatisfy({ ($0.int ?? -1) >= 0 })
            else { throw SafetensorsError.badEntry(name) }
            let (end, overflow) = base.addingReportingOverflow(b)
            guard !overflow, end <= data.count else { throw SafetensorsError.offsetsOutOfRange(name) }
            guard out[name] == nil else { throw SafetensorsError.badEntry(name) }
            out[name] = Entry(dtype: dtype, shape: shape.map { $0.int! }, start: base + a, end: end)
        }
        return out
    }

    static func dtype(_ s: String) -> (DType, Int)? {
        switch s {
        case "BF16": (.bfloat16, 2)
        case "F16": (.float16, 2)
        case "F32": (.float32, 4)
        case "U32": (.uint32, 4)
        default: nil
        }
    }

    static func byteCount(shape: [Int], elementSize: Int) -> Int? {
        var total = elementSize
        for d in shape {
            let (m, o) = total.multipliedReportingOverflow(by: d)
            if o { return nil }
            total = m
        }
        return total
    }

    /// The tensor as an MLX array, read with `pread` into a private buffer (the file does not stay resident).
    public func array(_ name: String) throws -> MLXArray {
        guard let e = entries[name] else { throw SafetensorsError.missingTensor(name) }
        guard let (dt, size) = Self.dtype(e.dtype) else { throw SafetensorsError.unsupportedDType(e.dtype) }
        guard Self.byteCount(shape: e.shape, elementSize: size) == e.end - e.start else { throw SafetensorsError.shapeMismatch(name) }
        var buf = Data(count: e.end - e.start)
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(e.start)) }
        guard n == e.end - e.start else { throw SafetensorsError.unreadable }
        return MLXArray(buf, e.shape, dtype: dt)
    }

    /// Rows of a [rows, cols] BF16 tensor, gathered from the mapping without materialising the tensor.
    public func gatherRowsBF16(_ name: String, ids: [Int32]) throws -> MLXArray {
        guard let e = entries[name] else { throw SafetensorsError.missingTensor(name) }
        guard e.dtype == "BF16", e.shape.count == 2 else { throw SafetensorsError.shapeMismatch(name) }
        // A crafted header can hold huge dimensions: the products are checked, never trapped on.
        let rows = e.shape[0], cols = e.shape[1]
        let (rowBytes, o1) = cols.multipliedReportingOverflow(by: 2)
        let (total, o2) = rows.multipliedReportingOverflow(by: rowBytes)
        guard !o1, !o2, e.end - e.start == total else { throw SafetensorsError.shapeMismatch(name) }
        for id in ids where id < 0 || Int(id) >= rows { throw SafetensorsError.tokenOutOfRange(id) }
        var out = Data(count: ids.count * rowBytes)
        out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                for (i, id) in ids.enumerated() {
                    memcpy(dst.baseAddress! + i * rowBytes, src.baseAddress! + e.start + Int(id) * rowBytes, rowBytes)
                }
            }
        }
        return MLXArray(out, [ids.count, cols], dtype: .bfloat16)
    }

    /// Rows of a [rows, cols] tensor (BF16 or U32), gathered from the mapping without materialising the tensor. Used for the
    /// language model's 1.6 GB per-layer embedding table, of which only the pages of the tokens in a prompt are ever read.
    public func gatherRows(_ name: String, ids: [Int32]) throws -> MLXArray {
        guard let e = entries[name] else { throw SafetensorsError.missingTensor(name) }
        guard let (dt, size) = Self.dtype(e.dtype), e.shape.count == 2 else { throw SafetensorsError.shapeMismatch(name) }
        let rows = e.shape[0], cols = e.shape[1]
        let (rowBytes, o1) = cols.multipliedReportingOverflow(by: size)
        let (total, o2) = rows.multipliedReportingOverflow(by: rowBytes)
        guard !o1, !o2, e.end - e.start == total else { throw SafetensorsError.shapeMismatch(name) }
        for id in ids where id < 0 || Int(id) >= rows { throw SafetensorsError.tokenOutOfRange(id) }
        var out = Data(count: ids.count * rowBytes)
        out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                for (i, id) in ids.enumerated() {
                    memcpy(dst.baseAddress! + i * rowBytes, src.baseAddress! + e.start + Int(id) * rowBytes, rowBytes)
                }
            }
        }
        return MLXArray(out, [ids.count, cols], dtype: dt)
    }
}
