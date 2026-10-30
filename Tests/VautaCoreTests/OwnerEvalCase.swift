// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
@testable import VautaCore

/// One invented meeting of the offline owner-accuracy evaluation, with what the model "answered" for it.
///
/// No model is involved: `baseline` is what a model that only sees "Me" and "Others" would plausibly answer for
/// this meeting, and `withSpeakers` what it would plausibly answer when every line carries a speaker label. Both are
/// written by hand and recorded here, so the evaluation measures the part that is code (the labels in the prompt, the
/// deterministic owner rules and the verification) given those answers. It does not measure a real model.
/// Everything here is invented: the people, the companies and the sentences.
struct OwnerEvalCase {
    struct Speaker {
        let channel: Channel
        /// The person the user named; nil = "Speaker k" or "Me 2".
        let person: String?
        /// The spread of the speaker's voice cluster as the diarizer measured it; nil = not measured (as before schema 32).
        var voiceSpread: Float?
    }

    struct Line {
        /// Index into `speakers`.
        let speaker: Int
        /// The diarizer's confidence for the line.
        let confidence: Double
        let overlap: Bool
        let text: String
        /// The speaker the diarizer wrongly assigned, when it got the line wrong (same channel as `speaker`).
        let labeled: Int?

        init(_ speaker: Int, _ confidence: Double, _ text: String, overlap: Bool = false, labeled: Int? = nil) {
            self.labeled = labeled
            self.speaker = speaker
            self.confidence = confidence
            self.overlap = overlap
            self.text = text
        }
    }

    /// The truth for a task: who owns it. "Me" = the user, a name, or nil = nobody the meeting identifies.
    struct Gold {
        let line: Int
        let owner: String?
    }

    /// A task as the model returned it.
    struct Output {
        let text: String
        let line: Int
        /// The owner exactly as the model wrote it ("Me", a name, nil).
        let owner: String?
        let quote: String
        let due: String?

        init(_ text: String, line: Int, owner: String?, quote: String, due: String? = nil) {
            self.text = text
            self.line = line
            self.owner = owner
            self.quote = quote
            self.due = due
        }
    }

    let id: String
    let locale: String
    /// The people of the meeting besides the user. All of them are attendees.
    let people: [String]
    /// Speakers by index; index 0 is always the user.
    let speakers: [Speaker]
    let lines: [Line]
    let gold: [Gold]
    let baseline: [Output]
    let withSpeakers: [Output]
    /// Tasks that look right but plant a wrong figure, date or name: the verification must mark them. They are
    /// returned unchanged in both arms and are not part of the owner score.
    let planted: [Output]
}

extension OwnerEvalCase {
    static let me = Speaker(channel: .me, person: nil)
    static func remote(_ person: String?, voiceSpread: Float? = nil) -> Speaker { Speaker(channel: .others, person: person, voiceSpread: voiceSpread) }
    static let roomVoice = Speaker(channel: .me, person: nil)
}
