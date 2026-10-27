// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Unsaved edits to a meeting's title, summary and topics, with the values
/// last read from or written to the store.
///
/// The meetings window autosaves drafts: shortly after typing stops, and at
/// once when the selection changes, the window closes or the app relocks.
/// `changes` says exactly what to write, so renaming a meeting never touches
/// its card (which would turn minutes proposed by the model into the user's).
public struct MeetingDraft: Sendable, Equatable {
    public let meetingID: Int64
    /// What to write to the store. `title` is `.some(nil)` to go back to the
    /// automatic title; `card` keeps the stored open questions (nil).
    public struct Changes: Sendable, Equatable {
        public var title: String??
        public var card: MeetingCard?
        public var isEmpty: Bool { title == nil && card == nil }
    }

    /// Editable values. An empty title means the automatic title.
    public var title: String
    public var summary: String
    public var topicsText: String

    private var savedTitle: String
    private var savedSummary: String
    private var savedTopicsText: String

    public init(meetingID: Int64, title: String?, card: MeetingCard?) {
        self.meetingID = meetingID
        self.title = title ?? ""
        self.summary = card?.summary ?? ""
        self.topicsText = Self.topicsText(card?.topics ?? [])
        savedTitle = self.title
        savedSummary = summary
        savedTopicsText = topicsText
    }

    public var titleChanged: Bool { Self.cleanTitle(title) != Self.cleanTitle(savedTitle) }
    public var cardChanged: Bool {
        summary.trimmingCharacters(in: .whitespacesAndNewlines) != savedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            || Self.topics(topicsText) != Self.topics(savedTopicsText)
    }
    public var isDirty: Bool { titleChanged || cardChanged }

    public var changes: Changes {
        var out = Changes()
        if titleChanged {
            let clean = Self.cleanTitle(title)
            out.title = .some(clean.isEmpty ? nil : clean)
        }
        if cardChanged {
            out.card = MeetingCard(summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                                   topics: Self.topics(topicsText), openQuestions: nil)
        }
        return out
    }

    /// `saved` was written. What was written becomes the saved state; edits
    /// typed while it was being written stay dirty and are saved next time.
    public mutating func markSaved(_ saved: Changes) {
        if let title = saved.title { savedTitle = title ?? "" }
        if let card = saved.card {
            savedSummary = card.summary
            savedTopicsText = Self.topicsText(card.topics)
        }
    }

    /// The store changed underneath (e.g. the model finished the minutes):
    /// fields the user has not touched take the new values; edited fields
    /// keep the user's text.
    public mutating func rebase(title newTitle: String?, card: MeetingCard?) {
        let fresh = MeetingDraft(meetingID: meetingID, title: newTitle, card: card)
        if !titleChanged { title = fresh.title }
        if summary == savedSummary { summary = fresh.summary }
        if topicsText == savedTopicsText { topicsText = fresh.topicsText }
        savedTitle = fresh.savedTitle
        savedSummary = fresh.savedSummary
        savedTopicsText = fresh.savedTopicsText
    }

    /// Topics typed as a list. Accepts the comma of the user's script
    /// (",", "、", "，", "،", ";").
    public static func topics(_ text: String) -> [String] {
        text.split(whereSeparator: { ",、，،;；".contains($0) || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Japanese and Chinese separate list items with the ideographic comma, not “, ”.
    public static func topicSeparator(for locale: Locale = .current) -> String {
        switch locale.language.languageCode?.identifier {
        case "ja", "zh": "、"
        default: ", "
        }
    }

    public static func topicsText(_ topics: [String], locale: Locale = .current) -> String {
        topics.joined(separator: topicSeparator(for: locale))
    }

    static func cleanTitle(_ title: String) -> String {
        SingleLineText.flatten(title).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Unsaved edits to one task (text, owner, due date, status).
public struct TaskDraft: Sendable, Equatable {
    public let original: TaskItem
    public var text: String
    public var ownerID: Int64?
    public var hasDue: Bool
    public var due: Date
    public var status: TaskItem.Status
    /// The zone the picker shows days in.
    public let zone: TimeZone

    /// `due` starts at the start of the task's due day in `zone`, so the picker shows the day the task says wherever the person is
    /// (the stored `due` is the start of that day in the zone it was set in).
    public init(_ task: TaskItem, now: Date = AppClock.now, zone: TimeZone = .current) {
        original = task
        self.zone = zone
        text = task.text
        ownerID = task.ownerID
        hasDue = task.due != nil
        due = task.displayDay(in: zone)?.startOfDay(in: zone) ?? now
        status = task.status
    }

    /// The person chose another day (or added or removed one). Only then is the stored `due` replaced; an untouched day keeps its
    /// stored moment and its `due_day`.
    var dueChanged: Bool {
        guard hasDue else { return original.due != nil }
        guard original.due != nil else { return true }
        return DueDay.containing(due, in: zone) != original.displayDay(in: zone)
    }

    public var taskID: Int64 { original.id }

    /// The task as it would be saved.
    public var edited: TaskItem {
        var t = original
        t.text = SingleLineText.flatten(text).trimmingCharacters(in: .whitespaces)
        t.ownerID = ownerID
        t.due = hasDue ? (dueChanged ? due : original.due) : nil
        t.status = status
        return t
    }

    public var isDirty: Bool {
        let e = edited
        return e.text != original.text || e.ownerID != original.ownerID || dueChanged || e.status != original.status
    }

    /// An empty text cannot be saved (the store rejects it).
    public var canSave: Bool { !edited.text.isEmpty }
}
