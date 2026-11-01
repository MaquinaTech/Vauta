// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension MeetingStore {
    /// How far apart, in seconds, a name said to someone and the turn it points to may be.
    static let addressReach = 10.0

    /// The speakers others spoke to by name (`SpeakerAddresses`): (speaker, person, line). A question or a handover points to the first
    /// turn of another speaker that starts after the name was said, thanks to the turn before, within `addressReach` seconds; a turn
    /// whose speaker is a guess or may be another voice points nowhere, and so does a line whose own speaker is a guess. A person counts only when the turns agree: at least twice
    /// as many point to one speaker as to any other ("What about you, Hugo?" answered by one speaker and "Hugo, could you…?" by
    /// another give nothing). A speaker two people won is left alone, and only an open speaker gets a suggestion.
    func addresses(in lines: [StoredSegment], open: Set<Int64>, names: SpeakerNameKeys, excluded: Set<Int64>, languages: [String],
                   profile: LanguageProfile) -> [(speaker: Int64, entity: Int64, segment: Int64)] {
        guard !open.isEmpty, !names.matcher.isEmpty else { return [] }
        // Each person's turns: the speaker they point to, with the lines that say it.
        var votes: [Int64: [Int64: [Int64]]] = [:]
        for (i, line) in lines.enumerated() {
            guard let own = line.speaker, let speaker = own.id, !own.isDoubtful else { continue }
            let matches = names.matcher.matches(in: line.text, tokens: TextKeys.tokens(line.text, profile: profile), profile: profile)
            guard !matches.isEmpty else { continue }
            for address in SpeakerAddresses.addresses(in: line.text, names: matches.map(\.range), languages: languages) {
                guard let match = matches.first(where: { $0.range == address.range }), Set(match.values).count == 1,
                      let entity = match.values.first else { continue }
                let turn: StoredSegment?
                switch address.turn {
                case .next:
                    // The answer starts after the name is said, which a long line says late ("…, so where would we move David? Do
                    // you have any preferences, David?"): when, read in proportion to the characters, give or take a tenth of the line.
                    let said = line.start + (line.end - line.start) * Double(line.text.distance(from: line.text.startIndex, to: address.range.upperBound))
                        / Double(max(line.text.count, 1))
                    let earliest = said - max(2, (line.end - line.start) / 10)
                    turn = lines[(i + 1)...].first { $0.speaker?.id != nil && $0.speaker?.id != speaker && $0.start >= earliest }
                        .flatMap { $0.start <= line.end + Self.addressReach ? $0 : nil }
                case .previous:
                    turn = lines[..<i].last { $0.speaker?.id != nil && $0.speaker?.id != speaker }
                        .flatMap { $0.end >= line.start - Self.addressReach ? $0 : nil }
                }
                guard let tag = turn?.speaker, let to = tag.id, !tag.isDoubtful, !tag.mayBeAnotherVoice else { continue }
                votes[entity, default: [:]][to, default: []].append(line.id)
            }
        }
        var won: [Int64: [(entity: Int64, segment: Int64)]] = [:]
        for (entity, bySpeaker) in votes {
            let ranked = bySpeaker.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            guard let top = ranked.first, top.value.count >= 2 * (ranked.dropFirst().first?.value.count ?? 0) else { continue }
            won[top.key, default: []].append((entity, top.value[0]))
        }
        return won.compactMap { speaker, people -> (speaker: Int64, entity: Int64, segment: Int64)? in
            guard people.count == 1, let pick = people.first, open.contains(speaker), !excluded.contains(pick.entity) else { return nil }
            return (speaker, pick.entity, pick.segment)
        }.sorted { $0.speaker < $1.speaker }
    }
}
