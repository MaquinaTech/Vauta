// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// The owner of a task from the clause that holds the quote and the lines around it, never from the model's label.
@Suite("Minutes: owner inference")
struct OwnerInferenceTests {
    static let me: Int64 = 1, ana: Int64 = 5
    static let people = [CandidateEntity(id: me, kind: .person, name: "Maya", aliases: []),
                         CandidateEntity(id: ana, kind: .person, name: "Ana Ruiz", aliases: ["Ana"])]

    /// 100 = the user's microphone, 101 = Others 1 (named Ana), 102 and 103 = Others 2 and 3 (nobody named).
    static let directory = SpeakerDirectory(speakers: [
        MeetingSpeaker(id: 100, meetingID: 1, channel: .me, ordinal: 1),
        MeetingSpeaker(id: 101, meetingID: 1, channel: .others, ordinal: 1, entityID: ana, entityName: "Ana Ruiz", source: .user),
        MeetingSpeaker(id: 102, meetingID: 1, channel: .others, ordinal: 2),
        MeetingSpeaker(id: 103, meetingID: 1, channel: .others, ordinal: 3),
    ], selfEntity: me)

    static func line(_ id: Int64, _ speaker: Int64, _ text: String, at t: Double? = nil, confidence: Double? = 0.9, overlap: Bool = false) -> CitableSegment {
        CitableSegment(id: id, channel: speaker == 100 ? .me : .others, start: t ?? Double(id) * 10, text: text,
                       speaker: SpeakerTag(id: speaker, ordinal: Int(speaker - 100) + 1, confidence: confidence, overlap: overlap))
    }

    static func infer(_ lines: [CitableSegment], cite: Int64, item: String, quote: String? = nil, hint: OwnerInference.Hint = .init(), language: String = "en") -> OwnerInference.Result {
        let order = SegmentOrder(lines)
        let seg = lines.first { $0.id == cite }!
        return OwnerInference.infer(text: item, quote: quote ?? item, segment: seg, order: order, directory: directory, selfEntity: me, people: people,
                                    meetingPeople: [ana], hint: hint, language: language)
    }

    @Test func aCommitmentInTheClauseIsTheSpeakersEvenWhenAQuestionFollowsInTheSameTurn() {
        let lines = [Self.line(1, 102, "But yeah I'll work on it. Um I was wondering about the budget?")]
        let r = Self.infer(lines, cite: 1, item: "Work on it", quote: "I'll work on it")
        #expect(r.rule == "self" && r.owner == nil && r.ownerSpeaker == 102 && !r.uncertain)
    }

    @Test func aCommitmentAboutAnotherActionInTheTurnIsNotTheTasks() {
        let lines = [Self.line(1, 102, "I will put the minutes in the folder; the Industrial Designer will do the components concept.")]
        let r = Self.infer(lines, cite: 1, item: "Components concept", quote: "the Industrial Designer will do the components concept")
        #expect(r.owner == nil && r.ownerSpeaker == nil && !r.uncertain, "a role: nobody in particular, and the role stays in the text")
        #expect(r.rule == "role")
        let own = Self.infer(lines, cite: 1, item: "Put the minutes in the folder", quote: "I will put the minutes in the folder")
        #expect(own.rule == "self" && own.ownerSpeaker == 102)
    }

    @Test func theAddresseeWhoCommitsOwnsTheTaskNotTheAsker() {
        let lines = [Self.line(1, 102, "Can you look into the company logo?"), Self.line(2, 103, "Yeah I'll do that.")]
        let r = Self.infer(lines, cite: 1, item: "Look into the company logo")
        #expect(r.rule == "addressee" && r.ownerSpeaker == 103 && !r.uncertain)
    }

    @Test func aCommitmentToAnotherActionIsNotTheAnswerToTheRequest() {
        let item = "Look into the company logo"
        // A commitment about something else is nobody accepting the logo.
        let alone = [Self.line(1, 102, "Can you look into the company logo?"), Self.line(2, 103, "I'll send the minutes tonight.")]
        let none = Self.infer(alone, cite: 1, item: item)
        #expect(none.owner == nil && none.ownerSpeaker == nil && none.rule != "addressee", "the unrelated commitment gives nobody the logo")
        // A weak yes from the addressee and an unrelated "I'll" from a third speaker: the yes is the answer, and the owner is uncertain.
        let both = [Self.line(1, 102, "Can you look into the company logo?"), Self.line(2, 103, "Yeah."), Self.line(3, 100, "I'll send the minutes tonight.")]
        let weak = Self.infer(both, cite: 1, item: item)
        #expect(weak.rule == "addresseeWeak" && weak.ownerSpeaker == 103 && weak.uncertain)
        // The unrelated commitment first, the yes after it: still the yes.
        let reversed = [Self.line(1, 102, "Can you look into the company logo?"), Self.line(2, 100, "I'll send the minutes tonight."), Self.line(3, 103, "Yeah.")]
        let again = Self.infer(reversed, cite: 1, item: item)
        #expect(again.rule == "addresseeWeak" && again.ownerSpeaker == 103 && again.uncertain)
    }

