// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Everything the deterministic part of a brief is made from (steps 1 to 4 of the pipeline, already gathered).
public struct BriefAssembly: Sendable {
    public var event: BriefEvent
    public var facts: BriefFacts
    /// The agenda lines of the invitation (empty unless "Use the invitation's notes" is on).
    public var invitationLines: [String]
    public var query: String
    /// False for a generic title with no history: the related sections are skipped.
    public var querySufficient: Bool
    public var mode: BriefRankingMode
    public var meetingHits: [BriefMeetingHit]
    public var documentHits: [BriefDocumentHit]
    /// Raw cosines of the open tasks' texts to the query, by task id (semantic mode only).
    public var taskCosines: [Int64: Double]?
    /// Reminders that passed `BriefReminderFilter.eligible`.
    public var reminders: [BriefReminder]
    /// Raw cosines of the reminders' titles, by reminder id (semantic mode only).
    public var reminderCosines: [String: Double]?
    public var now: Date
    public var locale: String?
    /// Whether "Last time" is built (`BriefLastTimeShipping`); the evaluation always builds it, to measure it.
    public var showsLastTime: Bool

    public init(event: BriefEvent, facts: BriefFacts, invitationLines: [String] = [], query: String, querySufficient: Bool = true,
                mode: BriefRankingMode, meetingHits: [BriefMeetingHit] = [], documentHits: [BriefDocumentHit] = [],
                taskCosines: [Int64: Double]? = nil, reminders: [BriefReminder] = [], reminderCosines: [String: Double]? = nil,
                now: Date = AppClock.now, locale: String? = nil, showsLastTime: Bool = true) {
        self.event = event
        self.facts = facts
        self.invitationLines = invitationLines
        self.query = query
        self.querySufficient = querySufficient
        self.mode = mode
        self.meetingHits = meetingHits
        self.documentHits = documentHits
        self.taskCosines = taskCosines
        self.reminders = reminders
        self.reminderCosines = reminderCosines
        self.now = now
        self.locale = locale
        self.showsLastTime = showsLastTime
    }
}

/// The deterministic brief. Pure: no store, no model, no network.
///
/// Series and attendees choose the candidates of "Last time" and "Open tasks"; the topic only re-orders inside them. Related meetings,
/// documents, notes and reminders come in on the raw cosine of the search model (floor 0.65, never the boosted score) or, without
/// it, on the keyword gate.
public enum BriefBuilder {
    public static let sectionItemLimit = 3
    public static let floor = Double(SemanticRanker.relatedFloor)

    public static func assemble(_ a: BriefAssembly) -> BriefSnapshot {
        let locale = a.locale ?? a.facts.last?.locale
        var sections: [BriefSection] = []
        func add(_ kind: BriefSectionKind, _ items: [BriefItem], total: Int? = nil) {
            if !items.isEmpty { sections.append(BriefSection(kind: kind, items: Array(items.prefix(BriefSnapshot.windowLimit)), total: total ?? items.count)) }
        }

        add(.people, people(a))
        var lastItems: (items: [BriefItem], total: Int) = ([], 0)
        var shownTasks = Set<Int64>()
        if a.showsLastTime { (lastItems, shownTasks) = lastTime(a) }
        add(.lastTime, lastItems.items, total: lastItems.total)
        let tasks = openTasks(a, excluding: shownTasks)
        add(.openTasks, tasks.items, total: tasks.total)

        let excluded = Set([a.facts.last?.meetingID].compactMap { $0 })
        var related = a.querySufficient ? relatedMeetings(a, excluding: excluded, locale: locale) : (items: [BriefItem](), total: 0)
        // Without "Last time" the last meeting leads the related meetings, so its minutes stay one click away.
        if !a.showsLastTime, let last = a.facts.last { related = ([lastMeeting(last)] + related.items, related.total + 1) }
        add(.relatedMeetings, related.items, total: related.total)
        let docs = documents(a, locale: locale)
        add(.documents, docs.items, total: docs.total)
        let reminders = a.querySufficient ? reminders(a, locale: locale) : (items: [BriefItem](), total: 0)
        add(.reminders, reminders.items, total: reminders.total)
        let invitation = a.invitationLines.map { BriefItem(kind: .invitationLine, text: BriefText.line($0, limit: 160)) }
        add(.invitation, invitation)

        // Item IDs, in the order shown.
        var n = 0
        for s in sections.indices {
            for i in sections[s].items.indices {
                n += 1
                sections[s].items[i].id = "b\(n)"
                if sections[s].items[i].kind == .task, let task = sections[s].items[i].taskID, a.facts.remindersTaskIDs.contains(task) {
                    sections[s].items[i].inReminders = true
                }
            }
        }
        var snapshot = BriefSnapshot(occurrence: a.event.occurrence, title: a.event.title, start: a.event.start, end: a.event.end, service: a.event.service,
                                     seriesName: a.facts.seriesName, mode: a.mode, relatedSkipped: !a.querySufficient, sections: sections)
        snapshot.lastTimeHidden = !a.showsLastTime && a.facts.last != nil
        return snapshot
    }

