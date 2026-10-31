// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import SwiftUI
import VautaCore

/// Under a line marked as an echo: what it is, why it is left out, and the way to say it isn't one. On a Me line it is the speakers'
/// echo of the others; on an Others line, the user's own voice sent back by a participant on speakers.
struct EchoNote: View {
    var channel: Channel = .me
    let restoreLine: () -> Void

    static let title = String(localized: "Echo of your speakers",
                              comment: "Transcript: under a line of the user's channel that repeats what the other participants said, because the microphone heard them from the speakers")
    static let restore = String(localized: "It Was Me",
                                comment: "Transcript: button under a line marked as an echo of the speakers; the line becomes the user's own again")
    static let farTitle = String(localized: "Your voice, sent back",
                                 comment: "Transcript: under a line of the other participants' channel that repeats what the user said, because a participant's speakers sent the user's voice back into the call")
    static let farRestore = String(localized: "Not an Echo",
                                   comment: "Transcript: button under a line marked as the user's voice sent back by the call; the line becomes the other participant's own again")

    static func title(for channel: Channel) -> String { channel == .me ? title : farTitle }
    static func restore(for channel: Channel) -> String { channel == .me ? restore : farRestore }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: channel == .me ? "speaker.wave.2" : "arrow.uturn.backward").accessibilityHidden(true)
            Text(Self.title(for: channel))
                .help(channel == .me
                      ? String(localized: "The microphone heard the other participants from your speakers, so this line repeats what they said. It is kept here, but left out of the minutes, answers, owners, search and exports. Headphones avoid it.",
                               comment: "Transcript: tooltip of the note under a line marked as an echo of the speakers")
                      : String(localized: "A participant’s speakers sent your voice back into the call, so this line repeats what you said. It is kept here, but left out of the minutes, answers, owners, search and exports.",
                               comment: "Transcript: tooltip of the note under a line of the other participants marked as the user's own voice sent back by the call"))
            Button(Self.restore(for: channel), action: restoreLine)
                .buttonStyle(.link)
                .help(channel == .me
                      ? String(localized: "This line is what you said: count it in answers, search and exports, and in the minutes the next time they are written",
                               comment: "Transcript: tooltip of the button that makes a line marked as an echo the user's own again")
                      : String(localized: "Another participant said this: count it in answers, search and exports, and in the minutes the next time they are written",
                               comment: "Transcript: tooltip of the button that makes a line marked as the user's voice sent back the other participant's own again"))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
