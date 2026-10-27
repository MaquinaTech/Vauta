// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore

extension RecorderModel {
    /// A line of the brief in the panel was chosen: the source it came from opens in the Meetings window, after Touch ID or the
    /// password. A reminder or the event opens the Apple app instead (read-only).
    func openBriefLink(_ link: BriefLink) {
        switch link {
        case .reminder(let id): brief.openReminders(id: id)
        case .event(let identifier): brief.openCalendar(eventIdentifier: identifier)
        case .none: break
        default:
            Task {
                guard await authorizeHistory() else { return }
                history?.open(link)
                showWindow("meetings")
            }
        }
    }
}
