// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Reading the meeting as it is recorded (the integrated model only): every few seconds of speech the transcript so far is read into
/// the model's kept prefix, so that live answers, live notes and, above all, the minutes only read what came after. A tick costs the
/// new lines plus 16 tokens (about half a second of GPU every 30 seconds, under 2% duty) and runs at the lowest priority of the gate:
/// it gives the GPU up between two chunks, steps aside for any call that needs the same prefix, and waits out a hot Mac. It never
/// blocks transcription: the recorder only tells this service that a segment was saved, and the service starts its own task.
extension LLMService {
    /// What the service remembers of the meeting being read.
    struct WarmState {
        let meetingID: Int64
        let startedAt: Date
        /// The people and projects of the prompt, frozen at the start of the recording (new ones go to the last message).
        var entities: [CandidateEntity]
        var selfEntity: Int64?
        /// The provisional speaker numbers of the other participants, by segment: the store only learns the speakers when the recording
        /// ends, and the lines read before then carry these. Dropped when the final speakers exist.
        var provisional: [Int64: Int] = [:]
        var lastTick = Date.distantPast
        var lastCount = 0
        var charactersSince = 0
        var reading = false
        /// Segments read in the last successful tick.
        var segmentsRead = 0
        /// The size of that reading by the same estimate the prompts are measured with (the engine counts real tokens, which differ).
        var estimatedTokensRead = 0
        var stopped = false
        /// A tick has read the meeting into the model at least once (so the model is loaded): Low Power Mode keeps ticking from then on
        /// but never loads the model itself.
        var loaded = false
    }

    /// When the reading ticks: not before 30 seconds of recording; then after 20 seconds and 600 new characters, or every 2 minutes with
    /// any new text; every 3 minutes in Low Power Mode.
    struct WarmCadence {
        var startDelay: TimeInterval = 30
        var minInterval: TimeInterval = 20
        var minCharacters = 600
        var maxInterval: TimeInterval = 120
        var lowPowerInterval: TimeInterval = 180
    }

    func setWarmCadence(_ cadence: WarmCadence) { warmCadence = cadence }

    /// A segment of the recording was saved (`characters` new characters). Cheap: it records the arrival and, when the debounce rules
    /// allow, starts the reading in a task of its own. The recorder calls it from a fire-and-forget task.
    public func segmentSaved(meetingID: Int64, segmentID: Int64? = nil, speaker: Int? = nil, characters: Int) {
        guard var state = warm, state.meetingID == meetingID, !state.stopped else { return }
        if let segmentID, let speaker { state.provisional[segmentID] = speaker }
        state.charactersSince += characters
        warm = state
        guard !state.reading, shouldTick(state) else { return }
        startWarmReading(meetingID)
    }

    /// The one way a reading starts (a tick, or a question that found the meeting unread): never two at once, so the flag of the
    /// running one is not cleared by the end of another.
    @discardableResult
    func startWarmReading(_ meetingID: Int64) -> Bool {
        guard let state = warm, state.meetingID == meetingID, !state.stopped, !state.reading else { return false }
        warm?.reading = true
        Task { await self.warmMeetingPrefix(meetingID) }
        return true
    }

    private func shouldTick(_ state: WarmState, now: Date = .now) -> Bool {
        let c = warmCadence
        guard now.timeIntervalSince(state.startedAt) >= c.startDelay else { return false }
        let since = now.timeIntervalSince(state.lastTick)
        let env = environmentProvider()
        if env.lowPowerMode { return since >= c.lowPowerInterval && state.charactersSince > 0 }
        if state.charactersSince >= c.minCharacters, since >= c.minInterval { return true }
        return state.charactersSince > 0 && since >= c.maxInterval
    }

