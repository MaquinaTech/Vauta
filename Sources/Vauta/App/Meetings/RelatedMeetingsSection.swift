// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Up to three other meetings that are about the same things as this one, found by meaning with the search model (there is no
/// keyword version, so the section only appears when the model ranks the meetings).
struct RelatedMeetingsSection: View {
    @Bindable var model: MeetingsModel

    var body: some View {
        DetailSection(String(localized: "Related meetings", comment: "Section title in a meeting: other meetings about the same things, found by meaning")) {
            Text("Found by meaning", comment: "Caption under “Related documents” or “Related meetings” when the search model found them")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.relatedMeetings) { meeting in
                Button { model.open(meeting: meeting.id) } label: {
                    Label {
                        Text("\(meeting.displayTitle) · \(meeting.startedAt.formatted(date: .abbreviated, time: .omitted))")
                    } icon: {
                        Image(systemName: "text.bubble")
                    }
                }
                .buttonStyle(.link)
                .lineLimit(1)
                .accessibilityHint(Text("Opens the meeting"))
            }
        }
    }
}
