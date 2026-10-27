// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreML
import Foundation
import Testing
@testable import VautaCore

/// The bundled models: located, verified before they are loaded, and numerically equal to the PyTorch references.
@Suite("Diarization models", .serialized)
struct DiarizationModelTests {
    // MARK: - Hash check

    /// A scratch copy of the models folder.
    private func copyOfModels() throws -> URL {
        let source = try #require(DiarizationModels.bundledFolder())
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    private func weights(in folder: URL, model: String) -> URL {
        folder.appendingPathComponent(model).appendingPathComponent("weights/weight.bin")
    }

    @Test func bundledModelsVerifyAndLoad() throws {
        let models = try DiarizationModels.verified()
        #expect(DiarizationModels.computeUnits == .cpuAndNeuralEngine)
        _ = try models.makeSegmenter()
        _ = try models.makeEmbedder()
        #expect(DiarizationModels.embeddingModelID == "wespeaker-resnet34-lm-837717dd-fp16-v1")
    }

    @Test func aCopyOfTheModelsVerifies() throws {
        let copy = try copyOfModels()
        defer { try? FileManager.default.removeItem(at: copy) }
        _ = try DiarizationModels.verified(in: copy)
    }

    @Test(arguments: [DiarizationModels.segmentationPin.folder, DiarizationModels.embeddingPin.folder])
    func aChangedByteRefusesToLoad(model: String) throws {
        let copy = try copyOfModels()
        defer { try? FileManager.default.removeItem(at: copy) }
        let file = weights(in: copy, model: model)
        var bytes = try Data(contentsOf: file)
        bytes[bytes.count / 2] ^= 0x01
        try bytes.write(to: file)
        #expect(throws: DiarizationModels.Failure.hashMismatch(model: model)) { try DiarizationModels.verified(in: copy) }
    }

    @Test func aChangedModelDescriptionRefusesToLoad() throws {
        let copy = try copyOfModels()
        defer { try? FileManager.default.removeItem(at: copy) }
        let model = DiarizationModels.segmentationPin.folder
        let file = copy.appendingPathComponent(model).appendingPathComponent("model.mil")
        try (try Data(contentsOf: file) + Data(" ".utf8)).write(to: file)
        #expect(throws: DiarizationModels.Failure.hashMismatch(model: model)) { try DiarizationModels.verified(in: copy) }
    }

    @Test func anExtraFileRefusesToLoad() throws {
        let copy = try copyOfModels()
        defer { try? FileManager.default.removeItem(at: copy) }
        let model = DiarizationModels.embeddingPin.folder
        try Data("x".utf8).write(to: copy.appendingPathComponent(model).appendingPathComponent("extra.bin"))
        #expect(throws: DiarizationModels.Failure.hashMismatch(model: model)) { try DiarizationModels.verified(in: copy) }
    }

    @Test func aMissingFileRefusesToLoad() throws {
        let copy = try copyOfModels()
        defer { try? FileManager.default.removeItem(at: copy) }
        let model = DiarizationModels.embeddingPin.folder
        try FileManager.default.removeItem(at: copy.appendingPathComponent(model).appendingPathComponent("analytics/coremldata.bin"))
        #expect(throws: DiarizationModels.Failure.hashMismatch(model: model)) { try DiarizationModels.verified(in: copy) }
    }

    @Test func aMissingModelIsReported() throws {
        let copy = try copyOfModels()
        defer { try? FileManager.default.removeItem(at: copy) }
        let model = DiarizationModels.segmentationPin.folder
        try FileManager.default.removeItem(at: copy.appendingPathComponent(model))
        #expect(throws: DiarizationModels.Failure.missing(model: model)) { try DiarizationModels.verified(in: copy) }
    }

    @Test func aSymbolicLinkIsRefused() throws {
        let copy = try copyOfModels()
        defer { try? FileManager.default.removeItem(at: copy) }
        let model = DiarizationModels.segmentationPin.folder
        let file = weights(in: copy, model: model)
        let elsewhere = copy.appendingPathComponent("elsewhere.bin")
        try FileManager.default.moveItem(at: file, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        #expect(throws: DiarizationModels.Failure.unsafeEntry(model: model)) { try DiarizationModels.verified(in: copy) }
    }

    @Test func aFolderWithoutModelsIsNotBundled() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: DiarizationModels.Failure.missing(model: DiarizationModels.segmentationPin.folder)) { try DiarizationModels.verified(in: empty) }
    }

