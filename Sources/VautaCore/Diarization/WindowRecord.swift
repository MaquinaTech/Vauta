// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Everything kept about one analysed 10 s window. No audio. About 3.7 KB per window (589 class bytes and up to
/// three 256-float embeddings), so about 6.6 MB for 60 minutes at the 2 s step.
///
/// The embeddings are voice data: they stay in memory (and in the encrypted journal) until the meeting is
/// finalized and are never logged, exported, indexed or sent anywhere.
public struct WindowRecord: Sendable {
    public var startSample: Int
    /// Powerset class per output frame (589 entries, 0...6).
    public var classes: [UInt8]
    /// L2-normalised embedding per local speaker; nil when the speaker had too little speech to embed.
    public var embeddings: [[Float]?]
    /// Seconds of usable speech behind each local speaker's embedding.
    public var usableSeconds: [Float]

    public init(startSample: Int, classes: [UInt8], embeddings: [[Float]?], usableSeconds: [Float]) {
        self.startSample = startSample
        self.classes = classes
        self.embeddings = embeddings
        self.usableSeconds = usableSeconds
    }

    /// Bit mask of the local speakers that speak in a frame (bit s = local speaker s).
    func activity(frame t: Int) -> UInt8 { Powerset.speakerMask[Int(classes[t])] }
}

extension WindowRecord: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never prints the embeddings.
    public var description: String { "WindowRecord(start: \(startSample), embedded: \(embeddings.compactMap { $0 }.count))" }
    public var debugDescription: String { description }
}
