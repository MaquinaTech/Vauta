// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Everything that identifies the one search model Vauta installs: Google's `google/embeddinggemma-2` at a pinned revision,
/// text tower only. Sizes and hashes were derived from the verified original file (docs/SEARCH_MODEL.md) and are pinned in
/// source; nothing here is read from the network.
public enum SearchModelManifest {
    public static let repository = "google/embeddinggemma-2"
    public static let revision = "914f7f89142e33e77833254d9c9b90c3cef7303b"
    /// The folder name of an install (the first 8 characters of the revision).
    public static let revisionFolder = "914f7f89"

    // MARK: The original file

    public static let sourceFile = "model.safetensors"
    public static let sourceSize = 1_488_915_288
    public static let sourceSHA256 = "197a32965d4b1105faf060417baa899e193fb73cd401f42ec9295234d5553d79"
    /// The text tower: the 413 `language_model.*` tensors are one contiguous byte range of the original file.
    public static let spanStart = 612_180_776
    public static let spanEnd = 1_154_186_072
    public static var spanSize: Int { spanEnd - spanStart }
    public static let blockSize = 33_554_432

    // MARK: The assembled file (header + span)

    public static let assembledSize = 542_050_256
    public static let assembledSHA256 = "dad39260a376f4d7372a4d605789b673e66dec03e910dcd8279a18b89bb37858"
    public static let assembledFile = "model.safetensors"

    // MARK: The tokenizer

    public static let tokenizerFile = "tokenizer.json"
    public static let tokenizerSize = 32_170_510
    public static let tokenizerSHA256 = "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"

    /// Bytes the download transfers: the tokenizer and the span.
    public static var downloadSize: Int { tokenizerSize + spanSize }
    /// Bytes on disk once installed.
    public static var installedSize: Int { assembledSize + tokenizerSize }

    // MARK: The recipe

    /// Prompts, as in the model's `config_sentence_transformers.json` at the pinned revision.
    public static let queryPrompt = "task: search result | query: "
    public static let documentPrompt = "title: none | text: "
    /// Vauta keeps the first 256 of the 768 dimensions (Matryoshka), renormalised.
    public static let dimensions = 256
    public static let maxSequence = 512
    /// Version of the recipe: prompts, mean pooling, the Matryoshka cut, the chunking rule and the tokenizer. Any change
    /// bumps it, and the stored vectors are embedded again. Frozen format (docs/ARCHITECTURE.md).
    public static let recipe = "r1"
    public static var spaceModel: String { "embeddinggemma-2@\(revisionFolder)/\(recipe)" }

    public typealias Tensor = SearchModelSpec.Tensor

    /// The 413 tensors of the text tower, in file order.
    public static let tensors: [Tensor] = tensorTable.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "|", omittingEmptySubsequences: false)
        guard f.count == 6, let offset = Int(f[3]), let size = Int(f[4]) else { return nil }
        return Tensor(name: String(f[0]), dtype: String(f[1]), shape: f[2].split(separator: ",").compactMap { Int($0) },
                      offset: offset, size: size, sha256: String(f[5]))
    }

    /// The 17 block hashes of the span.
    public static let blocks: [String] = blockTable.split(separator: "\n").map(String.init)

    /// The deterministic safetensors header of the assembled file (see `SearchModelSpec.headerBytes`).
    public static func headerBytes() -> Data { SearchModelSpec.pinned.headerBytes() }

    /// The header's size: the tensor data starts here in the assembled file.
    public static var headerSize: Int { SearchModelSpec.pinned.headerSize }
}

/// Hex digits of a digest.
func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    bytes.map { String(format: "%02x", $0) }.joined()
}