    @Test func modelMetadataCarriesSourceAndLicence() throws {
        let models = try DiarizationModels.verified()
        for (url, repo) in [(models.segmentationURL, "pyannote/speaker-diarization-community-1"),
                            (models.embeddingURL, "pyannote/wespeaker-voxceleb-resnet34-LM")] {
            let model = try MLModel(contentsOf: url)
            let metadata = model.modelDescription.metadata
            let user = metadata[.creatorDefinedKey] as? [String: String] ?? [:]
            #expect(user["source_repo"] == repo)
            #expect(user["license"] == "CC-BY-4.0")
            #expect(user["source_revision"]?.count == 40)
            #expect(user["source_checkpoint_sha256"]?.count == 64)
            #expect(user["modification"] == "Converted to Core ML; no changes to weights other than FP16 conversion.")
        }
    }

    // MARK: - Parity with the PyTorch references

    @Test func segmenterAgreesWithPyAnnote() throws {
        let segmenter = try DiarizationModels.verified().makeSegmenter()
        let clip = try DiarizationFixtures.clip()
        let reference = try DiarizationFixtures.reference()
        var same = 0, total = 0
        for window in reference.windows {
            let classes = try segmenter.classes(window: DiarizationFixtures.window(clip, at: window.startSeconds))
            #expect(classes.count == SegmentationGeometry.frames)
            same += zip(classes, window.classes).filter { Int($0) == $1 }.count
            total += classes.count
        }
        let agreement = Double(same) / Double(total)
        #expect(agreement >= 0.99, "frame agreement \(agreement)")
    }

    @Test func logProbabilitiesAreNormalised() throws {
        let segmenter = try DiarizationModels.verified().makeSegmenter()
        let clip = try DiarizationFixtures.clip()
        let scores = try segmenter.logProbabilities(window: DiarizationFixtures.window(clip, at: 0))
        #expect(scores.count == SegmentationGeometry.frames * Powerset.classes)
        for t in 0..<SegmentationGeometry.frames {
            let sum = (0..<Powerset.classes).reduce(0.0) { $0 + exp(Double(scores[t * Powerset.classes + $1])) }
            #expect(abs(sum - 1) < 1e-4)
        }
    }

    @Test func embedderAgreesWithPyAnnote() throws {
        let embedder = try DiarizationModels.verified().makeEmbedder()
        let clip = try DiarizationFixtures.clip()
        let fbank = Fbank()
        var compared = 0
        for window in try DiarizationFixtures.reference().windows {
            // the references' own masks, so only the embedding network is under test
            let (masks, seconds) = MaskBuilder.masks(classes: window.classes.map { UInt8($0) }, excludeOverlap: true, minSeconds: 1)
            for s in 0..<3 { #expect(abs(Double(seconds[s]) - window.usableSeconds[s]) < 1e-3) }
            let raw = try embedder.embed(fbank: fbank.compute(DiarizationFixtures.window(clip, at: window.startSeconds)), masks: masks)
            for s in 0..<3 {
                guard let expected = window.embeddings[s] else { continue }
                let cosine = DiarizationFixtures.cosine(raw[s], expected.map(Float.init))
                #expect(cosine >= 0.999, "window \(window.startSeconds) speaker \(s): cosine \(cosine)")
                compared += 1
            }
        }
        #expect(compared >= 3)
    }

    @Test func analyzerReproducesTheReferenceWindows() throws {
        // End to end with the app's own segmentation: its few frames of disagreement with PyTorch move the masks
        // a little, so the bar is lower than for the embedding network alone.
        let analyzer = try WindowAnalyzer(models: DiarizationModels.verified())
        let clip = try DiarizationFixtures.clip()
        var cosines: [Double] = []
        for window in try DiarizationFixtures.reference().windows {
            let record = try analyzer.analyze(window: DiarizationFixtures.window(clip, at: window.startSeconds),
                                              startSample: Int(window.startSeconds * 16_000))
            for s in 0..<3 {
                // an embedding exists exactly when the reference has one, give or take a speaker near the 1 s limit
                guard let expected = window.embeddings[s], let actual = record.embeddings[s] else { continue }
                #expect(abs(VectorMath.dot(actual, actual) - 1) < 1e-4)
                cosines.append(DiarizationFixtures.cosine(actual, expected.map(Float.init)))
            }
        }
        #expect(cosines.count >= 3)
        #expect(cosines.min()! >= 0.95)
        #expect(cosines.reduce(0, +) / Double(cosines.count) >= 0.985)
    }
}
