// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The stored fields a follow-up email is made of. Everything here already exists in the store; nothing is generated.
public struct FollowUpEmailInput: Sendable {
    public struct Decision: Sendable, Equatable {
        public var text: String
        public var unconfirmed: Bool
        public init(text: String, unconfirmed: Bool = false) {
            self.text = text
            self.unconfirmed = unconfirmed
        }
    }

    public struct Task: Sendable, Equatable {
        public var id: Int64
        public var text: String
        /// nil: no person owns it (or only a speaker nobody named: a speaker label never goes into an email).
        public var ownerID: Int64?
        public var ownerName: String?
        public var ownerEmail: String?
        public var ownerUncertain: Bool
        /// The sender's own task, while the person's entity still has the default "Me" stand-in for a name: there is no name to write, and
        /// the email says so in the first person, so the others can tell it from a task nobody owns.
        public var ownerIsSender: Bool
        public var unconfirmed: Bool
        public var dueDay: DueDay?
        public var status: TaskItem.Status
        public init(id: Int64, text: String, ownerID: Int64? = nil, ownerName: String? = nil, ownerEmail: String? = nil, ownerUncertain: Bool = false,
                    ownerIsSender: Bool = false, unconfirmed: Bool = false, dueDay: DueDay? = nil, status: TaskItem.Status = .open) {
            self.id = id
            self.text = text
            self.ownerID = ownerID
            self.ownerName = ownerName
            self.ownerEmail = ownerEmail
            self.ownerUncertain = ownerUncertain
            self.ownerIsSender = ownerIsSender
            self.unconfirmed = unconfirmed
            self.dueDay = dueDay
            self.status = status
        }
    }

    /// "Tuesday 21 October, 10:00": only when an event was created or a candidate was confirmed in the sheet.
    public struct NextMeeting: Sendable, Equatable {
        public var day: DueDay
        public var minuteOfDay: Int?
        public init(day: DueDay, minuteOfDay: Int? = nil) {
            self.day = day
            self.minuteOfDay = minuteOfDay
        }
    }

    public var meetingTitle: String
    public var meetingStart: Date
    /// The zone the meeting was recorded in; the email writes the meeting's date in it, never "today".
    public var timeZone: TimeZone
    public var decisions: [Decision]
    public var tasks: [Task]
    public var openQuestions: [String]
    public var summary: String
    /// The transcript's lines, to check the summary against (figures and names); never put into the email.
    public var transcript: [String]
    public var people: [CandidateEntity]
    public var nextMeeting: NextMeeting?

    public init(meetingTitle: String, meetingStart: Date, timeZone: TimeZone, decisions: [Decision] = [], tasks: [Task] = [], openQuestions: [String] = [],
                summary: String = "", transcript: [String] = [], people: [CandidateEntity] = [], nextMeeting: NextMeeting? = nil) {
        self.meetingTitle = meetingTitle
        self.meetingStart = meetingStart
        self.timeZone = timeZone
        self.decisions = decisions
        self.tasks = tasks
        self.openQuestions = openQuestions
        self.summary = summary
        self.transcript = transcript
        self.people = people
        self.nextMeeting = nextMeeting
    }
}

public struct FollowUpEmailOptions: Sendable, Equatable {
    public enum Mode: String, Sendable { case one, perOwner }
    public var mode: Mode = .one
    /// Off by default: the summary is the one part of the minutes with no citation.
    public var includeSummary = false
    public var includeOpenQuestions = true
    /// Off by default: items the transcript did not back are left out; on, they are marked "(to be confirmed)".
    public var includeUnconfirmed = false
    public var locale: Locale

    public init(locale: Locale, mode: Mode = .one, includeSummary: Bool = false, includeOpenQuestions: Bool = true, includeUnconfirmed: Bool = false) {
        self.locale = locale
        self.mode = mode
        self.includeSummary = includeSummary
        self.includeOpenQuestions = includeOpenQuestions
        self.includeUnconfirmed = includeUnconfirmed
    }
}

