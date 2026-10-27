// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit

/// During a recording: segments, marks, notes, naming "Others" and live notes.
extension RecorderModel {
    /// "Keep recording": restarts the silence count.
    func keepRecording() {
        guard capture != nil else { return }
        lastOthersHeard = .now
        lastMeHeard = .now
        pendingAutoStopAt = nil
        autoStopRemaining = nil
        hangupNotice = false
        notifier.remove(.autoStopWarning)
        notifier.remove(.hangup)
    }

    /// A failed write as a warning: what happened and what to do, with the system text as its tooltip.
    func saveFailure(_ what: String, _ error: Error) -> String {
        let message = SaveFailure.message(what, error)
        warningDetails[message] = error.localizedDescription
        warningParts[message] = SaveFailure.parts(what, error)
        return message
    }

    /// Marks the current moment (button or the mark shortcut from any app).
    func markMoment() {
        guard phase == .recording, let store, let id = meetingID else { return }
        let t = currentOffset
        Task {
            do {
                _ = try await store.addMark(id, at: t)
                marks = try await store.marks(id)
                // Not the sound of a recording start: from another app the two must tell apart.
                NSSound(named: "Morse")?.play()
                AccessibilityNotification.Announcement(
                    String(localized: "Moment marked at \(ElapsedTime.stamp(Int(t))).", comment: "VoiceOver announcement; the argument is the time in the meeting")).post()
            } catch {
                lastError = saveFailure(String(localized: "The mark couldn’t be saved.", comment: "Warning while recording"), error)
                // The shortcut is used from the meeting app with the panel closed: the failure is heard and announced.
                NSSound(named: "Basso")?.play()
                AccessibilityNotification.Announcement(String(localized: "The mark couldn’t be saved.", comment: "Warning while recording")).post()
            }
        }
    }

