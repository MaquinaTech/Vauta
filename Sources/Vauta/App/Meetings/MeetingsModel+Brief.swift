// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit

/// The brief inside the Meetings window: the Upcoming view and what its lines open.
extension MeetingsModel {
    /// Shows the brief of the next meeting (the sidebar row, or "Open Brief" in the notification).
    func showUpcoming() {
        mode = .meetings
        selectedID = nil
        showingUpcoming = true
        noteActivity()
        brief?.openUpcoming()
    }

    /// A line of the brief was chosen: it opens the source it came from. A reminder or the event opens the Apple app (read-only).
    func open(_ link: BriefLink) {
        noteActivity()
        switch link {
        case .segment(let meeting, let segment): open(meeting: meeting, segment: segment)
        case .meeting(let meeting, let t): open(meeting: meeting, at: t, tab: t == nil ? .summary : nil)
        case .person(let entity):
            mode = .people
            selectedEntityID = entity
        case .passage(let key, let source, let path):
            Task {
                guard let index = documentsModel?.index, let passage = try? await index.passage(source: source, relPath: path, key: key) else { return }
                openDocument(DocumentCitation(passage))
            }
        case .file(let source, let path):
            guard let indexer = documentsModel?.indexer else { return }
            openInApp(source: source, relPath: path, indexer: indexer)
        case .reminder(let id): brief?.openReminders(id: id)
        case .event(let identifier): brief?.openCalendar(eventIdentifier: identifier)
        case .none: break
        }
    }
}
