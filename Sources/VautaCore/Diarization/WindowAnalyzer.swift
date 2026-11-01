// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Something that turns one 10 s window of audio into a `WindowRecord`: the real analyzer, or a stand-in in tests.
public protocol WindowAnalyzing: Sendable {
    func analyze(window: [Float], startSample: Int) throws -> WindowRecord
}

/// The neural half of the pipeline for ONE 10 s window: segmentation, masks, fbank, embeddings. The caller owns
/// the audio buffering (and the clock): it hands over exactly 10 s of 16 kHz mono samples (zero-padded at the end
/// of a recording) and the window's first sample index. Use from one queue at a time.
public final class WindowAnalyzer: WindowAnalyzing, @unchecked Sendable {
    private let segmenter: Segmenter
    private let embedder: SpeakerEmbedder
    private let fbank = Fbank()
    private let config: DiarizationConfig

    public init(models: DiarizationModels, config: DiarizationConfig = DiarizationConfig()) throws {
        self.segmenter = try models.makeSegmenter()
        self.embedder = try models.makeEmbedder()
        self.config = config
    }

    public func analyze(window: [Float], startSample: Int) throws -> WindowRecord {
        let classes = try segmenter.classes(window: window, noneLogBias: config.noneLogBias)
        let speakers = SegmentationGeometry.localSpeakers
        let (masks, seconds) = MaskBuilder.masks(classes: classes, excludeOverlap: config.excludeOverlap,
                                                 minSeconds: config.minEmbeddingSeconds)
        let wanted = (0..<speakers).map { Double(seconds[$0]) >= config.minEmbeddingSeconds }
        var embeddings = [[Float]?](repeating: nil, count: speakers)
        if wanted.contains(true) {
            let silent = [Float](repeating: 0, count: SegmentationGeometry.frames)
            let raw = try embedder.embed(fbank: fbank.compute(window),
                                         masks: (0..<speakers).map { wanted[$0] ? masks[$0] : silent })
            for s in 0..<speakers where wanted[s] && raw[s].allSatisfy(\.isFinite) {
                embeddings[s] = VectorMath.normalised(raw[s])
            }
        }
        return WindowRecord(startSample: startSample, classes: classes, embeddings: embeddings, usableSeconds: seconds)
    }
}
