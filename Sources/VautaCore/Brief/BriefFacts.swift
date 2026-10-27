// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// An attendee as the brief shows them: the name the store knows when exactly one person matches, else the calendar's name and no
/// history. Never a guess between several people.
public struct BriefPerson: Sendable, Equatable {
    public let name: String
    public let entityID: Int64?
    public let lastMet: Date?
    public let meetingsTogether: Int

    public init(name: String, entityID: Int64?, lastMet: Date?, meetingsTogether: Int) {
        self.name = name
        self.entityID = entityID
        self.lastMet = lastMet
        self.meetingsTogether = meetingsTogether
    }
}

/// A question the last meeting left open and where in the meeting it was last discussed, when that can be found.
public struct BriefOpenQuestion: Sendable, Equatable {
    public let text: String
    public let segmentID: Int64?
    public let t: Double?
    public init(text: String, segmentID: Int64?, t: Double?) {
        self.text = text
        self.segmentID = segmentID
        self.t = t
    }
}

public struct BriefLastMeeting: Sendable, Equatable {
    public let meetingID: Int64
    public let date: Date
    public let title: String
    public let locale: String?
    public let summary: String?
    public let topics: [String]
    public let decisions: [Decision]
    public let openTasks: [TaskItem]
    public let openQuestions: [BriefOpenQuestion]
    /// Files the meeting carries as its materials (attached files and library files linked to it).
    public let materials: [BriefMaterial]

    public init(meetingID: Int64, date: Date, title: String, locale: String?, summary: String?, topics: [String], decisions: [Decision],
                openTasks: [TaskItem], openQuestions: [BriefOpenQuestion], materials: [BriefMaterial]) {
        self.meetingID = meetingID
        self.date = date
        self.title = title
        self.locale = locale
        self.summary = summary
        self.topics = topics
        self.decisions = decisions
        self.openTasks = openTasks
        self.openQuestions = openQuestions
        self.materials = materials
    }
}

public struct BriefMaterial: Sendable, Equatable {
    public let sourceID: Int64
    public let relPath: String
    public let name: String
    public init(sourceID: Int64, relPath: String, name: String) {
        self.sourceID = sourceID
        self.relPath = relPath
        self.name = name
    }
}

/// An open task with the date of the meeting it came from.
public struct BriefTaskFact: Sendable, Equatable {
    public let task: TaskItem
    public let meetingDate: Date?
    public init(task: TaskItem, meetingDate: Date?) {
        self.task = task
        self.meetingDate = meetingDate
    }
}

/// A chain of tasks the person confirmed as the same: how many mentions it has and when the first was.
public struct BriefChainInfo: Sendable, Equatable {
    /// The newest member, which stands for the chain.
    public let newest: Int64
    public let mentions: Int
    public let since: Date
    public init(newest: Int64, mentions: Int, since: Date) {
        self.newest = newest
        self.mentions = mentions
        self.since = since
    }
}

/// A confirmed link of a decision to an earlier one.
public enum BriefDecisionLink: Sendable, Equatable {
    /// "first decided on…": the date of the first decision of the chain.
    case same(first: Date)
    /// "replaces the decision of…": the earlier decision's words and date. Both decisions are shown.
    case changes(earlierText: String, earlierDate: Date)
}

/// Everything the store knows that the brief needs, gathered by SELECTs only (nothing is written before a meeting is recorded).
public struct BriefFacts: Sendable, Equatable {
    public var seriesID: Int64?
    public var seriesName: String?
    public var selfEntityID: Int64?
    public var people: [BriefPerson] = []
    public var last: BriefLastMeeting?
    public var openTasks: [BriefTaskFact] = []
    /// Documents sources the person marked as holding notes exported from Notes.
    public var notesSourceIDs: Set<Int64> = []
    /// Tasks with a live reminder in the ledger of actions (shown once, as the task, with an "In Reminders" mark).
    public var remindersTaskIDs: Set<Int64> = []
    /// The chains of tasks the person confirmed as the same task, by every member's id (post-meeting actions, Part B).
    public var taskChains: [Int64: BriefChainInfo] = [:]
    /// What the person confirmed about a decision against an earlier one, by the newer decision's id.
    public var decisionLinks: [Int64: BriefDecisionLink] = [:]

    public init() {}

