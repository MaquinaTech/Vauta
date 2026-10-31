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

    /// "Only “Weekly sync” (Oct 28, 2026)", under the question when it names its meetings by their place ("the last meeting", "the first
    /// meeting with Ana"): on until turned off. Changing it asks again.
    func placeToggle(_ found: [MeetingStore.Meeting]) -> some View {
        let on = model.usesPlace
        return Toggle(isOn: Binding(get: { model.usesPlace }, set: { model.choosePlace($0) })) {
            Label(AskModel.placeLabel(found), systemImage: "clock.arrow.circlepath")
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .disabled(model.busy)
        .help(on ? Text("Only the meetings the question names are searched. Click to search all meetings.",
                        comment: "Ask: help on the toggle of the meetings the question names by their place, when it is on")
                 : Text("Click to search only the meetings the question names.",
                        comment: "Ask: help on the toggle of the meetings the question names by their place, when it is off"))
    }

    /// "Following up on “What did we decide about the launch?”", under the question once one was asked: on when the question reads as
    /// going on from it ("And who owns it?"), off but there to turn on otherwise. Changing it asks again.
    func followUpToggle(_ thread: AskFollowUp) -> some View {
        let on = model.usesFollowUp
        return Toggle(isOn: Binding(get: { model.usesFollowUp }, set: { model.chooseFollowUp($0) })) {
            Label(AskModel.followUpLabel(thread), systemImage: "arrowshape.turn.up.left")
                .lineLimit(1)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .disabled(model.busy)
        .help(on ? Text("This question is read together with the one before. Click to ask it on its own.",
                        comment: "Ask: help on the follow-up toggle when it is on")
                 : Text("Click to read this question together with the one before.",
                        comment: "Ask: help on the follow-up toggle when it is off"))
    }
}