    /// The last meeting as a related meeting: its date and title, linked to its minutes, and no line of them.
    static func lastMeeting(_ last: BriefLastMeeting) -> BriefItem {
        var item = BriefItem(kind: .relatedMeeting, text: BriefText.line(last.title), link: .meeting(meetingID: last.meetingID, t: nil))
        item.meetingID = last.meetingID
        item.meetingDate = last.date
        return item
    }

    // MARK: People

    static func people(_ a: BriefAssembly) -> [BriefItem] {
        a.facts.people.map { p in
            var item = BriefItem(kind: .person, text: p.name, link: p.entityID.map { .person(entityID: $0) } ?? .none)
            item.entityID = p.entityID
            item.lastMet = p.lastMet
            item.meetingsTogether = p.meetingsTogether
            return item
        }
    }

    // MARK: Last time

    static func link(meeting: Int64?, segment: Int64?, t: Double? = nil) -> BriefLink {
        guard let meeting else { return .none }
        if let segment { return .segment(meetingID: meeting, segmentID: segment) }
        return .meeting(meetingID: meeting, t: t)
    }

    /// Due dates are whole days (stored at the start of the day): a task is overdue only when its day is before today, the same rule
    /// as the Tasks list. A task due today is not, and neither is one due on a later day, even when the meeting is further away.
    static func isOverdue(_ due: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let due else { return false }
        return due < calendar.startOfDay(for: now)
    }

    /// Due from today on, but on a day before the meeting's day: late for the meeting, not late yet (the mark reminders already use).
    static func isDueBeforeMeeting(_ due: Date?, at start: Date, now: Date, calendar: Calendar = .current) -> Bool {
        guard let due, !isOverdue(due, now: now, calendar: calendar) else { return false }
        return due < calendar.startOfDay(for: start)
    }

    static func taskItem(_ task: TaskItem, date: Date?, selfID: Int64?, event: BriefEvent, now: Date) -> BriefItem {
        var item = BriefItem(kind: .task, text: BriefText.line(task.text), link: link(meeting: task.meetingID, segment: task.segmentID, t: task.t))
        item.taskID = task.id
        item.meetingID = task.meetingID
        item.meetingDate = date
        item.owner = task.ownerName
        item.due = task.due
        item.overdue = isOverdue(task.due, now: now)
        item.dueBeforeMeeting = isDueBeforeMeeting(task.due, at: event.start, now: now)
        item.unconfirmed = task.unconfirmed
        item.ownerUncertain = task.ownerUncertain
        item.isYours = selfID != nil && task.ownerID == selfID
        return item
    }

    /// The summary line, up to 3 decisions, 3 open tasks and 3 open questions of the last meeting. Also the IDs of the tasks shown.
    static func lastTime(_ a: BriefAssembly) -> (items: (items: [BriefItem], total: Int), shown: Set<Int64>) {
        guard let last = a.facts.last else { return (([], 0), []) }
        var items: [BriefItem] = []
        var total = 0
        let summary = last.summary.flatMap { BriefText.firstSentence($0, meetingDate: last.date) } ?? ""
        var head = BriefItem(kind: .summary, text: summary.isEmpty ? BriefText.line(last.title) : summary, link: .meeting(meetingID: last.meetingID, t: nil))
        head.meetingID = last.meetingID
        head.meetingDate = last.date
        head.source = BriefText.line(last.title)
        items.append(head)
        total += 1

        total += last.decisions.count
        for d in last.decisions.prefix(sectionItemLimit) {
            var item = BriefItem(kind: .decision, text: BriefText.line(d.text), link: link(meeting: d.meetingID, segment: d.segmentID, t: d.t))
            item.decisionID = d.id
            item.meetingID = d.meetingID
            item.meetingDate = last.date
            item.unconfirmed = d.unconfirmed
            switch a.facts.decisionLinks[d.id] {
            case .same(let first)?: item.firstDecided = first
            case .changes(let text, let date)?:
                // Nothing is hidden: the new decision says it replaces the old one, and the old one's words stay under it.
                item.replacesDate = date
                item.replacesText = BriefText.line(text)
            case nil: break
            }
            items.append(item)
        }
        total += last.openTasks.count
        var shown = Set<Int64>()
        for t in last.openTasks.prefix(sectionItemLimit) {
            items.append(taskItem(t, date: last.date, selfID: a.facts.selfEntityID, event: a.event, now: a.now))
            shown.insert(t.id)
        }
        total += last.openQuestions.count
        for q in last.openQuestions.prefix(sectionItemLimit) {
            var item = BriefItem(kind: .openQuestion, text: BriefText.line(q.text), link: link(meeting: last.meetingID, segment: q.segmentID, t: q.t))
            item.meetingID = last.meetingID
            item.meetingDate = last.date
            item.fromMinutes = q.segmentID == nil
            items.append(item)
        }
        return ((items, total), shown)
    }

