// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Words that Live answers shows in more than one place.
enum LiveAnswersText {
    /// A verified seal means the quoted words were found in the source, not that the answer is right.
    static let canBeWrong = String(localized: "Answers quote your meetings and documents, but can still be wrong: check the source.",
                                   comment: "Live answers: reminder next to the verified seal of an answer, in Settings and as the tooltip and VoiceOver hint of an answer. The quote was found in the source, but the answer may still be wrong")
}
