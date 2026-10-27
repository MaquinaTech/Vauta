// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// How a running model job reads everywhere (the panel's model line and the Meetings status bar): the
/// stage and a stopwatch, "Writing minutes · 1:35".
enum MinutesActivity {
    static func elapsedText(since started: Date?, now: Date) -> String {
        let seconds = started.map { max(0, Int(now.timeIntervalSince($0))) } ?? 0
        return ElapsedTime.stamp(seconds)
    }

    /// The stage the integrated model reports ("Reading the transcript · 42%"), nil when it reports none (Apple's model and servers).
    static func stageText(_ status: LLMService.Status) -> String? {
        switch status.stage {
        case .readingTranscript?:
            guard let fraction = status.prefill?.fraction else { return nil }
            return String(localized: "Reading the transcript · \(fraction.formatted(.percent.precision(.fractionLength(0))))",
                          comment: "Minutes status while the integrated model reads the transcript; the argument is a percentage")
        case .findingItems(let part, let total)?:
            return String(localized: "Finding decisions and tasks · part \(part) of \(total)", comment: "Minutes status while the integrated model looks for decisions and tasks one stretch at a time; the arguments are the stretch and how many there are")
        case .checkingAnswer?:
            return String(localized: "Checking the answer", comment: "Status while the integrated model checks an answer to a question")
        case .writingMinutes?, nil:
            return nil
        }
    }

    /// 0...1 while the integrated model reads the transcript.
    static func fraction(_ status: LLMService.Status) -> Double? { status.stage == .readingTranscript ? status.prefill?.fraction : nil }

    /// "Reading the transcript, 40 percent": VoiceOver hears it in steps of 10%.
    static func spoken(fraction: Double) -> String {
        let percent = min(100, Int((fraction * 10).rounded(.down)) * 10)
        return String(localized: "Reading the transcript, \(percent) percent", comment: "Accessibility value of the minutes progress; the argument is a percentage in steps of 10")
    }

    static func text(_ status: LLMService.Status, now: Date) -> String {
        if let stage = stageText(status) {
            guard status.queued > 0 else { return stage }
            return String(localized: "\(stage) · \(status.queued) waiting", comment: "Minutes status while the model reads or checks with more jobs queued: the stage, then how many wait")
        }
        let elapsed = elapsedText(since: status.activityStarted, now: now)
        let stage = status.activity ?? String(localized: "Working", comment: "Minutes status when the stage is unknown")
        // The jobs behind this one are still on their way: they stay visible while one runs.
        if status.queued > 0 {
            return String(localized: "\(stage) · \(elapsed) elapsed · \(status.queued) waiting",
                          comment: "Minutes status while the model writes with more jobs queued: stage, the time elapsed since it began and how many wait")
        }
        return String(localized: "\(stage) · \(elapsed) elapsed", comment: "Minutes status while the model writes: stage and the time elapsed since it began; “elapsed” says the clock is not a time left or a meeting length")
    }
}