    @Test func aCommitmentThatIsAboutTheItemOrBareStillAnswersIt() {
        // Bare acceptances, English and Spanish.
        for (request, reply, language) in [("Can you look into the company logo?", "Will do.", "en"), ("Can you look into the company logo?", "Sure, I can.", "en"),
                                           ("Can you look into the company logo?", "I'll do it tomorrow.", "en"), ("¿Puedes revisar el logotipo de la empresa?", "Me encargo.", "es"),
                                           ("¿Puedes revisar el logotipo de la empresa?", "Lo hago yo.", "es")] {
            let r = Self.infer([Self.line(1, 102, request), Self.line(2, 103, reply)], cite: 1, item: language == "en" ? "Look into the company logo" : "Revisar el logotipo de la empresa", language: language)
            #expect(r.rule == "addressee" && r.ownerSpeaker == 103 && !r.uncertain, "\(reply)")
        }
        // Words about the item.
        let about = Self.infer([Self.line(1, 102, "Can you send the deck to the board?"), Self.line(2, 103, "Sure, I'll send the deck to them on Friday.")], cite: 1, item: "Send the deck to the board")
        #expect(about.rule == "addressee" && about.ownerSpeaker == 103)
    }

    @Test func aPlainYesGivesAnUncertainOwner() {
        let lines = [Self.line(1, 102, "Can you look into the company logo?"), Self.line(2, 103, "Yeah.")]
        let r = Self.infer(lines, cite: 1, item: "Look into the company logo")
        #expect(r.rule == "addresseeWeak" && r.ownerSpeaker == 103 && r.uncertain)
    }

    @Test func theCitedLineThatIsTheYesGetsTheOwnerUncertainToo() {
        let lines = [Self.line(1, 102, "Can you look into the company logo?"), Self.line(2, 103, "Okay.")]
        let r = Self.infer(lines, cite: 2, item: "Look into the company logo", quote: "Okay")
        #expect(r.rule == "addresseeWeak" && r.ownerSpeaker == 103 && r.uncertain)
    }

    @Test func twoAnswerersAreNoOwner() {
        let lines = [Self.line(1, 102, "Can you look into the company logo?"), Self.line(2, 103, "Yeah I'll do that."), Self.line(3, 100, "Yes I can take that.")]
        let r = Self.infer(lines, cite: 1, item: "Look into the company logo", hint: .init(speaker: 103))
        #expect(r.owner == nil && r.ownerSpeaker == nil && r.uncertain, "two people said yes: nobody, and the model named someone")
    }

    @Test func aCallForVolunteersGoesToWhoeverCommits() {
        let lines = [Self.line(1, 102, "Who wants to take the notes today?"), Self.line(2, 103, "Mm."), Self.line(3, 101, "I'll do it.")]
        let r = Self.infer(lines, cite: 1, item: "Take the notes")
        #expect(r.rule == "volunteer" && r.owner == Self.ana && !r.uncertain, "Ana is a named speaker: the person")
    }

    @Test func aNamePersonOfTheMeetingAsTheAddresseeIsCertain() {
        let lines = [Self.line(1, 102, "Ana, can you send the deck?")]
        let r = Self.infer(lines, cite: 1, item: "Send the deck")
        #expect(r.rule == "named" && r.owner == Self.ana && !r.uncertain)
        let will = Self.infer([Self.line(1, 102, "Ana will send the deck.")], cite: 1, item: "Send the deck")
        #expect(will.rule == "named" && will.owner == Self.ana)
    }

    @Test func theAskerIsNeverTheOwner() {
        // Nobody answers: the asker (102) must not get the task, and the model's guess is not used.
        let lines = [Self.line(1, 102, "Can you look into the company logo?"), Self.line(2, 102, "Right, the logo.")]
        let r = Self.infer(lines, cite: 1, item: "Look into the company logo", hint: .init(speaker: 102))
        #expect(r.owner == nil && r.ownerSpeaker == nil && r.uncertain)
    }

