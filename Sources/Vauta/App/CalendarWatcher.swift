// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import EventKit
import Foundation
import Observation
import SwiftUI

/// A calendar event with a meeting link, around now.
struct CalendarEventMatch: Equatable {
    let meeting: CalendarMeeting
    /// The service of the event's meeting link (Zoom, Google Meet, Teams…); nil for an in-person event.
    let service: ConferencingService?
    /// Which occurrence of which event this is (identifier and start), so a brief is only attached to the recording of its own event.
    var occurrence: BriefOccurrence? = nil
}

/// What the brief needs to know to schedule its notification (read by `CalendarWatcher.scheduleNext`).
struct BriefWakePlan {
    var leadMinutes: Int
    var ledger: BriefNotificationLedger
}

/// The calendar (optional, off by default). Data minimization:
/// - only the calendars the user picks,
/// - only events within ±10 minutes of now that have a meeting link,
/// - no cache: each query reads and lets go; of an event, only what belongs
///   to the meeting being transcribed is stored (encrypted).
/// Full access is required (macOS offers no read-only access).
@MainActor
@Observable
final class CalendarWatcher {
    struct CalendarChoice: Identifiable, Hashable {
        let id: String
        let title: String
        let source: String
        /// The calendar's own colour, as the Calendar app shows it.
        var color: Color? = nil
    }