    /// Any earlier meeting at all with these people or this series.
    public var hasHistory: Bool { last != nil || people.contains { $0.meetingsTogether > 0 } }
}

/// Where an open question was last discussed: the words of the question that a stretch of the meeting shares.
public enum BriefOpenQuestionLocator {
    /// Consecutive segments read together.
    public static let windowSegments = 3
    public static let minimumWords = 2

    /// The segment inside the window that shares the most content words with the question, when a window of three consecutive
    /// segments shares at least two (distinct). Ties go to the earlier window. nil: the question links to the meeting only.
    public static func locate(question: String, in segments: [(id: Int64, t: Double, text: String)], locale: String?) -> (id: Int64, t: Double)? {
        let language = locale ?? Locale.current.identifier
        let wanted = QuestionDedup.keys(question, locale: language)
        guard wanted.count >= minimumWords, !segments.isEmpty else { return nil }
        let keys = segments.map { QuestionDedup.keys($0.text, locale: language).intersection(wanted) }
        var best: (matches: Int, segment: Int)?
        for start in 0..<segments.count {
            let end = min(segments.count, start + windowSegments)
            let union = keys[start..<end].reduce(into: Set<String>()) { $0.formUnion($1) }
            guard union.count >= minimumWords else { continue }
            if let current = best, current.matches >= union.count { continue }
            // The segment of the window that holds the most of them (the earliest on a tie).
            let inner = (start..<end).max { keys[$0].count == keys[$1].count ? $0 > $1 : keys[$0].count < keys[$1].count } ?? start
            best = (union.count, inner)
        }
        return best.map { (segments[$0.segment].id, segments[$0.segment].t) }
    }
}

enum BriefText {
    /// Words whose full stop does not end a sentence ("Sra.", "Dr.", "Mrs."), folded to lower case without accents.
    static let abbreviations: Set<String> = [
        "sr", "sra", "srta", "sres", "dr", "dra", "ud", "uds", "mr", "mrs", "ms", "prof", "vs", "nro", "ej", "pág",
        "pag", "mme", "mlle", "herr", "frau", "sig", "sigg", "dott", "ing", "lic", "arq", "cia", "dpto", "excmo", "ilmo", "gral", "avda", "tel",
    ]

    /// Words that end a sentence when a capitalised word follows ("…staffing, etc. The board…", "…se votó que no. Luego…") and do not
    /// when a lower-case word or a figure does ("etc. and more", "No. 5").
    static let endsBeforeCapital: Set<String> = ["etc", "no"]

