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
/// it also catches a Bluetooth profile change mid-meeting). `add` is called
/// from the IOProc and `reset` from the control queue.
final class RateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var windowStart: Date?

    func reset() { lock.withLock { frames = 0; windowStart = nil } }

    func add(frames count: Int) -> Double? {
        lock.withLock {
            guard let start = windowStart else { windowStart = .now; return nil }
            frames += count
            let elapsed = Date.now.timeIntervalSince(start)
            guard elapsed >= 3 else { return nil }
            defer { frames = 0; windowStart = .now }
            return Double(frames) / elapsed
        }
    }
}