/// One email, ready to hand to the person's mail app. Each content line remembers the stored field it was copied from.
public struct FollowUpEmailDraft: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable { case greeting, intro, heading, decision, task, openQuestion, summary, nextMeeting, closing, blank }

    public struct Line: Sendable, Equatable {
        public var kind: Kind
        /// The line as written in the email.
        public var text: String
        /// The stored text copied into the line (a decision, a task, an owner's name, an open question, a summary sentence); nil for fixed
        /// sentences. The tracer checks that this is a stored field and that the line contains it unchanged.
        public var field: String?
        public var taskID: Int64?
        /// Other stored values the line contains (the owner's name, the due day as stored).
        public var extras: [String] = []
    }

    public let id: String
    /// The owner a per-owner draft is for.
    public let ownerName: String?
    public let ownerEmail: String?
    public let subject: String
    public let lines: [Line]

    /// Plain text, one line per row.
    public var plainText: String { lines.map(\.text).joined(separator: "\n") + "\n" }

    /// Markdown: headings in bold.
    public var markdown: String {
        lines.map { $0.kind == .heading ? "**\($0.text)**" : $0.text }.joined(separator: "\n") + "\n"
    }

    /// Whether the draft says anything beyond the greeting (a decision, a task, a question, a summary or a next meeting).
    public var hasContent: Bool { lines.contains { [.decision, .task, .openQuestion, .summary, .nextMeeting].contains($0.kind) } }
}

/// Builds the follow-up email from stored fields with a fixed template (no model). The fixed sentences are in the meeting's language.
public enum FollowUpEmail {
    public static func drafts(_ input: FollowUpEmailInput, options: FollowUpEmailOptions) -> [FollowUpEmailDraft] {
        let words = FollowUpEmailWords.words(for: options.locale)
        let style = Style(code: FollowUpEmailWords.code(of: options.locale))
        let open = input.tasks.filter { $0.status == .open && (options.includeUnconfirmed || !$0.unconfirmed) }
        let decisions = input.decisions.filter { options.includeUnconfirmed || !$0.unconfirmed }
        switch options.mode {
        case .one:
            return [draft(id: "all", owner: nil, tasks: open, decisions: decisions, input: input, options: options, words: words, style: style)]
        case .perOwner:
            var order: [Int64] = []
            var byOwner: [Int64: [FollowUpEmailInput.Task]] = [:]
            for task in open {
                guard let owner = task.ownerID, !task.ownerUncertain, let name = task.ownerName, !name.isEmpty else { continue }
                if byOwner[owner] == nil { order.append(owner) }
                byOwner[owner, default: []].append(task)
            }
            return order.compactMap { owner in
                guard let tasks = byOwner[owner], let first = tasks.first else { return nil }
                return draft(id: "owner-\(owner)", owner: (first.ownerName ?? "", first.ownerEmail), tasks: tasks, decisions: decisions, input: input,
                             options: options, words: words, style: style)
            }
        }
    }

    // MARK: Language-dependent punctuation

    struct Style {
        let code: String
        // French puts a no-break space before the colon, as the draft's subject line does; Japanese and Chinese use the full-width one.
        var colon: String { ["ja", "zh"].contains(code) ? "：" : (code == "fr" ? "\u{00A0}: " : ": ") }
        var comma: String { code == "ja" ? "、" : (code == "zh" ? "，" : ", ") }
        var dash: String { " — " }
        var bullet: String { "- " }
    }

    // MARK: One draft

