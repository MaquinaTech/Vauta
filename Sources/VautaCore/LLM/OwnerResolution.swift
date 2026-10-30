// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Who the speakers of a meeting are, as far as the minutes may rely on it: which speaker is which person, and
/// which people the user named. It holds IDs only: no names, no scores, no voice data.
public struct SpeakerDirectory: Sendable, Equatable {
    /// The person a speaker row stands for; nil when nobody is named.
    private let people: [Int64: Int64]
    /// People named on at least one speaker of the meeting.
    public let namedPeople: Set<Int64>
    /// The speakers of the meeting by the key the transcript shows them under in the streaming layout ("speaker 2", "me 2"): the
    /// row, and the person when the speaker is named.
    private let keyed: [String: (id: Int64, entity: Int64?)]

    public static let empty = SpeakerDirectory(people: [:], namedPeople: [], keyed: [:])

    private init(people: [Int64: Int64], namedPeople: Set<Int64>, keyed: [String: (id: Int64, entity: Int64?)]) {
        self.people = people
        self.namedPeople = namedPeople
        self.keyed = keyed
    }

    public static func == (a: SpeakerDirectory, b: SpeakerDirectory) -> Bool {
        a.people == b.people && a.namedPeople == b.namedPeople && a.keyed.keys == b.keyed.keys
    }

    /// `selfEntity` is the person the user's own microphone stands for until the user says otherwise.
    public init(speakers: [MeetingSpeaker], selfEntity: Int64?) {
        var people: [Int64: Int64] = [:]
        var named = Set<Int64>()
        var keyed: [String: (id: Int64, entity: Int64?)] = [:]
        for speaker in speakers {
            let key = speaker.channel == .me ? (speaker.ordinal == 1 ? "me" : "me \(speaker.ordinal)") : "speaker \(speaker.ordinal)"
            keyed[key] = (speaker.id, speaker.name != nil ? speaker.entityID : nil)
            if speaker.name != nil, let entity = speaker.entityID {
                people[speaker.id] = entity
                named.insert(entity)
            } else if speaker.channel == .me, speaker.ordinal == 1, let selfEntity {
                people[speaker.id] = selfEntity
            }
        }
        self.people = people
        namedPeople = named
        self.keyed = keyed
    }

    /// The speaker a task owner written as a transcript label stands for: "Speaker 2", "Speaker 2 (remote)", "Me 2 (in the room)". nil for
    /// anything else (a name, "Me", null).
    func speaker(forKey text: String) -> (id: Int64, entity: Int64?)? {
        var key = TextKeys.norm(text)
        for suffix in [" remote", " in the room"] where key.hasSuffix(suffix) { key = String(key.dropLast(suffix.count)) }
        guard key.hasPrefix("speaker ") || (key.hasPrefix("me ") && key.dropFirst(3).allSatisfy(\.isNumber)) else { return nil }
        return keyed[key]
    }

    /// The speaker row of a segment's tag, when it has one.
    func speakerRow(of tag: SpeakerTag?) -> (id: Int64, entity: Int64?)? {
        guard let id = tag?.id else { return nil }
        return keyed.values.first { $0.id == id }
    }

    /// The person who said a segment and whether the label deserves trust: the speaker is mapped to a person, the
    /// line is not in crosstalk, its assignment is not below `SpeakerTag.lowConfidenceBelow`. `mixed`: the speaker's
    /// cluster probably holds a second voice (`SpeakerTag.mayBeAnotherVoice`), so the owner it gives is marked.
    func person(of tag: SpeakerTag?) -> (entity: Int64, confident: Bool, mixed: Bool)? {
        guard let tag, let id = tag.id, let entity = people[id] else { return nil }
        return (entity, !tag.isLowConfidence && !tag.overlap, tag.mayBeAnotherVoice)
    }
}

/// What the minutes keep as the owner of a task.
struct OwnerVerdict: Equatable {
    var owner: Int64?
    /// Nothing in the cited segment backs the owner (not the user on their own channel, not a confident label, not
    /// named in the words), or a confident speaker commits to something else in the same line: shown as "not
    /// confirmed". Applies to every meeting, with or without speaker data.
    var uncertain = false
    /// Set by the rule "a confident speaker says what they will do", not by the model.
    var deterministic = false
}

