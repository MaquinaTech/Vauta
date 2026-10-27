// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreML
import CryptoKit
import Foundation

/// Only to find the bundle this code lives in.
private final class BundleAnchor {}

/// The two speaker-diarization models Vauta bundles, located, verified and loaded.
///
/// What ships (see NOTICE for the licences, tools/convert-diarization-models for how they are made):
/// - pyannote community-1 segmentation, CC-BY-4.0, converted to Core ML FP16;
/// - WeSpeaker ResNet34-LM speaker embedding, CC-BY-4.0, converted to Core ML FP16.
///
/// The models are committed COMPILED (`.mlmodelc`), so nothing is compiled on the user's Mac and the files Core ML
/// reads are the files that were pinned. (Core ML itself then compiles them for the Neural Engine into its own cache
/// in the app's Caches folder; that cache holds no meeting data and is not covered by the hash.) Before any of them is
/// loaded, a SHA-256 over EVERY file in the model folder (names and contents, see `treeHash(of:)`) is compared with the constant
/// below; a mismatch, a missing or extra file, or a symbolic link refuses to load (`Failure`). Loading happens
/// straight after the check, from the same path: the app bundle is sealed by its code signature, so this guards
/// against a damaged or tampered copy, not against an attacker who can already rewrite the bundle.
public struct DiarizationModels: Sendable {
    /// Why the models cannot be used.
    public enum Failure: Error, Equatable, CustomStringConvertible, Sendable {
        /// The model folder is not in the app or package resources.
        case notBundled
        /// A model folder is missing.
        case missing(model: String)
        /// A model contains a symbolic link or another entry that is not a plain file or folder.
        case unsafeEntry(model: String)
        /// The contents do not match the pinned SHA-256.
        case hashMismatch(model: String)
        /// Core ML could not load the (verified) model.
        case cannotLoad(model: String)
        /// A prediction returned something other than the contract.
        case badOutput(String)

        public var description: String {
            switch self {
            case .notBundled: "The speaker models are not part of this build."
            case .missing(let model): "The speaker model \(model) is missing."
            case .unsafeEntry(let model): "The speaker model \(model) contains an unexpected entry."
            case .hashMismatch(let model): "The speaker model \(model) does not match its pinned checksum."
            case .cannotLoad(let model): "The speaker model \(model) could not be loaded."
            case .badOutput(let name): "A speaker model returned an unexpected \(name)."
            }
        }
    }

    /// One pinned model.
    struct Pin: Sendable {
        /// Folder name inside the models folder.
        let folder: String
        /// SHA-256 over the whole folder (`treeHash(of:)`). Recorded by tools/convert-diarization-models.
        let treeSHA256: String
        /// Identifies the exact weights and conversion.
        let modelID: String
    }

    static let segmentationPin = Pin(
        folder: "Segmentation_community1_fp16.mlmodelc",
        treeSHA256: "8cfb3d88307e2aa4d44c43d4a63ec5bbb67a6933fc955a46a248ab6a161fbdd5",
        modelID: "pyannote-community-1-segmentation-3533c8cf-fp16-v1")
    static let embeddingPin = Pin(
        folder: "WeSpeakerResNet34LM_fp16.mlmodelc",
        treeSHA256: "a2d1fb32a9a6bb9f457e5682b9ba567e7081bf2407e0989f6aad208807d9820d",
        modelID: "wespeaker-resnet34-lm-837717dd-fp16-v1")

    /// The ID of the embedding model, stored as `voice_profiles.model_id`: a profile made by another model (or
    /// another conversion of it) is not comparable and is never matched.
    public static let embeddingModelID = embeddingPin.modelID
    public static let segmentationModelID = segmentationPin.modelID

    /// Both models run on the CPU and the Neural Engine, never the GPU (which the app keeps free for the user's
    /// models and the interface). 5 to 7 ms per window on the Neural Engine of an M-series Mac.
    public static let computeUnits: MLComputeUnits = .cpuAndNeuralEngine

    public let segmentationURL: URL
    public let embeddingURL: URL

    /// Locates the models (in `folder`, or in the app / package resources) and verifies both. Reads the 16 MB of
    /// model files once (a few milliseconds); loading them is the slow part, so verify once per run.
    public static func verified(in folder: URL? = nil) throws -> DiarizationModels {
        guard let folder = folder ?? bundledFolder() else { throw Failure.notBundled }
        let found = try [segmentationPin, embeddingPin].map { pin -> URL in
            let url = folder.appendingPathComponent(pin.folder, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw Failure.missing(model: pin.folder)
            }
            guard try treeHash(of: url, model: pin.folder) == pin.treeSHA256 else { throw Failure.hashMismatch(model: pin.folder) }
            return url
        }
        return DiarizationModels(segmentationURL: found[0], embeddingURL: found[1])
    }

    /// The models folder: the SwiftPM resource bundle in the app's `Contents/Resources` first, then the ones next to
    /// the executable or to the code's own bundle (`swift run`, tests). `Bundle.module` is NOT used: its generated
    /// accessor traps when the bundle is absent, and a copy of the app without it must degrade to "no speakers"
    /// (`Failure.notBundled`), not crash in the middle of a recording.
    static func bundledFolder() -> URL? {
        let bundleName = "Vauta_VautaCore.bundle"
        let own = Bundle(for: BundleAnchor.self).bundleURL
        let bases = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent(),
                     own, own.deletingLastPathComponent()]
        for base in bases {
            if let url = base?.appendingPathComponent(bundleName, isDirectory: true), let bundle = Bundle(url: url),
               let folder = bundle.resourceURL?.appendingPathComponent("Models", isDirectory: true),
               FileManager.default.fileExists(atPath: folder.path) { return folder }
        }
        return nil
    }

    /// Loads the segmentation network.
    public func makeSegmenter() throws -> Segmenter {
        Segmenter(model: try Self.load(segmentationURL, model: Self.segmentationPin.folder))
    }

    /// Loads the embedding network.
    public func makeEmbedder() throws -> SpeakerEmbedder {
        SpeakerEmbedder(model: try Self.load(embeddingURL, model: Self.embeddingPin.folder))
    }

    private static func load(_ url: URL, model: String) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        do {
            return try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw Failure.cannotLoad(model: model)
        }
    }

    // MARK: - Hash

    /// SHA-256 over every file of a folder: for each regular file in path order (UTF-8 byte order of the path
    /// relative to the folder, `/` separated), the text "<path>\n<SHA-256 of the file>\n". Equal to `tree_hash` in
    /// tools/convert-diarization-models/convert.py. A symbolic link or special file is refused.
    static func treeHash(of root: URL, model: String = "") throws -> String {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else {
            throw Failure.missing(model: model)
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        var files: [(path: String, url: URL)] = []
        for case let url as URL in walker {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true { throw Failure.unsafeEntry(model: model) }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw Failure.unsafeEntry(model: model) }
            let full = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard full.hasPrefix(base + "/") else { throw Failure.unsafeEntry(model: model) }
            files.append((String(full.dropFirst(base.count + 1)), url))
        }
        files.sort { Array($0.path.utf8).lexicographicallyPrecedes(Array($1.path.utf8)) }
        var tree = SHA256()
        for file in files {
            tree.update(data: Data("\(file.path)\n\(try fileHash(file.url, model: model))\n".utf8))
        }
        return hex(tree.finalize())
    }

    private static func fileHash(_ url: URL, model: String) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw Failure.missing(model: model) }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hex(hash.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
