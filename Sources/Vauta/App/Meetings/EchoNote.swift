// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI

/// Under a Me line marked as the speakers' echo: what it is, why it is left out, and the way to say it was the user.
struct EchoNote: View {
    let restoreLine: () -> Void

    static let title = String(localized: "Echo of your speakers",
                              comment: "Transcript: under a line of the user's channel that repeats what the other participants said, because the microphone heard them from the speakers")
    static let restore = String(localized: "It Was Me",
                                comment: "Transcript: button under a line marked as an echo of the speakers; the line becomes the user's own again")

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "speaker.wave.2").accessibilityHidden(true)
            Text(Self.title)
                .help(String(localized: "The microphone heard the other participants from your speakers, so this line repeats what they said. It is kept here, but left out of the minutes, answers, owners, search and exports. Headphones avoid it.",
                             comment: "Transcript: tooltip of the note under a line marked as an echo of the speakers"))
            Button(Self.restore, action: restoreLine)
                .buttonStyle(.link)
                .help(String(localized: "This line is what you said: count it in answers, search and exports, and in the minutes the next time they are written",
                             comment: "Transcript: tooltip of the button that makes a line marked as an echo the user's own again"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