    @Test func aLowConfidenceOrOverlappedLabelNeverGivesATask() {
        let doubtful = [Self.line(1, 102, "I'll send the numbers.", confidence: 0.2)]
        let r = Self.infer(doubtful, cite: 1, item: "Send the numbers", hint: .init(speaker: 102))
        #expect(r.owner == nil && r.ownerSpeaker == nil && r.uncertain)
        let overlapped = [Self.line(1, 102, "I'll send the numbers.", overlap: true)]
        #expect(Self.infer(overlapped, cite: 1, item: "Send the numbers").ownerSpeaker == nil)
    }

    @Test func meOnALineThatIsNotTheUsersWithoutACommitmentIsNobody() {
        let lines = [Self.line(1, 102, "We should send the numbers by Friday.")]
        let r = Self.infer(lines, cite: 1, item: "Send the numbers", hint: .init(entity: Self.me))
        #expect(r.owner == nil && r.ownerSpeaker == nil)
        #expect(r.rule == "group")
    }

    @Test func theUsersOwnLineWithACommitmentIsTheUser() {
        let r = Self.infer([Self.line(1, 100, "Yo me encargo del informe.")], cite: 1, item: "Preparar el informe", language: "es")
        #expect(r.rule == "self" && r.owner == Self.me && !r.uncertain)
    }

    @Test func aThirdPartyInSpanishAndAGroupObligationAreNoOwnerAndNotUncertain() {
        let third = Self.infer([Self.line(1, 102, "Que el ejecutivo envíe un informe.")], cite: 1, item: "Enviar un informe", hint: .init(speaker: 102), language: "es")
        #expect(third.rule == "role" && third.owner == nil && third.ownerSpeaker == nil && !third.uncertain)
        let group = Self.infer([Self.line(1, 102, "Tenemos que preparar el informe.")], cite: 1, item: "Preparar el informe", hint: .init(speaker: 102), language: "es")
        #expect(group.rule == "group" && group.owner == nil && !group.uncertain)
    }

    @Test func anExchangeEndsAtAGap() {
        let lines = [Self.line(1, 102, "Can you look into the company logo?", at: 0), Self.line(2, 103, "Yeah I'll do that.", at: 200)]
        let r = Self.infer(lines, cite: 1, item: "Look into the company logo", hint: .init(speaker: 103))
        #expect(r.ownerSpeaker == nil && r.uncertain, "the answer came too late to be one")
    }

    @Test func theLinesAroundACitedSegmentAreFoundInOrder() {
        let order = SegmentOrder([Self.line(3, 102, "c"), Self.line(1, 102, "a"), Self.line(2, 102, "b"), Self.line(4, 102, "d", at: 500)])
        #expect(order.previous(of: 2)?.id == 1)
        #expect(order.following(1, count: 3).map(\.id) == [2, 3])
        #expect(order.following(3).isEmpty)
    }

    // MARK: Through validateMinutes

    @Test func validateMinutesDecidesTheOwnerFromTheTranscriptNotFromTheModel() throws {
        let lines = [Self.line(1, 102, "Can you look into the company logo?"), Self.line(2, 103, "Yeah I'll do that.")]
        let json = """
            {"decisions": [], "tasks": [{"text": "Look into the company logo", "owner": "Me", "owner_id": 1, "due": null, "seg": 1, "quote": "look into the company logo"}]}
            """
        let byID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        let legacy = try VautaPrompts.validateMinutes(json, segments: byID, candidates: Self.people, selfEntity: Self.me, meetingPeople: [Self.ana], directory: Self.directory)
        #expect(legacy.tasks.first?.owner != nil || legacy.tasks.first?.ownerSpeaker != nil || legacy.counts["task.ownerMeUnbacked"] == 1)
        let shipped = try VautaPrompts.validateMinutes(json, segments: byID, candidates: Self.people, selfEntity: Self.me, meetingPeople: [Self.ana], directory: Self.directory,
                                                       extraction: .owners)
        let task = try #require(shipped.tasks.first)
        #expect(task.owner == nil && task.ownerSpeaker == 103 && !task.ownerUncertain)
        #expect(shipped.counts["owner.addressee"] == 1 && shipped.counts["task.ownerMeUnbacked"] == 1)
    }

    @Test func theSpeakerWhoSaysIllLetOrAskSomeoneOwnsTheTask() {
        for (line, item) in [("I'll let Ana know the date.", "Let Ana know the date"), ("I'll ask Ana about the budget.", "Ask Ana about the budget"),
                             ("Ana can't make it, so I'll send the deck.", "Send the deck")] {
            let r = Self.infer([Self.line(1, 102, line)], cite: 1, item: item)
            #expect(r.rule == "self" && r.ownerSpeaker == 102 && r.owner == nil, "\(line) -> \(r.rule)")
        }
        let imperative = Self.infer([Self.line(1, 102, "Ask Ana to send the deck.")], cite: 1, item: "Send the deck")
        #expect(imperative.rule == "named" && imperative.owner == Self.ana)
    }

