// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Who owns a task: decided from who said the cited segment where it can be, else the model's proposal checked.
@Suite("Minutes: owner resolution")
struct OwnerResolutionTests {
    static let me: Int64 = 1, ana: Int64 = 5, bruno: Int64 = 6, outsider: Int64 = 9
    static let candidates = [CandidateEntity(id: me, kind: .person, name: "Yo", aliases: []),
                             CandidateEntity(id: ana, kind: .person, name: "Ana Ruiz", aliases: ["Ana"]),
                             CandidateEntity(id: bruno, kind: .person, name: "Bruno", aliases: []),
                             CandidateEntity(id: outsider, kind: .person, name: "Olga", aliases: [])]
    static let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })

    /// Speakers: 100 = the user (mic), 101 = Others 1 named Ana, 102 = Others 2 unnamed, 103 = Others 3 named Bruno, 104 = Others 4 only suggested as Olga by a saved voice (not a name).
    static let directory = SpeakerDirectory(speakers: [
        MeetingSpeaker(id: 100, meetingID: 1, channel: .me, ordinal: 1),
        MeetingSpeaker(id: 101, meetingID: 1, channel: .others, ordinal: 1, entityID: ana, entityName: "Ana Ruiz", source: .user),
        MeetingSpeaker(id: 102, meetingID: 1, channel: .others, ordinal: 2),
        MeetingSpeaker(id: 103, meetingID: 1, channel: .others, ordinal: 3, entityID: bruno, entityName: "Bruno", source: .user),
        MeetingSpeaker(id: 104, meetingID: 1, channel: .others, ordinal: 4, entityID: outsider, entityName: "Olga", source: .suggested),
    ], selfEntity: me)

    private func segment(_ speaker: Int64, _ text: String, confidence: Double? = 0.9, overlap: Bool = false) -> CitableSegment {
        let channel: Channel = speaker == 100 ? .me : .others
        let tag = SpeakerTag(id: speaker, ordinal: Int(speaker - 100) + 1, confidence: confidence, overlap: overlap)
        return CitableSegment(id: 1, channel: channel, start: 0, text: text, speaker: tag)
    }

    private func resolve(_ proposed: Int64?, _ segment: CitableSegment, people: Set<Int64> = []) -> OwnerVerdict {
        OwnerResolver.resolve(proposed: proposed, segment: segment, directory: Self.directory, selfEntity: Self.me,
                              byID: Self.byID, meetingPeople: people)
    }

    @Test func aConfidentSpeakerWhoCommitsOwnsTheTaskTheModelLeftOpenOrGaveThem() {
        #expect(resolve(Self.ana, segment(101, "I'll send the report on Friday")) == OwnerVerdict(owner: Self.ana, uncertain: false, deterministic: true))
        #expect(resolve(nil, segment(101, "I'll send the report")) == OwnerVerdict(owner: Self.ana, uncertain: false, deterministic: true))
        // The user's own microphone is the user.
        #expect(resolve(nil, segment(100, "Yo me encargo del informe")).owner == Self.me)
        #expect(resolve(Self.me, segment(100, "Yo me encargo del informe")) == OwnerVerdict(owner: Self.me, uncertain: false, deterministic: true))
        // A suggestion from a saved voice is not a name: it never settles an owner.
        #expect(resolve(nil, segment(104, "Je m'en occupe demain")) == OwnerVerdict())
        #expect(resolve(Self.outsider, segment(104, "Je m'en occupe demain"), people: [Self.outsider]).deterministic == false)
        // Bruno was named by the user: a confident line of his owns the task.
        #expect(resolve(nil, segment(103, "Je m'en occupe demain")) == OwnerVerdict(owner: Self.bruno, uncertain: false, deterministic: true))
    }

    @Test func aDifferentOwnerFromTheModelIsKeptButMarked() {
        // A line can hold two actions: Swift does not know which one the task is, so the model's owner stays, marked.
        let other = resolve(Self.bruno, segment(101, "I'll send the report on Friday"), people: [Self.bruno])
        #expect(other == OwnerVerdict(owner: Self.bruno, uncertain: true, deterministic: false))
        // "You handle the invoices and I'll send the deck": the model's "Me" is the addressee, who is not named.
        let second = resolve(Self.me, segment(101, "You handle the invoices and I'll send the deck."))
        #expect(second.owner == Self.me && second.uncertain && !second.deterministic)
        let german = resolve(Self.me, segment(101, "Du kümmerst dich um die Rechnung und ich schicke das Angebot."))
        #expect(german.owner == Self.me && german.uncertain)
    }

    @Test func aRequestWithoutAnOwnerFromTheModelIsNotTheSpeakersCommitment() {
        // The model left the owner empty and the words name somebody else of the meeting.
        let request = segment(103, "Ana, send the deck and I'll review it")
        let v = resolve(nil, request, people: [Self.ana])
        #expect(v.owner == nil && !v.deterministic)
        // Naming the user by their name counts as well.
        let me = CandidateEntity(id: Self.me, kind: .person, name: "Maya", aliases: [])
        let byID = Self.byID.merging([Self.me: me]) { _, new in new }
        let named = OwnerResolver.resolve(proposed: nil, segment: segment(101, "Maya, send the deck and I'll review it"), directory: Self.directory,
                                          selfEntity: Self.me, byID: byID, meetingPeople: [])
        #expect(named.owner == nil)
        // Nobody else is named: the speaker owns it.
        #expect(resolve(nil, segment(101, "I'll review the deck"), people: [Self.bruno]).owner == Self.ana)
        #expect(resolve(nil, segment(104, "I'll review the deck"), people: [Self.ana]).owner == nil, "a suggestion is not a name")
    }

    @Test func statementsThatAreNotCommitmentsDoNotCount() {
        for text in ["私が確認したところ、問題ありません。", "誰かが対応する必要がある。", "僕が見たかぎりでは大丈夫です。",
                     "Eu fico com medo de errar.", "Eu fico preocupado com o prazo.", "Fico com a impressão de que atrasou.",
                     "私が思うに、これは難しい。"] {
            #expect(!FirstPerson.commits(text), "\(text)")
        }
        for text in ["私が確認します。", "僕が送ります。", "請求書は私が担当します。", "Eu fico responsável por isso.", "Fico com isso, pode deixar."] {
            #expect(FirstPerson.commits(text), "\(text)")
        }
    }

    @Test func commitmentsInTheNineLanguages() {
        let cases = ["I'll take care of the invoice", "Me encargo de la factura", "Je m'en occupe pour la facture",
                     "Ich kümmere mich um die Rechnung", "Me ne occupo io della fattura", "Eu cuido da fatura",
                     "請求書は私が対応します", "청구서는 제가 처리하겠습니다", "发票我来处理"]
        for text in cases {
            #expect(FirstPerson.commits(text), "\(text)")
        }
        for text in ["Can I send the invoice?", "I can't send the invoice", "Nobody sends the invoice", "The invoice is late",
                     "No me encargo yo de eso", "Ich schicke das nicht", "我不会处理发票",
                     "田中さん、資料の送付をお願いします。", "我去年做过这个项目。", "제가 보기에는 민수 씨가 하면 좋겠어요.",
                     "Il faro del porto è chiuso."] {
            #expect(!FirstPerson.commits(text), "\(text)")
        }
    }

    @Test func aRequestToSomebodyElseIsNotACommitmentOfTheSpeaker() {
        // The model named the addressee and the words name them too: the rule must not give the task to the speaker.
        let request = segment(100, "Ana, send the deck and I'll review it")
        let v = resolve(Self.ana, request, people: [Self.ana])
        #expect(v.owner == Self.ana && !v.deterministic)
        let japanese = segment(101, "田中さん、資料の送付をお願いします。")
        #expect(!FirstPerson.commits(japanese.text))
        // Without a proposal, a real commitment still goes to the confident speaker.
        #expect(resolve(nil, segment(101, "I'll send the deck")).owner == Self.ana)
    }

    @Test func aGuessedLabelNeverGivesATaskUnlessTheWordsNameTheOwner() {
        // Ana's label is unsure on this line: the model's "Ana" is dropped, and the rule does not fire either.
        let doubtful = segment(101, "I'll send the report on Friday", confidence: 0.4)
        #expect(resolve(Self.ana, doubtful, people: [Self.ana]).owner == nil)
        #expect(resolve(nil, doubtful).owner == nil)
        // Crosstalk is as doubtful as a low score.
        #expect(resolve(Self.ana, segment(101, "I'll send the report", overlap: true), people: [Self.ana]).owner == nil)
        // The words name Ana: allowed, and not marked.
        let named = segment(101, "Ana will send the report", confidence: 0.4)
        #expect(resolve(Self.ana, named) == OwnerVerdict(owner: Self.ana, uncertain: false, deterministic: false))
        // On the user's own channel, a doubtful label gives no owner either, unless the words name them.
        #expect(resolve(Self.me, segment(100, "I'll do it", confidence: 0.3)).owner == nil)
    }

    @Test func theModelsOwnerIsCheckedAgainstTheMeeting() {
        // Somebody the meeting does not have, not named in the words: dropped (as before speakers existed).
        #expect(resolve(Self.outsider, segment(102, "Somebody should send the report")).owner == nil)
        // Named in the words: kept even if they are not in the meeting.
        #expect(resolve(Self.outsider, segment(102, "Olga should send the report")).owner == Self.outsider)
        // A named speaker of the meeting is allowed without being an attendee.
        #expect(resolve(Self.bruno, segment(102, "Somebody should send the report")).owner == Self.bruno)
    }

    @Test func ownersTheSegmentDoesNotBackAreMarked() {
        let unbacked = resolve(Self.bruno, segment(102, "Somebody should send the report"))
        #expect(unbacked.owner == Self.bruno && unbacked.uncertain)
        let named = resolve(Self.bruno, segment(102, "Bruno should send the report"))
        #expect(!named.uncertain)
        // The model chose the confident speaker of the segment.
        let speaker = resolve(Self.ana, segment(101, "The report needs to go out"))
        #expect(speaker.owner == Self.ana && !speaker.uncertain)
        // The user, on their own channel, is backed; the user addressed by somebody else is not.
        #expect(!resolve(Self.me, segment(100, "The report needs to go out")).uncertain)
        #expect(resolve(Self.me, segment(101, "The report needs to go out")).uncertain)
    }

    @Test func theOwnerIsCheckedAgainstTheWordsInEveryMeeting() {
        func resolveWithout(_ owner: Int64, _ channel: Channel, _ text: String) -> OwnerVerdict {
            OwnerResolver.resolve(proposed: owner, segment: CitableSegment(id: 1, channel: channel, start: 0, text: text),
                                  directory: .empty, selfEntity: Self.me, byID: Self.byID, meetingPeople: [Self.ana, Self.bruno])
        }
        // An attendee the model picked for an "Others" line that never names them: kept, marked.
        let guessed = resolveWithout(Self.ana, .others, "I'll chase legal this week")
        #expect(guessed.owner == Self.ana && guessed.uncertain)
        // Named in the words: not marked. The user on their own channel: not marked.
        #expect(!resolveWithout(Self.ana, .others, "Ana, can you chase legal?").uncertain)
        #expect(!resolveWithout(Self.me, .me, "I'll chase legal").uncertain)
        // The user as the owner of what somebody else said is not backed.
        #expect(resolveWithout(Self.me, .others, "Somebody has to chase legal").uncertain)
    }

    @Test func meetingsWithoutSpeakerDataResolveAsBefore() {
        let plain = CitableSegment(id: 1, channel: .others, start: 0, text: "Ana, can you send the report?")
        let kept = OwnerResolver.resolve(proposed: Self.ana, segment: plain, directory: .empty, selfEntity: Self.me,
                                         byID: Self.byID, meetingPeople: [])
        #expect(kept == OwnerVerdict(owner: Self.ana, uncertain: false, deterministic: false))
        let dropped = OwnerResolver.resolve(proposed: Self.bruno, segment: plain, directory: .empty, selfEntity: Self.me,
                                            byID: Self.byID, meetingPeople: [])
        #expect(dropped.owner == nil)
        let mine = CitableSegment(id: 2, channel: .me, start: 0, text: "I'll do it")
        #expect(OwnerResolver.resolve(proposed: nil, segment: mine, directory: .empty, selfEntity: Self.me,
                                      byID: Self.byID, meetingPeople: []).owner == nil, "no speaker data, no deterministic owner")
    }

    @Test func validateMinutesAppliesTheRulesToTheModelsJSON() throws {
        let segments: [Int64: CitableSegment] = [
            1: CitableSegment(id: 1, channel: .others, start: 5, text: "I'll send the Kobaltix report on Friday",
                              speaker: SpeakerTag(id: 101, ordinal: 1, name: "Ana Ruiz", confidence: 0.92)),
            2: CitableSegment(id: 2, channel: .others, start: 9, text: "I'll prepare the 40 slides for Monday",
                              speaker: SpeakerTag(id: 103, ordinal: 3, name: "Bruno", confidence: 0.3)),
        ]
        let json = """
            {"title": "t", "summary": "s", "topics": [], "decisions": [], "entities": [], "open_questions": [],
             "tasks": [{"text": "Send the report", "owner": "Bruno", "due": "2026-10-09", "seg": 1, "quote": "send the Kobaltix report"},
                       {"text": "Prepare 40 slides", "owner": "Bruno", "due": "2026-10-12", "seg": 2, "quote": "prepare the 40 slides"}]}
            """
        let minutes = try VautaPrompts.validateMinutes(json, segments: segments, candidates: Self.candidates, selfEntity: Self.me,
                                                   meetingPeople: [Self.bruno], directory: Self.directory,
                                                   reference: Date(timeIntervalSince1970: 1_791_354_600))
        #expect(minutes.tasks.count == 2)
        #expect(minutes.tasks[0].owner == Self.bruno && minutes.tasks[0].ownerUncertain,
                "the model chose Bruno for what Ana said she would do: kept, and marked")
        #expect(minutes.tasks[1].owner == nil, "Bruno's label is below the threshold on that line")
    }

    @Test func withoutSpeakersAnOwnerTheWordsDoNotNameIsMarkedInTheMinutes() throws {
        let segments: [Int64: CitableSegment] = [
            1: CitableSegment(id: 1, channel: .others, start: 5, text: "I'll chase legal about the Kobaltix contract"),
            2: CitableSegment(id: 2, channel: .others, start: 9, text: "Bruno, please send the Kobaltix contract"),
        ]
        let json = """
            {"title": "t", "summary": "s", "topics": [], "decisions": [], "entities": [], "open_questions": [],
             "tasks": [{"text": "Chase legal", "owner": "Bruno", "seg": 1, "quote": "chase legal about the Kobaltix"},
                       {"text": "Send the contract", "owner": "Bruno", "seg": 2, "quote": "send the Kobaltix contract"}]}
            """
        let minutes = try VautaPrompts.validateMinutes(json, segments: segments, candidates: Self.candidates, selfEntity: Self.me,
                                                       meetingPeople: [Self.bruno])
        #expect(minutes.tasks.map(\.owner) == [Self.bruno, Self.bruno])
        #expect(minutes.tasks.map(\.ownerUncertain) == [true, false], "only the owner the words name is backed")
    }
}
