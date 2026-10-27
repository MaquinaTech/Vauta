// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// An event whose notification may be due: only its occurrence and start, nothing else about it is read to schedule a wake-up.
public struct BriefWakeCandidate: Sendable, Equatable {
    public let occurrence: BriefOccurrence
    public let start: Date

    public init(occurrence: BriefOccurrence, start: Date) {
        self.occurrence = occurrence
        self.start = start
    }
}

public enum BriefWake {
    /// The next moment the app has to wake for a brief notification: the earliest `start − lead` of an event that has not started and
    /// whose notification was not sent. A notification already due (the app was closed at `start − lead`) is due now. nil when the
    /// notification is Off or nothing qualifies.
    public static func next(_ candidates: [BriefWakeCandidate], now: Date, leadMinutes: Int, ledger: BriefNotificationLedger) -> Date? {
        guard leadMinutes > 0, BriefEventSelector.leadOptions.contains(leadMinutes) else { return nil }
        let wakes = candidates.filter { $0.start > now && !ledger.wasSent($0.occurrence) }
            .map { max($0.start.addingTimeInterval(-Double(leadMinutes) * 60), now.addingTimeInterval(1)) }
        return wakes.min()
    }

    /// The occurrences whose notification is due at `now` (its time has come, the event has not started, it was not sent).
    public static func due(_ candidates: [BriefWakeCandidate], now: Date, leadMinutes: Int, ledger: BriefNotificationLedger) -> [BriefOccurrence] {
        guard leadMinutes > 0, BriefEventSelector.leadOptions.contains(leadMinutes) else { return [] }
        return candidates.filter {
            $0.start > now && !ledger.wasSent($0.occurrence) && $0.start.addingTimeInterval(-Double(leadMinutes) * 60) <= now.addingTimeInterval(1)
        }.map(\.occurrence)
    }
}

/// Which recording the brief belongs to: the one that starts while the brief of the event is on screen and takes that same occurrence.
public enum BriefRecordingMatch {
    /// `recordingOccurrence` is the identifier and start of the calendar occurrence the recording takes (nil when it takes none, or when
    /// the event cannot be told apart). A recording of another event, of another occurrence of the same series or of no event does not
    /// carry the brief: a title is never enough, two events can share it.
    public static func matches(_ event: BriefOccurrence, at now: Date, leadMinutes: Int, recordingOccurrence: BriefOccurrence?) -> Bool {
        let lead = leadMinutes > 0 ? leadMinutes : BriefEventSelector.defaultLeadMinutes
        let start = Date(timeIntervalSince1970: TimeInterval(event.startSeconds))
        guard now >= start.addingTimeInterval(-Double(lead) * 60), now <= start.addingTimeInterval(BriefEventSelector.lateGrace) else { return false }
        return recordingOccurrence == event
    }
}

/// Whether the model-written agenda is shown: only for a backend that passed the agenda gates of the evaluation
/// (unsupported and hallucinated lines, usefulness). The deterministic brief always ships. The set stays empty until the gates have been
/// measured and it has been decided; nothing here is a quality claim.
public enum BriefAgendaShipping {
    /// Backends whose agenda passed the gates.
    public static let shipped: Set<BriefBackend> = []

    public enum Decision: Sendable, Equatable {
        /// Ask the model.
        case run
        /// The agenda section does not exist for this backend (no state is shown).
        case hidden
        /// Agendas exist for some backend, but no model can be used now: "Suggestions need a model."
        case needsModel
    }

    public static func decision(backend: BriefBackend?, shipped: Set<BriefBackend> = BriefAgendaShipping.shipped) -> Decision {
        guard !shipped.isEmpty else { return .hidden }
        guard let backend else { return .needsModel }
        return shipped.contains(backend) ? .run : .hidden
    }
}

/// Whether the search model may rank a brief. It may not: on the evaluation's test series it ranked related meetings, documents, notes
/// and reminders no better than keywords and showed more irrelevant ones, so keywords rank. The retrieval and the semantic path stay
/// in the code and in the tests.
public enum BriefRankingShipping {
    public static let searchModelRanks = false
}

/// What the panel's brief card shows. It is made from the event's title and start alone when Meetings is locked:
/// the type has no other text, so a locked card cannot show an item of the brief.
public struct BriefPanelCard: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        /// "Unlock to see the brief."
        case locked
        /// The brief is off: "Vauta can prepare a brief before your meetings. Set Up…". Made from the title and time alone; nothing is built.
        case setUp
        /// "Preparing brief…"
        case building
        /// "Brief paused while the Mac cools down."
        case paused
        case ready(Ready)
    }

    public struct Ready: Sendable, Equatable {
        public enum Body: Sendable, Equatable {
            /// "First meeting with these people."
            case firstMeeting
            /// "Nothing open from earlier meetings."
            case nothingOpen
            /// The top line of "Last time" and of "Open tasks".
            case lines([BriefItem])
        }

        public let peopleCount: Int
        public let body: Body
        /// Who is coming (their names as the brief lists them), for the first-meeting card.
        public let people: [String]

        public init(peopleCount: Int, body: Body, people: [String] = []) {
            self.peopleCount = peopleCount
            self.body = body
            self.people = people
        }
    }

    public let summary: BriefLockedSummary
    public let content: Content
    public var occurrence: BriefOccurrence { BriefOccurrence(identifier: identifier, start: summary.start) }
    let identifier: String

    /// The one-time offer while the brief is off: the event's title and time and nothing else.
    public static func offer(event: BriefEvent) -> BriefPanelCard {
        BriefPanelCard(summary: BriefLockedSummary(event), content: .setUp, identifier: event.identifier)
    }

    public static func make(event: BriefEvent, snapshot: BriefSnapshot?, locked: Bool, hot: Bool) -> BriefPanelCard {
        let summary = BriefLockedSummary(event)
        if locked { return BriefPanelCard(summary: summary, content: .locked, identifier: event.identifier) }
        if hot { return BriefPanelCard(summary: summary, content: .paused, identifier: event.identifier) }
        guard let snapshot else { return BriefPanelCard(summary: summary, content: .building, identifier: event.identifier) }
        let people = snapshot.section(.people)?.items.count ?? 0
        let body: Ready.Body
        if snapshot.isFirstMeeting {
            body = .firstMeeting
        } else {
            let lines = [snapshot.section(.lastTime)?.items.first, snapshot.section(.openTasks)?.items.first].compactMap { $0 }
            body = lines.isEmpty ? .nothingOpen : .lines(lines)
        }
        return BriefPanelCard(summary: summary, content: .ready(Ready(peopleCount: people, body: body, people: snapshot.section(.people)?.items.map(\.text) ?? [])), identifier: event.identifier)
    }
}
