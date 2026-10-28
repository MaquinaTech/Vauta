// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation

/// Captures the default microphone ("Me"). Buffers only live in memory.
/// Multi-channel inputs are mixed down to mono (channel average).
///
/// When the input changes (headphones plugged in or out, another rate),
/// AVAudioEngine stops and posts AVAudioEngineConfigurationChange: the tap is
/// reinstalled with the new format and the engine restarted. All state is
/// touched only on `queue`.
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "vauta.mic.reconfig", qos: .userInitiated)
    private var observer: NSObjectProtocol?
    private var running = false
    private var onBuffer: (@Sendable (AVAudioPCMBuffer, _ hostTime: UInt64?) -> Void)?
    private var attempts = 0
    private var retryItem: DispatchWorkItem?
    /// Once the microphone is lost, how often it is tried again while recording.
    static let lostRetrySeconds = 8.0

    /// Diagnostic messages (reconfigurations).
    var onDiagnostic: (@Sendable (String) -> Void)?
    /// Channel state (reconnecting / lost / ok).
    var onHealth: (@Sendable (ChannelHealth) -> Void)?

    var format: AVAudioFormat { queue.sync { engine.inputNode.outputFormat(forBus: 0) } }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer, _ hostTime: UInt64?) -> Void) throws {
        try queue.sync {
            let input = engine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            // installTap with 0 Hz / 0 channels raises an Objective-C exception that can't be caught.
            guard fmt.sampleRate > 0, fmt.channelCount > 0 else { throw CaptureError(.noMicrophone) }
            try Self.installTap(on: input, format: fmt, onBuffer)
            engine.prepare()
            do {
                try engine.start()
            } catch {
                input.removeTap(onBus: 0)
                throw CaptureError(.microphoneStartFailed, detail: error.localizedDescription)
            }
            self.onBuffer = onBuffer
            running = true
            attempts = 0
            observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                // No work inside the notification: reconfigure on the queue.
                guard let self else { return }
                self.queue.async {
                    self.retryItem?.cancel()
                    self.retryItem = nil
                    self.attempts = 0
                    self.reconfigure()
                }
            }
        }
    }

    func stop() {
        queue.sync {
            running = false
            retryItem?.cancel()
            retryItem = nil
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            onBuffer = nil
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    /// Installs the input tap, mixing multi-channel input down to mono.
    /// On macOS 27 it uses the variant that returns an error instead of raising
    /// an Objective-C exception (which can't be caught and would crash the app).
    private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                   _ onBuffer: @escaping @Sendable (AVAudioPCMBuffer, _ hostTime: UInt64?) -> Void) throws {
        let downmixer = Downmixer()
        let block: AVAudioNodeTapBlock = { buffer, when in
            onBuffer(downmixer.mono(buffer), when.isHostTimeValid ? when.hostTime : nil)
        }
        if #available(macOS 27.0, *) {
            // The Swift importer exposes it as `throws` with a leftover `error: ()`.
            do {
                try input.__installTap(onBus: 0, bufferSize: 4096, format: format, error: (), block: block)
            } catch {
                throw CaptureError(.microphoneStartFailed, detail: error.localizedDescription)
            }
        } else {
            // macOS 26: the classic API raises an Objective-C exception on an invalid
            // format, so reject the formats that trigger it before calling it.
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError(.microphoneStartFailed) }
            input.installTap(onBus: 0, bufferSize: 4096, format: format, block: block)
        }
    }

    private func reconfigure() {
        guard running, let onBuffer else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        engine.stop()
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { retry(CaptureError(.noMicrophone)); return }
        do {
            try Self.installTap(on: input, format: fmt, onBuffer)
        } catch {
            retry(error)
            return
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            retry(error)
            return
        }
        attempts = 0
        onDiagnostic?("microphone reconfigured: \(Int(fmt.sampleRate)) Hz, \(fmt.channelCount) channel(s)")
        onHealth?(.ok)
    }

    /// Retries with growing delays; after ~10 attempts reports the channel as
    /// lost and goes on trying every `lostRetrySeconds` while recording (a
    /// configuration change starts over at once).
    private func retry(_ error: Error) {
        attempts += 1
        if attempts == 1 { onHealth?(.reconnecting) }
        let delay: Double
        if attempts <= 10 {
            onDiagnostic?("microphone: \(error); retry \(attempts)")
            delay = min(0.5 * Double(attempts), 2)
        } else {
            if attempts == 11 {
                onDiagnostic?("microphone lost: \(error)")
                onHealth?(.lost(CaptureError(.microphoneLost, detail: error.localizedDescription)))
            }
            delay = Self.lostRetrySeconds
        }
        retryItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.retryItem = nil
            self?.reconfigure()
        }
        retryItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
