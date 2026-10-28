// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Host time: the monotonic clock of `AVAudioTime.hostTime` and `AudioTimeStamp.mHostTime` (mach_absolute_time ticks),
/// in seconds. It does not advance while the Mac sleeps, like the audio itself.
enum HostTime {
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func seconds(_ ticks: UInt64) -> Double { Double(ticks) * secondsPerTick }
    static var now: Double { seconds(mach_absolute_time()) }
}

/// Time 0 of a recording's transcript: the host time of the first audio captured on either channel. Both channels and
/// the offsets of marks and notes are measured from it, on the same monotonic clock. Safe from any thread.
final class SessionOrigin: @unchecked Sendable {
    private let lock = NSLock()
    private var origin: Double?

    /// Seconds since the origin of audio captured at `hostSeconds`; the first call sets the origin. Never negative.
    func offset(ofHostSeconds hostSeconds: Double) -> Double {
        lock.withLock {
            let origin = origin ?? hostSeconds
            self.origin = origin
            return max(0, hostSeconds - origin)
        }
    }

    /// Seconds of the session at `hostSeconds`; nil before any audio was captured.
    func elapsed(atHostSeconds hostSeconds: Double) -> Double? {
        lock.withLock { origin.map { max(0, hostSeconds - $0) } }
    }
}

/// Where each chunk of one channel goes on the transcript's timeline, in frames of the analyzer's format.
///
/// Chunks follow each other (the frame counter) while they keep up with the time they were captured at. When the
/// capture time runs ahead of the counter by more than `gapTolerance` (the device was reconfigured, the system-audio
/// tap was rebuilt, a Bluetooth headset dropped out), the counter jumps to the capture time and the gap stays a gap,
/// so the channel keeps to the session's clock and to the other channel. The first chunk is placed at its capture
/// time exactly (the tap starts after the microphone). Smaller differences are jitter and are ignored, and the
/// counter never goes backwards: chunks never overlap.
struct ChannelTimeline {
    let sampleRate: Double
    var gapTolerance: Double = 0.5
    private(set) var position: Int64 = 0
    private var started = false

    init(sampleRate: Double) { self.sampleRate = sampleRate }

    /// The first frame of a chunk of `frames` frames captured `offset` seconds after the session origin (nil: unknown,
    /// the chunk follows the previous one).
    mutating func place(frames: Int64, capturedAt offset: Double?) -> Int64 {
        if let offset, offset.isFinite {
            let target = Int64((max(0, offset) * sampleRate).rounded())
            if !started {
                position = target
            } else if Double(target - position) > gapTolerance * sampleRate {
                position = target
            }
        }
        started = true
        defer { position += frames }
        return position
    }
}
