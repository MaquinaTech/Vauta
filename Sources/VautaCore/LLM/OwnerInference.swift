// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The meeting's segments in order, with the position of each, for the checks that look at the lines around a cited one.
struct SegmentOrder {
    let segments: [CitableSegment]
    private let position: [Int64: Int]
    /// Two segments further apart than this (seconds between their starts) are not one exchange.
    static let exchangeGap = 90.0

    init(_ segments: [CitableSegment]) {
        let sorted = segments.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        self.segments = sorted
        position = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1.id, $0) })
    }

    func index(of id: Int64) -> Int? { position[id] }

    func segment(_ id: Int64) -> CitableSegment? { position[id].map { segments[$0] } }

    func previous(of id: Int64) -> CitableSegment? {
        guard let i = position[id], i > 0, segments[i].start - segments[i - 1].start <= Self.exchangeGap else { return nil }
        return segments[i - 1]
    }

    /// Up to `count` segments after `id`, stopping at a gap.
    func following(_ id: Int64, count: Int = 3) -> [CitableSegment] {
        guard let i = position[id] else { return [] }
        var out: [CitableSegment] = []
        var last = segments[i]
        for s in segments.dropFirst(i + 1).prefix(count) {
            if s.start - last.start > Self.exchangeGap { break }
            out.append(s)
            last = s
        }
        return out
    }
}

/// Who said a segment, as far as the minutes may rely on it.
struct Voice: Equatable {
    /// Stable within a meeting: the person's entity, the speaker row, or "user".
    var key: String
    var entity: Int64?
    /// The `meeting_speakers` row, when the segment has speaker data.
    var speaker: Int64?
    /// The label deserves trust: not below `SpeakerTag.lowConfidenceBelow`, not crosstalk.
    var confident: Bool
    /// The speaker's cluster probably holds a second voice (`SpeakerTag.mayBeAnotherVoice`): an owner this voice gives is marked.
    var mixed = false
}

extension SpeakerDirectory {
    func voice(of segment: CitableSegment, selfEntity: Int64?) -> Voice? {
        let row = speakerRow(of: segment.speaker)
        if VautaPrompts.lineIsTheUsers(segment, directory: self, selfEntity: selfEntity ?? -1) {
            return Voice(key: "user", entity: selfEntity, speaker: row?.id ?? segment.speaker?.id, confident: true,
                         mixed: segment.speaker?.mayBeAnotherVoice ?? false)
        }
        guard let tag = segment.speaker, let id = tag.id else { return nil }
        let person = self.person(of: tag)
        let entity = person?.entity
        return Voice(key: entity.map { "e\($0)" } ?? "s\(id)", entity: entity, speaker: row?.id ?? id, confident: !tag.isLowConfidence && !tag.overlap,
                     mixed: tag.mayBeAnotherVoice)
    }
}

/// The owner of a task from the transcript: the clause that holds the quote and the lines around it, never the model's label (the
/// model's owner is a hint). Order, first match wins; the design is in docs/LANGUAGE_MODEL.md. A missed cue leaves the task without an
/// owner (marked "not confirmed" when the model named someone); it never gives the task to the person who asked or to whoever spoke
/// the cited line without a commitment.
enum OwnerInference {
    struct Result: Equatable {
        var owner: Int64?
        /// A speaker nobody has named yet (`owner` is nil).
        var ownerSpeaker: Int64?
        var uncertain = false
        /// The rule that decided: "named", "self", "addressee", "addresseeWeak", "volunteer", "role", "group", "ambiguous", "refused", "hint", "withheld".
        var rule: String
        var deterministic: Bool { ["named", "self", "addressee", "volunteer"].contains(rule) }
    }

    /// What the model proposed, already resolved: a person, or a speaker of the transcript. `named` = the model proposed something other
    /// than the user on a line that is not the user's (that "Me" is not a proposal).
    struct Hint {
        var entity: Int64?
        var speaker: Int64?
        var proposed: Bool { entity != nil || speaker != nil }
    }

