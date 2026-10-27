// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension MeetingStore {
    /// The stored fields of a meeting's follow-up email (nothing is generated). Tasks with no meeting never appear. Owners are named
    /// people only: a speaker nobody named has no name here, and the self entity keeps the name the person gave it (with the default
    /// "Me" stand-in the task is marked as the sender's own, and the email writes it in the first person).
    public func followUpEmailInput(_ meetingID: Int64, nextMeeting: FollowUpEmailInput.NextMeeting? = nil) throws -> FollowUpEmailInput? {
        guard let meeting = try meeting(meetingID) else { return nil }
        let selfID = try selfEntityID()
        let people = try entities(.person)
        let byID = Dictionary(uniqueKeysWithValues: people.map { ($0.id, $0) })
        let zone = try meetingTimeZone(meetingID) ?? .current
        let card = try card(meetingID)
        let meetingDay = DueDay.containing(meeting.startedAt, in: zone)
        let tasks = try tasks(meetingID).map { t -> FollowUpEmailInput.Task in
            var name: String?
            var email: String?
            var isSender = false
            if let owner = t.ownerID, let person = byID[owner] {
                isSender = owner == selfID && person.name == Self.legacySelfName
                name = isSender ? nil : person.name
                email = person.email
            }
            return FollowUpEmailInput.Task(id: t.id, text: t.text, ownerID: name == nil ? nil : t.ownerID, ownerName: name, ownerEmail: email,
                                           ownerUncertain: t.ownerMarked, ownerIsSender: isSender, unconfirmed: t.unconfirmed, dueDay: t.dueDay.flatMap { $0.isPlausible(meetingDay: meetingDay) ? $0 : nil }, status: t.status)
        }
        return FollowUpEmailInput(
            meetingTitle: meeting.displayTitle, meetingStart: meeting.startedAt, timeZone: zone,
            decisions: try decisions(meetingID).map { .init(text: $0.text, unconfirmed: $0.unconfirmed) }, tasks: tasks,
            openQuestions: card?.openQuestions ?? [], summary: card?.summary ?? "", transcript: try segments(of: meetingID).map(\.text),
            people: people.map { CandidateEntity(id: $0.id, kind: $0.kind, name: $0.name, aliases: $0.aliases) }, nextMeeting: nextMeeting)
    }

    /// The addresses the email could go to: the attendees' stored addresses, none ticked.
    public func followUpRecipients(_ meetingID: Int64) throws -> EmailRecipients {
        let selfID = try selfEntityID()
        let selfEntity = try selfID.flatMap { id in try entities(.person).first { $0.id == id } }
        return FollowUpRecipients.candidates(attendees: try meetingEntities(meetingID, role: .attendee), selfEntity: selfEntity)
    }
}
