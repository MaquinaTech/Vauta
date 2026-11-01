// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Translates a finished meeting's transcript into one language (Meetings → Transcript → Translate). The lines keep their words:
/// each translation is stored beside its line with the text it was made from, so a line corrected later shows none until it is
/// translated again (`MeetingStore.translationLines`).
///
/// - With the model server (the person improves translations with it, Settings → Translation), each line is translated with
///   the lines before it and their translations as context (`ServerTranslator`, as Live Translation does). A line the server
///   can't translate takes Apple's; when the server stops answering, Apple's translation does the rest.
/// - Otherwise Apple's translation on this Mac does every line, in batches.
///
/// Which lines are translated is the `Scope`. Nothing is sent or translated while a meeting is being recorded: the live
/// captions, notes and answers keep the Mac and the server, and the work goes on when the recording ends.
public struct TranscriptTranslator: Sendable {
    /// Which lines a translation covers. Each covers the ones before it.
    public enum Scope: Int, Sendable, Comparable {
        /// The lines whose translation is of an earlier text (corrected since): a correction translates its line again, and a
        /// line that never had one stays without.
        case changed
        /// Every line without a translation of what it reads (Translate Into).
        case missing
        /// Every line again (Translate Again).
        case all

        public static func < (a: Scope, b: Scope) -> Bool { a.rawValue < b.rawValue }
    }

    public struct Progress: Sendable, Equatable {
        /// Lines done (translated, or left without one), of `total`.
        public var done: Int
        public var total: Int
        /// The work waits for the meeting being recorded to end.
        public var waitingForRecording: Bool

        public init(done: Int, total: Int, waitingForRecording: Bool = false) {
            self.done = done
            self.total = total
            self.waitingForRecording = waitingForRecording
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// Lines translated and stored.
        public var translated = 0
        /// Lines left without a translation: nothing usable came back for them.
        public var missing = 0
        /// What the model server answered when it stopped (Apple's translation then did the rest, when it could).
        public var serverFailure: String?

        public init(translated: Int = 0, missing: Int = 0, serverFailure: String? = nil) {
            self.translated = translated
            self.missing = missing
            self.serverFailure = serverFailure
        }
    }

    /// Apple's translator for the pair, when its languages are on this Mac.
    let onDevice: (any Translator)?
    /// The model server, when the person improves translations with it.
    let server: (any RefiningTranslator)?
    /// How often the work looks again whether the recording ended.
    let recordingPoll: Duration

    /// Lines per request to Apple's translation.
    static let batchSize = 24

    public init(onDevice: (any Translator)?, server: (any RefiningTranslator)?, recordingPoll: Duration = .seconds(1)) {
        self.onDevice = onDevice
        self.server = server
        self.recordingPoll = recordingPoll
    }