    /// Non-sensitive preferences (switches and opaque identifiers).
    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            if enabled { start(); loadCalendars() } else { stop() }
            onChange?()
        }
    }
    /// Show event and meeting titles in notifications (off by default:
    /// notifications can appear on a shared or projected screen).
    var showTitleInNotifications: Bool {
        didSet { UserDefaults.standard.set(showTitleInNotifications, forKey: Self.titleKey) }
    }
    var selected: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(selected), forKey: Self.calendarsKey)
            if enabled { start() }
            onChange?()
        }
    }
    private(set) var status = EKEventStore.authorizationStatus(for: .event)
    private(set) var calendars: [CalendarChoice] = []

    /// An event with a meeting link reaches its start time (to suggest
    /// recording if a call is in progress).
    @ObservationIgnored var onEventStart: (() -> Void)?

    /// The brief's notification settings and what was already sent; nil when the brief is off. Only start times and attendee counts
    /// are looked at to schedule it: the event is read in full when the notification is due.
    @ObservationIgnored var briefPlan: (@MainActor () -> BriefWakePlan?)?
    /// The calendar switch, the chosen calendars or the access changed (the brief follows).
    @ObservationIgnored var onChange: (() -> Void)?
    /// Occurrences whose brief notification is due now.
    @ObservationIgnored var onBriefDue: (([BriefOccurrence]) -> Void)?

    @ObservationIgnored private var store: EKEventStore?
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var timer: Task<Void, Never>?

    private static let enabledKey = "calendarEnabled"
    private static let titleKey = "calendarTitleInNotifications"
    private static let calendarsKey = "calendarIDs"
    static let window: TimeInterval = 10 * 60
    /// The timer never sleeps longer than this (calendar changes also wake it).
    private static let horizon: TimeInterval = 6 * 3600

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        showTitleInNotifications = UserDefaults.standard.bool(forKey: Self.titleKey)
        selected = Set(UserDefaults.standard.stringArray(forKey: Self.calendarsKey) ?? [])
        if enabled { start() }
    }

    /// A restore wrote the notification switch: read it again (the calendar switch and the chosen calendars are this Mac's own).
    func reloadShowTitleInNotifications() {
        let value = UserDefaults.standard.bool(forKey: Self.titleKey)
        if showTitleInNotifications != value { showTitleInNotifications = value }
    }

    /// Access was never asked for: the system prompt can still be shown. Once it was answered, only System Settings can change it.
    var canRequestAccess: Bool {
        #if VAUTA_DIAGNOSTICS
        if let snapshotCanRequest { return snapshotCanRequest }
        #endif
        return status == .notDetermined
    }

    var hasAccess: Bool {
        #if VAUTA_DIAGNOSTICS
        if let snapshotAccess { return snapshotAccess }
        #endif
        return status == .fullAccess
    }

    #if VAUTA_DIAGNOSTICS
    /// Set by `Vauta render-ui`: the state is invented, so EventKit is never touched.
    @ObservationIgnored private var snapshotAccess: Bool?
    @ObservationIgnored private var snapshotCanRequest: Bool?

    /// For `Vauta render-ui`: the pane as it looks with this access and these calendars (nothing reads EventKit).
    func installSnapshotState(enabled: Bool, access: Bool, calendars: [CalendarChoice], selected: Set<String>, canRequest: Bool = true) {
        snapshotAccess = access
        snapshotCanRequest = canRequest
        self.enabled = enabled
        self.calendars = calendars
        self.selected = selected
    }
    #endif

    func requestAccess() async {
        let store = self.store ?? EKEventStore()
        self.store = store
        _ = try? await store.requestFullAccessToEvents()
        status = EKEventStore.authorizationStatus(for: .event)
        if hasAccess { loadCalendars(); start() }
        onChange?()
    }

    /// The calendars to choose from (only while the Settings tab is open).
    func loadCalendars() {
        #if VAUTA_DIAGNOSTICS
        if snapshotAccess != nil { return }
        #endif
        guard hasAccess else { calendars = []; return }
        let store = self.store ?? EKEventStore()
        self.store = store
        calendars = store.calendars(for: .event).map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title,
                                                             color: $0.cgColor.map { Color(cgColor: $0) }) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    func forgetCalendars() {
        #if VAUTA_DIAGNOSTICS
        if snapshotAccess != nil { return }
        #endif
        calendars = []
    }

    /// The event with a meeting link that overlaps most with now ± 10 minutes.
    func currentEvent(at now: Date = .now) -> CalendarEventMatch? {
        guard let store, let cals = selectedCalendars() else { return nil }
        let predicate = store.predicateForEvents(withStart: now - Self.window, end: now + Self.window, calendars: cals)
        let events = store.events(matching: predicate).filter { !$0.isAllDay }.compactMap { event in
            Self.link(of: event).map { (event, $0) }
        }
        guard let index = CalendarEventPicker.best(events.map { ($0.0.startDate, $0.0.endDate) }, now: now, window: Self.window)
        else { return nil }
        let (event, link) = events[index]
        let attendees = (event.attendees ?? []).map { p in
            let address = p.url.absoluteString
            return CalendarMeeting.Attendee(name: p.name ?? "",
                                            email: address.lowercased().hasPrefix("mailto:") ? String(address.dropFirst(7)) : nil,
                                            isCurrentUser: p.isCurrentUser)
        }
        let meeting = CalendarMeeting(title: event.title ?? "", attendees: attendees,
                                      seriesKey: event.hasRecurrenceRules ? event.calendarItemExternalIdentifier : nil)
        return CalendarEventMatch(meeting: meeting, service: link.service,
                                  occurrence: BriefOccurrence(identifier: event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? "", start: event.startDate))
    }

    /// The meeting link in the event's URL, location or notes.
    nonisolated static func link(of event: EKEvent) -> ConferencingLink? {
        if let url = event.url, let link = ConferencingLink(url: url) { return link }
        for text in [event.location, event.notes].compactMap({ $0 }) {
            if let link = ConferencingLink.first(in: text) { return link }
        }
        return nil
    }

    private func selectedCalendars() -> [EKCalendar]? {
        guard enabled, hasAccess, !selected.isEmpty, let store else { return nil }
        let cals = store.calendars(for: .event).filter { selected.contains($0.calendarIdentifier) }
        return cals.isEmpty ? nil : cals
    }

    // MARK: No polling: calendar changes plus a timer for the next start

    private func start() {
        #if VAUTA_DIAGNOSTICS
        if snapshotAccess != nil { return }
        #endif
        guard enabled, hasAccess else { return }
        if store == nil { store = EKEventStore() }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleNext() }
            }
        }
        scheduleNext()
    }

    private func stop() {
        #if VAUTA_DIAGNOSTICS
        if snapshotAccess != nil { return }
        #endif
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        timer?.cancel()
        timer = nil
        store = nil
        calendars = []
    }

    /// Sleeps until the next event with a meeting link starts, or until a brief notification is due (at most 6 h).
    func scheduleNext() {
        timer?.cancel()
        guard let store, let cals = selectedCalendars() else { return }
        let now = Date.now
        let upcoming = store.events(matching: store.predicateForEvents(withStart: now, end: now + Self.horizon, calendars: cals))
            .filter { !$0.isAllDay && $0.startDate > now }
        let next = upcoming.filter { Self.link(of: $0) != nil }.map(\.startDate).min()
        var candidates: [BriefWakeCandidate] = []
        var briefAt: Date?
        let plan = briefPlan?()
        if let plan {
            // Start times and identifiers only: no attendee, answer, link or note of an event is read to schedule. Whether the event
            // qualifies is decided when its notification is due, on that event alone.
            candidates = upcoming.map {
                BriefWakeCandidate(occurrence: BriefOccurrence(identifier: $0.calendarItemExternalIdentifier ?? $0.eventIdentifier ?? "", start: $0.startDate), start: $0.startDate)
            }
            briefAt = BriefWake.next(candidates, now: now, leadMinutes: plan.leadMinutes, ledger: plan.ledger)
        }
        let wake = [next, briefAt].compactMap { $0 }.min() ?? now + Self.horizon
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, wake.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            let woke = Date.now
            if let next, woke >= next.addingTimeInterval(-1) { self.onEventStart?() }
            if let plan, briefAt != nil {
                let due = BriefWake.due(candidates, now: woke, leadMinutes: plan.leadMinutes, ledger: plan.ledger)
                if !due.isEmpty { self.onBriefDue?(due) }
            }
            self.scheduleNext()
        }
    }
}
