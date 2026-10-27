// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import Foundation

/// Marks on the featured meeting's decisions and tasks for the UI snapshot renderer: what the interface shows when the
/// model's proposal does not match the passage it cites, or its owner is not confirmed. Invented; nothing is real.
extension SampleWorld {
    /// The first decision is unconfirmed; the first task is unconfirmed and its owner too; the second task's owner
    /// is not confirmed (when it has one). Everything else stays as the model proposed it.
    public func seedVerificationMarks() async throws {
        try await clearVerificationMarks()
        let decisions = try await store.decisions(featuredMeetingID)
        let tasks = try await store.tasks(featuredMeetingID)
        if let first = decisions.first { try await store.markForSnapshots(decision: first.id) }
        for (index, task) in tasks.enumerated().prefix(2) {
            try await store.markForSnapshots(task: task.id, unconfirmed: index == 0, ownerUncertain: true)
        }
    }

    /// What the Minutes tab shows for items that ranked out ("Other possible items"): every decision but the first and every task but the
    /// first are marked ranked out. `extra` adds that many more (up to nine invented ones, citing lines of the meeting that no sample decision or task cites), `long` adds a decision
    /// and a task that read as several lines, and `doubted` also marks the first decision as doubted by a check
    /// (the "Unconfirmed" mark), so the two kinds can be told apart.
    public func seedRankedOutItems(extra: Int = 0, long: Bool = false, doubted: Bool = false, uncertainOwner: Bool = false) async throws {
        try await clearVerificationMarks()
        let segments = try await store.segments(of: featuredMeetingID)
        let decisions = try await store.decisions(featuredMeetingID)
        let tasks = try await store.tasks(featuredMeetingID)
        // As the ranking stores them: most ranked-out items had also been doubted softly by the evidence check (`rank:<code>`).
        let soft = ["noAgreement", "tentative", "noCommitment"]
        func reason(_ index: Int) -> String { index % 3 == 0 ? UnconfirmedReason.rankedOut : UnconfirmedReason.rankedOut(after: soft[index % soft.count]) }
        for (index, decision) in decisions.dropFirst().enumerated() { try await store.markForSnapshots(decision: decision.id, reason: reason(index)) }
        for (index, task) in tasks.dropFirst().enumerated() { try await store.markForSnapshots(task: task.id, unconfirmed: true, ownerUncertain: uncertainOwner && task.ownerID != nil, reason: reason(index + 1)) }
        if doubted, let first = decisions.first { try await store.markForSnapshots(decision: first.id, reason: "figures") }
        // Invented items in the language being rendered, citing lines of the meeting that no sample decision or task cites (never a copy of a decision or a task
        // of the sample, nor an answer or a greeting).
        let language = locale.language.languageCode?.identifier ?? "en"
        func add(_ item: SampleRankedOutItem) async throws {
            let line = segments[min(item.segment, segments.count - 1)]
            try await store.addRankedOutForSnapshots(meeting: featuredMeetingID, segment: line.id, t: line.start, text: item.text, isTask: item.isTask)
        }
        for item in SampleRankedOut.items(for: language).prefix(extra) { try await add(item) }
        if long {
            let pair = SampleRankedOut.long(for: language)
            try await add(pair.decision)
            try await add(pair.task)
        }
    }

    /// The marks of `seedVerificationMarks`, with a person whose name does not fit the owner column owning the
    /// second task (and still not confirmed).
    public func seedLongOwnerName() async throws {
        try await seedVerificationMarks()
        let person = try await store.saveEntity(EntityDraft(kind: .person, name: speakerText.longName))
        guard let task = try await store.tasks(featuredMeetingID).dropFirst().first else { return }
        // Not `updateTask`: an edit would make it the user's task and drop the model's sparkle, which is exactly what
        // sits next to the mark in the width-critical text column.
        try await store.setOwnerForSnapshots(task: task.id, owner: person)
        try await store.markForSnapshots(task: task.id, unconfirmed: false, ownerUncertain: true)
    }

    /// The first task owned by a speaker nobody has named (the label "Speaker 2"), with the owner marked as not confirmed: what a plain "yes"
    /// from an unnamed speaker is stored as. The task itself is confirmed.
    public func seedSpeakerOwner() async throws {
        try await clearVerificationMarks()
        guard let first = try await store.tasks(featuredMeetingID).first else { return }
        let speaker = try await store.addSpeaker(meetingID: featuredMeetingID, channel: .others).speaker
        try await store.setSpeakerOwnerForSnapshots(task: first.id, speaker: speaker.id)
    }

