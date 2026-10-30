// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

extension AskView {
    /// "Only meetings from Oct 19 – 25, 2026", under the question: on when the question names when its meetings were ("last
    /// week"), off but there to turn on when the time may be what it is about ("this week", "in October"). Changing it asks again.
    func timeScopeToggle(_ period: AskTimeScope) -> some View {
        let label = period.label()
        let on = model.usesTimeScope
        return Toggle(isOn: Binding(get: { model.usesTimeScope }, set: { model.chooseTimeScope($0) })) {
            Label(String(localized: "Only meetings from \(label)",
                         comment: "Ask: a toggle under the question that limits the search to the meetings of the time the question names; the argument is a date, a range of dates, a month, a quarter or a year"),
                  systemImage: "calendar")
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .disabled(model.busy)
        .help(on ? Text("Only the meetings held then are searched. Click to search all meetings.", comment: "Ask: help on the time toggle when it is on")
                 : Text("Click to search only the meetings held then.", comment: "Ask: help on the time toggle when it is off"))
    }
}