    /// The sentences of a summary, in order (full stop, "!" or "?" followed by a space or the end, or a CJK full stop). A full stop after an
    /// abbreviation or a single letter does not end one.
    static func sentences(_ text: String) -> [String] {
        let flat = SingleLineText.flatten(TextSanitizer.clean(text)).trimmingCharacters(in: .whitespaces)
        var out: [String] = []
        var start = flat.startIndex
        for index in flat.indices {
            let ch = flat[index]
            var ends = "。！？".contains(ch)
            if !ends, ".!?".contains(ch) {
                let next = flat.index(after: index)
                ends = next == flat.endIndex || flat[next] == " "
                if ends, ch == "." {
                    var wordStart = index
                    while wordStart > start {
                        let before = flat.index(before: wordStart)
                        if flat[before].isLetter { wordStart = before } else { break }
                    }
                    let word = String(flat[wordStart..<index])
                    let folded = TextKeys.norm(word)
                    if next != flat.endIndex {
                        let following = flat[next...].first { $0 != " " }
                        if word.isEmpty, isDayOrdinal(in: flat, before: index) {
                            // "am 28. Oktober", "am 28. beizubehalten": a day number with its ordinal dot (de) does not end the sentence
                            // when a lower-case word or a month name follows.
                            let nextWord = flat[next...].drop { $0 == " " }.prefix { $0.isLetter }
                            if following?.isLowercase == true || isMonthName(String(nextWord)) { ends = false }
                        } else if abbreviations.contains(folded) {
                            ends = false
                        } else if endsBeforeCapital.contains(folded) {
                            ends = following.map { !$0.isLowercase && !$0.isNumber } ?? true
                        } else if word.count == 1 {
                            // An initial ("J. Smith") is an uppercase letter before a capitalised word; any other single letter ends the sentence.
                            let isInitial = word.first?.isUppercase == true && following?.isUppercase == true
                            if isInitial { ends = false }
                        }
                    }
                }
            }
            if ends {
                let end = flat.index(after: index)
                let piece = flat[start..<end].trimmingCharacters(in: .whitespaces)
                if !piece.isEmpty { out.append(piece) }
                start = end
            }
        }
        let rest = flat[start...].trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// The full stop at `index` follows a one- or two-digit number that stands alone ("28.", not "2028." or "3.5").
    private static func isDayOrdinal(in text: String, before index: String.Index) -> Bool {
        var digits = 0
        var cursor = index
        while cursor > text.startIndex {
            let before = text.index(before: cursor)
            guard text[before].isNumber else { break }
            digits += 1
            cursor = before
        }
        guard (1...2).contains(digits) else { return false }
        return cursor == text.startIndex || !(text[text.index(before: cursor)].isLetter || text[text.index(before: cursor)] == "." || text[text.index(before: cursor)] == ",")
    }

    private static func isMonthName(_ word: String) -> Bool {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return !folded.isEmpty && DateWords.months.contains { $0.value.contains(folded) }
    }

    /// The first sentence of a summary, at most `limit` characters.
    static func firstSentence(_ text: String, limit: Int = 220) -> String {
        clip(sentences(text).first ?? "", limit: limit)
    }

    /// The first sentence of a summary that does not date its meeting differently from the stored date: a summary written by a model may
    /// carry a wrong reference date ("on 2005-01-01"), and the brief shows the date it holds. nil when every sentence disagrees.
    static func firstSentence(_ text: String, meetingDate: Date?, calendar: Calendar = .current, limit: Int = 220) -> String? {
        guard let meetingDate else { return sentences(text).first.map { clip($0, limit: limit) } }
        for sentence in sentences(text) where !datesAnotherDay(sentence, than: meetingDate, calendar: calendar) { return clip(sentence, limit: limit) }
        return nil
    }

    /// The sentence writes a day other than `meetingDate`: an ISO date, a day and a month in words ("1 January", "1 de enero de 2005",
    /// "1. Januar", "January 1") or a CJK month and day. The meeting's own day, written in any of these forms, is fine; a month with no
    /// day ("the January pricing") is not a date.
    static func datesAnotherDay(_ sentence: String, than meetingDate: Date, calendar: Calendar) -> Bool {
        let held = calendar.dateComponents([.month, .day], from: meetingDate)
        let heldISO = isoDay(meetingDate, calendar: calendar)
        if isoDays(in: sentence).contains(where: { $0 != heldISO }) { return true }
        let text = sentence.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var monthOf: [String: Int] = [:]
        for (month, names) in DateWords.months { for name in names { monthOf[name] = month } }
        let names = monthOf.keys.sorted { $0.count > $1.count }.joined(separator: "|")
        func other(_ pattern: String, day: Int, month: (NSTextCheckingResult) -> Int?) -> Bool {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let d = Int(ns.substring(with: match.range(at: day))), let m = month(match) else { continue }
                if d != held.day || m != held.month { return true }
            }
            return false
        }
        let ns = text as NSString
        if other(#"\b(\d{1,2})(?:st|nd|rd|th|º|ª|er|\.)?\s*(?:de\s+|of\s+|di\s+|do\s+)?("# + names + #")\b"#, day: 1, month: { monthOf[ns.substring(with: $0.range(at: 2))] }) { return true }
        if other(#"\b("# + names + #")\s+(\d{1,2})(?:st|nd|rd|th)?\b"#, day: 2, month: { monthOf[ns.substring(with: $0.range(at: 1))] }) { return true }
        return other(#"(\d{1,2})\s*[月월]\s*(\d{1,2})\s*[日일]"#, day: 2, month: { Int(ns.substring(with: $0.range(at: 1))) })
    }

    static func isoDay(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func isoDays(in text: String) -> [String] {
        var out: [String] = []
        var search = text.startIndex..<text.endIndex
        while let r = text.range(of: #"\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression, range: search) {
            out.append(String(text[r]))
            search = r.upperBound..<text.endIndex
        }
        return out
    }

    private static func clip(_ sentence: String, limit: Int) -> String {
        sentence.count <= limit ? sentence : String(sentence.prefix(limit - 1)) + "…"
    }

    static func line(_ text: String, limit: Int = 200) -> String { TextSanitizer.oneLine(text, limit: limit) }
}
