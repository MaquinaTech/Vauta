// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension MeetingStore {
    /// Reads everything an export of the meeting needs. nil if the meeting no
    /// longer exists. Speaker names: the user's own name for "Me" (the self
    /// entity, unless it still has the default name) and the people the user
    /// said "Others" stands for. The translation is the one in `shownTranslation` (the language the transcript shows) when given,
    /// else the language with the most translated lines (`translationLanguage` wins a tie).
    public func meetingExport(_ meetingID: Int64, translationLanguage: String? = nil, shownTranslation: String? = nil) throws -> MeetingExport? {
        guard let meeting = try meeting(meetingID) else { return nil }
        let card = try card(meetingID)
        let attendees = try meetingEntities(meetingID, role: .attendee)
        let others = try meetingEntities(meetingID, role: .others)
        let selfID = try selfEntityID()
        var myName: String?
        if let selfID, let me = try entities(.person).first(where: { $0.id == selfID }),
           me.name != Self.legacySelfName {
            myName = me.name
        }
        let stored = try translations(of: meetingID)
        let translated = TranslationDisplay.chooseLanguage(from: stored, preferred: translationLanguage, chosen: shownTranslation)
        let translations = TranslationDisplay.texts(from: stored, preferred: translationLanguage, chosen: translated)
        let speakerRows = try speakers(of: meetingID)
        let othersName = others.isEmpty ? nil : others.map(\.displayName).joined(separator: ", ")
        return MeetingExport(
            title: meeting.displayTitle,
            startedAt: meeting.startedAt,
            endedAt: meeting.endedAt,
            language: meeting.locale,
            participantsInformedAt: try participantsInformedAt(meetingID),
            attendees: attendees.map(\.displayName),
            summary: card?.summary ?? "",
            topics: card?.topics ?? [],
            openQuestions: card?.openQuestions ?? [],
            decisions: try decisions(meetingID).map { MeetingExport.Item(text: $0.text, time: $0.t, unconfirmed: $0.unconfirmed) },
            tasks: try tasks(meetingID).map { t in
                MeetingExport.TaskEntry(text: t.text, owner: t.ownerName.map { Self.displayName($0, isSelf: t.ownerID == selfID) },
                                        due: t.due, status: t.status, time: t.t,
                                        unconfirmed: t.unconfirmed, ownerUncertain: t.ownerMarked)
            },
            notes: try noteRows(meetingID).map { row in
                MeetingExport.NoteEntry(text: row.note.text, time: row.note.t, expansion: row.isStale ? [] : row.visibleSentences.map {
                    MeetingExport.NoteEntry.Sentence(text: $0.text, times: $0.cites.map(\.t), segmentIDs: $0.cites.map(\.seg),
                                                     unconfirmed: $0.unconfirmed && row.expansion?.userEdited != true, differs: $0.differs)
                }, editedByUser: row.expansion?.userEdited == true)
            },
            transcript: try segments(of: meetingID).map { s in
                MeetingExport.Line(start: s.start, end: s.end, channel: s.channel,
                                   name: s.channel == .me ? myName : othersName, text: s.text,
                                   translation: translations[s.id], speaker: s.speaker, corrected: s.originalText != nil)
            },
            pauses: try pauses(of: meetingID),
            speakers: speakerRows.map {
                MeetingExport.Speaker(id: $0.id, channel: $0.channel, label: $0.stableLabel, name: $0.exportName, talkSeconds: $0.talkSeconds)
            },
            questions: try detectedQuestions(meetingID, keptOnly: true).compactMap { q in
                guard let answer = q.answer else { return nil }
                return MeetingExport.QuestionEntry(time: q.t, channel: q.channel, text: q.text, answer: answer.answer, sources: answer.exportSources())
            },
            translationLanguage: translations.isEmpty ? nil : translated)
    }
}