    /// Every sample task back with the owner it was created with (deleting the long-named person left their task
    /// unowned, which showed as a dash in the next scene's task lists).
    public func restoreTaskOwners() async throws {
        for (index, meeting) in content.meetings.enumerated() where index < meetingIDs.count {
            let tasks = try await store.tasks(meetingIDs[index])
            for sample in meeting.tasks {
                guard let owner = sample.owner, owner < peopleIDs.count,
                      let task = tasks.first(where: { $0.text == sample.text }), task.ownerID != peopleIDs[owner] else { continue }
                try await store.setOwnerForSnapshots(task: task.id, owner: peopleIDs[owner])
            }
        }
    }

    /// Every sample meeting's minutes as the model wrote them: the card (summary, topics, open questions) with its source back to
    /// the model, and no task or decision that a scene added (the doubled tasks of the long email scene, a hand-written summary).
    public func restoreSampleMinutes() async throws {
        for (index, meeting) in content.meetings.enumerated() where index < meetingIDs.count {
            let id = meetingIDs[index]
            let tasks = Set(meeting.tasks.map(\.text)), decisions = Set(meeting.decisions.map(\.0))
            for task in try await store.tasks(id) where !tasks.contains(task.text) { try await store.deleteTask(task.id) }
            for decision in try await store.decisions(id) where !decisions.contains(decision.text) { try await store.deleteDecision(decision.id) }
            try await store.restoreCardForSnapshots(id, MeetingCard(summary: meeting.summary, topics: meeting.topics, openQuestions: meeting.questions))
        }
    }

    /// Back to the minutes as the model proposed them, with no marks.
    public func clearVerificationMarks() async throws {
        try await store.clearMarksForSnapshots()
    }
}

extension MeetingStore {
    func restoreCardForSnapshots(_ id: Int64, _ card: MeetingCard) async throws {
        try run("UPDATE meetings SET card = ?, card_source = 'llm' WHERE id = ?", [.text(try card.json()), .integer(id)])
        try await commitEdit()
    }

    func markForSnapshots(decision id: Int64, reason: String? = nil) async throws {
        try run("UPDATE decisions SET unconfirmed = 1, unconfirmed_reason = ? WHERE id = ?", [reason.map { .text($0) }, .integer(id)])
        try await commitEdit()
    }

    func markForSnapshots(task id: Int64, unconfirmed: Bool, ownerUncertain: Bool, reason: String? = nil) async throws {
        try run("UPDATE tasks SET unconfirmed = ?, owner_uncertain = ?, unconfirmed_reason = ? WHERE id = ?",
                [.integer(unconfirmed ? 1 : 0), .integer(ownerUncertain ? 1 : 0), unconfirmed ? reason.map { .text($0) } : nil, .integer(id)])
        try await commitEdit()
    }

    /// An invented ranked-out item. Its `created_at` of 0 is how `clearMarksForSnapshots` finds it again (no real row has it).
    func addRankedOutForSnapshots(meeting: Int64, segment: Int64, t: Double, text: String, isTask: Bool) async throws {
        if isTask {
            try run("INSERT INTO tasks(meeting_id, segment_id, t, text, source, created_at, unconfirmed, unconfirmed_reason) VALUES (?, ?, ?, ?, 'llm', 0, 1, 'rank')",
                    [.integer(meeting), .integer(segment), .real(t), .text(text)])
        } else {
            try run("INSERT INTO decisions(meeting_id, segment_id, t, text, source, created_at, unconfirmed, unconfirmed_reason) VALUES (?, ?, ?, ?, 'llm', 0, 1, 'rank')",
                    [.integer(meeting), .integer(segment), .real(t), .text(text)])
        }
        try await commitEdit()
    }

    func setSpeakerOwnerForSnapshots(task id: Int64, speaker: Int64) async throws {
        try run("UPDATE tasks SET owner_id = NULL, owner_speaker_id = ?, owner_uncertain = 1, unconfirmed = 0 WHERE id = ?", [.integer(speaker), .integer(id)])
        try syncOwnerEdge(id, nil)
        try await commitEdit()
    }

    func setOwnerForSnapshots(task id: Int64, owner: Int64) async throws {
        try run("UPDATE tasks SET owner_id = ? WHERE id = ?", [.integer(owner), .integer(id)])
        try syncOwnerEdge(id, owner)
        try await commitEdit()
    }

    func clearMarksForSnapshots() async throws {
        try run("DELETE FROM decisions WHERE created_at = 0")
        try run("DELETE FROM tasks WHERE created_at = 0")
        try run("UPDATE decisions SET unconfirmed = 0, unconfirmed_reason = NULL WHERE unconfirmed != 0 OR unconfirmed_reason IS NOT NULL")
        try run("UPDATE tasks SET unconfirmed = 0, unconfirmed_reason = NULL, owner_uncertain = 0, owner_speaker_id = NULL WHERE unconfirmed != 0 OR owner_uncertain != 0 OR owner_speaker_id IS NOT NULL")
        try await commitEdit()
    }
}
#endif
