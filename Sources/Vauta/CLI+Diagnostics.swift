// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import Foundation

// Capture diagnostics: only in the VAUTA_DIAGNOSTICS build (see CLI.swift).
//
//   Vauta spike [seconds] [--all-audio] [--locale <id>] [--show-text]
//       microphone + the meeting app in the call, live (Ctrl-C to stop);
//       --all-audio: all system audio as "Others"

func spike(locale: Locale, seconds: Double, scope: SystemAudioScope, showText: Bool) async throws {
    let capture = MeetingCapture(systemAudioScope: scope)
    capture.onDiagnostic = { print("  ⓘ \($0)") }
    capture.onChannelHealth = { channel, health in
        if health != .ok { print("  ⚠︎ \(channel.rawValue): \(health)") }
    }
    let counts = SegmentCounter()
    let usage0 = ResourceUsage.now()
    let t0 = Date()
    try await capture.start(locale: locale) { s in
        guard s.isFinal else { return }
        counts.add(s.channel, characters: s.text.count)
        let channel = s.channel.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
        if showText {
            printError("[\(ElapsedTime.clock(Int(s.start)))] \(channel) \(s.text)")
        } else {
            print("[\(ElapsedTime.clock(Int(s.start)))] \(channel) · \(s.text.count) chars")
        }
    }
    print("● Recording \(Int(seconds)) s (Ctrl-C to stop earlier). Mic → \(Channel.me.rawValue), \(capture.systemAudioScope.summary) → \(Channel.others.rawValue).")

    let interrupted = SignalFlag(SIGINT)
    while Date().timeIntervalSince(t0) < seconds, !interrupted.isSet {
        try await Task.sleep(for: .seconds(1))
        if Int(Date().timeIntervalSince(t0)) % 10 == 0 {
            let lv = capture.drainLevels()
            let fmt = { (k: Channel) in lv[k].map { String(format: "%.0f dBFS", $0) } ?? "no signal" }
            print("  · levels: \(Channel.me.rawValue) \(fmt(.me)) | \(Channel.others.rawValue) \(fmt(.others))")
        }
    }
    print("■ Stopping…")
    try await capture.stop()

    let wall = Date().timeIntervalSince(t0)
    let used = ResourceUsage.now()
    let cpu = used.cpuSeconds - usage0.cpuSeconds
    for channel in Channel.allCases {
        let (n, chars) = counts.get(channel)
        print("\(channel.rawValue): \(n) segments · \(chars) characters")
    }
    print(String(format: "Duration %.0f s · CPU %.1f s (%.1f %% of one core) · peak memory %.0f MB",
                 wall, cpu, cpu / wall * 100, used.maxRSSMB))
}

/// Counts per channel (the callback arrives from several threads).
final class SegmentCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Channel: (Int, Int)] = [:]

    func add(_ channel: Channel, characters: Int) {
        lock.withLock {
            let (n, c) = counts[channel] ?? (0, 0)
            counts[channel] = (n + 1, c + characters)
        }
    }

    func get(_ channel: Channel) -> (Int, Int) { lock.withLock { counts[channel] ?? (0, 0) } }
}

struct ResourceUsage {
    let cpuSeconds: Double
    let maxRSSMB: Double

    static func now() -> ResourceUsage {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        let t = { (tv: timeval) in Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6 }
        return ResourceUsage(cpuSeconds: t(u.ru_utime) + t(u.ru_stime), maxRSSMB: Double(u.ru_maxrss) / 1_048_576)
    }
}

/// Ctrl-C stops the recording in order (the transcription is finalized).
final class SignalFlag: @unchecked Sendable {
    private let source: DispatchSourceSignal
    private let lock = NSLock()
    private var set = false
    var isSet: Bool { lock.withLock { set } }

    init(_ sig: Int32) {
        signal(sig, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: sig)
        source.setEventHandler { [unowned self] in lock.withLock { set = true } }
        source.resume()
    }
}
#endif
