// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class TranslationKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// Where a stub translation waits until the test opens it.
private final class Hold: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let waiting = lock.withLock { isOpen = true; defer { waiters = [] }; return waiters }
        waiting.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(c)
                return false
            }
            if now { c.resume() }
        }
    }
}

/// Apple's translation as a stub: "en:text", after the hold of its language if there is one.
private final class TaggingTranslator: Translator, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    let tag: String
    let hold: Hold?
    var calls: [String] { lock.withLock { _calls } }

    init(tag: String, hold: Hold?) {
        self.tag = tag
        self.hold = hold
    }

    func translate(_ text: String) async throws -> String {
        lock.withLock { _calls.append(text) }
        if let hold { await hold.wait() }
        return "\(tag):\(text)"
    }
}

private final class StubTranscriptBackend: TranscriptTranslationBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _made: [TaggingTranslator] = []
    /// By target language; the rest are installed.
    var statuses: [String: PairAvailability] = [:]
    var holds: [String: Hold] = [:]
    var made: [TaggingTranslator] { lock.withLock { _made } }

    func availability(from source: Locale.Language, to target: Locale.Language) async -> PairAvailability {
        source.isSameLanguage(as: target) ? .unsupported : statuses[target.storageCode] ?? .installed
    }

    func makeTranslator(from source: Locale.Language, to target: Locale.Language) async throws -> any Translator {
        try await makeTranscriptTranslator(from: source, to: target)
    }

    func supportedLanguages() async -> [Locale.Language] { ["de", "en", "es", "fr"].map { Locale.Language(identifier: $0) } }

    func makeTranscriptTranslator(from source: Locale.Language, to target: Locale.Language) async throws -> any Translator {
        let translator = TaggingTranslator(tag: target.storageCode, hold: holds[target.storageCode])
        lock.withLock { _made.append(translator) }
        return translator
    }

    func transcriptDownloadStrategy(from source: Locale.Language, to target: Locale.Language) async -> TranslationStrategy { .highFidelity }
}

/// Transcript → Translate: one meeting at a time, what replaces what, a correction translated after quietly, and what is said
/// when a language can't be translated.
@Suite("Meetings: translating a transcript")
@MainActor
struct TranscriptTranslationModelTests {
    private let spanish = Locale.Language(identifier: "es")
    private let english = Locale.Language(identifier: "en")
    private let french = Locale.Language(identifier: "fr")

    private func until(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    private final class Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-translate-\(UUID().uuidString)", isDirectory: true)
        let store: MeetingStore
        let backend = StubTranscriptBackend()
        let model: TranscriptTranslationModel

        init() throws {
            store = try MeetingStore(directory: dir, keyStore: TranslationKey())
            model = TranscriptTranslationModel(backend: backend)
            model.store = store
        }

        deinit { try? FileManager.default.removeItem(at: dir) }

        func meeting(_ texts: [String]) async throws -> (id: Int64, lines: [Int64]) {
            let start = Date() - 86_400
            let id = try await store.startMeeting(at: start, locale: Locale(identifier: "es-ES"))
            var lines: [Int64] = []
            for (i, text) in texts.enumerated() {
                lines.append(try await store.append(Segment(channel: .others, start: Double(i * 5), end: Double(i * 5 + 4), text: text, isFinal: true), to: id))
            }
            _ = try await store.endMeeting(id, at: start + 600)
            return (id, lines)
        }

        func texts(_ meeting: Int64) async throws -> [String] { try await store.translations(of: meeting).map(\.text) }
    }

    @Test func aTranscriptIsTranslatedAndTheMeetingShownReadsIt() async throws {
        let rig = try Rig()
        let (id, _) = try await rig.meeting(["Uno", "Dos"])
        var told: [Int64] = []
        rig.model.onStored = { told.append($0) }
        rig.model.translate(id, source: spanish, into: english)
        #expect(rig.model.stages[id] != nil)
        try await until { rig.model.stages[id] == nil }
        #expect(rig.model.notices[id] == nil)
        #expect(try await rig.texts(id) == ["en:Uno", "en:Dos"])
        #expect(told.contains(id))
    }

    @Test func oneMeetingAtATimeAndAskingAgainChangesNothing() async throws {
        let rig = try Rig()
        let first = try await rig.meeting(["Uno", "Dos"])
        let second = try await rig.meeting(["Tres"])
        let hold = Hold()
        rig.backend.holds = ["en": hold]
        rig.model.translate(first.id, source: spanish, into: english)
        try await until { rig.backend.made.first?.calls.count == 1 }
        rig.model.translate(first.id, source: spanish, into: english)
        rig.model.translate(second.id, source: spanish, into: english)
        #expect(rig.model.stages[second.id] == .waiting(english))
        hold.open()
        try await until { rig.model.stages.isEmpty }
        #expect(rig.backend.made.count == 2, "once for each meeting")
        #expect(try await rig.texts(first.id) == ["en:Uno", "en:Dos"])
        #expect(try await rig.texts(second.id) == ["en:Tres"])
    }