/// The owner of a task: decided by Swift from who said the cited segment where it can, otherwise the model's
/// proposal checked against the same evidence. Pure.
enum OwnerResolver {
    /// - Parameters:
    ///   - proposed: the owner the model named (already resolved to a person), if any.
    ///   - meetingPeople: attendees and people marked as Others in the meeting.
    static func resolve(proposed: Int64?, segment: CitableSegment, directory: SpeakerDirectory, selfEntity: Int64?,
                        byID: [Int64: CandidateEntity], meetingPeople: Set<Int64>) -> OwnerVerdict {
        let speaker = directory.person(of: segment.speaker)
        let segmentText = TextKeys.norm(segment.text)
        func names(_ entity: CandidateEntity) -> Bool {
            ([entity.name] + entity.aliases).map(TextKeys.norm).contains { name in
                name.count >= 2 && !MeetingStore.isSelfPronoun(name) && PromptText.containsNormalizedWords(segmentText, name)
            }
        }
        let named = proposed.flatMap { byID[$0] }.map(names) ?? false
        // 1. A confidently identified speaker who says what they will do owns it when the model agrees or gave no
        //    owner and the words name nobody else of the meeting ("Ana, send the deck and I'll review it" names Ana).
        //    When the model chose somebody else, its owner is kept (after the checks below) and marked: a line can
        //    hold two actions, and Swift cannot tell which one the task is. A speaker whose cluster holds two voices
        //    owns it too, marked: the line may be the other voice's.
        var disagrees = false
        if let speaker, speaker.confident, FirstPerson.commits(segment.text) {
            if proposed == speaker.entity {
                return OwnerVerdict(owner: speaker.entity, uncertain: speaker.mixed, deterministic: !speaker.mixed)
            }
            if proposed == nil {
                let others = Set(meetingPeople).union(directory.namedPeople).union(selfEntity.map { [$0] } ?? [])
                    .subtracting([speaker.entity])
                if !others.contains(where: { byID[$0].map(names) ?? false }) {
                    return OwnerVerdict(owner: speaker.entity, uncertain: speaker.mixed, deterministic: !speaker.mixed)
                }
            } else if !named {
                disagrees = true
            }
        }
        guard let owner = proposed else { return OwnerVerdict() }
        // 2. A label the system is unsure about never gives a task to anybody, unless the words name the owner.
        if let speaker, !speaker.confident, speaker.entity == owner, !named { return OwnerVerdict() }
        // A second voice on the user's microphone is somebody else: "Me" is not the answer unless the words say so.
        if owner == selfEntity, segment.channel == .me, let tag = segment.speaker, tag.ordinal > 1, speaker == nil, !named {
            return OwnerVerdict()
        }
        // 3. Somebody in the meeting, the user, or somebody the words name.
        if owner != selfEntity, !meetingPeople.contains(owner), !directory.namedPeople.contains(owner), !named {
            return OwnerVerdict()
        }
        // 4. Backed by a name in the words, by a confident label of one voice, or (the user) by their own channel.
        let backed = named
            || (speaker?.confident == true && speaker?.mixed == false && speaker?.entity == owner)
            || (owner == selfEntity && segment.channel == .me && (segment.speaker == nil || speaker?.entity == selfEntity && speaker?.confident == true))
        return OwnerVerdict(owner: owner, uncertain: !backed || disagrees)
    }
}

/// Whether a segment is somebody saying what they themselves will do ("I'll send it", "me encargo yo", "我来处理").
/// Words of the nine interface languages; a phrase list, not grammar. Questions and negations never count, so the
/// rule fails towards leaving the decision to the model and to the user.
enum FirstPerson {
    static func commits(_ text: String) -> Bool {
        if text.contains("?") || text.contains("？") { return false }
        let norm = TextKeys.norm(text)
        if DateWords.contains(norm, negations) { return false }
        return DateWords.contains(norm, phrases)
    }

    static let negations = [
        "not", "never", "can t", "won t", "don t", "cannot", "no", "nunca", "jamais", "pas", "nicht", "kein", "keine",
        "mai", "non", "nao", "ない", "ません", "できません", "必要", "べき", "お願い", "ください", "下さい", "부탁", "拜托", "请你", "請你", "않", "못", "不", "没", "別", "别",
    ]

    static let phrases = [
        // English
        "i ll", "i will", "i can take", "i can do", "i can handle", "i m going to", "i am going to",
        "i got it", "i take care", "i ll take", "i can send", "i can write", "i can prepare",
        // Spanish
        "me encargo", "lo hago", "lo hare", "me ocupo", "me hago cargo", "lo envio", "te lo envio",
        "te lo mando", "lo mando", "me pongo", "yo me encargo", "puedo encargarme",
        // French
        "je m en occupe", "je m occupe", "je vais le", "je vais vous", "je vais te", "je vais m", "je vais envoyer", "je vais preparer", "je vais faire", "je le fais", "je le ferai", "je ferai", "je t envoie", "je l envoie",
        "j envoie", "j enverrai", "je m en charge", "je me charge", "je prends", "je peux m en occuper",
        // German
        "ich mache", "ich kummere mich", "ich schicke", "ich werde", "ich ubernehme", "ich erledige", "ich sende",
        "mach ich", "mache ich", "schicke ich", "sende ich", "erledige ich", "ubernehme ich", "kummere ich mich", "ich kann das machen", "ich kann das ubernehmen", "ich ubernehm",
        // Italian
        "me ne occupo", "mi occupo", "lo faccio io", "ti mando", "lo mando", "lo faro", "faro io", "ci penso io", "lo preparo",
        "mi prendo", "me ne incarico", "penso io",
        // Portuguese (Brazil)
        "eu cuido", "eu faco", "vou enviar", "vou mandar", "eu mando", "eu envio", "eu resolvo",
        "me encarrego", "eu me encarrego", "fico responsavel", "fico encarregado", "fico com isso", "fico com essa tarefa", "cuido disso",
        // Japanese
        "やります", "引き受け", "担当します", "対応します", "私が担当", "私が対応します", "私がやり", "私がします", "私が送り", "私が確認します",
        "私が手配", "私が連絡します", "私が準備", "私が作成します", "僕がやり", "僕がします", "僕が送り", "僕が確認します", "僕が担当",
        "俺がやる", "俺がやり", "俺がします", "俺が担当",
        // Korean
        "제가 하겠", "제가 할게", "제가 처리", "제가 맡", "제가 보낼", "제가 진행", "하겠습니다", "할게요", "할게", "보낼게요", "맡을게요", "맡겠습니다", "드릴게요",
        // Chinese
        "我来", "我會", "我会", "我负责", "我負責", "我去处理", "我去办", "我去做", "我处理", "我處理", "我安排", "我跟进", "我跟進", "我准备", "我準備",
    ]
}