    // MARK: Open tasks

    static func openTasks(_ a: BriefAssembly, excluding shown: Set<Int64>) -> (items: [BriefItem], total: Int) {
        var candidates = a.facts.openTasks.filter { !shown.contains($0.task.id) && $0.task.status == .open }
        // A chain of tasks the person confirmed as the same appears once, as its newest open member, "carried over since…". A member that is
        // already shown under "Last time" stands for its whole chain.
        var carried: [Int64: BriefChainInfo] = [:]
        if !a.facts.taskChains.isEmpty {
            let shownChains = Set(shown.compactMap { a.facts.taskChains[$0]?.newest })
            var newest: [Int64: BriefTaskFact] = [:]
            for fact in candidates {
                guard let chain = a.facts.taskChains[fact.task.id] else { continue }
                let key = chain.newest
                if let current = newest[key], (current.meetingDate ?? .distantPast, current.task.id) >= (fact.meetingDate ?? .distantPast, fact.task.id) { continue }
                newest[key] = fact
            }
            candidates = candidates.filter { fact in
                guard let chain = a.facts.taskChains[fact.task.id] else { return true }
                if shownChains.contains(chain.newest) { return false }
                return newest[chain.newest]?.task.id == fact.task.id
            }
            for fact in candidates { carried[fact.task.id] = a.facts.taskChains[fact.task.id] }
        }
        guard !candidates.isEmpty else { return ([], 0) }
        func overdue(_ t: TaskItem) -> Bool { isOverdue(t.due, now: a.now) }
        func yours(_ t: TaskItem) -> Bool { a.facts.selfEntityID != nil && t.ownerID == a.facts.selfEntityID }
        func related(_ t: TaskItem) -> Double? { a.taskCosines?[t.id].flatMap { $0 >= floor ? $0 : nil } }
        // Related to the topic first (semantic mode), then by due date and recency: below the floor a task is never dropped, it is the
        // person's own commitment.
        let ordered = candidates.sorted { x, y in
            let (p, q) = (x.task, y.task)
            if overdue(p) != overdue(q) { return overdue(p) }
            if yours(p) != yours(q) { return yours(p) }
            let (rp, rq) = (related(p), related(q))
            if (rp != nil) != (rq != nil) { return rp != nil }
            if let rp, let rq, rp != rq { return rp > rq }
            switch (p.due, q.due) {
            case let (d1?, d2?) where d1 != d2: return d1 < d2
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }
            if p.createdAt != q.createdAt { return p.createdAt > q.createdAt }
            return p.id < q.id
        }
        let items = ordered.prefix(BriefSnapshot.windowLimit).map { f -> BriefItem in
            var item = taskItem(f.task, date: f.meetingDate, selfID: a.facts.selfEntityID, event: a.event, now: a.now)
            item.cosine = a.taskCosines?[f.task.id]
            if let chain = carried[f.task.id] {
                item.carriedMentions = chain.mentions
                item.carriedSince = chain.since
            }
            return item
        }
        return (Array(items), ordered.count)
    }

    // MARK: Related meetings

    static func relatedMeetings(_ a: BriefAssembly, excluding: Set<Int64>, locale: String?) -> (items: [BriefItem], total: Int) {
        var seen = Set<Int64>()
        var kept: [BriefMeetingHit] = []
        for hit in a.meetingHits where !excluding.contains(hit.meetingID) && !seen.contains(hit.meetingID) {
            let passes: Bool
            switch a.mode {
            case .semantic: passes = (hit.cosine ?? 0) >= floor
            case .keyword: passes = BriefKeywordGate.passes(query: a.query, text: hit.title + " " + hit.text, locale: locale)
            }
            if passes { seen.insert(hit.meetingID); kept.append(hit) }
        }
        if a.mode == .semantic { kept.sort { ($0.cosine ?? 0) > ($1.cosine ?? 0) } }
        let items = kept.prefix(sectionItemLimit).map { hit -> BriefItem in
            var item = BriefItem(kind: .relatedMeeting, text: BriefText.line(hit.title), link: link(meeting: hit.meetingID, segment: hit.segmentID, t: hit.t))
            item.meetingID = hit.meetingID
            item.meetingDate = hit.date
            item.detail = BriefText.line(hit.text, limit: 160)
            item.cosine = hit.cosine
            return item
        }
        return (Array(items), kept.count)
    }