    /// Reads the transcript so far into the meeting's prefix. Runs only when the minutes would use the integrated model, the model is
    /// installed and the meeting is the one being recorded. Never two at once; an error is logged at debug level and tried again at the
    /// next tick.
    func warmMeetingPrefix(_ meetingID: Int64) async {
        defer { warm?.reading = false }
        guard recording, live?.meetingID == meetingID, let state = warm, state.meetingID == meetingID, !state.stopped else { return }
        guard let chat = try? chatProvider(for: .main), chat.integrated, let model = chat.model as? WarmableChatModel else { return }
        // "While recording" is Apple Intelligence (since 2026-10-15): the integrated model stays idle during the recording, with
        // no reading of the meeting and no model load. The minutes read the whole transcript cold when the recording ends.
        guard (try? chatProvider(for: .live))?.integrated == true else { return }
        // Loading the model is allowed on the first tick, but not on a Mac that is saving energy or hot.
        let env = environmentProvider()
        guard !env.lowPowerMode || state.loaded, env.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else {
            // Refused: the next try is a whole interval away, not one per saved segment.
            warm?.lastTick = .now
            return
        }
        guard await model.meetingPrefixHasRoom() else { return }
        do {
            let segments = withProvisionalSpeakers(try await store.citableSegments(meetingID), meetingID: meetingID)
            guard !segments.isEmpty else { return }
            let messages: [ChatMessage] = [.system(VautaPrompts.system),
                                           await streamingPeople(meetingID: meetingID, entities: state.entities, selfEntity: state.selfEntity),
                                           VautaPrompts.streamingTranscriptMessage(segments)]
            // Past the one-call window the minutes use blocks and the live answers retrieval: reading more would not be used.
            guard PromptText.tokens(messages) <= ContextBudget(contextTokens: chat.contextTokens).minutesInput else { warm?.stopped = true; return }
            status.readingMeeting = true
            publish()
            defer { status.readingMeeting = false; publish() }
            try await model.readMeeting(messages, onPrefill: nil)
            warm?.lastTick = .now
            warm?.loaded = true
            warm?.charactersSince = 0
            warm?.lastCount = segments.count
            warm?.segmentsRead = segments.count
            warm?.estimatedTokensRead = PromptText.tokens(messages)
        } catch {
            // Tried again at the next tick (a more urgent call took the prefix, the Mac was busy or hot).
            warm?.lastTick = .now
        }
    }

    /// The second message of every request that shares the meeting's prefix: the people, then the rules for answering questions. The
    /// rules say nothing about time: the prefix is the same from the first tick of the recording to the minutes and the questions
    /// after them, and each question carries its own rule about time (`VautaPrompts.askTimingRules`).
    func streamingPeople(meetingID: Int64, entities: [CandidateEntity], selfEntity: Int64?, documents: Bool? = nil) async -> ChatMessage {
        let useDocuments: Bool
        if let documents { useDocuments = documents } else { useDocuments = await askUsesDocuments(meetingID: meetingID) }
        return VautaPrompts.streamingPeopleMessage(entities, selfEntity: selfEntity,
                                                   rules: VautaPrompts.askRulesBody(documents: useDocuments, timeless: true))
    }

    /// Whether a question about this meeting also gets excerpts of the person's documents (the same rule Ask follows).
    func askUsesDocuments(meetingID: Int64) async -> Bool {
        guard let documents, ((try? await documents.totalPassages()) ?? 0) > 0 else { return false }
        return (try? await store.materialsFilter(meetingID)) != nil
    }

    /// While the meeting is recorded, its lines carry the provisional speaker numbers (the store has none yet). After the final speakers
    /// exist, every line has its own and this changes nothing.
    func withProvisionalSpeakers(_ segments: [CitableSegment], meetingID: Int64) -> [CitableSegment] {
        guard let state = warm, state.meetingID == meetingID, !state.provisional.isEmpty else { return segments }
        return segments.map { s in
            guard s.speaker == nil, s.channel == .others, let ordinal = state.provisional[s.id] else { return s }
            var out = s
            out.speaker = SpeakerTag(ordinal: ordinal)
            return out
        }
    }

    /// Reads the meeting now (the evaluation, which replays a recording without the recorder).
    public func readMeetingNow(_ meetingID: Int64) async {
        warm?.reading = true
        await warmMeetingPrefix(meetingID)
    }

    /// The recording started: the meeting's people are frozen for the prefix.
    func beginWarm(meetingID: Int64, entities: [CandidateEntity], selfEntity: Int64?) {
        warm = WarmState(meetingID: meetingID, startedAt: .now, entities: entities, selfEntity: selfEntity)
        meetingSlotMeetings = []   // the recording's reading takes the meeting slot over
    }

    /// The recording stopped: the prefix is kept for the minutes of that meeting.
    func endWarm() async {
        guard let state = warm else { return }
        warm?.stopped = true
        guard state.segmentsRead > 0, let chat = try? chatProvider(for: .main), let model = chat.model as? WarmableChatModel else {
            warm = nil
            return
        }
        warmMeetingKept = state.meetingID
        await model.pinMeeting()
    }

