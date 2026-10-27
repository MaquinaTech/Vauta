// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Live captions for the "Others" channel: turns the segments the speech
/// recognizer emits (provisional and final) into translated captions.
///
/// - Finals are translated at once and in order (a backlog goes through one
///   batch). Each result is handed to `onFinal` to be stored.
/// - The provisional tail is translated only after `debounce` of quiet and
///   only when it grew by `minGrowthWords` words or `minGrowthCharacters`
///   characters since the last translated version; a newer version cancels
///   the one in flight, and a long run of speech cannot starve it
///   (`maxDebounceWait`).
/// - One translator per language pair for the whole meeting; a small LRU
///   cache answers repeated sentences.
/// - Everything runs here, never on the main actor. The caller feeds it with
///   the non-blocking `submit` and reads `snapshots`, which is coalesced to
///   at most one value per `publishInterval` (newest wins).
/// - Without a pair (feature off) nothing exists, so there is no cost.
/// - Finals are also sent to the user's model server when a `refiner` is
///   given and usable (see `LiveTranslator+Refinement`): Apple's caption
///   shows at once and is replaced in place if the server answers in time.
public actor LiveTranslator {
    public struct Tuning: Sendable {
        public var debounce: Duration = .milliseconds(250)
        public var maxDebounceWait: Duration = .milliseconds(600)
        public var minGrowthWords = 2
        public var minGrowthCharacters = 15
        /// Characters for scripts written without spaces (Japanese, Chinese, Thai…).
        public var minGrowthDenseCharacters = 6
        public var publishInterval: Duration = .milliseconds(100)
        public var visibleLines = 3
        public var cacheCapacity = 128
        /// Finals translated again when the target language changes mid-meeting.
        public var retranslateOnChange = 3
        public var maxBatch = 8
        public var failuresBeforeGivingUp = 3
        /// How long after Apple's caption the server's version may still replace it.
        public var refineBudget: Duration = .seconds(4)
        /// How long a request may run in all. An answer after `refineBudget` is stored but
        /// does not change the caption; one that is still missing at this bound is given up.
        public var refineLateBound: Duration = .seconds(20)
        /// Server requests in flight at once.
        public var refineInFlight = 2
        /// Previous sentences sent with each one.
        public var refineContext = ServerTranslator.contextSentences
        /// After this many failures in a row the server is left alone for `refinePause`.
        public var refineFailuresBeforePause = 3
        public var refinePause: Duration = .seconds(20)

        public init() {}
    }

    private enum Input: Sendable {
        case partial(String)
        case final(key: Int, text: String, speaker: Int?)
    }

    struct PendingFinal {
        let key: Int
        let lineID: Int
        let text: String
    }

    /// Gives the server translator for a pair, or nil when refinement is off or there is no usable server.
    public typealias Refiner = @Sendable (TranslationPair) async -> (any RefiningTranslator)?

    private let backend: any TranslationBackend
    let tuning: Tuning
    let refiner: Refiner?
    let onFinal: @Sendable (FinalTranslation) async -> Void
    private let input: AsyncStream<Input>.Continuation
    private let inputStream: AsyncStream<Input>
    private let output: AsyncStream<CaptionSnapshot>.Continuation
    /// The captions, coalesced: at most one value per `publishInterval`.
    public nonisolated let snapshots: AsyncStream<CaptionSnapshot>

    var pair: TranslationPair?
    private var translator: (any Translator)?
    private var status: CaptionStatus = .starting
    var paused = false
    var epoch = 0
    private var cache: TranslationCache
    var finished = false

    // Refinement by the model server (see `LiveTranslator+Refinement`).
    struct RefineItem {
        let key: Int
        let lineID: Int
        let text: String
        let deadline: ContinuousClock.Instant
    }
    var refineQueue: [RefineItem] = []
    var refineTasks: [Int: Task<Void, Never>] = [:]
    /// Requests past the caption budget that are still allowed to finish and be stored.
    var lateTasks: [Int: Task<Void, Never>] = [:]
    /// Changes when in-flight requests must be forgotten (pause, pair change, hard stop), not when a recording ends.
    var refineEpoch = 0
    /// The last finals with their best translation so far (refined when available): the context of the next one.
    var history: [(lineID: Int, source: String, translation: String)] = []
    var refinement: RefinementStatus = .off
    var refineFailures = 0
    var refinePausedUntil: ContinuousClock.Instant?

    var finals: [CaptionLine] = []
    private var partial: CaptionLine?
    private var nextLineID = 0
    private var recent: [PendingFinal] = []
    private var queue: [PendingFinal] = []
    private var failures = 0

    private var consumer: Task<Void, Never>?
    private var finalWorker: Task<Void, Never>?
    private var workerToken: UUID?
    private var debounceTask: Task<Void, Never>?
    private var debounceStarted: ContinuousClock.Instant?
    private var partialJob: Task<Void, Never>?
    private var refirePartial = false
    private var partialBaseline = ""

    private var publishTask: Task<Void, Never>?
    private var lastPublish: ContinuousClock.Instant?
    private var dirty = false

    public init(backend: any TranslationBackend, tuning: Tuning = Tuning(), refiner: Refiner? = nil,
                onFinal: @escaping @Sendable (FinalTranslation) async -> Void) {
        self.backend = backend
        self.tuning = tuning
        self.refiner = refiner
        self.onFinal = onFinal
        cache = TranslationCache(capacity: tuning.cacheCapacity)
        (inputStream, input) = AsyncStream.makeStream(of: Input.self)
        (snapshots, output) = AsyncStream.makeStream(of: CaptionSnapshot.self, bufferingPolicy: .bufferingNewest(1))
    }

    // MARK: Input (any thread, never blocks)

    /// Feeds one segment of the "Others" channel. Order is kept; segments of
    /// other channels are ignored. `key` identifies a final segment in `onFinal`.
    public nonisolated func submit(_ segment: Segment, key: Int) {
        guard segment.channel == .others else { return }
        input.yield(segment.isFinal ? .final(key: key, text: segment.text, speaker: segment.speaker?.ordinal) : .partial(segment.text))
    }

    // MARK: Control

    /// Sets (or changes, mid-meeting) the language pair and prepares its
    /// translator. Returns once the pair is ready or its state is known.
    public func configure(source: Locale.Language, target: Locale.Language) async {
        guard !finished else { return }
        if consumer == nil { consumer = Task { await self.consume() } }
        let newPair = TranslationPair(source: source, target: target)
        let changed = pair != nil && pair != newPair
        epoch += 1
        let e = epoch
        cancelJobs()
        translator = nil
        cache.removeAll()
        failures = 0
        pair = newPair
        if changed {
            history.removeAll()
            refinePausedUntil = nil
            retranslateRecent()
        }
        guard !newPair.isIdentity else {
            setStatus(.sameLanguage)
            return
        }
        setStatus(.starting)
        let availability = await backend.availability(from: source, to: target)
        guard e == epoch else { return }
        switch availability {
        case .unsupported:
            setStatus(.unsupported)
        case .downloadable:
            setStatus(.needsDownload)
        case .installed:
            do {
                let made = try await backend.makeTranslator(from: source, to: target)
                guard e == epoch else { return }
                translator = made
                setStatus(paused ? .paused : .listening)
                pumpFinals()
            } catch {
                guard e == epoch else { return }
                setStatus(.failed)
            }
        }
    }

    /// The pair was downloaded (or something else changed): prepare it again.
    public func retry() async {
        guard let pair else { return }
        await configure(source: pair.source, target: pair.target)
    }

    /// The app is downloading the pair: say so while it lasts.
    public func setDownloading(_ downloading: Bool) {
        if downloading, status == .needsDownload || status == .failed { setStatus(.downloading) }
        if !downloading, status == .downloading { setStatus(.needsDownload) }
    }

    /// While paused nothing is translated and nothing is stored.
    public func setPaused(_ paused: Bool) {
        guard paused != self.paused, !finished else { return }
        self.paused = paused
        if paused {
            epoch += 1
            cancelJobs()
            queue.removeAll()
            partial = nil
            partialBaseline = ""
            if status == .listening || status == .starting { setStatus(.paused) }
        } else {
            if status == .paused { setStatus(translator == nil ? .starting : .listening) }
            if translator == nil, let pair { Task { await self.configure(source: pair.source, target: pair.target) } }
        }
    }

    /// Ends the meeting's captions: the finals still waiting get up to
    /// `maxWait` to be translated and stored, everything else is dropped.
    public func finish(maxWait: Duration = .seconds(2)) async {
        guard !finished else { return }
        input.finish()
        await consumer?.value
        if let worker = finalWorker {
            // Whichever comes first: the queue is empty or the budget is spent.
            // (A translation that ignores cancellation must not hold the quit.)
            let (signal, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
            let waiter = Task { await worker.value; wake.yield() }
            let timer = Task { try? await Task.sleep(for: maxWait); wake.yield() }
            for await _ in signal { break }
            waiter.cancel()
            timer.cancel()
        }
        stop(keepingRefinements: true)
    }

    /// Stops at once (feature turned off). Nothing runs afterwards.
    public func stop() {
        stop(keepingRefinements: false)
    }

    /// With `keepingRefinements` (the recording ended) the requests already sent to the
    /// model server finish in the background, within `Tuning.refineLateBound`, and their
    /// answers are still handed to `onFinal`; use `waitForRefinements()` to know when.
    private func stop(keepingRefinements: Bool) {
        guard !finished else { return }
        finished = true
        epoch += 1
        cancelJobs(refinements: !keepingRefinements)
        if keepingRefinements { dropQueuedRefinements() }
        publishTask?.cancel()
        publishTask = nil
        consumer?.cancel()
        input.finish()
        translator = nil
        queue.removeAll()
        output.finish()
    }

    // MARK: Input handling

    private func consume() async {
        for await item in inputStream {
            if finished { break }
            switch item {
            case .partial(let text): handlePartial(text)
            case .final(let key, let text, let speaker): handleFinal(key: key, text: text, speaker: speaker)
            }
        }
    }

    private var accepting: Bool {
        guard !paused, !finished, pair != nil else { return false }
        return status == .starting || status == .listening
    }

    private func handleFinal(key: Int, text: String, speaker: Int?) {
        guard accepting else { return }
        let lineID = partial?.id ?? takeLineID()
        let provisional = partial?.translation ?? ""
        partial = nil
        partialBaseline = ""
        debounceTask?.cancel()
        debounceTask = nil
        debounceStarted = nil
        refirePartial = false
        partialJob?.cancel()
        finals.append(CaptionLine(id: lineID, original: text, translation: provisional, state: .translating, speaker: speaker))
        if finals.count > 8 { finals.removeFirst(finals.count - 8) }
        recent.append(PendingFinal(key: key, lineID: lineID, text: text))
        if recent.count > tuning.retranslateOnChange { recent.removeFirst(recent.count - tuning.retranslateOnChange) }
        queue.append(PendingFinal(key: key, lineID: lineID, text: text))
        markDirty()
        pumpFinals()
    }

    private func handlePartial(_ text: String) {
        guard accepting else { return }
        if partial == nil {
            partial = CaptionLine(id: takeLineID(), original: text, translation: "", state: .partial)
        } else {
            partial?.original = text
        }
        markDirty()
        guard translator != nil, grewEnough(from: partialBaseline, to: text) else { return }
        scheduleFire()
    }

    private func takeLineID() -> Int {
        defer { nextLineID += 1 }
        return nextLineID
    }

    /// Whether `new` is long enough beyond `old` to be worth translating again.
    func grewEnough(from old: String, to new: String) -> Bool {
        let denseScript = new.suffix(24).unicodeScalars.contains { Self.isDense($0) }
        let characters = denseScript ? tuning.minGrowthDenseCharacters : tuning.minGrowthCharacters
        if new.count - old.count >= characters { return true }
        return Self.wordCount(new) - Self.wordCount(old) >= tuning.minGrowthWords
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Scripts whose words are not separated by spaces.
    private static func isDense(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x0E00...0x0E7F: true
        default: false
        }
    }

    // MARK: Provisional tail

    private func scheduleFire() {
        let now = ContinuousClock.now
        // Pending for too long: let it fire with the newest text instead of postponing again.
        if let started = debounceStarted, now - started >= tuning.maxDebounceWait { return }
        debounceTask?.cancel()
        if debounceStarted == nil { debounceStarted = now }
        let e = epoch
        let wait = tuning.debounce
        debounceTask = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            await self?.firePartial(epoch: e)
        }
    }

    private func firePartial(epoch e: Int) {
        guard e == epoch, !paused, !finished, let partial, let translator else { return }
        debounceTask = nil
        debounceStarted = nil
        let text = partial.original
        guard grewEnough(from: partialBaseline, to: text) else { return }
        if partialJob != nil {
            // The one in flight is stale: cancel it and start again when it returns.
            partialJob?.cancel()
            refirePartial = true
            return
        }
        partialBaseline = text
        if let cached = cache.value(for: text) {
            applyPartial(id: partial.id, translation: cached)
            return
        }
        let id = partial.id
        partialJob = Task { [weak self] in
            let result = try? await translator.translate(text)
            await self?.partialFinished(id: id, source: text, translation: result, epoch: e)
        }
    }

    private func partialFinished(id: Int, source: String, translation: String?, epoch e: Int) {
        // A job of an earlier epoch was already forgotten; it must not clear the current one.
        guard e == epoch else { return }
        partialJob = nil
        guard !finished else { return }
        if let translation, !translation.isEmpty, partial?.id == id {
            cache.insert(translation, for: source)
            applyPartial(id: id, translation: translation)
        }
        if refirePartial {
            refirePartial = false
            firePartial(epoch: e)
        }
    }

    private func applyPartial(id: Int, translation: String) {
        guard partial?.id == id, partial?.translation != translation else { return }
        partial?.translation = translation
        markDirty()
    }

    // MARK: Finals

    private func pumpFinals() {
        guard finalWorker == nil, translator != nil, !queue.isEmpty, !paused, !finished else { return }
        let e = epoch
        let token = UUID()
        workerToken = token
        finalWorker = Task { [weak self] in await self?.drainFinals(epoch: e, token: token) }
    }

    private func drainFinals(epoch e: Int, token: UUID) async {
        defer { if workerToken == token { finalWorker = nil; workerToken = nil } }
        while e == epoch, !Task.isCancelled, let translator, !queue.isEmpty {
            let batch = Array(queue.prefix(tuning.maxBatch))
            var results = [String?](repeating: nil, count: batch.count)
            var missing: [Int] = []
            for (i, item) in batch.enumerated() {
                if let cached = cache.value(for: item.text) { results[i] = cached } else { missing.append(i) }
            }
            if !missing.isEmpty {
                let texts = missing.map { batch[$0].text }
                do {
                    let translated = texts.count == 1 ? [try await translator.translate(texts[0])] : try await translator.translate(batch: texts)
                    for (slot, text) in zip(missing, translated) { results[slot] = text }
                    failures = 0
                } catch is CancellationError {
                    return
                } catch {
                    // The batch failed: one by one, so a single bad sentence costs only itself.
                    for slot in missing {
                        do {
                            results[slot] = try await translator.translate(batch[slot].text)
                            failures = 0
                        } catch is CancellationError {
                            return
                        } catch {
                            failures += 1
                        }
                    }
                    // Repeated failures stop the feature instead of retrying forever.
                    if failures >= tuning.failuresBeforeGivingUp, e == epoch {
                        queue.removeAll()
                        self.translator = nil
                        setStatus(.failed)
                        return
                    }
                }
            }
            guard e == epoch, let language = pair?.targetCode else { return }
            for (i, item) in batch.enumerated() {
                // `onFinal` suspends: the pair may change (or a pause start) meanwhile, and
                // what is left of this batch is in the old language.
                guard e == epoch else { return }
                queue.removeAll { $0.key == item.key && $0.lineID == item.lineID }
                let text = results[i] ?? ""
                if let index = finals.firstIndex(where: { $0.id == item.lineID }) {
                    if !text.isEmpty { finals[index].translation = text }
                    finals[index].state = .final
                }
                guard !text.isEmpty else { continue }
                cache.insert(text, for: item.text)
                recordHistory(lineID: item.lineID, source: item.text, translation: text)
                markDirty()
                await onFinal(FinalTranslation(key: item.key, language: language, text: text, source: item.text))
                guard e == epoch else { return }
                enqueueRefinement(item)
            }
            markDirty()
        }
    }

    /// The target changed: the last few captions are translated again in the new language.
    /// Finals still waiting stay queued (now for the new language), so none is left "translating" forever.
    private func retranslateRecent() {
        var waiting = Set(queue.map(\.lineID))
        for entry in recent where !waiting.contains(entry.lineID) {
            guard let index = finals.firstIndex(where: { $0.id == entry.lineID }) else { continue }
            finals[index].translation = ""
            finals[index].isRefined = false
            finals[index].state = .translating
            queue.append(entry)
            waiting.insert(entry.lineID)
        }
        queue.sort { $0.lineID < $1.lineID }
    }

    // MARK: State and publication

    private func cancelJobs(refinements: Bool = true) {
        debounceTask?.cancel()
        debounceTask = nil
        debounceStarted = nil
        partialJob?.cancel()
        partialJob = nil
        refirePartial = false
        finalWorker?.cancel()
        finalWorker = nil
        workerToken = nil
        if refinements { cancelRefinement() }
    }

    private func setStatus(_ new: CaptionStatus) {
        status = new
        if new != .listening && new != .starting {
            // Nothing will translate what is waiting.
            if new != .paused { queue.removeAll() }
            for index in finals.indices where finals[index].state == .translating { finals[index].state = .final }
        }
        markDirty()
    }

    func markDirty() {
        dirty = true
        guard publishTask == nil, !finished else { return }
        let wait: Duration
        if let last = lastPublish {
            let elapsed = ContinuousClock.now - last
            wait = elapsed >= tuning.publishInterval ? .zero : tuning.publishInterval - elapsed
        } else {
            wait = .zero
        }
        if wait == .zero {
            publishNow()
        } else {
            publishTask = Task { [weak self] in
                do { try await Task.sleep(for: wait) } catch { return }
                await self?.publishDeferred()
            }
        }
    }

    private func publishDeferred() {
        publishTask = nil
        if dirty { publishNow() }
    }

    private func publishNow() {
        dirty = false
        lastPublish = .now
        let lines = Array((finals + (partial.map { [$0] } ?? [])).suffix(tuning.visibleLines))
        output.yield(CaptionSnapshot(pair: pair, status: status, lines: lines, refinement: refinement))
    }
}
