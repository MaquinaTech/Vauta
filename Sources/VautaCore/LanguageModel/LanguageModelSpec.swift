// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What an install of the integrated language model must be: the byte layout of the original file's language tower, the
/// tensors of the quantised file Vauta assembles from it, and their hashes. The shipped value is `pinned`; tests build small
/// synthetic ones, so download, quantisation, import and verification are exercised without the real model.
public struct LanguageModelSpec: Sendable, Equatable {
    public enum Action: String, Sendable { case quantize, copy, drop }

    /// A tensor of the language tower in the original file (BF16), at `offset` inside the span.
    public struct SourceTensor: Sendable, Equatable {
        public let name: String
        public let shape: [Int]
        public let offset: Int
        public let size: Int
        public let sha256: String
        public let action: Action
        public init(name: String, shape: [Int], offset: Int, size: Int, sha256: String, action: Action) {
            self.name = name
            self.shape = shape
            self.offset = offset
            self.size = size
            self.sha256 = sha256
            self.action = action
        }
        public var rows: Int { shape.count == 2 ? shape[0] : 1 }
        public var cols: Int { shape.count == 2 ? shape[1] : (shape.first ?? 1) }
        /// The module path in the quantised file (`language_model.model.…` without the `.weight` suffix) for a quantised tensor.
        public var outputStem: String { LanguageModelSpec.outputName(forSource: name).replacingOccurrences(of: ".weight", with: "", options: [.backwards, .anchored]) }
        public var outputName: String { LanguageModelSpec.outputName(forSource: name) }
    }

    /// A tensor of the assembled 4-bit file, at `offset` inside its data (after the header).
    public struct OutputTensor: Sendable, Equatable {
        public let name: String
        public let dtype: String
        public let shape: [Int]
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
    public var sourceHeaderSize: Int
    public var sourceHeaderSHA256: String
    public var spanStart: Int
    public var spanEnd: Int
    public var blockSize: Int
    public var blocks: [String]
    public var sources: [SourceTensor]
    public var outputs: [OutputTensor] { didSet { memo = Memo() } }
    /// The header and the name index of `outputs`, built once (the header is 176 KB of JSON, asked for by every quantised chunk).
    private var memo = Memo()
    public var assembledSize: Int
    public var assembledSHA256: String
    public var tokenizerFile: String
    public var tokenizerSize: Int
    public var tokenizerSHA256: String

    public init(repository: String, revision: String, sourceFile: String, sourceSize: Int, sourceSHA256: String, sourceHeaderSize: Int,
                sourceHeaderSHA256: String, spanStart: Int, spanEnd: Int, blockSize: Int, blocks: [String], sources: [SourceTensor],
                outputs: [OutputTensor], assembledSize: Int, assembledSHA256: String, tokenizerFile: String, tokenizerSize: Int,
                tokenizerSHA256: String) {
        self.repository = repository
        self.revision = revision
        self.sourceFile = sourceFile
        self.sourceSize = sourceSize
        self.sourceSHA256 = sourceSHA256
        self.sourceHeaderSize = sourceHeaderSize
        self.sourceHeaderSHA256 = sourceHeaderSHA256
        self.spanStart = spanStart
        self.spanEnd = spanEnd
        self.blockSize = blockSize
        self.blocks = blocks
        self.sources = sources
        self.outputs = outputs
        self.assembledSize = assembledSize
        self.assembledSHA256 = assembledSHA256
        self.tokenizerFile = tokenizerFile
        self.tokenizerSize = tokenizerSize
        self.tokenizerSHA256 = tokenizerSHA256
    }

    public static let sourcePrefix = "model.language_model."
    public static let outputPrefix = "language_model.model."

    /// `model.language_model.layers.0.mlp.up_proj.weight` -> `language_model.model.layers.0.mlp.up_proj.weight`.
    public static func outputName(forSource name: String) -> String {
        name.hasPrefix(sourcePrefix) ? outputPrefix + name.dropFirst(sourcePrefix.count) : name
    }