    /// The minutes of `meetingID` are written (or failed for good): the prefix goes back to the normal idle rules.
    /// Called on every end of the minutes job: written, failed for good, cancelled, nothing to write or another provider.
    func releaseWarm(_ meetingID: Int64) async {
        if let state = warm, state.meetingID == meetingID, state.stopped { warm = nil }
        guard warmMeetingKept == meetingID else { return }
        warmMeetingKept = nil
        if let chat = try? chatProvider(for: .main), let model = chat.model as? WarmableChatModel { await model.unpinMeeting() }
    }

    /// A meeting was deleted (`meetingID`) or all of them were erased (nil): the model's kept copies of the transcript go with it, not
    /// after the idle timeout. Only what belongs to that meeting is dropped (everything for nil): the Ask slot when it holds this
    /// meeting, the meeting slot (and its pin) when it holds this one. The state of a meeting that is still recorded is never touched
    /// for another meeting's deletion.
    public func forgetKeptTranscripts(meetingID: Int64? = nil) async {
        var slots = Set<KeptSlot>()
        if let id = meetingID {
            if askPrefixMeetings.contains(id) { slots.insert(.ask) }
            if warm?.meetingID == id || warmMeetingKept == id || meetingSlotMeetings.contains(id) { slots.insert(.meeting) }
        } else {
            slots = [.ask, .meeting]
        }
        guard !slots.isEmpty else { return }
        if slots.contains(.ask) { askPrefixMeetings = [] }
        if slots.contains(.meeting) {
            warm = nil
            warmMeetingKept = nil
            meetingSlotMeetings = []
        }
        await dropFromEngines(slots)
    }

    /// Retention removed meetings (which ones is not known here): the Ask slot goes, and the meeting slot too unless it belongs to a
    /// meeting that is recorded or waiting for its minutes (retention never removes those).
    public func forgetPastTranscripts() async {
        askPrefixMeetings = []
        var slots: Set<KeptSlot> = [.ask]
        if warm == nil, warmMeetingKept == nil {
            meetingSlotMeetings = []
            slots.insert(.meeting)
        }
        await dropFromEngines(slots)
    }

    /// Every integrated engine that can hold a kept transcript: the one of the main provider and the one of the live notes, whichever the
    /// person chose now (a model that is no longer chosen may still be loaded until its idle timeout).
    private func dropFromEngines(_ slots: Set<KeptSlot>) async {
        var seen: [ObjectIdentifier] = []
        for task in [ChatTask.main, .live] {
            guard let chat = try? chatProvider(for: task), let model = chat.model as? WarmableChatModel else { continue }
            if let object = model as AnyObject? {
                let id = ObjectIdentifier(object)
                if seen.contains(id) { continue }
                seen.append(id)
            }
            await model.dropKeptTranscripts(slots)
        }
    }

    /// A call about `meetingID` writes its transcript into `slot` (it sets `options.slot`): remember whose it is, so deleting that
    /// meeting drops it. The meeting is recorded when the call starts, because the prefix exists as soon as the model has read it, also
    /// when the call then fails, throws (an invalid reply, a length cut) or is cancelled; the note is made again when the call ends,
    /// so a meeting that was deleted while the call ran leaves nothing behind.
    func keeping<T>(_ slot: KeptSlot?, meetingID: Int64?, _ call: () async throws -> T) async throws -> T {
        guard let slot, let meetingID else { return try await call() }
        await noteKept(slot, meetingID: meetingID)
        do {
            let value = try await call()
            await noteKept(slot, meetingID: meetingID)
            return value
        } catch {
            await noteKept(slot, meetingID: meetingID)
            throw error
        }
    }

    func noteKept(_ slot: KeptSlot, meetingID: Int64?) async {
        guard let meetingID else { return }
        // A lookup that fails (a cancelled task, a busy store) is not "the meeting is gone": only a clean "no such meeting" drops.
        var exists = true
        do { exists = try await store.meeting(meetingID) != nil } catch {}
        switch slot {
        case .ask: askPrefixMeetings.insert(meetingID)
        case .meeting: if warmMeetingID != meetingID { meetingSlotMeetings.insert(meetingID) }
        }
        if !exists { await forgetKeptTranscripts(meetingID: meetingID) }
    }

    /// The meeting whose transcript the integrated model has read (being recorded, or just recorded and waiting for its minutes):
    /// requests about it use the meeting's kept prefix.
    var warmMeetingID: Int64? { warm?.meetingID ?? warmMeetingKept }
}