    static func infer(text: String, quote: String, segment: CitableSegment, order: SegmentOrder, directory: SpeakerDirectory, selfEntity: Int64?,
                      people: [CandidateEntity], meetingPeople: Set<Int64>, hint: Hint, language: String?) -> Result {
        let itemText = text
        let (index, clauses) = ItemCues.evidenceClause(item: itemText, quote: quote, in: segment.text, language: language)
        let clause = clauses[index]
        let text = ItemCues.Text(clause)
        let voice = directory.voice(of: segment, selfEntity: selfEntity)
        let followers = order.following(segment.id)
        /// What an answer must be about to count as the answer: the item and the clause that holds the request.
        let about = ItemCues.contentWords(itemText + " " + clause, language: language)
        // An owner given by who spoke is marked when that speaker's cluster holds two voices.
        func result(_ v: Voice, rule: String, uncertain: Bool = false) -> Result {
            if let entity = v.entity { return Result(owner: entity, ownerSpeaker: nil, uncertain: uncertain || v.mixed, rule: rule) }
            return Result(owner: nil, ownerSpeaker: v.speaker, uncertain: uncertain || v.mixed, rule: rule)
        }
        func withheld(_ rule: String = "withheld") -> Result { Result(owner: nil, ownerSpeaker: nil, uncertain: hint.proposed, rule: rule) }

        // 1. A person of the meeting named as the one who will do it ("Ana, can you…", "Ana will send…", "que Ana se encargue").
        let known = meetingPeople.union(directory.namedPeople).union(selfEntity.map { [$0] } ?? [])
        let voiceOf: (CitableSegment) -> Voice? = { directory.voice(of: $0, selfEntity: selfEntity) }
        if let named = namedAssignee(in: clause, item: itemText, people: people.filter { known.contains($0.id) && $0.id != selfEntity }) {
            // The first answer from somebody else refuses ("Sorry, I can't this week"): the request was not accepted.
            if refusedAnswer(after: followers, asker: voice, addressee: named, voiceOf: voiceOf) { return withheld("refused") }
            return Result(owner: named, ownerSpeaker: nil, uncertain: false, rule: "named")
        }
        let selfCommits = ItemCues.commits(clause)
        let thirdParty = ItemCues.thirdPartySubject(clause)
        // 2. Self-commitment in the clause, said by a confident speaker.
        if selfCommits, !thirdParty {
            if let voice, voice.confident { return result(voice, rule: "self") }
            return withheld()
        }
        if selfCommits, thirdParty { return withheld("ambiguous") }
        // 3. A request answered by somebody else.
        if text.has(ItemCues.request) || (ItemCues.vocative(clause) && ItemCues.isQuestion(clause)) {
            if refusedAnswer(after: followers, asker: voice, addressee: nil, voiceOf: voiceOf) { return withheld("refused") }
            if let voice, let answer = answerer(after: followers, asker: voice, directory: directory, selfEntity: selfEntity, committing: true, about: (about, language)) {
                switch answer {
                case .committed(let v): return v.confident ? result(v, rule: "addressee") : withheld()
                case .weak(let v): return v.confident ? result(v, rule: "addresseeWeak", uncertain: true) : withheld()
                case .none: break
                case .several: return withheld()
                }
            }
            if voice == nil, let answer = answerer(after: followers, asker: nil, directory: directory, selfEntity: selfEntity, committing: true, about: (about, language)) {
                if case .committed(let v) = answer, v.confident { return result(v, rule: "addressee") }
            }
        }
        // 3b. The cited line is a weak "yes" to the request just before it.
        if isWeakAcceptance(clause), let before = order.previous(of: segment.id), let voice, let asker = directory.voice(of: before, selfEntity: selfEntity),
           asker.key != voice.key, ItemCues.clauses(before.text).last.map({ ItemCues.Text($0).has(ItemCues.request) }) == true {
            return voice.confident ? result(voice, rule: "addresseeWeak", uncertain: true) : withheld()
        }
        // 4. A call for volunteers answered by somebody who commits.
        if text.has(ItemCues.volunteerCall) {
            if let answer = answerer(after: followers, asker: voice, directory: directory, selfEntity: selfEntity, committing: false, about: (about, language)), case .committed(let v) = answer, v.confident {
                return result(v, rule: "volunteer")
            }
            return withheld()
        }
        // 5. A role or somebody else; 6. the group: nobody in particular.
        if thirdParty { return Result(owner: nil, ownerSpeaker: nil, uncertain: false, rule: "role") }
        if text.has(ItemCues.groupObligation) { return Result(owner: nil, ownerSpeaker: nil, uncertain: false, rule: "group") }
        // 7. Anything else: the model's person only if the words name them; otherwise nobody.
        if let entity = hint.entity, entity != selfEntity, known.contains(entity),
           let person = people.first(where: { $0.id == entity }), names(person, in: clause) {
            return Result(owner: entity, ownerSpeaker: nil, uncertain: true, rule: "hint")
        }
        return withheld()
    }