    private static func draft(id: String, owner: (name: String, email: String?)?, tasks: [FollowUpEmailInput.Task], decisions: [FollowUpEmailInput.Decision],
                              input: FollowUpEmailInput, options: FollowUpEmailOptions, words: FollowUpEmailWords, style: Style) -> FollowUpEmailDraft {
        let locale = options.locale
        let meetingDay = DueDay.containing(input.meetingStart, in: input.timeZone)
        let longDate = meetingDay.formatted(locale: locale)
        let title = SingleLineText.flatten(input.meetingTitle)
        let subject = FollowUpEmailWords.fill(owner == nil ? words.subject : words.subjectOwner, title, meetingDay.shortFormatted(locale: locale))
        var lines: [FollowUpEmailDraft.Line] = []
        func fixed(_ kind: FollowUpEmailDraft.Kind, _ text: String) { lines.append(.init(kind: kind, text: text, field: nil, taskID: nil)) }
        func blank() { if lines.last?.kind != .blank { fixed(.blank, "") } }

        // A per-owner draft greets the person by first name ("Hello Priya,"); the full name is not repeated in the next paragraph.
        let firstName = owner.flatMap { $0.name.split(whereSeparator: \.isWhitespace).first.map(String.init) }
        fixed(.greeting, firstName.map { FollowUpEmailWords.fill(words.helloOwner, $0) } ?? words.hello)
        blank()
        if owner != nil {
            fixed(.intro, FollowUpEmailWords.fill(words.introOwner, longDate))
        } else {
            fixed(.intro, FollowUpEmailWords.fill(words.intro, longDate))
        }

        func section(_ heading: String, _ body: [FollowUpEmailDraft.Line]) {
            guard !body.isEmpty else { return }
            blank()
            fixed(.heading, heading)
            lines += body
        }
        func decisionLines() -> [FollowUpEmailDraft.Line] {
            decisions.map { d in
                let text = SingleLineText.flatten(d.text)
                let mark = d.unconfirmed ? " " + words.toConfirm : ""
                return .init(kind: .decision, text: style.bullet + text + mark, field: text, taskID: nil)
            }
        }
        func taskLines() -> [FollowUpEmailDraft.Line] {
            tasks.map { t in
                let text = SingleLineText.flatten(t.text)
                var line = style.bullet
                var extras: [String] = []
                // The owner is written when the person is named and the owner is not in doubt; in a per-owner draft every task is theirs.
                // The sender's own tasks, which have no name to write, say so in the first person; a task nobody owns says that instead,
                // so no bare line is ambiguous for the people who receive the email.
                let named = !t.ownerUncertain ? t.ownerName.flatMap { $0.isEmpty ? nil : $0 } : nil
                if owner == nil {
                    if let named {
                        line += named + style.colon
                        extras.append(named)
                    } else if t.ownerIsSender, !t.ownerUncertain {
                        line += words.me + style.colon
                    }
                }
                line += text
                if let day = t.dueDay {
                    let formatted = day.formatted(locale: locale)
                    // After a sentence end ("share it.") a comma would read ". , by Monday": a dash joins it instead.
                    let endsSentence = text.last.map { ".。!！?？;；".contains($0) } ?? false
                    line += (endsSentence ? style.dash : style.comma) + FollowUpEmailWords.fill(words.by, formatted)
                    extras.append(day.string)
                }
                if t.unconfirmed { line += " " + words.toConfirm }
                if t.ownerUncertain || (owner == nil && named == nil && !t.ownerIsSender) { line += style.dash + words.ownerToAgree }
                return .init(kind: .task, text: line, field: text, taskID: t.id, extras: extras)
            }
        }

        if options.includeSummary {
            section(words.summary, FollowUpEmailSummary.sentences(of: input).map { .init(kind: .summary, text: $0, field: $0, taskID: nil) })
        }
        if owner != nil {
            // A per-owner draft is one person's tasks: the decisions and open questions are in the one-email draft, and repeating them in
            // every draft repeated every error in them (judged evaluation).
            section(words.nextSteps, taskLines())
        } else {
            section(words.decisions, decisionLines())
            section(words.nextSteps, taskLines())
        }
        if options.includeOpenQuestions, owner == nil {
            section(words.openQuestions, input.openQuestions.map { SingleLineText.flatten($0) }.filter { !$0.isEmpty }
                .map { .init(kind: .openQuestion, text: style.bullet + $0, field: $0, taskID: nil) })
        }
        if let next = input.nextMeeting {
            blank()
            var when = next.day.formatted(locale: locale)
            if let minute = next.minuteOfDay { when += style.comma + next.day.formattedTime(minuteOfDay: minute, locale: locale) }
            fixed(.nextMeeting, FollowUpEmailWords.fill(words.nextMeeting, when))
        }
        blank()
        fixed(.closing, words.regards)
        return FollowUpEmailDraft(id: id, ownerName: owner?.name, ownerEmail: owner?.email, subject: subject, lines: lines)
    }

    // MARK: The language

    /// The language of the email: the minutes' language, else the transcription's, else the app's. `app` is the app's current locale.
    public static func language(minutes: String?, transcription: String?, app: Locale = .current) -> Locale {
        for identifier in [minutes, transcription] {
            if let identifier, !identifier.isEmpty {
                let locale = Locale(identifier: identifier)
                if FollowUpEmailWords.supported.contains(locale.language.languageCode?.identifier ?? "") { return locale }
            }
        }
        return app
    }
}

extension DueDay {
    /// "12 Oct" in `locale`'s wording, never converted through a time zone.
    public func shortFormatted(locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: utcNoon)
    }

    /// "10:00" (or "10:00 AM" where the locale writes it so): a wall-clock time with no zone.
    public func formattedTime(minuteOfDay: Int, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: Double(epochDay) * 86_400 + Double(minuteOfDay) * 60))
    }
}