    @Test func anotherLanguageTakesThePlaceOfTheOneRunning() async throws {
        let rig = try Rig()
        let (id, _) = try await rig.meeting(["Uno", "Dos"])
        let hold = Hold()
        rig.backend.holds = ["en": hold]
        rig.model.translate(id, source: spanish, into: english)
        try await until { rig.backend.made.first?.calls.count == 1 }
        rig.model.translate(id, source: spanish, into: french)
        hold.open()
        try await until { rig.model.stages[id] == nil && rig.backend.made.count == 2 }
        try await until { try await !rig.texts(id).isEmpty }
        #expect(try await rig.store.translations(of: id).map(\.language) == ["fr", "fr"])
        #expect(rig.model.notices[id] == nil, "stopped by the person, nothing to say")
    }

    @Test func aCorrectionDuringTheTranslationIsTranslatedAfterQuietly() async throws {
        let rig = try Rig()
        let (id, lines) = try await rig.meeting(["Uno", "Dos"])
        let hold = Hold()
        rig.backend.holds = ["en": hold]
        rig.model.translate(id, source: spanish, into: english)
        try await until { rig.backend.made.first?.calls.count == 1 }
        _ = try await rig.store.correctSegment(lines[1], text: "Dos y medio")
        rig.model.translate(id, source: spanish, into: english, scope: .changed, quiet: true)
        hold.open()
        try await until { try await rig.texts(id) == ["en:Uno", "en:Dos y medio"] }
        #expect(rig.model.stages[id] == nil, "the follow-up shows nothing")
        #expect(rig.model.notices[id] == nil)
    }

    @Test func aLanguageThatCantBeTranslatedSaysSoButACorrectionSaysNothing() async throws {
        let rig = try Rig()
        let (id, _) = try await rig.meeting(["Uno"])
        rig.backend.statuses = ["fr": .unsupported]
        rig.model.translate(id, source: spanish, into: french)
        try await until { rig.model.notices[id] != nil }
        guard case .failed = rig.model.notices[id] else { Issue.record("expected a failure, got \(String(describing: rig.model.notices[id]))"); return }
        rig.model.dismissNotice(id)
        // A correction never starts Apple's download, and says nothing.
        rig.backend.statuses = ["fr": .downloadable]
        rig.model.translate(id, source: spanish, into: french, scope: .changed, quiet: true)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.model.downloader.running == nil)
        #expect(rig.model.notices[id] == nil)
        #expect(rig.model.stages[id] == nil)
    }

    @Test func noDownloadIsAskedForWhileTheWindowIsClosed() async throws {
        let rig = try Rig()
        let (id, _) = try await rig.meeting(["Uno"])
        rig.backend.statuses = ["fr": .downloadable]
        rig.model.canAskForDownload = { false }
        rig.model.translate(id, source: spanish, into: french)
        try await until { rig.model.notices[id] != nil }
        #expect(rig.model.notices[id] == .downloadFailed)
        #expect(rig.model.downloader.running == nil)
        #expect(rig.model.stages[id] == nil)
    }

    @Test func stoppingEverythingForgetsTheQueue() async throws {
        let rig = try Rig()
        let first = try await rig.meeting(["Uno"])
        let second = try await rig.meeting(["Dos"])
        let hold = Hold()
        rig.backend.holds = ["en": hold]
        rig.model.translate(first.id, source: spanish, into: english)
        rig.model.translate(second.id, source: spanish, into: english)
        try await until { rig.backend.made.first?.calls.count == 1 }
        rig.model.stopAll()
        #expect(rig.model.stages.isEmpty)
        hold.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await rig.texts(first.id).isEmpty)
        #expect(try await rig.texts(second.id).isEmpty)
        #expect(rig.backend.made.count == 1)
    }

    @Test func theLanguagesOfferedLeaveOutTheMeetingsOwn() async throws {
        let rig = try Rig()
        rig.backend.statuses = ["de": .downloadable]
        await rig.model.refreshTargets(source: spanish)
        #expect(rig.model.targets.map(\.id).sorted() == ["de", "en", "fr"])
        #expect(rig.model.targets.first { $0.id == "de" }?.needsDownload == true)
        #expect(rig.model.targets.first { $0.id == "en" }?.needsDownload == false)
    }
}
