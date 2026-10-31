// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// A question that goes on from the one before ("And who owns it?"): a control under the question reads it together with the earlier
/// one (`AskFollowUp`). On when the question reads as going on, off but there to turn on otherwise; changing it asks again. Nothing of it
/// is stored: it lives until Ask is cleared or the window is locked.
extension AskModel {
    /// The question in the field, as `ask()` reads it.
    private var currentQuestion: String { SingleLineText.flatten(question).trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The question before, offered under the question: for the question on screen, the one it was asked after; for a new
    /// question, the last one asked. None before the first question, or with an empty field.
    var offeredFollowUp: AskFollowUp? {
        let current = currentQuestion
        guard !current.isEmpty else { return nil }
        return current == answeredQuestion ? answeredFollowUp : followUp
    }

    /// Whether the question is read after the one before.
    var usesFollowUp: Bool {
        guard offeredFollowUp != nil else { return false }
        if let choice = followUpChoice, choice.question == currentQuestion { return choice.on }
        return followUpSuggested
    }

    /// Turns the control on or off for this question; the time and place carried over follow, and the answer on screen, if it is
    /// this question's, is asked again.
    func chooseFollowUp(_ on: Bool) {
        followUpChoice = (currentQuestion, on)
        readQuestion()
        askAgainIfAnswered()
    }

    /// The text the field's question is read as: after the question before when it follows up.
    var readingOfQuestion: String {
        guard usesFollowUp, let thread = offeredFollowUp else { return question }
        return thread.reading(question)
    }

    /// The words marked in the passages and previews: those search read, the question before included when it followed up.
    var markedWords: String { answeredReading.isEmpty ? answeredQuestion : answeredReading }

    /// "Following up on “What did we decide about the launch?”": the label of the control, the earlier question cut to a line.
    static func followUpLabel(_ thread: AskFollowUp) -> String {
        let last = thread.last
        let shown = last.count > 60 ? String(last.prefix(57)).trimmingCharacters(in: .whitespaces) + "…" : last
        return String(localized: "Following up on “\(shown)”",
                      comment: "Ask: a toggle under the question that reads it together with the question asked before it; the argument is that earlier question")
    }
}