    // MARK: Rule helpers

    private enum Answer {
        case committed(Voice), weak(Voice), none, several
    }

    /// Who answers a request or a call for volunteers within the next lines: the first voice other than the asker that commits (or, for a
    /// request, says a plain "yes"). Two different voices answering is `several`.
    private static func answerer(after followers: [CitableSegment], asker: Voice?, directory: SpeakerDirectory, selfEntity: Int64?, committing: Bool, about: (words: Set<String>, language: String?)) -> Answer? {
        var committed: [Voice] = [], weak: [Voice] = []
        for s in followers {
            guard let v = directory.voice(of: s, selfEntity: selfEntity) else { continue }
            if let asker, v.key == asker.key { continue }
            let clauses = ItemCues.clauses(s.text)
            if clauses.contains(where: { ItemCues.answersRequest($0, reference: about.words, language: about.language) }) {
                if !committed.contains(where: { $0.key == v.key }) { committed.append(v) }
            } else if committing, isWeakAcceptance(s.text), !clauses.contains(where: { ItemCues.isQuestion($0) }) {
                if !weak.contains(where: { $0.key == v.key }) { weak.append(v) }
            }
        }
        if committed.count > 1 { return .several }
        if let one = committed.first { return .committed(one) }
        if weak.count > 1 { return .several }
        if let one = weak.first { return .weak(one) }
        return Answer.none
    }

    /// Whether the first answer to a request, from a voice other than the asker's, refuses it. With an `addressee`, a voice that is a different
    /// known person is not answering for them. Lines with no voice (no speaker data) are skipped: nobody can be told apart there.
    static func refusedAnswer(after followers: [CitableSegment], asker: Voice?, addressee: Int64?, voiceOf: (CitableSegment) -> Voice?) -> Bool {
        for s in followers {
            guard let v = voiceOf(s) else { continue }
            if let asker, v.key == asker.key { continue }
            if let addressee, let entity = v.entity, entity != addressee { continue }
            return ItemCues.refuses(s.text)
        }
        return false
    }

    /// A short plain "yes" (no commitment in it, no refusal): see `ItemCues.isWeakYes`.
    static func isWeakAcceptance(_ text: String) -> Bool { ItemCues.isWeakYes(text) }

    /// The words after a name that opens the clause run up to the speaker's own commitment ("… and I'll review it") or the end of the
    /// clause, and the item is about them (it shares a word of four letters or more with that stretch).
    private static func imperativeBeforeSelf(_ words: [String], after start: Int, item: String) -> Bool {
        guard start < words.count else { return false }
        var end = words.count
        for (i, w) in words.enumerated() where i >= start && ["ll", "will", "voy", "me", "je", "ich"].contains(w) && i > 0 && ["i", "and", "y", "et", "und", "yo"].contains(words[i - 1]) { end = i - 1; break }
        let stretch = Set(words[start..<max(start, end)].filter { $0.count >= 4 })
        guard stretch.count >= 2 else { return false }
        let wanted = Set(QuoteKey.make(item).filter { $0.count >= 4 })
        return !stretch.isDisjoint(with: wanted)
    }

