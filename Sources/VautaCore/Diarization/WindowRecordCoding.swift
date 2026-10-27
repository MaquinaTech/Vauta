// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The bytes of a `WindowRecord` as the encrypted store keeps them until the speakers are finalized
/// (`diarization_windows`). The blob is voice data: it is only ever written inside the encrypted store and journal.
///
///     version (1) | startSample (Int64 LE) | classes (589) | usable seconds (3 x Float32 LE)
///     | embedding mask (1, bit s = local speaker s) | 256 x Float32 LE per set bit
extension WindowRecord {
    private static let codingVersion: UInt8 = 1
    private static let headerBytes = 1 + 8 + SegmentationGeometry.frames + 4 * SegmentationGeometry.localSpeakers + 1

    public func encoded() -> Data {
        let dimension = SegmentationGeometry.embeddingDimension
        var out = Data()
        out.reserveCapacity(Self.headerBytes + 4 * dimension * embeddings.count)
        out.append(Self.codingVersion)
        withUnsafeBytes(of: Int64(startSample).littleEndian) { out.append(contentsOf: $0) }
        out.append(contentsOf: classes)
        var mask: UInt8 = 0
        for s in 0..<SegmentationGeometry.localSpeakers {
            withUnsafeBytes(of: (s < usableSeconds.count ? usableSeconds[s] : 0).bitPattern.littleEndian) { out.append(contentsOf: $0) }
            if s < embeddings.count, embeddings[s] != nil { mask |= 1 << UInt8(s) }
        }
        out.append(mask)
        for s in 0..<SegmentationGeometry.localSpeakers where mask & (1 << UInt8(s)) != 0 {
            for value in embeddings[s]! { withUnsafeBytes(of: value.bitPattern.littleEndian) { out.append(contentsOf: $0) } }
        }
        return out
    }

    /// nil when the bytes are not a record of this version (damaged, or from a newer Vauta).
    public init?(decoding data: Data) {
        let geometry = SegmentationGeometry.self
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerBytes, bytes[0] == Self.codingVersion else { return nil }
        func load<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T {
            var value: T = 0
            for i in 0..<MemoryLayout<T>.size { value |= T(truncatingIfNeeded: bytes[offset + i]) << T(8 * i) }
            return value
        }
        let start = Int64(bitPattern: load(UInt64.self, at: 1))
        guard start >= 0, start <= Int64(geometry.sampleRate) * 86_400 else { return nil }
        let classes = Array(bytes[9..<(9 + geometry.frames)])
        guard classes.allSatisfy({ $0 <= 6 }) else { return nil }
        var usable: [Float] = []
        var offset = 9 + geometry.frames
        for _ in 0..<geometry.localSpeakers {
            let value = Float(bitPattern: load(UInt32.self, at: offset))
            guard value.isFinite, value >= 0 else { return nil }
            usable.append(value)
            offset += 4
        }
        let mask = bytes[offset]
        offset += 1
        guard mask < 1 << UInt8(geometry.localSpeakers) else { return nil }
        var embeddings = [[Float]?](repeating: nil, count: geometry.localSpeakers)
        for s in 0..<geometry.localSpeakers where mask & (1 << UInt8(s)) != 0 {
            guard offset + 4 * geometry.embeddingDimension <= bytes.count else { return nil }
            var vector: [Float] = []
            vector.reserveCapacity(geometry.embeddingDimension)
            for _ in 0..<geometry.embeddingDimension {
                let value = Float(bitPattern: load(UInt32.self, at: offset))
                guard value.isFinite else { return nil }
                vector.append(value)
                offset += 4
            }
            embeddings[s] = vector
        }
        guard offset == bytes.count else { return nil }
        self.init(startSample: Int(start), classes: classes, embeddings: embeddings, usableSeconds: usable)
    }
}
