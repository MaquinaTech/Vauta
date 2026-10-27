// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The "Test" button in Settings → Translation: one invented sentence goes
/// through the real path and the real latency is shown.
public struct RefinementTest: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case translated(String)
        /// Nothing came back in time.
        case timedOut
        /// The server or the answer was refused; the message is already localized.
        case failed(String)
    }

    public let sample: Sample
    public let outcome: Outcome
    public let seconds: Double

    public init(sample: Sample, outcome: Outcome, seconds: Double) {
        self.sample = sample
        self.outcome = outcome
        self.seconds = seconds
    }

    /// Whether the answer would have been in time to replace a caption.
    public var withinBudget: Bool {
        if case .translated = outcome { return seconds <= Double(LiveTranslator.Tuning().refineBudget.components.seconds) }
        return false
    }

    public struct Sample: Sendable, Equatable {
        public let text: String
        public let source: Locale.Language
        public let target: Locale.Language

        public init(text: String, source: Locale.Language, target: Locale.Language) {
            self.text = text
            self.source = source
            self.target = target
        }

        /// An invented sentence in English (or Spanish for a Spanish speaker) translated into `target`;
        /// the other one of the two when `target` is the sample's own language.
        public static func make(source: Locale.Language?, target: Locale.Language?) -> Sample {
            let english = Locale.Language(identifier: "en"), spanish = Locale.Language(identifier: "es")
            let from = (source?.isSameLanguage(as: spanish) ?? false) ? spanish : english
            var to = target ?? (from == english ? spanish : english)
            if to.isSameLanguage(as: from) { to = from == english ? spanish : english }
            let text = from == english ? "Can everyone send me their estimates by Friday?" : "¿Podéis enviarme vuestras estimaciones antes del viernes?"
            return Sample(text: text, source: from, target: to)
        }
    }

    /// Runs the sample through `translator`, waiting at most `timeout`.
    public static func run(_ sample: Sample, with translator: any RefiningTranslator, timeout: Duration = .seconds(20)) async -> RefinementTest {
        let start = ContinuousClock.now
        let failure = FailureBox()
        let outcome = await LiveTranslator.race(budget: timeout) {
            do { return try await translator.refine(sample.text, context: []) } catch {
                failure.message = error.localizedDescription
                throw error
            }
        }
        let elapsed = (ContinuousClock.now - start).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        switch outcome {
        case .text(let text): return RefinementTest(sample: sample, outcome: .translated(text), seconds: seconds)
        case .cancelled: return RefinementTest(sample: sample, outcome: .failed(failure.message ?? ""), seconds: seconds)
        case .failed:
            if let message = failure.message { return RefinementTest(sample: sample, outcome: .failed(message), seconds: seconds) }
            return RefinementTest(sample: sample, outcome: .timedOut, seconds: seconds)
        }
    }

    private final class FailureBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _message: String?
        var message: String? {
            get { lock.withLock { _message } }
            set { lock.withLock { _message = newValue } }
        }
    }
}
