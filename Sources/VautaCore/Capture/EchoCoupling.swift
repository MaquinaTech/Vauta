// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What `EchoCoupling` measured in a recording: whether the microphone heard the Others channel.
public struct SpeakerEcho: Sendable, Equatable {
    /// Windows of 10 s in which the others spoke: the only ones that tell.
    public internal(set) var windows = 0
    /// Of those, the windows in which the microphone heard them.
    public internal(set) var heard = 0
    /// The lag the microphone heard them at, in seconds (the median of the windows heard).
    public internal(set) var delay: Double?
    /// Whether each of the last six windows was heard, the latest last.
    var recent: [Bool] = []

    public init() {}

    /// A minute of the others speaking, and the microphone (almost) never heard them: headphones.
    public var neverHeard: Bool { windows >= 6 && heard * 20 < windows }
    /// The microphone heard them in two of the last six windows: speakers now, whatever came before.
    public var heardLately: Bool { recent.filter { $0 }.count >= 2 }
}

/// Whether the microphone hears the Others channel: speakers instead of headphones. Measured from the loudness of both
/// channels only (10 ms energies, no samples kept), in windows of 10 s in which the others speak: the microphone's loudness
/// follows theirs, a little later, when it hears them. Over headphones it doesn't, and while the others speak the user is
/// mostly quiet.
///
/// The text's echo marks (`EchoDetection`) can then be left out of a meeting the microphone never heard the others in, and
/// the panel can suggest headphones for speakers it can't name (Bluetooth, USB). Safe from any thread; the windows are
/// measured by `summary()`, never on the audio threads.
final class EchoCoupling: @unchecked Sendable {
    static let frame = 0.01
    static let windowFrames = 1000
    /// How much earlier (the clocks of two devices) and later (output latency, the room, Bluetooth) the microphone may hear it.
    static let lags = -10...60
    /// Correlation of the loudness, at the best lag, for a window to count as heard.
    static let heardCorrelation = 0.5
    /// Frames above this level are the others speaking; a window needs `activeShare` of them.
    static let activeDB: Float = -50
    static let activeShare = 0.25
    /// Frames around the others' speech that are still their turn (the pauses between their words).
    static let turn = 30

    private let lock = NSLock()
    /// Energy in dBFS by frame index (`capturedAt / frame`), per channel, from the start of the next window on.
    private var energy: [Channel: [Int: Float]] = [:]
    private var next: Int?
    private var measured = SpeakerEcho()
    private var delays: [Int] = []

    /// `meanSquares`: one value per 10 ms frame, from the frame captured `capturedAt` seconds after the session's origin.
    func add(_ channel: Channel, capturedAt: Double, meanSquares: [Float]) {
        guard capturedAt.isFinite, !meanSquares.isEmpty else { return }
        let first = Int((capturedAt / Self.frame).rounded())
        lock.withLock {
            let start = next ?? first
            next = start
            for (i, ms) in meanSquares.enumerated() where first + i >= start + Self.lags.lowerBound {
                energy[channel, default: [:]][first + i] = ms > 1e-12 ? 10 * log10(ms) : -120
            }
            // Windows nobody measured, or a channel with nothing to measure against (no system audio at all): only the last
            // two windows are kept.
            if let count = energy[channel]?.count, count > 6 * Self.windowFrames {
                let keep = first + meanSquares.count - 2 * Self.windowFrames
                next = max(start, keep - Self.lags.lowerBound)
                for c in energy.keys { energy[c] = energy[c]?.filter { $0.key >= keep } }
            }
        }
    }

    /// The frames kept, of both channels.
    var storedFrames: Int { lock.withLock { energy.values.reduce(0) { $0 + $1.count } } }

    /// Measures every window both channels have reached, and returns the meeting so far.
    func summary() -> SpeakerEcho {
        lock.withLock {
            while let start = next, let me = energy[.me], let others = energy[.others],
                  let lastMe = me.keys.max(), let lastOthers = others.keys.max(),
                  lastOthers >= start + Self.windowFrames - 1, lastMe >= start + Self.windowFrames - 1 + Self.lags.upperBound {
                let x = (start..<start + Self.windowFrames).map { others[$0] }
                let y = (start + Self.lags.lowerBound..<start + Self.windowFrames + Self.lags.upperBound).map { me[$0] }
                if let window = Self.window(others: x, me: y) {
                    measured.windows += 1
                    measured.recent = (measured.recent + [window.correlation >= Self.heardCorrelation]).suffix(6)
                    if window.correlation >= Self.heardCorrelation {
                        measured.heard += 1
                        delays.append(window.lag)
                        measured.delay = Double(delays.sorted()[delays.count / 2]) * Self.frame
                    }
                }
                next = start + Self.windowFrames
                let keep = start + Self.windowFrames + Self.lags.lowerBound
                for channel in energy.keys { energy[channel] = energy[channel]?.filter { $0.key >= keep } }
            }
            return measured
        }
    }

    /// The best correlation of the window's loudness and its lag, or nil when the others hardly spoke. `others` has the
    /// window's frames; `me` the same frames from `lags.lowerBound` before to `lags.upperBound` after. Only the others' turns
    /// count (within `turn` frames of their speech): in the user's own turns the microphone is the user, loud, whatever it
    /// hears. Missing frames are left out.
    static func window(others: [Float?], me: [Float?]) -> (correlation: Double, lag: Int)? {
        let speaking = others.map { ($0 ?? -120) > activeDB }
        guard Double(speaking.filter { $0 }.count) >= activeShare * Double(others.count) else { return nil }
        var inTurn = [Bool](repeating: false, count: others.count)
        for (i, s) in speaking.enumerated() where s {
            for k in max(0, i - turn)...min(others.count - 1, i + turn) { inTurn[k] = true }
        }
        var best: (correlation: Double, lag: Int)?
        for lag in lags {
            var pairs: [(Double, Double)] = []
            pairs.reserveCapacity(others.count)
            for (i, x) in others.enumerated() where inTurn[i] {
                let j = i + lag - lags.lowerBound
                guard let x, j >= 0, j < me.count, let y = me[j] else { continue }
                pairs.append((Double(x), Double(y)))
            }
            guard let r = correlation(pairs) else { continue }
            if best.map({ r > $0.correlation }) ?? true { best = (r, lag) }
        }
        return best ?? (0, 0)
    }

    /// Pearson's correlation; nil for fewer than 100 pairs or a channel that doesn't change (a muted microphone).
    private static func correlation(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count >= 100 else { return nil }
        let n = Double(pairs.count)
        let mx = pairs.reduce(0) { $0 + $1.0 } / n, my = pairs.reduce(0) { $0 + $1.1 } / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in pairs {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
            syy += (y - my) * (y - my)
        }
        guard sxx > 1e-6, syy > 1e-6 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }
}