    private static let subjectModals: [[String]] = ["will", "is going to", "can", "could", "should", "needs to", "has to", "must", "va a", "puede", "debe", "tiene que",
                                                    "se encarga", "se encargara", "se ocupa", "enviara", "will take", "to take"].map { $0.split(separator: " ").map(String.init) }
    private static let stretchEnds: Set<String> = ["so", "but", "pero", "mais", "aber", "mas", "ma", "entonces", "i", "yo", "je", "ich", "io", "eu"]

    /// A modal in the four words after a name ("Ana will…") makes the person the owner only when what follows it is the item: the content
    /// words after the modal, up to the speaker's own clause ("so I'll…"), share a word with the item. "Ana will be away next week, so I'll
    /// send the deck" is about Ana's week, not about the deck. A stretch with no content word ("Ana will do it") has nothing to contradict.
    private static func subjectOfTheItem(_ words: [String], from start: Int, item: String) -> Bool {
        let tail = Array(words.dropFirst(start))
        var modalEnd: Int?
        search: for i in 0..<min(4, tail.count) {
            for modal in subjectModals where i + modal.count <= min(4, tail.count) && Array(tail[i..<(i + modal.count)]) == modal {
                modalEnd = i + modal.count
                break search
            }
        }
        guard let modalEnd else { return false }
        let stretch = tail.dropFirst(modalEnd).prefix { !stretchEnds.contains($0) }.filter { $0.count >= 4 }
        guard !stretch.isEmpty else { return true }
        let wanted = Set(QuoteKey.make(item).filter { $0.count >= 4 })
        return !Set(stretch).isDisjoint(with: wanted)
    }

    private static func names(_ person: CandidateEntity, in clause: String) -> Bool {
        let norm = TextKeys.norm(clause)
        return ([person.name] + person.aliases).map(TextKeys.norm).contains { name in
            name.count >= 2 && !MeetingStore.isSelfPronoun(name) && PromptText.containsNormalizedWords(norm, name)
        }
    }

    /// The person the clause hands the task to: named as the addressee ("Ana, can you…"), as the subject of a modal ("Ana will send…")
    /// or after "que"/"let"/"ask" in a request. nil when no person is named that way (or two are).
    private static func namedAssignee(in clause: String, item: String, people: [CandidateEntity]) -> Int64? {
        let words = TextKeys.norm(clause).split(separator: " ").map(String.init)
        var found = Set<Int64>()
        for person in people {
            for name in ([person.name] + person.aliases).map(TextKeys.norm) where name.count >= 2 && !MeetingStore.isSelfPronoun(name) {
                let parts = name.split(separator: " ").map(String.init)
                guard let at = (0...max(0, words.count - parts.count)).first(where: { $0 + parts.count <= words.count && Array(words[$0..<($0 + parts.count)]) == parts }) else { continue }
                let after = words.dropFirst(at + parts.count).prefix(4).joined(separator: " ")
                let before = words.prefix(at).suffix(2).joined(separator: " ")
                // "Bruno, send the deck to the board and I'll review it": a name opening the clause hands over what comes before the speaker's own
                // commitment, if the item is about that.
                let beforeSelf = imperativeBeforeSelf(words, after: at + parts.count, item: item)
                let vocative = at <= 1 && (ItemCues.Text(clause).has(ItemCues.request) || beforeSelf)
                // "Ana can't make it, so I'll send the deck": a negated modal hands nothing over.
                let afterTokens = after.split(separator: " ").prefix(3)
                let negated = afterTokens.contains { ["t", "not", "never", "no", "cannot"].contains($0) }
                let subject = !negated && subjectOfTheItem(words, from: at + parts.count, item: item)
                // "Ask Ana to…", "Let Ana handle…", "que Ana se encargue": the imperative form only. "I'll let Ana know", "I'll ask Ana" are the
                // speaker's own commitment.
                let firstPerson: Set<String> = ["i", "ll", "we", "me", "my", "yo", "voy", "je", "ich", "io", "eu", "i'll"]
                let handed = !words.prefix(at).contains(where: { firstPerson.contains($0) })
                    && DateWords.contains(before, ["que", "let", "ask", "tell", "dile a", "pidele a", "pedile a", "asking"])
                if vocative || subject || handed { found.insert(person.id) }
            }
        }
        return found.count == 1 ? found.first : nil
    }
}
