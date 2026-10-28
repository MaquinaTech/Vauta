// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import EventKit
import Foundation
import Observation

extension BriefController {
    /// One event and its brief.
    struct Entry: Equatable, Identifiable {
        var event: BriefEvent
        var snapshot: BriefSnapshot?
        /// The Mac is too hot: nothing was built.
        var hot = false
        var reminders = BriefRemindersState.off
        var id: BriefOccurrence { event.occurrence }
    }

    /// What the Upcoming view shows.
    enum UpcomingState: Equatable {
        /// Calendar or the brief is off: the view is not offered.
        case off
        case calendarDenied
        case loading
        /// No qualifying meeting in the next 12 hours.
        case none
        case entries([Entry])
    }

    /// What a test replaces so the controller runs without Calendar, a recorder or a store.
    struct Seams {
        var isLocked: () -> Bool = { false }
        var calendarOn: () -> Bool = { true }
        var hasAccess: () -> Bool = { true }
        var calendars: () -> Set<String> = { ["work"] }
        var source: any BriefEventSource
        var build: (BriefEvent, Bool) async -> Entry
        /// Whether a recording is running; nil asks the recorder.
        var isRecording: (() -> Bool)?
        /// Keeps the brief with the meeting; nil writes it to the recorder's store.
        var saveBrief: ((BriefStoredReferences, Int64, Date) async -> Void)?
    }

    struct Attachment {
        var references: BriefStoredReferences
        var occurrence: BriefOccurrence
        var title: String
        var start: Date
        var end: Date
        var service: ConferencingService?
        /// When the recording began: the brief is the one the person had then.
        var recordedAt: Date
    }
}