    /// Translates the lines of `meetingID` in `scope` into `language` and stores each as it comes. `progress` is called before the first
    /// line and after every line or batch. Cancelling stops at once; what was stored stays.
    public func translate(_ meetingID: Int64, into language: Locale.Language, store: MeetingStore, scope: Scope = .missing,
                          progress: @Sendable (Progress) async -> Void = { _ in }) async throws -> Outcome {
        let code = language.storageCode
        try await waitWhileRecording(store) { await progress(Progress(done: 0, total: 0, waitingForRecording: true)) }
        var lines = try await store.translationLines(of: meetingID, language: code)
        var rest = lines.indices.filter { index in
            switch scope {
            case .changed: lines[index].stale
            case .missing: lines[index].translation == nil
            case .all: true
            }
        }[...]
        let total = rest.count
        var outcome = Outcome()
        await progress(Progress(done: 0, total: total))
        // Said while it waits, and the count again once the recording ended.
        func pause() async throws {
            try await waitWhileRecording(store) { await progress(Progress(done: total - rest.count, total: total, waitingForRecording: true)) }
        }

        func keep(_ results: [(index: Int, text: String)]) async throws {
            let items = results.map { MeetingStore.LineTranslation(segmentID: lines[$0.index].segmentID, source: lines[$0.index].text, text: $0.text) }
            let stored = try await store.saveLineTranslations(items, language: code, inMeeting: meetingID)
            // Nothing stored because the meeting is gone (deleted, purged, erased): nothing is left to translate.
            if stored == 0, try await store.meeting(meetingID) == nil { throw CancellationError() }
            outcome.translated += stored
            for result in results { lines[result.index].translation = result.text }
        }

        if let server {
            while let index = rest.first {
                try await pause()
                let line = lines[index]
                var text: String
                do {
                    text = try await server.refine(line.text, context: Self.context(before: index, in: lines))
                } catch is RefinementError {
                    // Nothing usable for this line: Apple's translation, when it can.
                    text = (try? await onDevice?.translate(line.text)) ?? ""
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                    outcome.serverFailure = error.localizedDescription
                    break
                }
                try Task.checkCancellation()
                text = Self.cleaned(text, line: line.text)
                rest.removeFirst()
                if text.isEmpty { outcome.missing += 1 } else { try await keep([(index, text)]) }
                await progress(Progress(done: total - rest.count, total: total))
            }
        }

        // Apple's translation: every line without the server, and what the server left when it stopped answering.
        if let onDevice {
            while !rest.isEmpty {
                try await pause()
                let batch = Array(rest.prefix(Self.batchSize))
                let outputs = try await Self.translate(batch.map { lines[$0].text }, with: onDevice)
                var results: [(index: Int, text: String)] = []
                for (index, output) in zip(batch, outputs) {
                    let text = Self.cleaned(output, line: lines[index].text)
                    if text.isEmpty { outcome.missing += 1 } else { results.append((index, text)) }
                }
                outcome.missing += max(0, batch.count - outputs.count)
                rest.removeFirst(batch.count)
                if !results.isEmpty { try await keep(results) }
                await progress(Progress(done: total - rest.count, total: total))
            }
        }
        outcome.missing += rest.count
        return outcome
    }

    /// A batch through Apple's translation. One text can fail a whole batch: then each line goes alone, and a line that still
    /// fails is left without a translation (the batch's error stands when every line fails, as when the languages were removed).
    static func translate(_ texts: [String], with translator: any Translator) async throws -> [String] {
        do {
            let outputs = try await translator.translate(batch: texts)
            try Task.checkCancellation()
            return outputs
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            var outputs: [String] = []
            for text in texts {
                try Task.checkCancellation()
                outputs.append((try? await translator.translate(text)) ?? "")
            }
            guard outputs.contains(where: { !$0.isEmpty }) || texts.count < 2 else { throw error }
            return outputs
        }
    }

    /// The lines before `index` that have a translation, nearest last, as the context the server reads (as many as Live
    /// Translation sends).
    static func context(before index: Int, in lines: [MeetingStore.TranslationLine]) -> [TranslationExample] {
        var examples: [TranslationExample] = []
        var i = index - 1
        while i >= 0, examples.count < ServerTranslator.contextSentences {
            if let translation = lines[i].translation { examples.insert(TranslationExample(source: lines[i].text, translation: translation), at: 0) }
            i -= 1
        }
        return examples
    }

    /// A translation as stored: trimmed, and the line's own text when it reads the same but for case and spaces (a line already
    /// in the language), so it counts as translated and the transcript shows nothing under it.
    static func cleaned(_ output: String, line: String) -> String {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let same = text.compare(line.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive]) == .orderedSame
        return same && !text.isEmpty ? line : text
    }

    /// Returns once no meeting is being recorded; `waiting` is called once when it has to wait, and `progress` again after.
    private func waitWhileRecording(_ store: MeetingStore, waiting: () async -> Void) async throws {
        try Task.checkCancellation()
        guard await store.activeMeetingID != nil else { return }
        await waiting()
        while await store.activeMeetingID != nil { try await Task.sleep(for: recordingPoll) }
    }
}