    // MARK: Documents and notes

    static func documents(_ a: BriefAssembly, locale: String?) -> (items: [BriefItem], total: Int) {
        var items: [BriefItem] = []
        var total = 0
        var materialKeys = Set<String>()
        let materials = a.facts.last?.materials ?? []
        total += materials.count
        for m in materials {
            materialKeys.insert("\(m.sourceID)|\(m.relPath)")
            guard items.count < sectionItemLimit else { continue }
            var item = BriefItem(kind: .material, text: BriefText.line(m.name, limit: 120), link: .file(sourceID: m.sourceID, relPath: m.relPath))
            item.meetingID = a.facts.last?.meetingID
            item.meetingDate = a.facts.last?.date
            items.append(item)
        }
        guard a.querySufficient else { return (items, total) }
        // One passage per file, the best.
        var best: [String: BriefDocumentHit] = [:]
        var order: [String] = []
        for hit in a.documentHits {
            let key = "\(hit.sourceID)|\(hit.relPath)"
            guard !materialKeys.contains(key) else { continue }
            let passes: Bool
            switch a.mode {
            case .semantic: passes = (hit.cosine ?? 0) >= floor
            case .keyword: passes = BriefKeywordGate.passes(query: a.query, text: hit.fileName + " " + hit.text, locale: locale)
            }
            guard passes else { continue }
            if let current = best[key] {
                if (hit.cosine ?? 0) > (current.cosine ?? 0) { best[key] = hit }
            } else {
                best[key] = hit
                order.append(key)
            }
        }
        var hits = order.compactMap { best[$0] }
        if a.mode == .semantic { hits.sort { ($0.cosine ?? 0) > ($1.cosine ?? 0) } }
        total += hits.count
        for hit in hits.prefix(sectionItemLimit) {
            var item = BriefItem(kind: a.facts.notesSourceIDs.contains(hit.sourceID) ? .note : .document, text: BriefText.line(hit.fileName, limit: 120),
                                 link: .passage(key: hit.passageKey, sourceID: hit.sourceID, relPath: hit.relPath))
            item.detail = BriefText.line(hit.text, limit: 160)
            item.cosine = hit.cosine
            items.append(item)
        }
        return (items, total)
    }

    // MARK: Reminders

    static func reminders(_ a: BriefAssembly, locale: String?) -> (items: [BriefItem], total: Int) {
        let attendees = a.event.otherAttendees.map(\.name).filter { !$0.isEmpty }
        struct Candidate { let reminder: BriefReminder; let named: Bool; let cosine: Double? }
        var kept: [Candidate] = []
        for r in a.reminders {
            let named = BriefNames.attendeeIsNamed(in: r.title, attendees: attendees)
            let cosine = a.reminderCosines?[r.id]
            let topical: Bool
            switch a.mode {
            case .semantic: topical = (cosine ?? 0) >= floor
            case .keyword: topical = BriefKeywordGate.passes(query: a.query, text: r.title, locale: locale)
            }
            if named || topical { kept.append(Candidate(reminder: r, named: named, cosine: cosine)) }
        }
        kept.sort { x, y in
            if x.named != y.named { return x.named }
            if a.mode == .semantic, (x.cosine ?? 0) != (y.cosine ?? 0) { return (x.cosine ?? 0) > (y.cosine ?? 0) }
            switch (x.reminder.due, y.reminder.due) {
            case let (d1?, d2?) where d1 != d2: return d1 < d2
            case (nil, _?): return false
            case (_?, nil): return true
            default: break
            }
            return x.reminder.id < y.reminder.id
        }
        let items = kept.prefix(BriefReminderFilter.maximumShown).map { c -> BriefItem in
            var item = BriefItem(kind: .reminder, text: c.reminder.title, link: .reminder(id: c.reminder.id))
            item.due = c.reminder.due
            // A reminder may carry a time of day: one whose time has passed today is late too. Otherwise the task rule applies.
            let due = c.reminder.due
            let timedAndPast = due.map { $0 < a.now && $0 != Calendar.current.startOfDay(for: $0) } ?? false
            item.overdue = isOverdue(due, now: a.now) || timedAndPast
            item.dueBeforeMeeting = !item.overdue && isDueBeforeMeeting(due, at: a.event.start, now: a.now)
            item.source = c.reminder.listName
            item.isYours = true
            item.cosine = c.cosine
            return item
        }
        return (Array(items), kept.count)
    }
}
