// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AVFoundation
import CoreMedia
import Speech

/// Transcribes an audio file as a single channel, for tests without a
/// microphone or permissions (e.g. with speech recorded by `say`). A non-empty
/// `vocabulary` uses the dictation engine with that vocabulary.
public func transcribeFile(_ url: URL, locale: Locale, vocabulary: [String] = []) async throws -> [Segment] {
    try await transcribeFileScored(url, locale: locale, vocabulary: vocabulary, confidence: false).segments
}

/// `transcribeFile`, with the words of the final results. With `confidence` the recognizer is also asked for each word's
/// confidence, which the app never asks for: the evaluation measures what that costs and how well it is calibrated
/// (`eval/scripts/run_wer.py --confidence`) before anything uses it.
public func transcribeFileScored(_ url: URL, locale: Locale, vocabulary: [String] = [], confidence: Bool) async throws -> (segments: [Segment], words: [RecognizedWord]) {
    let engine: SpeechEngineKind = vocabulary.isEmpty ? .speech : .dictation
    try await SpeechAssets.requireInstalled(locale, engine: engine)
    let module = SpeechAssets.module(locale, engine, confidence: confidence)
    let analyzer = SpeechAnalyzer(modules: [module])
    if !vocabulary.isEmpty {
        let context = AnalysisContext()
        context.contextualStrings[.general] = Array(vocabulary.prefix(TranscriptionEngine.maxVocabulary))
        try await analyzer.setContext(context)
    }
    let collector = Task {
        var out: [Segment] = []
        var words: [RecognizedWord] = []
        func add(_ text: AttributedString, _ range: CMTimeRange, _ isFinal: Bool) {
            // A file has a single channel: tagged `.others` (only `isFinal` and text are used).
            out.append(Segment(channel: .others, start: range.start.seconds, end: range.end.seconds,
                               text: String(text.characters), isFinal: isFinal))
            if isFinal { words += SpeechWordTimes.words(in: text) }
        }
        if let speech = module as? SpeechTranscriber {
            for try await r in speech.results { add(r.text, r.range, r.isFinal) }
        } else if let dictation = module as? DictationTranscriber {
            for try await r in dictation.results { add(r.text, r.range, r.isFinal) }
        }
        return (out, words)
    }
    let file = try AVAudioFile(forReading: url)
    if let end = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: end)
    } else {
        await analyzer.cancelAndFinishNow()
    }
    return try await collector.value
}
