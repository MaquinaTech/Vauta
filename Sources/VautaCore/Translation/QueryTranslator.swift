// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Translates a question into the language of the transcripts so a keyword search can find it (E4). Everything runs on this Mac
/// through a `TranslationBackend` (Apple's Translation, installed language pairs only: it never downloads a language and never
/// contacts a server). It answers nil, and the caller searches with the original question, when the pair is not installed, the
/// translation fails, comes back empty or takes longer than `timeout`.
///
/// Translators are kept per pair for the length of the process, and the last translations are remembered, so asking the same
/// thing twice (or the live gate and Ask asking about the same question) translates once. The text of a question is never logged.
public actor QueryTranslator {
    /// What Ask waits for a translation.
    public static let askTimeout: Duration = .seconds(2)
    /// What the evidence gate of a question heard in the meeting waits (the answer is time sensitive).
    public static let liveTimeout: Duration = .milliseconds(1_500)
    /// How long a pair that was not usable is not asked about again.
    static let unavailableFor: Duration = .seconds(30)
    static let rememberedTranslations = 64
    /// Consecutive late translations after which a pair is left alone: the first call of a session can be slow while Apple loads its model.
    static let timeoutsBeforeUnavailable = 2

    private let backend: any TranslationBackend
    private var translators: [String: any Translator] = [:]
    private var unusable: [String: ContinuousClock.Instant] = [:]
    private var lateInARow: [String: Int] = [:]
    /// The call that is still running for a pair (a late one the caller stopped waiting for, which Apple's session may not honour
    /// cancelling): the next question waits for it before it calls the same session again, as the session is not documented as safe
    /// for two calls at once.
    private var inFlight: [String: (token: Int, job: Task<String?, Never>)] = [:]
    private var nextToken = 0
    private var remembered: [String: String] = [:]
    private var order: [String] = []

    public init(backend: any TranslationBackend) {
        self.backend = backend
    }

    /// The text in `target`, or nil when the original should be used.
    public func translate(_ text: String, from source: Locale.Language, to target: Locale.Language, timeout: Duration = askTimeout) async -> String? {
        guard !source.isSameLanguage(as: target), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let pair = "\(source.storageCode)>\(target.storageCode)"
        let memoKey = pair + "\u{1F}" + text
        if let known = remembered[memoKey] { return known }
        if let until = unusable[pair], ContinuousClock.now < until { return nil }
        if Task.isCancelled { return nil }
        let translator: any Translator
        if let kept = translators[pair] {
            translator = kept
        } else {
            guard await backend.availability(from: source, to: target) == .installed,
                  let made = try? await backend.makeTranslator(from: source, to: target) else {
                unusable[pair] = ContinuousClock.now + Self.unavailableFor
                return nil
            }
            translators[pair] = made
            translator = made
        }
        let deadline = ContinuousClock.now + timeout
        if let busy = inFlight[pair]?.job {
            let waited = await Self.race(timeout: timeout) { _ = await busy.value; return nil }
            if case .late = waited { noteLate(pair); return nil }
            if Task.isCancelled { return nil }
        }
        let remaining = max(deadline - ContinuousClock.now, .milliseconds(1))
        nextToken += 1
        let token = nextToken
        // Detached: the job keeps its own life, so it can be waited for by the next question even after this one gave up.
        let job = Task.detached { try? await translator.translate(text) }
        inFlight[pair] = (token, job)
        Task { [job] in
            _ = await job.value
            if inFlight[pair]?.token == token { inFlight[pair] = nil }
        }
        let outcome = await Self.race(timeout: remaining) { await job.value }
        if case .late = outcome {
            // A late translation keeps the translator (the first call loads Apple's model); only repeated lateness leaves the pair alone.
            job.cancel()
            noteLate(pair)
            return nil
        }
        if case .done(nil) = outcome, Task.isCancelled { job.cancel() }
        guard case .done(let finished) = outcome, let result = finished, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // A pair that fails is left alone for a while: the next question does not wait for it again.
            if !Task.isCancelled {
                unusable[pair] = ContinuousClock.now + Self.unavailableFor
                translators[pair] = nil
            }
            return nil
        }
        lateInARow[pair] = nil
        if Task.isCancelled { return nil }
        remembered[memoKey] = result
        order.append(memoKey)
        if order.count > Self.rememberedTranslations { remembered[order.removeFirst()] = nil }
        return result
    }

    private func noteLate(_ pair: String) {
        let late = (lateInARow[pair] ?? 0) + 1
        lateInARow[pair] = late
        if late >= Self.timeoutsBeforeUnavailable {
            unusable[pair] = ContinuousClock.now + Self.unavailableFor
            lateInARow[pair] = nil
        }
    }

    private enum Outcome: Sendable {
        /// The translation finished (nil: it failed, or the caller was cancelled).
        case done(String?)
        /// The time limit passed first.
        case late
    }

    /// The first of the work, the timer and the caller's cancellation. The work is cancelled when it loses, but a translation that
    /// ignores cancellation is not waited for. The timer is cancelled when anything else finishes first.
    private static func race(timeout: Duration, _ work: @escaping @Sendable () async -> String?) async -> Outcome {
        let box = Finish()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.attach(continuation)
                let job = Task { box.finish(.done(await work())) }
                let timer = Task {
                    try? await Task.sleep(for: timeout)
                    if !Task.isCancelled { box.finish(.late) }
                }
                box.onFinish {
                    job.cancel()
                    timer.cancel()
                }
            }
        } onCancel: {
            box.finish(.done(nil))
        }
    }

    /// Resumes the continuation once, whoever finishes first.
    private final class Finish: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Outcome, Never>?
        private var done = false
        private var cleanup: (@Sendable () -> Void)?

        func attach(_ c: CheckedContinuation<Outcome, Never>) {
            let already = lock.withLock { () -> Bool in
                if done { return true }
                continuation = c
                return false
            }
            if already { c.resume(returning: .done(nil)) }
        }

        func onFinish(_ body: @escaping @Sendable () -> Void) {
            let already = lock.withLock { () -> Bool in
                if done { return true }
                cleanup = body
                return false
            }
            if already { body() }
        }

        func finish(_ value: Outcome) {
            let (c, clean) = lock.withLock { () -> (CheckedContinuation<Outcome, Never>?, (@Sendable () -> Void)?) in
                guard !done else { return (nil, nil) }
                done = true
                defer { continuation = nil; cleanup = nil }
                return (continuation, cleanup)
            }
            c?.resume(returning: value)
            clean?()
        }
    }
}
