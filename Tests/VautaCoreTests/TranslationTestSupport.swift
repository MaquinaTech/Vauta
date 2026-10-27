// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

extension Duration {
    /// A delay no test waits for: the operation ends only when it is cancelled. Used for "the server never answers", so the outcome
    /// does not depend on how long a loaded Mac takes to schedule the rest of the test.
    static let untilCancelled: Duration = .seconds(3_600)
}

/// A hold that a test opens when it wants an operation to finish (instead of a delay that a loaded Mac may overrun). Waiting ends
/// when it is opened (returns) or when the waiting task is cancelled (throws), like a request to a server.
final class StubGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if isOpen { lock.unlock(); continuation.resume(); return }
                if Task.isCancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                waiters[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let all = waiters
        waiters = [:]
        lock.unlock()
        for continuation in all.values { continuation.resume() }
    }
}

/// A translator that answers "«text»" after a delay and remembers what it was asked.
final class StubTranslator: Translator, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _batches: [[String]] = []
    private var _cancelled: [String] = []
    private var _active = 0
    private var _maxActive = 0
    var delay: Duration = .milliseconds(1)
    var failing: Set<String> = []
    /// Per-text delay, for tests that need a slow first sentence.
    var delays: [String: Duration] = [:]
    /// Put before every answer (e.g. the target language), so tests can tell pairs apart.
    var tag = ""

    var calls: [String] { lock.withLock { _calls } }
    var batches: [[String]] { lock.withLock { _batches } }
    var cancelled: [String] { lock.withLock { _cancelled } }
    var maxConcurrent: Int { lock.withLock { _maxActive } }

    struct Failure: Error {}

    func translate(_ text: String) async throws -> String {
        lock.withLock {
            _calls.append(text)
            _active += 1
            _maxActive = max(_maxActive, _active)
        }
        defer { lock.withLock { _active -= 1 } }
        do {
            try await Task.sleep(for: delays[text] ?? delay)
        } catch {
            lock.withLock { _cancelled.append(text) }
            throw error
        }
        if failing.contains(text) { throw Failure() }
        return "«\(tag)\(text)»"
    }

    func translate(batch: [String]) async throws -> [String] {
        lock.withLock { _batches.append(batch) }
        var out: [String] = []
        for text in batch { out.append(try await translate(text)) }
        return out
    }
}

final class StubBackend: TranslationBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _made: [(String, StubTranslator)] = []
    var statuses: [String: PairAvailability] = [:]
    var makeDelay: Duration = .zero
    var configure: (StubTranslator) -> Void = { _ in }
    /// Each translator tags its answers with its target ("fr:"), so a caption in the wrong language shows.
    var tagsTarget = false

    var made: [(pair: String, translator: StubTranslator)] { lock.withLock { _made.map { ($0.0, $0.1) } } }
    var last: StubTranslator? { made.last?.translator }

    func availability(from source: Locale.Language, to target: Locale.Language) async -> PairAvailability {
        statuses["\(source.storageCode)>\(target.storageCode)"] ?? .installed
    }

    func makeTranslator(from source: Locale.Language, to target: Locale.Language) async throws -> any Translator {
        if makeDelay > .zero { try await Task.sleep(for: makeDelay) }
        let translator = StubTranslator()
        if tagsTarget { translator.tag = "\(target.storageCode):" }
        configure(translator)
        lock.withLock { _made.append(("\(source.storageCode)>\(target.storageCode)", translator)) }
        return translator
    }
}

/// Collects what the translator publishes and stores.
final class CaptionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [(CaptionSnapshot, ContinuousClock.Instant)] = []
    private var _finals: [FinalTranslation] = []
    private var task: Task<Void, Never>?

    var snapshots: [CaptionSnapshot] { lock.withLock { _snapshots.map(\.0) } }
    var times: [ContinuousClock.Instant] { lock.withLock { _snapshots.map(\.1) } }
    var finals: [FinalTranslation] { lock.withLock { _finals } }
    var latest: CaptionSnapshot? { lock.withLock { _snapshots.last?.0 } }

    func addFinal(_ final: FinalTranslation) { lock.withLock { _finals.append(final) } }

    func watch(_ stream: AsyncStream<CaptionSnapshot>) {
        task = Task { [self] in
            for await snapshot in stream { lock.withLock { _snapshots.append((snapshot, .now)) } }
        }
    }

    deinit { task?.cancel() }
}

/// Polls until `condition` holds (or fails the test after `timeout`). The timeout only bounds a hang: the
/// suite runs hundreds of tests at once and a loaded machine can starve the pool for seconds.
func eventually(timeout: Duration = .seconds(120), _ message: Comment = "condition", _ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        if ContinuousClock.now > deadline {
            Issue.record("Timed out waiting for \(message)")
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

func spoken(_ text: String, final: Bool = false, channel: Channel = .others, start: Double = 0) -> Segment {
    Segment(channel: channel, start: start, end: start + 1, text: text, isFinal: final)
}

let english = Locale.Language(identifier: "en")
let spanish = Locale.Language(identifier: "es")
let french = Locale.Language(identifier: "fr")

/// A translator wired to a stub backend, with fast timings.
struct TranslationRig {
    let backend = StubBackend()
    let recorder = CaptionRecorder()
    let translator: LiveTranslator

    init(tuning: LiveTranslator.Tuning = .fast) {
        let recorder = recorder
        translator = LiveTranslator(backend: backend, tuning: tuning) { recorder.addFinal($0) }
        recorder.watch(translator.snapshots)
    }

    func start(target: Locale.Language = spanish) async {
        await translator.configure(source: english, target: target)
    }
}

extension LiveTranslator.Tuning {
    /// Real behavior at test speed.
    static var fast: LiveTranslator.Tuning {
        var tuning = LiveTranslator.Tuning()
        tuning.debounce = .milliseconds(40)
        tuning.maxDebounceWait = .milliseconds(120)
        tuning.publishInterval = .milliseconds(30)
        return tuning
    }
}
