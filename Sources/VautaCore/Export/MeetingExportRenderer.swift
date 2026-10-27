// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Markdown and plain-text minutes. Both share one outline: title, date,
/// attendees, the user's own notes (their document comes first), summary, topics, decisions, tasks, open questions
/// and (optionally) the transcript. Empty sections are left out.
public enum MeetingExportRenderer {
    // MARK: Markdown

    public static func markdown(_ e: MeetingExport, options: MeetingExportOptions) -> String {
        var blocks: [String] = ["# " + Markdown.inline(e.title)]
        var meta = ["- **\(Labels.date):** " + Markdown.inline(dateLine(e, options: options))]
        if !e.attendees.isEmpty {
            meta.append("- **\(Labels.attendees):** " + Markdown.inline(e.attendees.joined(separator: ", ")))
        }
        blocks.append(meta.joined(separator: "\n"))

        if !e.notes.isEmpty {
            blocks.append("## \(Labels.notes)")
            if e.notes.contains(where: { !$0.expansion.isEmpty && !$0.editedByUser }) { blocks.append("*" + Labels.expanded + "*") }
            blocks.append(e.notes.map { markdownNote($0) }.joined(separator: "\n"))
        }
        if !e.summary.isEmpty {
            blocks.append("## \(Labels.summary)")
            blocks.append(contentsOf: Markdown.paragraphs(e.summary))
        }
        func list(_ heading: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            blocks.append("## \(heading)")
            blocks.append(lines.joined(separator: "\n"))
        }
        list(Labels.topics, e.topics.map { "- " + Markdown.inline($0) })
        list(Labels.decisions, e.decisions.map { "- " + Markdown.inline($0.text) + Markdown.inline(decisionNote($0)) + timeSuffix($0.time) })
        list(Labels.tasks, e.tasks.map { markdownTask($0, options: options) })
        list(Labels.openQuestions, e.openQuestions.map { "- " + Markdown.inline($0) })
        if !e.questions.isEmpty {
            blocks.append("## \(Labels.questions)")
            blocks.append(e.questions.map { q in
                var entry = "- (\(ExportTimestamp.clock(q.time))) **" + Markdown.inline(q.text) + "**\n  " + Markdown.inline(q.answer)
                if !q.sources.isEmpty { entry += "\n  *" + Markdown.inline(Labels.sources + ": " + q.sources.joined(separator: "; ")) + "*" }
                return entry
            }.joined(separator: "\n"))
        }

        if options.includeTranscript && !e.transcript.isEmpty {
            blocks.append("## \(Labels.transcript)")
            for line in e.transcript {
                let who = Markdown.inline(options.speaker(of: line))
                var entry = "**[\(ExportTimestamp.clock(line.start))] \(who):** " + Markdown.inline(line.text)
                if let translation = line.translation(options) { entry += "  \n> " + Markdown.inline(SingleLineText.flatten(translation)) }
                blocks.append(entry)
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The user's words in bold; under them, indented, what the transcript says (with the moments it cites).
    private static func markdownNote(_ n: MeetingExport.NoteEntry) -> String {
        var out = "- " + timePrefix(n.time) + "**" + Markdown.inline(n.text) + "**"
        for (i, s) in n.expansion.enumerated() {
            out += "\n  - " + Markdown.inline(sentenceText(s)) + (s.unconfirmed ? " *" + Labels.unconfirmed + "*" : "")
            // The user rewrote this expansion: the reader is told whose words these are, on the text itself (not as an
            // item of its own); the times left are those of lines the user kept as the model wrote them.
            if n.editedByUser && i == n.expansion.count - 1 { out += " *" + Labels.editedByYou + "*" }
        }
        return out
    }

    /// " — Not confirmed in the transcript" (the same words for decisions, tasks and expanded notes).
    public static var unconfirmedLabel: String { Labels.unconfirmed }

    /// Under an expansion the user rewrote.
    public static var editedByYouLabel: String { Labels.editedByYou }

    /// "The transcript says: …" for a sentence that differs from the note, then the moments it cites.
    public static func sentenceText(_ s: MeetingExport.NoteEntry.Sentence) -> String {
        let moments = Array(Set(s.times.map { Int($0) })).sorted().map { ExportTimestamp.clock(Double($0)) }
        return (s.differs ? Labels.transcriptSays + " " : "") + s.text + (moments.isEmpty ? "" : " (" + moments.joined(separator: ", ") + ")")
    }

    private static func markdownTask(_ t: MeetingExport.TaskEntry, options: MeetingExportOptions) -> String {
        let text = Markdown.inline(t.text)
        let head: String = switch t.status {
        case .open: "- [ ] " + text
        case .done: "- [x] " + text
        case .dropped: "- [ ] ~~" + text + "~~"
        }
        let details = taskDetails(t, options: options).map(Markdown.inline)
        return head + (details.isEmpty ? "" : " — " + details.joined(separator: " · ")) + timeSuffix(t.time)
    }

    // MARK: Plain text

    public static func plainText(_ e: MeetingExport, options: MeetingExportOptions) -> String {
        var blocks: [String] = []
        var head = [e.title, "\(Labels.date): \(dateLine(e, options: options))"]
        if !e.attendees.isEmpty { head.append("\(Labels.attendees): \(e.attendees.joined(separator: ", "))") }
        blocks.append(head.joined(separator: "\n"))

        func section(_ heading: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            blocks.append(([heading] + lines).joined(separator: "\n"))
        }
        if !e.notes.isEmpty {
            var lines: [String] = []
            if e.notes.contains(where: { !$0.expansion.isEmpty && !$0.editedByUser }) { lines.append(Labels.expanded) }
            for n in e.notes {
                lines.append("- " + timePrefix(n.time) + n.text)
                for s in n.expansion { lines.append("    " + sentenceText(s) + (s.unconfirmed ? " — " + Labels.unconfirmed : "")) }
                if n.editedByUser && !n.expansion.isEmpty { lines.append("    " + Labels.editedByYou) }
            }
            section(Labels.notes, lines)
        }
        if !e.summary.isEmpty { section(Labels.summary, [e.summary]) }
        section(Labels.topics, e.topics.map { "- " + $0 })
        section(Labels.decisions, e.decisions.map { "- " + $0.text + decisionNote($0) + timeSuffix($0.time) })
        section(Labels.tasks, e.tasks.map { t in
            let box = t.status == .done ? "[x]" : "[ ]"
            var parts = [t.text]
            if t.status == .dropped { parts.append(Labels.dropped) }
            parts += taskDetails(t, options: options)
            return "- \(box) " + parts.joined(separator: " · ") + timeSuffix(t.time)
        })
        section(Labels.openQuestions, e.openQuestions.map { "- " + $0 })
        section(Labels.questions, e.questions.flatMap { q in
            var lines = ["- (\(ExportTimestamp.clock(q.time))) " + SingleLineText.flatten(q.text), "    " + SingleLineText.flatten(q.answer)]
            if !q.sources.isEmpty { lines.append("    " + Labels.sources + ": " + q.sources.joined(separator: "; ")) }
            return lines
        })
        if options.includeTranscript && !e.transcript.isEmpty {
            section(Labels.transcript, e.transcript.map { line in
                var entry = "[\(ExportTimestamp.clock(line.start))] \(SingleLineText.flatten(options.speaker(of: line))): \(SingleLineText.flatten(line.text))"
                if let translation = line.translation(options) { entry += "\n    " + SingleLineText.flatten(translation) }
                return entry
            })
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: Shared pieces

    /// "Tuesday, October 7, 2026 at 10:00 AM – 10:45 AM (45 min)".
    public static func dateLine(_ e: MeetingExport, options: MeetingExportOptions) -> String {
        var calendar = options.locale.calendar
        calendar.timeZone = options.timeZone
        let start = e.startedAt.formatted(Date.FormatStyle(date: .complete, time: .shortened, locale: options.locale,
                                                           calendar: calendar, timeZone: options.timeZone))
        guard let end = e.endedAt, let minutes = e.durationMinutes else { return start }
        let endTime = end.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: options.locale,
                                                     calendar: calendar, timeZone: options.timeZone))
        return String(localized: "\(start) – \(endTime) (\(minutes) min)",
                      comment: "Meeting date line in exports: start date and time, end time, duration in minutes")
    }

    /// " — Not confirmed in the transcript" after a decision the transcript does not back; nothing otherwise.
    public static func decisionNote(_ item: MeetingExport.Item) -> String {
        item.unconfirmed ? " — " + Labels.unconfirmed : ""
    }

    /// Owner, due date and what the transcript does not confirm, as separate labelled fields.
    public static func taskDetails(_ t: MeetingExport.TaskEntry, options: MeetingExportOptions) -> [String] {
        var out: [String] = []
        if let owner = t.owner, !owner.isEmpty {
            out.append(String(localized: "Owner: \(owner)", comment: "Task owner in exported minutes"))
            if t.ownerUncertain { out.append(Labels.ownerUnconfirmed) }
        }
        if let due = t.due {
            out.append(String(localized: "Due: \(dueDate(due, options: options))", comment: "Task due date in exported minutes"))
        }
        if t.unconfirmed { out.append(Labels.unconfirmed) }
        return out
    }

    public static func dueDate(_ date: Date, options: MeetingExportOptions) -> String {
        var calendar = options.locale.calendar
        calendar.timeZone = options.timeZone
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: options.locale,
                                               calendar: calendar, timeZone: options.timeZone))
    }

    private static func timeSuffix(_ t: Double?) -> String { t.map { " (\(ExportTimestamp.clock($0)))" } ?? "" }
    static func timePrefix(_ t: Double?) -> String { t.map { "(\(ExportTimestamp.clock($0))) " } ?? "" }

    /// Section titles, localized once here so every format uses the same words.
    enum Labels {
        static var date: String { String(localized: "Date", comment: "Exported minutes: label of the meeting date") }
        static var attendees: String { String(localized: "Attendees", comment: "Exported minutes: label of the attendee list") }
        static var summary: String { String(localized: "Summary", comment: "Exported minutes: section title") }
        static var topics: String { String(localized: "Topics", comment: "Exported minutes: section title") }
        static var decisions: String { String(localized: "Decisions", comment: "Exported minutes: section title") }
        static var tasks: String { String(localized: "Tasks", comment: "Exported minutes: section title") }
        static var openQuestions: String { String(localized: "Open questions", comment: "Exported minutes: section title") }
        static var questions: String { String(localized: "Questions and answers", comment: "Exported minutes: section title for the questions heard in the meeting that the person kept, each with its verified answer") }
        static var sources: String { String(localized: "Sources", comment: "Exported minutes: label before the places where an answer to a question was verified (this meeting, a past meeting, a document)") }
        static var notes: String { String(localized: "Your notes", comment: "Exported minutes: section title for the notes the user typed themselves; it comes first") }
        static var expanded: String {
            String(localized: "Expanded from the transcript", comment: "Exported minutes: line under “Your notes” saying that the indented sentences under each note were written by the model from the transcript, while the note itself is the user’s own words")
        }
        static var editedByYou: String { String(localized: "Edited by you", comment: "Badge on an expansion the user rewrote") }
        static var transcriptSays: String {
            String(localized: "The transcript says:", comment: "Exported minutes: starts a sentence about a note when the transcript says something different from what the user wrote; the sentence follows")
        }
        static var transcript: String { String(localized: "Transcript", comment: "Exported minutes: section title") }
        static var unconfirmed: String {
            String(localized: "Not confirmed in the transcript", comment: "Exported minutes: note after a decision or task the transcript does not back")
        }
        static var ownerUnconfirmed: String {
            String(localized: "Owner not confirmed", comment: "A short mark: nothing in the passage the model cited confirms the owner of a task (a note after the owner in exported minutes, a mark on a line of the brief)")
        }
        static var dropped: String { String(localized: "Dropped", comment: "Exported minutes: status of a task that was dropped") }
    }
}

/// CommonMark escaping for text the user or the model wrote.
enum Markdown {
    /// One line of inline text: line breaks become spaces, and characters that
    /// would start emphasis, code, links, HTML or a block are escaped.
    static func inline(_ text: String) -> String {
        let flat = SingleLineText.flatten(text)
        var out = ""
        let chars = Array(flat)
        for (i, c) in chars.enumerated() {
            switch c {
            case "\\", "`", "*", "[", "]", "<", "~":
                out.append("\\")
            case "_":
                let before = i > 0 ? chars[i - 1] : " "
                let after = i + 1 < chars.count ? chars[i + 1] : " "
                if !(before.isLetter || before.isNumber) || !(after.isLetter || after.isNumber) { out.append("\\") }
            case "#", ">", "+", "-", "|":
                if out.isEmpty { out.append("\\") }
            default:
                break
            }
            out.append(c)
        }
        // "1. text" at the start would become an ordered list.
        if let dot = out.firstIndex(where: { !$0.isNumber }), dot != out.startIndex,
           out[dot] == "." || out[dot] == ")" {
            out.insert("\\", at: dot)
        }
        return out
    }

    /// Paragraphs of a multi-line text (the summary): each non-empty line is
    /// its own paragraph, so the author's line breaks survive.
    static func paragraphs(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.map(inline)
    }
}
