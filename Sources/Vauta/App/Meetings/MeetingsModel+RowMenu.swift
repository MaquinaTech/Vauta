// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// The meetings list's context menu: the same commands as the File and Edit menus, for the row it was opened on.
extension MeetingsModel {
    enum RowAction {
        case export
        case copyMinutes(markdown: Bool)
        case delete
    }

    /// The row's meeting is selected and loaded first, as a click would, so the detail shows the meeting the command is about
    /// (and Delete counts its own transcript, decisions and tasks). A selection that moves on meanwhile cancels the command.
    func perform(_ action: RowAction, onMeeting id: Int64) async {
        noteActivity()
        if selectedID != id {
            selectedID = id
            await loadDetail()
            guard selectedID == id else { return }
        }
        switch action {
        case .export: requestExport()
        case .copyMinutes(let markdown): await copyMinutes(asMarkdown: markdown)
        case .delete: confirmDeleteSelected()
        }
    }

    /// The meeting can't be deleted from the menu while it is being recorded, as from the Edit menu.
    func canDeleteFromMenu(_ id: Int64) -> Bool {
        id != activeMeetingID && meetings.first { $0.id == id }?.endedAt != nil
    }
}