    @Test func aPlainYesFromAnUnnamedSpeakerIsAMarkedSpeakerOwner() {
        let lines = [Self.line(1, 102, "Can you look into the company logo?"), Self.line(2, 103, "Yeah.")]
        let r = Self.infer(lines, cite: 1, item: "Look into the company logo")
        #expect(r.rule == "addresseeWeak" && r.owner == nil && r.ownerSpeaker == 103 && r.uncertain)
        var task = TaskItem(id: 1, meetingID: 1, segmentID: 1, t: 0, text: "x", ownerID: nil, ownerName: "Speaker 3", due: nil, status: .open, source: "llm", createdAt: .now, meetingTitle: nil)
        task.ownerUncertain = true
        task.ownerSpeakerID = 103
        #expect(task.ownerMarked)
        task.ownerUncertain = false
        #expect(!task.ownerMarked)
    }

    // MARK: Refusals and subjects of other actions

    @Test func aRefusedRequestToANamedPersonHasNoOwner() {
        let lines = [Self.line(1, 102, "Ana, can you send the budget?"), Self.line(2, 101, "Sorry, I can't this week.")]
        let r = Self.infer(lines, cite: 1, item: "Send the budget", hint: .init(entity: Self.ana))
        #expect(r.rule == "refused" && r.owner == nil && r.ownerSpeaker == nil && r.uncertain)
        let accepted = Self.infer([lines[0], Self.line(2, 101, "Sure, I'll send it.")], cite: 1, item: "Send the budget")
        #expect(accepted.rule == "named" && accepted.owner == Self.ana)
        // Somebody else's "no" is not Ana's answer.
        let other = Self.infer([lines[0], Self.line(2, 100, "No, the other one is late.")], cite: 1, item: "Send the budget")
        #expect(other.rule == "named" && other.owner == Self.ana, "the user is a different known person: their no is not Ana's answer")
    }

    @Test func aRefusedRequestToAnUnnamedSpeakerHasNoOwner() {
        let lines = [Self.line(1, 102, "Can you look into the company logo?"), Self.line(2, 103, "No, I can't do that.")]
        let r = Self.infer(lines, cite: 1, item: "Look into the company logo")
        #expect(r.rule == "refused" && r.ownerSpeaker == nil && r.owner == nil)
        let spanish = Self.infer([Self.line(1, 102, "¿Puedes revisar el logo?"), Self.line(2, 103, "Lo siento, no puedo esta semana.")], cite: 1, item: "Revisar el logo", language: "es")
        #expect(spanish.rule == "refused" && spanish.ownerSpeaker == nil)
    }

    @Test func yeahNoIsARefusalNotAWeakYes() {
        #expect(!OwnerInference.isWeakAcceptance("Yeah, no, I can't do that."))
        #expect(!OwnerInference.isWeakAcceptance("Si no llego, aviso."))
        #expect(OwnerInference.isWeakAcceptance("Yeah, no problem."))
        let lines = [Self.line(1, 102, "Can you look into the company logo?"), Self.line(2, 103, "Yeah, no, I can't do that.")]
        let r = Self.infer(lines, cite: 1, item: "Look into the company logo")
        #expect(r.ownerSpeaker == nil && r.rule != "addresseeWeak")
        let cited = Self.infer(lines, cite: 2, item: "Look into the company logo", quote: "Yeah, no, I can't do that")
        #expect(cited.ownerSpeaker == nil)
    }

    @Test func aPersonWhoIsTheSubjectOfAnotherActionDoesNotGetTheTask() {
        let r = Self.infer([Self.line(1, 102, "Ana will be away next week, so I'll send the deck.")], cite: 1, item: "Send the deck")
        #expect(r.rule == "self" && r.ownerSpeaker == 102 && r.owner == nil)
        let spanish = Self.infer([Self.line(1, 102, "Ana va a estar fuera la semana que viene, pero yo me encargo del informe.")], cite: 1, item: "Enviar el informe", language: "es")
        #expect(spanish.rule == "self" && spanish.ownerSpeaker == 102)
        // The modal that is about the item still hands it over.
        let will = Self.infer([Self.line(1, 102, "Ana will send the deck by Friday.")], cite: 1, item: "Send the deck")
        #expect(will.rule == "named" && will.owner == Self.ana)
        let bare = Self.infer([Self.line(1, 102, "Ana can do it.")], cite: 1, item: "Send the deck")
        #expect(bare.rule == "named" && bare.owner == Self.ana)
    }
}
