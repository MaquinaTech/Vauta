// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension MeetingStore {
    /// Suggests ("Is this Ana?") the person a speaker said they are ("Hi, I'm Ana"; `SpeakerIntroductions`), as a saved voice does: it
    /// never names a speaker. A name counts only when it is a person of Context (by name or alias), and a suggestion is made only for a
    /// speaker nobody named, that has no suggestion yet and is not the user's own microphone; never for a person the user gave to
    /// another speaker of the meeting, rejected for this meeting, or the user's own entity. A speaker who gives two different names, or
    /// a person two speakers say they are, is left alone. Returns how many speakers got a suggestion.
    @discardableResult
    public func suggestSpeakersFromIntroductions(meetingID: Int64) async throws -> Int {
        let planned = try planIntroductions(meetingID: meetingID)
        guard !planned.isEmpty else { return 0 }
        try transaction {
            for (speaker, entity, segment) in planned {
                try run("""
                    UPDATE meeting_speakers SET entity_id = ?2, source = 'suggested', suggested_by_segment = ?3
                    WHERE id = ?1 AND source = 'auto' AND entity_id IS NULL
                    """, [.integer(speaker), .integer(entity), .integer(segment)])
            }
        }
        try await commitEdit()
        return planned.count
    }

    /// The suggestions to write: (speaker, person, line).
    func planIntroductions(meetingID: Int64) throws -> [(speaker: Int64, entity: Int64, segment: Int64)] {
        let speakers = try speakers(of: meetingID)
        let open = Dictionary(uniqueKeysWithValues: speakers.filter { speaker in
            speaker.source == .auto && speaker.entityID == nil && !(speaker.channel == .me && speaker.ordinal == 1)
        }.map { ($0.id, $0) })
        guard !open.isEmpty, let meeting = try meeting(meetingID) else { return [] }
        let languages = Array(Set([meeting.locale, meeting.outputLocale].compactMap { $0 } + ["en"]))
        // People of Context by every name they go by; a key two people share names nobody.
        var people: [String: Set<Int64>] = [:]
        for row in try db.query("""
            SELECT e.id, e.name FROM entities e WHERE e.kind = 'person' AND e.merged_into IS NULL AND e.confirmed = 1
            UNION ALL
            SELECT e.id, a.alias FROM aliases a JOIN entities e ON e.id = a.entity_id
            WHERE e.kind = 'person' AND e.merged_into IS NULL AND e.confirmed = 1
            """) {
            let key = TextKeys.matchKey(TextKeys.norm(row.string(1)))
            if !key.isEmpty { people[key, default: []].insert(row.int(0)) }
        }
        var excluded = Set(try db.query("SELECT entity_id FROM speaker_suggestion_rejections WHERE meeting_id = ?", [.integer(meetingID)]).map { $0.int(0) })
        excluded.formUnion(speakers.filter { $0.source != .auto }.compactMap(\.entityID))
        if let me = try selfEntityID() { excluded.insert(me) }

        var said: [Int64: [(entity: Int64, segment: Int64)]] = [:]
        for line in try segments(of: meetingID) {
            guard let speaker = line.speaker?.id, open[speaker] != nil else { continue }
            for cue in SpeakerIntroductions.cues(in: line.text, languages: languages) {
                // The longest candidate that is exactly one person.
                guard let entity = cue.candidates.lazy.compactMap({ people[TextKeys.matchKey(TextKeys.norm($0))] })
                    .first(where: { $0.count == 1 })?.first, !excluded.contains(entity) else { continue }
                said[speaker, default: []].append((entity, line.id))
            }
        }
        // One person per speaker, one speaker per person.
        var bySpeaker: [Int64: (entity: Int64, segment: Int64)] = [:]
        for (speaker, cues) in said where Set(cues.map(\.entity)).count == 1 { bySpeaker[speaker] = cues[0] }
        var speakersOf: [Int64: Int] = [:]
        for (_, cue) in bySpeaker { speakersOf[cue.entity, default: 0] += 1 }
        return bySpeaker.filter { speakersOf[$0.value.entity] == 1 }.sorted { $0.key < $1.key }.map { ($0.key, $0.value.entity, $0.value.segment) }
    }
}