    func searchOthers(_ query: String) {
        othersSearch?.cancel()
        othersSearch = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, let store = self.store else { return }
            let hits = (try? await store.searchNames(query)) ?? []
            // "Me" is never one of the others.
            let selfID = (try? await store.selfEntityID()) ?? nil
            // Only people: a project, a client or a term is never the name of a voice.
            let people = Set(((try? await store.entities(.person)) ?? []).map(\.id))
            if self.othersQuery == query {
                // The user's own name (or an alias, in any case or accents) is said at once, before a click.
                let everyone = (try? await store.entities(.person)) ?? []
                if Self.isSelfName(query, among: everyone) { self.othersNotice = Self.selfNotice }
                self.othersHits = hits.filter { if case .entity(let id) = $0.target { id != selfID && people.contains(id) } else { false } }
                self.othersHitsQuery = query
            }
        }
    }

    /// "Others" is this person (added to the ones already named).
    func nameOthers(_ entityID: Int64) {
        guard let store, let id = meetingID else { return }
        // With voices told apart the name is for the chosen voice; a name is a suggestion made by the user, never a guess.
        // Read before the field is cleared: the pin that kept the voice still while typing ends with the text.
        let voice = namingLiveSpeaker
        othersQuery = ""
        othersHits = []
        Task {
            do {
                // From the store, not the visible list: two quick clicks don't overwrite each other.
                // "Me" is never one of the others.
                // Only a person can be named; a project or a client never is.
                guard let person = try await store.entities(.person).first(where: { $0.id == entityID }), !person.isSelf else { return }
                let current = try await store.meetingEntities(id, role: .others).map(\.id)
                try await store.setMeetingEntities(id, role: .others, Array(Set(current + [entityID])))
                othersNamed = try await store.meetingEntities(id, role: .others)
                if let voice, let person = othersNamed.first(where: { $0.id == entityID }) { assignLiveSpeaker(voice, to: person) }
            } catch {
                lastError = saveFailure(String(localized: "Couldn’t save the name for “\(Channel.others.displayName)”.",
                                               comment: "Warning; the argument is the channel name (Others)"), error)
            }
        }
    }

    func unnameOthers(_ entityID: Int64) {
        guard let store, let id = meetingID else { return }
        liveSpeakerPeople = liveSpeakerPeople.filter { $0.value.id != entityID }
        syncCaptionSpeakers()
        Task {
            do {
                let current = try await store.meetingEntities(id, role: .others).map(\.id)
                try await store.setMeetingEntities(id, role: .others, current.filter { $0 != entityID })
            } catch {
                lastError = saveFailure(String(localized: "Couldn’t remove the name for “\(Channel.others.displayName)”.",
                                               comment: "Warning; the argument is the channel name (Others)"), error)
            }
            othersNamed = (try? await store.meetingEntities(id, role: .others)) ?? []
        }
    }

    static var selfNotice: String {
        String(localized: "“\(Channel.me.displayName)” is always you. Name the other participants here.",
               comment: "Hint under the name field of the other participants when the user typed their own name; the argument is the channel name (Me)")
    }

    /// The typed text is the user's own name or one of its aliases, compared without case, accents or width.
    static func isSelfName(_ text: String, among people: [Entity]) -> Bool {
        func folded(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        let typed = folded(text)
        guard !typed.isEmpty else { return false }
        return people.contains { $0.isSelf && ([$0.displayName, $0.name] + $0.aliases).contains { folded($0) == typed } }
    }

    /// Return in the name field: the first match is named; with no match the typed name is added as a new person.
    func commitOthersName() {
        guard othersHitsQuery == othersQuery, !othersQuery.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let first = othersHits.first, case .entity(let id) = first.target {
            nameOthers(id)
        } else {
            addOthersAsNewPerson()
        }
    }

    /// A new person from what was typed (kept in the context).
    func addOthersAsNewPerson() {
        let name = othersQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let store else { return }
        Task {
            do {
                // Typing your own name is not adding a person: "Me" is never one of the others.
                if Self.isSelfName(name, among: try await store.entities(.person)) {
                    // The text stays and the reason is said, so the action never looks like it did nothing.
                    othersNotice = Self.selfNotice
                    NSSound.beep()
                    AccessibilityNotification.Announcement(Self.selfNotice).post()
                    return
                }
                let entity = try await store.saveEntity(EntityDraft(kind: .person, name: name))
                nameOthers(entity)
            } catch {
                lastError = String(localized: "“\(name)” couldn’t be added. \(error.localizedDescription)",
                                   comment: "Warning; the first argument is a person's name, the second the error")
            }
        }
    }

    // MARK: Segments

    func update(_ channel: Channel, _ health: ChannelHealth) {
        guard capture != nil else { return }
        switch health {
        case .ok:
            channelWarnings[channel] = nil
            liveAnswerEnvironment.setLagging(false, channel: channel)
        case .reconnecting, .lost, .lagging:
            channelWarnings[channel] = health.message(for: channel)
            liveAnswerEnvironment.setLagging(health == .lagging, channel: channel)
        case .failed:
            channelWarnings[channel] = health.message(for: channel)
            // A channel that failed is not lagging any more; the other one decides whether live answers wait.
            liveAnswerEnvironment.setLagging(false, channel: channel)
            // What was transcribed, to disk as soon as possible.
            let previous = writes
            Task { [store] in
                await previous?.value
                try? await store?.saveIfNeeded()
            }
        }
    }

    func receive(_ segment: Segment) {
        var segment = segment
        // Provisional speaker labels go on FINAL segments only (the captions stay one per channel). The Me channel is
        // always the same single speaker. The labels are data for the views; nothing shows them yet.
        if segment.isFinal, let diarizer {
            segment = segment.with(speaker: segment.channel == .me ? SpeakerTag(ordinal: 1)
                                   : diarizer.provisionalSpeaker(start: segment.start, end: segment.end))
            noteLiveSpeaker(of: segment)
        }
        guard segment.isFinal else {
            liveTranslation.feed(segment, key: -1)
            volatile[segment.channel] = segment
            volatileSegments = volatile.values.sorted { $0.start < $1.start }
            return
        }
        if volatile.removeValue(forKey: segment.channel) != nil {
            volatileSegments = volatile.values.sorted { $0.start < $1.start }
        }
        let index = segments.lastIndex { $0.segment.start <= segment.start }.map { $0 + 1 } ?? 0
        let liveID = nextSegmentID
        segments.insert(LiveSegment(id: liveID, segment: segment), at: index)
        nextSegmentID += 1
        liveTranslation.feed(segment, key: liveID)
        persist(segment, liveID: liveID)
        charsSinceLiveNotes += segment.text.count
        considerNoteExpansion()
        considerLiveNotes()
        considerWarmPrefix(liveID: liveID, segment: segment)
        considerQuestion(liveID: liveID, segment: segment)
    }

    /// Tells the model service that a segment was saved, so that the integrated model can read the meeting as it goes (the service
    /// decides when; most calls do nothing). A task of its own: the segment path never waits for it.
    ///
    /// The speaker of the line while it is recorded is provisional (the final clustering may renumber it): the service reads the meeting
    /// with the provisional number so that the lines it has read are the lines the minutes will see.
    private func considerWarmPrefix(liveID: Int, segment: Segment) {
        guard phase == .recording, let llm, let id = meetingID else { return }
        let pending = writes
        let ordinal = segment.channel == .others ? segment.speaker?.ordinal : nil
        let characters = segment.text.count
        Task {
            await pending?.value
            await llm.segmentSaved(meetingID: id, segmentID: segmentRowIDs[liveID], speaker: ordinal, characters: characters)
        }
    }

    private func persist(_ segment: Segment, liveID: Int) {
        guard let store else { return }
        guard let meetingID else {
            sessionLostData = true
            lastError = String(localized: "A segment arrived without an open meeting and wasn’t saved.", comment: "Warning while recording")
            return
        }
        let previous = writes
        writes = Task {
            await previous?.value
            do {
                segmentRowIDs[liveID] = try await store.append(segment, to: meetingID)
            } catch {
                // A warning, not a failure: the recording goes on.
                sessionLostData = true
                lastError = saveFailure(String(localized: "A segment couldn’t be saved.", comment: "Warning while recording"), error)
            }
        }
    }

    // MARK: Speaker separation

    /// The diarizer of this recording. Its analysed windows are saved with the transcript, encrypted, so a recording
    /// that crashes can still have its speakers finalized at the next launch.
    func makeDiarizer(meetingID: Int64) -> Diarizer {
        let spool = WindowSpool()
        windowSpool = spool
        return Diarizer(windowSink: { [weak self] batch in
            spool.add(batch)
            Task { @MainActor in self?.saveSpooledWindows(meetingID: meetingID) }
        }, onDiagnostic: { [weak self] _ in
            // The models failed (the detail names no content and has nowhere to go): say that this recording has no speakers.
            Task { @MainActor in
                guard let self, self.meetingID == meetingID, self.lastError == nil else { return }
                self.lastError = String(localized: "Speakers couldn’t be told apart in this recording.", comment: "Warning while recording: speaker separation stopped working")
            }
        })
    }

    /// Queues what the diarizer produced since the last call behind the segment writes. Called again at stop, when
    /// the diarizer is done, so nothing is saved after the speakers are finalized (and then deleted).
    func saveSpooledWindows(meetingID: Int64) {
        // No diarizer: the recording was abandoned (or is over), so what is still spooled must not reach the store.
        guard diarizer != nil, self.meetingID == meetingID else { _ = windowSpool.take(); return }
        let batch = windowSpool.take()
        guard !batch.isEmpty, let store else { return }
        let previous = writes
        // A failure costs only the crash recovery of the speakers, never the transcript: nothing to report.
        writes = Task {
            await previous?.value
            try? await store.saveDiarizationWindows(batch, meetingID: meetingID)
        }
    }

    /// At stop: clusters every window, splits the segments where the speaker changes and writes the speakers. It
    /// runs after the last segment is saved and BEFORE the meeting is closed and analyzed, the late translations
    /// are stored and the minutes are written (see `SpeakerFinalizer`).
    func finalizeSpeakers(run: DiarizationRun?) async {
        guard diarizer != nil, let store, let id = meetingID else { return }
        var words: [Int64: [AlignableSegment.Run]] = [:]
        for live in segments where !live.segment.words.isEmpty {
            if let row = segmentRowIDs[live.id] { words[row] = live.segment.words }
        }
        let outcome = await SpeakerFinalizer.finalize(meetingID: id, in: store, run: run, wordRuns: words,
                                                     recognizeVoices: preferences.recognizesVoices)
        guard case .written = outcome else { return }
        // The names given while recording go to the voices they belong to; the labels shown may now read differently.
        if await carryOverLiveSpeakerNames(meetingID: id, store: store) {
            speakersUpdatedMeetingID = id
            speakersUpdated = true
        }
    }

    /// The button of the “Speakers updated” notice: the saved meeting's transcript, where the final names are.
    func checkSpeakers() {
        guard let id = speakersUpdatedMeetingID else { return }
        speakersUpdated = false
        Task {
            guard await authorizeHistory() else { return }
            history?.open(meeting: id, at: 0)
            showWindow("meetings")
        }
    }

    // MARK: Live notes

    /// Every 3 min or ~600 tokens of new text, never two at once.
    static let liveNotesInterval: TimeInterval = 180
    static let liveNotesChars = 2100

    /// Live notes from the fast model. They wait until the segment is saved (they cite its ID).
    private func considerLiveNotes() {
        guard phase == .recording, liveNotesTask == nil, noteExpansionTask == nil, !liveNotesWaitForNotes,
              let llm, let id = meetingID, llmStatus.configured else { return }
        let due = lastLiveNotes.map { ContinuousClock.now - $0 >= .seconds(Self.liveNotesInterval) } ?? true
        guard charsSinceLiveNotes >= Self.liveNotesChars || (due && charsSinceLiveNotes > 0) else { return }
        charsSinceLiveNotes = 0
        lastLiveNotes = .now
        let t = currentOffset
        let pending = writes
        let token = UUID()
        liveNotesToken = token
        liveNotesTask = Task {
            await pending?.value
            do {
                if let notes = try await llm.liveNotes(meetingID: id, at: t), meetingID == id {
                    append(Self.lines(of: notes))
                }
                liveNotesError = nil
            } catch {
                liveNotesError = Self.liveNotesNotice(for: error)
            }
            // Only the current task clears itself (an old one never overwrites a new one).
            if liveNotesToken == token { liveNotesTask = nil }
        }
    }

    /// A title and what to expect, never an error composed after a colon. A server that is slow, busy or not answering is
    /// "didn't answer" (the footer's "ready" is the last check, and the next try is automatic); any other error
    /// is said as the model's own sentence.
    static func liveNotesNotice(for error: Error) -> LiveNotesNotice {
        // Inside the "Live notes" card, whose heading already names them: the title says only the state.
        let title = String(localized: "Paused", comment: "Notice title inside the Live notes card of the panel: the notes stopped; the sentence under it says why")
        if let llm = error as? LLMError, llm.isRetryable {
            return LiveNotesNotice(title: title, detail: String(localized: "The model server didn’t answer. Vauta will try again.",
                                                                 comment: "Live notes notice, temporary: the model server was slow, busy or not answering; the next try is automatic"),
                                   serverDidNotAnswer: true)
        }
        return LiveNotesNotice(title: title, detail: error.localizedDescription)
    }

    private func append(_ lines: (points: [String], decisions: [String], tasks: [String])) {
        livePoints += lines.points
        liveDecisions += lines.decisions
        liveTasks += lines.tasks
    }

    private static func task(_ text: String, owner: String?) -> String {
        guard let owner, !owner.isEmpty else { return text }
        return String(localized: "\(text) (\(owner))", comment: "A live task and its owner")
    }

    static func lines(of notes: LiveNotesBatch) -> (points: [String], decisions: [String], tasks: [String]) {
        (notes.points.map(\.text), notes.decisions.map(\.text), notes.tasks.map { task($0.text, owner: $0.owner) })
    }
}

/// Why the live notes are paused: the title and, under it, what happened and what comes next.
struct LiveNotesNotice: Equatable {
    var title: String
    var detail: String
    /// The server was slow, busy or not answering: the panel's server status says so too, so the two never disagree.
    var serverDidNotAnswer = false
}
