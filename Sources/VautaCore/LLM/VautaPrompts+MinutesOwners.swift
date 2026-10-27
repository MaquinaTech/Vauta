// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension VautaPrompts {
    /// What the owner of a task is decided from.
    struct OwnerContext {
        let directory: SpeakerDirectory
        let selfEntity: Int64?
        let people: [CandidateEntity]
        let byID: [Int64: CandidateEntity]
        let selfNames: Set<String>
        let meetingPeople: Set<Int64>
        /// The meeting's segments in order (nil in the legacy path, which reads only the cited one).
        let order: SegmentOrder?
        let language: String?
        /// The owner comes from the clause and the lines around it (`OwnerInference`), not from the model's label.
        let owners: Bool
    }

    /// The owner of a task the model listed, and the speaker when the owner is somebody nobody has named yet.
    static func taskOwner(_ t: RawMinutes.Task, segment seg: CitableSegment, context c: OwnerContext, counts: inout [String: Int]) -> (verdict: OwnerVerdict, speaker: Int64?) {
        var proposed: Int64?
        var ownerSpeaker: Int64?
        if let id = t.ownerID, c.byID[id]?.kind == .person { proposed = id }
        else if let name = t.owner {
            // The owner written as a speaker label of the transcript ("Speaker 2"): the speaker, and the person if they are named.
            if let speaker = c.directory.speaker(forKey: name) {
                if let entity = speaker.entity { proposed = entity } else { ownerSpeaker = speaker.id }
            } else {
                proposed = resolvePerson(name, people: c.people, selfEntity: c.selfEntity, selfNames: c.selfNames)
            }
        }
        if c.owners, let order = c.order {
            // "Me" on a line that is not the user's is not a proposal: nobody is named.
            if let me = c.selfEntity, proposed == me, !lineIsTheUsers(seg, directory: c.directory, selfEntity: me) {
                proposed = nil
                counts["task.ownerMeUnbacked", default: 0] += 1
            }
            let found = OwnerInference.infer(text: t.text ?? "", quote: t.quote ?? "", segment: seg, order: order, directory: c.directory, selfEntity: c.selfEntity,
                                             people: c.people, meetingPeople: c.meetingPeople,
                                             hint: .init(entity: proposed, speaker: ownerSpeaker), language: c.language)
            counts["owner.\(found.rule)", default: 0] += 1
            return (OwnerVerdict(owner: found.owner, uncertain: found.uncertain, deterministic: found.deterministic), found.owner == nil ? found.ownerSpeaker : nil)
        }
        // "Me" on a line that is not the user's own: the speaker owns it if they commit in the first person, else nobody does.
        if let me = c.selfEntity, proposed == me, !lineIsTheUsers(seg, directory: c.directory, selfEntity: me) {
            if FirstPerson.commits(seg.text), let row = c.directory.speakerRow(of: seg.speaker) {
                if let entity = row.entity { proposed = entity } else { proposed = nil; ownerSpeaker = row.id }
            } else {
                proposed = nil
                counts["task.ownerMeUnbacked", default: 0] += 1
            }
        }
        var verdict = OwnerResolver.resolve(proposed: proposed, segment: seg, directory: c.directory, selfEntity: c.selfEntity,
                                            byID: c.byID, meetingPeople: c.meetingPeople)
        if proposed == nil, let ownerSpeaker {
            let row = c.directory.speakerRow(of: seg.speaker)
            let confident = seg.speaker.map { !$0.isLowConfidence && !$0.overlap } ?? false
            verdict = OwnerVerdict(owner: nil, uncertain: !(row?.id == ownerSpeaker && confident), deterministic: false)
        }
        return (verdict, ownerSpeaker)
    }
}
