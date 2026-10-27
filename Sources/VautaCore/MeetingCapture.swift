// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation

/// The transcription language of each channel.
public struct ChannelLocales: Sendable, Equatable {
    public var me: Locale
    public var others: Locale

    public init(me: Locale, others: Locale) {
        self.me = me
        self.others = others
    }

    /// The same language on both channels.
    public init(_ both: Locale) {
        self.init(me: both, others: both)
    }

    public subscript(channel: Channel) -> Locale {
        switch channel {
        case .me: me
        case .others: others
        }
    }
}

/// Orchestrates a meeting's two channels:
///   microphone → `.me`,  meeting-app / system audio → `.others`.
/// Each channel has its own transcriber, so who speaks is known without
/// diarization. Audio is never written to disk: it only lives in memory while
/// it is converted and handed to the analyzer.
public final class MeetingCapture: @unchecked Sendable {
    private let mic = MicrophoneCapture()
    private let system: SystemAudioTap
    private var micChannel: ChannelTranscriber?
    private var systemChannel: ChannelTranscriber?
    private var micPipe: ChannelPipe?
    private var systemPipe: ChannelPipe?
    private let levels = LevelMeter()

    /// Diagnostic messages (audio formats, device changes). No content.
    public var onDiagnostic: (@Sendable (String) -> Void)?
    /// Health of each channel: reconnections, losses, lag, analyzer failures.
    /// Reports only changes of the channel's combined state.
    public var onChannelHealth: (@Sendable (Channel, ChannelHealth) -> Void)?

    public init(systemAudioScope: SystemAudioScope = .legacyDefault) {
        system = SystemAudioTap(scope: systemAudioScope)
    }

    /// The system-audio scope in use; `.auto` is resolved once capture starts.
    public var systemAudioScope: SystemAudioScope { system.activeScope }

    /// Same language on both channels.
    public func start(locale: Locale, engines: [Channel: TranscriptionEngine] = [:], diarizer: Diarizer? = nil,
                      onSegment: @escaping @Sendable (Segment) -> Void) async throws {
        try await start(locales: ChannelLocales(locale), engines: engines, diarizer: diarizer, onSegment: onSegment)
    }

    /// `engines`: engine per channel; SpeechTranscriber by default. Each
    /// channel's model must be installed for its language and engine.
    /// `diarizer` separates the speakers of the Others channel: it gets the same chunks as that channel's
    /// transcriber, which then also keeps word times for splitting segments. It never delays transcription.
    public func start(locales: ChannelLocales, engines: [Channel: TranscriptionEngine] = [:], diarizer: Diarizer? = nil,
                      onSegment: @escaping @Sendable (Segment) -> Void) async throws {
        for channel in Channel.allCases {
            try await SpeechAssets.requireInstalled(locales[channel], engine: (engines[channel] ?? .speech).kind)
        }
        SpeechLanguageUsage().noteUsed(Channel.allCases.map { locales[$0].identifier(.bcp47) })
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw CaptureError(.microphonePermissionDenied)
        }
        let diagnostic = onDiagnostic
        let health = HealthRelay(onChannelHealth)
        do {
            let micChannel = try await ChannelTranscriber(channel: .me, locale: locales.me, engine: engines[.me] ?? .speech)
            let systemChannel = try await ChannelTranscriber(channel: .others, locale: locales.others, engine: engines[.others] ?? .speech)
            self.micChannel = micChannel
            self.systemChannel = systemChannel
            systemChannel.collectWordTimes(diarizer != nil)
            for transcriber in [micChannel, systemChannel] {
                let channel = transcriber.channel
                transcriber.onDiagnostic = diagnostic
                transcriber.onHealth = { health.report($0, for: channel, from: .transcriber) }
                transcriber.onFailure = { channel, error in
                    diagnostic?("\(channel.rawValue): analyzer failed: \(error)")
                    health.report(.failed(CaptureError(.transcriptionStopped, detail: error.localizedDescription)),
                                  for: channel, from: .transcriber)
                }
                try await transcriber.start(onSegment: onSegment)
            }

            // Microphone first: with Bluetooth headsets opening it switches the
            // profile (A2DP → HFP) and the output rate, so the tap starts with the right one.
            let micPipe = ChannelPipe(channel: micChannel, levels: levels)
            self.micPipe = micPipe
            mic.onDiagnostic = diagnostic
            mic.onHealth = { health.report($0, for: .me, from: .device) }
            try mic.start { micPipe.push($0) }
            let micFormat = mic.format
            diagnostic?("microphone: \(Int(micFormat.sampleRate)) Hz, \(micFormat.channelCount) channel(s)")

            let systemPipe = ChannelPipe(channel: systemChannel, levels: levels, diarizer: diarizer)
            self.systemPipe = systemPipe
            system.onDiagnostic = diagnostic
            system.onHealth = { health.report($0, for: .others, from: .device) }
            try system.start { systemPipe.push($0) }
        } catch {
            // No analyzers or taps left open if something fails halfway.
            try? await stop()
            throw error
        }
    }

    /// Stops capture and finalizes both channels in parallel and independently:
    /// a failure in one doesn't prevent collecting the other's last results.
    public func stop() async throws {
        mic.stop()
        system.stop()
        // Whatever was left in the 100 ms accumulator.
        micPipe?.flush()
        systemPipe?.flush()
        micPipe = nil
        systemPipe = nil
        let channels = [micChannel, systemChannel].compactMap { $0 }
        micChannel = nil
        systemChannel = nil
        let errors = await withTaskGroup(of: (Channel, Error)?.self) { group in
            for channel in channels {
                group.addTask {
                    do { try await channel.finish(); return nil } catch { return (channel.channel, error) }
                }
            }
            var errors: [(Channel, Error)] = []
            for await e in group { if let e { errors.append(e) } }
            return errors
        }
        if !errors.isEmpty {
            throw CaptureError(.finishFailed, channels: errors.map(\.0).sorted { $0.rawValue < $1.rawValue },
                               detail: errors[0].1.localizedDescription)
        }
    }

    /// Mean level (dBFS) per channel since the last call; for the meters.
    public func drainLevels() -> [Channel: Double] { levels.drain() }
}

/// Merges device and transcriber health per channel (from any thread) and
/// forwards only changes of the combined state.
private final class HealthRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker = ChannelHealthTracker()
    private let forward: (@Sendable (Channel, ChannelHealth) -> Void)?

    init(_ forward: (@Sendable (Channel, ChannelHealth) -> Void)?) { self.forward = forward }

    func report(_ health: ChannelHealth, for channel: Channel, from source: ChannelHealthTracker.Source) {
        guard let combined = lock.withLock({ tracker.update(health, for: channel, from: source) }) else { return }
        forward?(channel, combined)
    }
}
