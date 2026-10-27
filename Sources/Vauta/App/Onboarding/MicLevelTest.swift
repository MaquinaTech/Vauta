// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import Observation

/// A five-second microphone check for the setup. Only the input level is
/// computed from each buffer; no audio is kept or written anywhere.
@MainActor
@Observable
final class MicLevelTest {
    /// 0…1 (−60 dBFS…0 dBFS).
    private(set) var level = 0.0
    private(set) var running = false
    /// The level went clearly above silence at least once.
    private(set) var heardSound = false
    private(set) var failure: String?
    /// The test ran to its end (or was stopped): the result is final.
    private(set) var finished = false

    /// What to do when there is no input; the text names where.
    static var noMicrophoneMessage: String {
        String(localized: "No microphone is available. Connect one or choose an input in System Settings\u{00A0}→\u{00A0}Sound.",
               comment: "Microphone test error with what to do")
    }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var timer: Task<Void, Never>?

    static let duration: Duration = .seconds(5)

    #if VAUTA_DIAGNOSTICS
    /// For `Vauta render-ui`: a test in a given state, without opening the microphone.
    func installSnapshot(level: Double, running: Bool, heardSound: Bool, failure: String? = nil, finished: Bool = false) {
        self.finished = finished
        self.level = level
        self.running = running
        self.heardSound = heardSound
        self.failure = failure
    }
    #endif

    func start() {
        guard !running else { return }
        failure = nil
        heardSound = false
        finished = false
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            failure = Self.noMicrophoneMessage
            return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.tap { [weak self] level in
            let test = self
            Task { @MainActor in test?.update(level) }
        })
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            failure = String(localized: "The microphone couldn’t start: \(error.localizedDescription)",
                             comment: "Microphone test error; argument is the system error")
            return
        }
        self.engine = engine
        running = true
        timer = Task { [weak self] in
            // A cancelled timer must not stop a test started after it.
            do { try await Task.sleep(for: Self.duration) } catch { return }
            self?.stop()
        }
    }

    func stop() {
        if running { finished = true }
        timer?.cancel()
        timer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        running = false
        level = 0
    }

    private func update(_ value: Double) {
        guard running else { return }
        level = value
        if value > 0.35 { heardSound = true }
    }

    /// Built outside the main actor: the block runs on the audio thread.
    private nonisolated static func tap(_ report: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in report(level(of: buffer)) }
    }

    /// RMS of the first channel, mapped from −60…0 dBFS to 0…1.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<count { sum += samples[i] * samples[i] }
        let rms = (sum / Float(count)).squareRoot()
        guard rms > 0 else { return 0 }
        let db = 20 * log10(Double(rms))
        return min(1, max(0, (db + 60) / 60))
    }
}
