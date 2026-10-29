// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import CoreAudio

/// Picks the tap's buffer out of the aggregate's input buffer list. With a
/// single stream (the usual case) the list is passed through untouched;
/// otherwise the chosen buffer is presented as a one-buffer list. Used only
/// from the IOProc (serial `ioQueue`).
final class TapStream: @unchecked Sendable {
    private let preferredIndex: Int?
    private let single: UnsafeMutableAudioBufferListPointer

    /// `preferredIndex`: where the aggregate reports the tap's stream (nil if unknown).
    init(preferredIndex: Int?) {
        self.preferredIndex = preferredIndex
        single = AudioBufferList.allocate(maximumBuffers: 1)
    }

    /// `AudioBufferList.allocate` uses `calloc`, so the list is released with `free`.
    deinit { free(single.unsafeMutablePointer) }

    func list(from input: UnsafePointer<AudioBufferList>, channels: AVAudioChannelCount) -> UnsafePointer<AudioBufferList>? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if buffers.count == 1 { return input }
        guard let index = Self.index(channelCounts: buffers.map(\.mNumberChannels), hasData: buffers.map { $0.mData != nil },
                                     preferred: preferredIndex, tapChannels: channels) else { return nil }
        single[0] = buffers[index]
        return UnsafePointer(single.unsafeMutablePointer)
    }

    /// Channel count of each input stream of `device`, in IOProc buffer order.
    static func inputStreamChannels(_ device: AudioObjectID) -> [UInt32] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map(\.mNumberChannels)
    }

    /// Turns off every input stream but `index` for this IOProc, so a headset
    /// microphone in the clock device is neither delivered nor mistaken for
    /// the tap. Best effort: `TapStream` still picks the right buffer if this fails.
    static func enableOnlyInputStream(_ index: Int, of count: Int, _ device: AudioObjectID, _ procID: AudioDeviceIOProcID) {
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)! + count * MemoryLayout<UInt32>.stride
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(count)
        let flags = (raw + MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!).assumingMemoryBound(to: UInt32.self)
        for i in 0..<count { flags[i] = i == index ? 1 : 0 }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIOProcStreamUsage,
                                                 mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), raw)
    }

    /// The preferred stream if it looks like the tap (same channel count, has
    /// data); else the last one that does. Taps come after the subdevices'
    /// streams in an aggregate.
    static func index(channelCounts: [UInt32], hasData: [Bool], preferred: Int?, tapChannels: UInt32) -> Int? {
        func fits(_ i: Int) -> Bool { channelCounts[i] == tapChannels && hasData[i] }
        if channelCounts.count == 1 { return hasData[0] ? 0 : nil }
        if let preferred, channelCounts.indices.contains(preferred), fits(preferred) { return preferred }
        return channelCounts.indices.last(where: fits)
    }
}

/// Measures the samples per second that reach the IOProc, in 3 s windows (so
/// it also catches a Bluetooth profile change mid-meeting). Windows are timed
/// by when each buffer was captured (host time), not by when the IOProc ran or
/// by the wall clock, so a late callback or a clock change does not look like
/// a slower rate. A window is dropped when its buffers did not arrive at an
/// even pace (a stall lost frames: one buffer came much later than the frames
/// before it account for), and a gap of more than 0.5 s between buffers (the
/// tap stopped, the Mac slept, the clock went back) starts a new one. `add` is
/// called from the IOProc; `reset` and `confirm` from the control queue.
final class RateProbe: @unchecked Sendable {
    static let window = 3.0
    static let maxGap = 0.5
    /// How much faster the quickest buffer of a window may arrive than the slowest (frames over the time to the next buffer).
    static let maxUnevenness = 1.5
    private let lock = NSLock()
    private var frames = 0
    private var windowStart: Double?
    private var last: (seconds: Double, frames: Int)?
    private var slowest = Double.infinity, fastest = 0.0
    private var suggested: (measured: Double, rate: Double)?

    func reset() { lock.withLock { begin(at: nil, frames: 0); last = nil; suggested = nil } }

    /// `hostSeconds`: when the buffer's first frame was captured. The rate of a finished window: the frames of its buffers over the
    /// time from its first buffer to the one that ends it (which starts the next window).
    func add(frames count: Int, at hostSeconds: Double) -> Double? {
        lock.withLock {
            let previous = last
            last = (hostSeconds, count)
            guard let start = windowStart, let previous, hostSeconds > previous.seconds, hostSeconds - previous.seconds <= Self.maxGap else {
                begin(at: hostSeconds, frames: count)
                return nil
            }
            let pace = Double(previous.frames) / (hostSeconds - previous.seconds)
            slowest = min(slowest, pace)
            fastest = max(fastest, pace)
            let elapsed = hostSeconds - start
            guard elapsed >= Self.window else { frames += count; return nil }
            let even = fastest <= Self.maxUnevenness * slowest
            defer { begin(at: hostSeconds, frames: count) }
            return even ? Double(frames) / elapsed : nil
        }
    }

    private func begin(at hostSeconds: Double?, frames count: Int) {
        windowStart = hostSeconds
        frames = count
        slowest = .infinity
        fastest = 0
    }

    /// The rate a window suggests (`SystemAudioTap.correctedRate` of its measure), once the next window measures the same within
    /// 1 %: whatever slipped past the pace check throws one window off, a wrong rate measures the same every time. A window that
    /// found the rate right (`corrected` nil) clears the suggestion.
    func confirm(measured: Double, corrected: Double?) -> Double? {
        lock.withLock {
            let previous = suggested
            suggested = corrected.map { (measured, $0) }
            guard let corrected, let previous, previous.rate == corrected,
                  abs(measured - previous.measured) <= 0.01 * previous.measured else { return nil }
            return corrected
        }
    }
}
