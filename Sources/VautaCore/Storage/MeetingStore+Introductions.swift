// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension MeetingStore {
    /// Suggests ("Is this Ana?") a person for speakers from what was said, as a saved voice does: it never names a speaker. First the
    /// person a speaker said they are ("Hi, I'm Ana"; `SpeakerIntroductions`), then the person others spoke to by name when that speaker
    /// answered or had just spoken ("What do you think, Ana?", "Thanks, Ana"; `SpeakerAddresses`). A name counts only when it is a
    /// person of Context or invited to the meeting (`speakerNameKeys`), and a suggestion is made only for a speaker nobody named, that
    /// has no suggestion yet and is not the user's own microphone; never for a person the user gave to another speaker of the meeting,
    /// rejected for this meeting, or the user's own entity. A speaker who gives two different names, or a person two speakers say
    /// they are, is left alone. Returns how many speakers got a suggestion.
    @discardableResult
    public func suggestSpeakersFromTranscript(meetingID: Int64) async throws -> Int {
        let planned = try planSpeakerSuggestions(meetingID: meetingID)
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

    /// The suggestions to write: (speaker, person, line). The line is the one that gave the name: the speaker's own for an introduction,
    /// another speaker's for a name said to them.
    func planSpeakerSuggestions(meetingID: Int64) throws -> [(speaker: Int64, entity: Int64, segment: Int64)] {
        let speakers = try speakers(of: meetingID)
        let open = Set(speakers.filter { $0.source == .auto && $0.entityID == nil && !($0.channel == .me && $0.ordinal == 1) }.map(\.id))
        guard !open.isEmpty, let meeting = try meeting(meetingID) else { return [] }
        let languages = Array(Set([meeting.locale, meeting.outputLocale].compactMap { $0 } + ["en"]))
        let profile = LanguageProfile(locale: try meetingLocale(meetingID))
        let names = try speakerNameKeys(meetingID: meetingID, profile: profile)
        guard !names.people.isEmpty else { return [] }
        var excluded = Set(try db.query("SELECT entity_id FROM speaker_suggestion_rejections WHERE meeting_id = ?", [.integer(meetingID)]).map { $0.int(0) })
        excluded.formUnion(speakers.filter { $0.source != .auto }.compactMap(\.entityID))
        if let me = try selfEntityID() { excluded.insert(me) }
        let lines = try segments(of: meetingID)
        let introduced = introductions(in: lines, open: open, names: names, excluded: excluded, languages: languages)
        // What a speaker says of themselves comes first: a speaker or a person it took is not asked about again.
        let addressed = addresses(in: lines, open: open.subtracting(introduced.map(\.speaker)), names: names,
                                  excluded: excluded.union(introduced.map(\.entity)), languages: languages, profile: profile)
        return (introduced + addressed).sorted { $0.speaker < $1.speaker }
    }

    /// The speakers who said who they are: (speaker, person, line).
    func introductions(in lines: [StoredSegment], open: Set<Int64>, names: SpeakerNameKeys, excluded: Set<Int64>,
                       languages: [String]) -> [(speaker: Int64, entity: Int64, segment: Int64)] {
        var said: [Int64: [(entity: Int64, segment: Int64)]] = [:]
        for line in lines {
            guard let speaker = line.speaker?.id, open.contains(speaker) else { continue }
            for cue in SpeakerIntroductions.cues(in: line.text, languages: languages) {
                // The longest candidate that is exactly one person.
                guard let entity = cue.candidates.lazy.compactMap({ names.people[TextKeys.matchKey(TextKeys.norm($0))] })
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

    /// The names that may stand for a person in a meeting's transcript.
    struct SpeakerNameKeys {
        let matcher: NameMatcher<Int64>
        /// The people each key (`TextKeys.matchKey` of a normalized name) stands for; a key two people share names nobody.
        let people: [String: Set<Int64>]
    }

    /// Every name and alias of the people of Context and of the people invited to the meeting (calendar attendees, confirmed or not),
    /// and the short names of a longer name (`shortNames`, "Ana" for Ana García, as people are called in a meeting) when they are nobody
    /// else's name, or when only one of the people who have them was invited. The user's own names are in too, so a name said to the
    /// user is the user's.
    func speakerNameKeys(meetingID: Int64, profile: LanguageProfile) throws -> SpeakerNameKeys {
        let invited = Set(try db.query("SELECT entity_id FROM meeting_entities WHERE meeting_id = ? AND role = 'attendee'",
                                       [.integer(meetingID)]).map { $0.int(0) })
        let rows = try db.query("""
            SELECT e.id, e.name, 1 FROM entities e WHERE e.kind = 'person' AND e.merged_into IS NULL AND (e.confirmed = 1 OR e.id IN (SELECT value FROM json_each(?1)))
            UNION ALL
            SELECT e.id, a.alias, 0 FROM aliases a JOIN entities e ON e.id = a.entity_id
            WHERE e.kind = 'person' AND e.merged_into IS NULL AND (e.confirmed = 1 OR e.id IN (SELECT value FROM json_each(?1)))
            """, [.ids(Array(invited))])
        var people: [String: Set<Int64>] = [:]
        var given: [String: Set<Int64>] = [:]
        for row in rows {
            let key = TextKeys.matchKey(TextKeys.norm(row.string(1)))
            guard !key.isEmpty else { continue }
            people[key, default: []].insert(row.int(0))
            if row.int(2) == 1 {
                for short in Self.shortNames(of: row.string(1)) { given[TextKeys.matchKey(TextKeys.norm(short)), default: []].insert(row.int(0)) }
            }
        }
        for (key, ids) in given where people[key] == nil && !key.isEmpty {
            let guests = ids.intersection(invited)
            if ids.count == 1 { people[key] = ids } else if guests.count == 1 { people[key] = guests }
        }
        let matcher = NameMatcher(people.flatMap { key, ids in ids.map { (norm: key, value: $0) } }, profile: profile)
        return SpeakerNameKeys(matcher: matcher, people: people)
    }

    /// What a longer name is said as in a meeting: its first word ("Ana" for "Ana García", "Tanaka" for "Tanaka Aiko", after a title such
    /// as "Dr."), and the given name the system reads in it when that is another word (it reads "Ludvík Novák" family name first). None
    /// for a name in Han or Kana script, written without spaces, or for an email address.
    static func shortNames(of fullName: String) -> [String] {
        if fullName.contains("@") || fullName.unicodeScalars.contains(where: TextKeys.isNoSpaceScript) { return [] }
        var words = fullName.split(separator: " ").map(String.init)
        while words.count > 1, let first = words.first, first.hasSuffix("."), first.count <= 6 { words.removeFirst() }
        guard words.count >= 2 else { return [] }
        var out: [String] = []
        let first = words[0].trimmingCharacters(in: .punctuationCharacters)
        if first.count >= 2 { out.append(first) }
        if let given = givenName(of: fullName), !out.contains(given) { out.append(given) }
        return out
    }
}
