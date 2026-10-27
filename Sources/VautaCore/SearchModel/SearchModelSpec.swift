// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What an install of the search model must be: sizes, hashes and the byte layout. The shipped value is `pinned`; tests build
/// small synthetic ones, so the download, verification and import code is exercised without the real model.
public struct SearchModelSpec: Sendable, Equatable {
    public struct Tensor: Sendable, Equatable {
        public let name: String
        public let dtype: String
        public let shape: [Int]
        /// Offset inside the span (and, after the header, inside the assembled file).
        public let offset: Int
        public let size: Int
        public let sha256: String

        public init(name: String, dtype: String, shape: [Int], offset: Int, size: Int, sha256: String) {
            self.name = name
            self.dtype = dtype
            self.shape = shape
            self.offset = offset
            self.size = size
            self.sha256 = sha256
        }
    }

    public var repository: String
    public var revision: String
    public var sourceFile: String
    public var sourceSize: Int
    public var sourceSHA256: String
    public var spanStart: Int
    public var spanEnd: Int
    public var blockSize: Int
    public var blocks: [String]
    public var tensors: [Tensor]
    public var assembledSize: Int
    public var assembledSHA256: String
    public var tokenizerFile: String
    public var tokenizerSize: Int
    public var tokenizerSHA256: String

    public init(repository: String, revision: String, sourceFile: String, sourceSize: Int, sourceSHA256: String, spanStart: Int,
                spanEnd: Int, blockSize: Int, blocks: [String], tensors: [Tensor], assembledSize: Int, assembledSHA256: String,
                tokenizerFile: String, tokenizerSize: Int, tokenizerSHA256: String) {
        self.repository = repository
        self.revision = revision
        self.sourceFile = sourceFile
        self.sourceSize = sourceSize
        self.sourceSHA256 = sourceSHA256
        self.spanStart = spanStart
        self.spanEnd = spanEnd
        self.blockSize = blockSize
        self.blocks = blocks
        self.tensors = tensors
        self.assembledSize = assembledSize
        self.assembledSHA256 = assembledSHA256
        self.tokenizerFile = tokenizerFile
        self.tokenizerSize = tokenizerSize
        self.tokenizerSHA256 = tokenizerSHA256
    }

    /// EmbeddingGemma 2 at the pinned revision, text tower only.
    public static let pinned = SearchModelSpec(
        repository: SearchModelManifest.repository, revision: SearchModelManifest.revision,
        sourceFile: SearchModelManifest.sourceFile, sourceSize: SearchModelManifest.sourceSize,
        sourceSHA256: SearchModelManifest.sourceSHA256, spanStart: SearchModelManifest.spanStart,
        spanEnd: SearchModelManifest.spanEnd, blockSize: SearchModelManifest.blockSize, blocks: SearchModelManifest.blocks,
        tensors: SearchModelManifest.tensors, assembledSize: SearchModelManifest.assembledSize,
        assembledSHA256: SearchModelManifest.assembledSHA256, tokenizerFile: SearchModelManifest.tokenizerFile,
        tokenizerSize: SearchModelManifest.tokenizerSize, tokenizerSHA256: SearchModelManifest.tokenizerSHA256)

    public var spanSize: Int { spanEnd - spanStart }
    public var revisionFolder: String { String(revision.prefix(8)) }
    public var downloadSize: Int { tokenizerSize + spanSize }
    public var installedSize: Int { assembledSize + tokenizerSize }

    /// The length of block `index` of the span.
    public func blockLength(_ index: Int) -> Int { min(blockSize, spanSize - index * blockSize) }

    /// The file offset (in the original file) where block `index` starts.
    public func blockSourceOffset(_ index: Int) -> Int { spanStart + index * blockSize }

    /// Whether the table is self-consistent: the tensors tile the span exactly, the blocks cover it and the sizes add up.
    public var isConsistent: Bool {
        var cursor = 0
        for t in tensors {
            guard t.offset == cursor, t.size >= 0 else { return false }
            cursor += t.size
        }
        let blockCount = (spanSize + blockSize - 1) / blockSize
        return cursor == spanSize && blocks.count == blockCount && assembledSize == headerSize + spanSize && spanSize > 0 && blockSize > 0
    }

    /// The deterministic safetensors header of the assembled file: an 8-byte little-endian length, then the JSON with sorted
    /// keys padded with spaces to a multiple of 8. Tensor offsets are relative to the end of the header.
    public func headerBytes() -> Data {
        var items: [(String, String)] = tensors.map { t in
            (t.name, "{\"data_offsets\":[\(t.offset),\(t.offset + t.size)],\"dtype\":\"\(t.dtype)\",\"shape\":[\(t.shape.map(String.init).joined(separator: ","))]}")
        }
        items.append(("__metadata__", "{\"format\":\"pt\"}"))
        items.sort { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
        var json = Data("{".utf8)
        json.append(Data(items.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",").utf8))
        json.append(Data("}".utf8))
        while json.count % 8 != 0 { json.append(0x20) }
        var out = Data()
        var n = UInt64(json.count).littleEndian
        withUnsafeBytes(of: &n) { out.append(contentsOf: $0) }
        out.append(json)
        return out
    }

    public var headerSize: Int { headerBytes().count }

    /// The path of a file of the repository at the pinned revision.
    public func resolvePath(_ file: String) -> String { "/\(repository)/resolve/\(revision)/\(file)" }
}