    public var spanSize: Int { spanEnd - spanStart }
    public var revisionFolder: String { String(revision.prefix(8)) }
    /// Bytes the download transfers: the tokenizer and the language tower.
    public var downloadSize: Int { tokenizerSize + spanSize }
    public var installedSize: Int { assembledSize + tokenizerSize }
    public var outputDataSize: Int { outputs.last.map { $0.offset + $0.size } ?? 0 }

    public func blockLength(_ index: Int) -> Int { min(blockSize, spanSize - index * blockSize) }
    public func blockSourceOffset(_ index: Int) -> Int { spanStart + index * blockSize }

    /// The tensors tile the span, the blocks cover it, the outputs tile the data and the sizes add up.
    public var isConsistent: Bool {
        var cursor = 0
        for t in sources {
            guard t.offset == cursor, t.size >= 0, t.size == 2 * t.shape.reduce(1, *) else { return false }
            cursor += t.size
        }
        var out = 0
        for t in outputs {
            guard t.offset == out, t.size >= 0 else { return false }
            out += t.size
        }
        let blockCount = (spanSize + blockSize - 1) / blockSize
        guard cursor == spanSize, blocks.count == blockCount, spanSize > 0, blockSize > 0 else { return false }
        return assembledSize == headerSize + out
    }

    /// The deterministic safetensors header of the assembled file: an 8-byte little-endian length, then the JSON with sorted
    /// keys (byte order) padded with spaces to a multiple of 8. `__metadata__` is `{"format":"mlx"}` as `mlx_lm` writes it.
    public func headerBytes() -> Data {
        memo.header { builtHeader() }
    }

    private func builtHeader() -> Data {
        var items: [(String, String)] = outputs.map { t in
            (t.name, "{\"data_offsets\":[\(t.offset),\(t.offset + t.size)],\"dtype\":\"\(t.dtype)\",\"shape\":[\(t.shape.map(String.init).joined(separator: ","))]}")
        }
        items.append(("__metadata__", "{\"format\":\"mlx\"}"))
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
    public func resolvePath(_ file: String) -> String { "/\(repository)/resolve/\(revision)/\(file)" }

    /// The outputs of a source tensor that is quantised: weight, scales and biases (by name).
    public func outputs(forStem stem: String) -> (weight: OutputTensor, scales: OutputTensor, biases: OutputTensor)? {
        guard let w = outputIndex[stem + ".weight"], let s = outputIndex[stem + ".scales"], let b = outputIndex[stem + ".biases"] else { return nil }
        return (outputs[w], outputs[s], outputs[b])
    }

    /// Output tensors by name.
    public var outputIndex: [String: Int] { memo.index { Dictionary(uniqueKeysWithValues: outputs.enumerated().map { ($1.name, $0) }) } }
}

/// Lazily computed values of a spec. A copy of the spec that changes its outputs gets a fresh one, so copies never share stale values.
private struct Memo: Equatable, @unchecked Sendable {
    final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var header: Data?
        var index: [String: Int]?
    }
    let storage = Storage()
    static func == (a: Memo, b: Memo) -> Bool { true }

    func header(_ make: () -> Data) -> Data {
        storage.lock.lock(); defer { storage.lock.unlock() }
        if let h = storage.header { return h }
        let h = make()
        storage.header = h
        return h
    }

    func index(_ make: () -> [String: Int]) -> [String: Int] {
        storage.lock.lock(); defer { storage.lock.unlock() }
        if let i = storage.index { return i }
        let i = make()
        storage.index = i
        return i
    }
}

extension LanguageModelSpec {
    /// What happens to a tensor of the original file: the k/v projections of the layers that share keys and values are dropped
    /// (mlx-lm's `sanitize` drops them too), bf16 matrices whose rows are a multiple of 64 long are quantised, everything else
    /// (norms, `layer_scalar`) is copied.
    public static func action(forSource name: String, shape: [Int], firstSharedLayer: Int) -> Action {
        if let r = name.range(of: ".layers."), let dot = name[r.upperBound...].firstIndex(of: "."), let layer = Int(name[r.upperBound..<dot]) {
            let rest = name[name.index(after: dot)...]
            if layer >= firstSharedLayer, rest.hasPrefix("self_attn.k_proj") || rest.hasPrefix("self_attn.v_proj") || rest.hasPrefix("self_attn.k_norm") {
                return .drop
            }
        }
        if shape.count == 2, shape[1] % AffineQuantizer.groupSize == 0, name.hasSuffix(".weight") { return .quantize }
        return .copy
    }

    /// The tensors of the assembled file for these source tensors (names, dtypes, shapes and sorted byte offsets; hashes empty).
    public static func derivedOutputs(from sources: [SourceTensor]) -> [OutputTensor] {
        var items: [(String, String, [Int])] = []
        for t in sources {
            switch t.action {
            case .drop: continue
            case .copy: items.append((t.outputName, "BF16", t.shape))
            case .quantize:
                items.append((t.outputStem + ".weight", "U32", [t.shape[0], t.shape[1] / 8]))
                items.append((t.outputStem + ".scales", "BF16", [t.shape[0], t.shape[1] / AffineQuantizer.groupSize]))
                items.append((t.outputStem + ".biases", "BF16", [t.shape[0], t.shape[1] / AffineQuantizer.groupSize]))
            }
        }
        items.sort { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }
        var offset = 0
        return items.map { name, dtype, shape in
            let size = (dtype == "U32" ? 4 : 2) * shape.reduce(1, *)
            defer { offset += size }
            return OutputTensor(name: name, dtype: dtype, shape: shape, offset: offset, size: size, sha256: "")
        }
    }

    /// The language model at the pinned revision (generated tables).
    public static let pinned: LanguageModelSpec = {
        typealias M = LanguageModelManifest
        let sources: [SourceTensor] = (LanguageModelTable.sourcePart1 + "\n" + LanguageModelTable.sourcePart2).split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
            guard f.count == 6, let offset = Int(f[2]), let size = Int(f[3]), let action = Action(rawValue: String(f[5])) else { return nil }
            return SourceTensor(name: String(f[0]), shape: f[1].split(separator: ",").compactMap { Int($0) }, offset: offset, size: size,
                                sha256: String(f[4]), action: action)
        }
        let parts = [LanguageModelTable.outputPart1, LanguageModelTable.outputPart2, LanguageModelTable.outputPart3]
        let outputs: [OutputTensor] = parts.joined(separator: "\n").split(separator: "\n").compactMap { line in
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
            guard f.count == 6, let offset = Int(f[3]), let size = Int(f[4]) else { return nil }
            return OutputTensor(name: String(f[0]), dtype: String(f[1]), shape: f[2].split(separator: ",").compactMap { Int($0) },
                                offset: offset, size: size, sha256: String(f[5]))
        }
        return LanguageModelSpec(
            repository: M.repository, revision: M.revision, sourceFile: M.sourceFile, sourceSize: M.sourceSize, sourceSHA256: M.sourceSHA256,
            sourceHeaderSize: M.sourceHeaderSize, sourceHeaderSHA256: M.sourceHeaderSHA256, spanStart: M.spanStart, spanEnd: M.spanEnd,
            blockSize: M.blockSize, blocks: LanguageModelTable.blockTable.split(separator: "\n").map(String.init), sources: sources,
            outputs: outputs, assembledSize: M.assembledSize, assembledSHA256: M.assembledSHA256, tokenizerFile: M.tokenizerFile,
            tokenizerSize: M.tokenizerSize, tokenizerSHA256: M.tokenizerSHA256)
    }()
}
