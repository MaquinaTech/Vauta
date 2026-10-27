// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Deterministic checks of the suggested agenda against the items it cites, modelled on `MinutesVerifier`: pure, lexical, no model and
/// no cosine (an embedding cannot tell a supported claim from a related one). A line that fails any check is not shown; nothing is
/// repaired. Fewer than two accepted lines hide the whole section.
public enum BriefVerifier {
    public enum Rejection: String, Sendable, Equatable, CaseIterable {
        case empty, tooLong, noCite, tooManyCites, unknownCite, figure, date, code, name, status, overlap, duplicate
    }

    public struct Context: Sendable {
        public let snapshot: BriefSnapshot
        /// The IDs the model was given (a cite outside them is unknown even if the snapshot has it).
        public let offered: Set<String>
        /// Names of the attendees the store resolved to one person.
        public let resolvedNames: [String]
        /// Names of the attendees nobody could be resolved for: a line that names one fails unless a cited item does.
        public let unresolvedNames: [String]
        /// The language of the line (BCP-47), as the model was asked to write it.
        public let language: String
        public let calendar: Calendar

        public init(snapshot: BriefSnapshot, offered: Set<String>, resolvedNames: [String], unresolvedNames: [String], language: String,
                    calendar: Calendar = .current) {
            self.snapshot = snapshot
            self.offered = offered
            self.resolvedNames = resolvedNames
            self.unresolvedNames = unresolvedNames
            self.language = language
            self.calendar = calendar
        }
    }

    public struct Result: Sendable, Equatable {
        public let accepted: [BriefAgendaLine]
        public let rejected: [(line: BriefAgendaLine, reason: Rejection)]

        /// Counts by reason, for diagnostics (never the text).
        public var rejectionCounts: [Rejection: Int] { Dictionary(grouping: rejected, by: \.reason).mapValues(\.count) }
        /// The section is shown only with at least `BriefAgendaPrompt.minimumLines` lines.
        public var isShown: Bool { accepted.count >= BriefAgendaPrompt.minimumLines }

        public static func == (a: Result, b: Result) -> Bool {
            a.accepted == b.accepted && a.rejected.map(\.line) == b.rejected.map(\.line) && a.rejected.map(\.reason) == b.rejected.map(\.reason)
        }
    }

    public static func verify(_ lines: [BriefAgendaLine], context c: Context) -> Result {
        var accepted: [BriefAgendaLine] = []
        var rejected: [(BriefAgendaLine, Rejection)] = []
        var acceptedKeys: [Set<String>] = []
        for line in lines.prefix(BriefAgendaPrompt.maximumLines) {
            if let reason = check(line, context: c, acceptedKeys: acceptedKeys) {
                rejected.append((line, reason))
            } else {
                accepted.append(line)
                acceptedKeys.append(keys(of: stripped(line.text), language: c.language))
            }
        }
        return Result(accepted: accepted, rejected: rejected.map { (line: $0.0, reason: $0.1) })
    }

    // MARK: One line

    static func stripped(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[?\s*\b[bB]\d+\s*\]?"#, with: " ", options: .regularExpression)
    }

    static func keys(of text: String, language: String) -> Set<String> {
        QuestionDedup.keys(text, locale: language).union(QuestionDedup.keys(text, locale: "en"))
    }

    static func check(_ line: BriefAgendaLine, context c: Context, acceptedKeys: [Set<String>]) -> Rejection? {
        let text = stripped(line.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        guard line.text.count <= BriefAgendaPrompt.maximumLineCharacters else { return .tooLong }
        guard !line.cites.isEmpty else { return .noCite }
        guard line.cites.count <= 3 else { return .tooManyCites }
        var cited: [BriefItem] = []
        for id in line.cites {
            guard c.offered.contains(id), let item = c.snapshot.item(id) else { return .unknownCite }
            cited.append(item)
        }
        let corpusLines = cited.compactMap { BriefAgendaPrompt.line($0) }.map { $0.replacingOccurrences(of: #"^\[b\d+\]\s*"#, with: "", options: .regularExpression) }
        let corpus = corpusLines.joined(separator: "\n")
        let corpusNorm = TextKeys.norm(corpus)

        if let reason = checkNumbers(text, cited: cited, corpus: corpus, corpusNorm: corpusNorm, calendar: c.calendar) { return reason }
        if hasUnbackedName(text, cited: cited, corpusNorm: corpusNorm, context: c) { return .name }
        if hasUnbackedStatus(text, cited: cited, corpusNorm: corpusNorm) { return .status }

        let lineKeys = keys(of: text, language: c.language)
        // A template form ("Follow up on [b7]") adds no words of its own beyond its kind's verb: it needs no overlap. Any other line shares
        // at least two content words with what it cites (one when it has only one), so a short invented line cannot pass on a cite alone.
        let own = lineKeys.subtracting(verbKeys(of: line.kind))
        if !own.isEmpty {
            let shared = own.intersection(keys(of: corpus, language: c.language))
            if shared.isEmpty || shared.count < min(2, own.count) { return .overlap }
        }
        if acceptedKeys.contains(where: { QuestionDedup.jaccard(lineKeys, $0) >= 0.6 }) { return .duplicate }
        return nil
    }

    /// The words of a kind's template ("Follow up on", "Decide", "Ask", "Review").
    static func verbKeys(of kind: BriefAgendaLine.Kind) -> Set<String> {
        switch kind {
        case .followUp: keys(of: "follow up followup", language: "en")
        case .decide: keys(of: "decide decision", language: "en")
        case .ask: keys(of: "ask", language: "en")
        case .review: keys(of: "review", language: "en")
        }
    }

    // MARK: Figures, dates and codes

    static func checkNumbers(_ text: String, cited: [BriefItem], corpus: String, corpusNorm: String, calendar: Calendar) -> Rejection? {
        // A number that equals the day, month or year of a cited date vouches for nothing but that date: the dates are cut out of the line
        // and of the cited items (as written in the numeric, month-name and CJK forms), and every figure left must be in a cited item.
        // "Approve 12 units" is not backed by an item dated on the 12th; "20/10" is, for an item due on 20 October.
        var months = Set<Int>(), weekdays = Set<Int>(), dates: [Date] = [], dateNumbers = Set<Int>()
        for item in cited {
            for date in [item.due, item.meetingDate, item.lastMet].compactMap({ $0 }) {
                dates.append(date)
                let p = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
                if let y = p.year { dateNumbers.insert(y); dateNumbers.insert(y % 100) }
                if let m = p.month { dateNumbers.insert(m); months.insert(m) }
                if let d = p.day { dateNumbers.insert(d) }
                if let w = p.weekday { weekdays.insert(w) }
            }
        }
        func withoutDates(_ value: String) -> String {
            dates.reduce(value) { MinutesVerifier.removingDate($1, from: $0, timeZone: calendar.timeZone) }
        }
        let have = Set(MinutesVerifier.figures(in: withoutDates(corpus))).union(MinutesVerifier.hanFigures(in: corpus))
        let spoken = withoutDates(text)
        let wanted = MinutesVerifier.figures(in: spoken) + MinutesVerifier.hanFigures(in: text, excluding: dateNumbers, skippingIndefiniteOne: true).sorted()
        if !wanted.allSatisfy(have.contains) { return .figure }

        let norm = TextKeys.norm(text)
        let mentionedMonths = Set(DateWords.months.filter { DateWords.contains(norm, $0.value) }.map(\.key))
        if !mentionedMonths.isSubset(of: months.union(DateWords.months.filter { DateWords.contains(corpusNorm, $0.value) }.map(\.key))) { return .date }
        let corpusWeekdays = DateWords.mentionedWeekdays(corpusNorm)
        if !DateWords.mentionedWeekdays(norm).isSubset(of: weekdays.union(corpusWeekdays)) { return .date }

        for code in SemanticRanker.codes(in: text) where !PromptText.containsNormalizedWords(corpusNorm, TextKeys.norm(code)) { return .code }
        return nil
    }

    // MARK: Names

    static func hasUnbackedName(_ text: String, cited: [BriefItem], corpusNorm: String, context c: Context) -> Bool {
        let norm = TextKeys.norm(text)
        let corpusWords = Set(corpusNorm.split(separator: " ").map(String.init))
        let resolvedWords = Set(c.resolvedNames.flatMap { TextKeys.norm($0).split(separator: " ").map(String.init) })
        for name in BriefKeywordGate.names(in: text, locale: c.language) {
            let words = name.split(separator: " ").map(String.init)
            if !words.allSatisfy({ corpusWords.contains($0) || resolvedWords.contains($0) }) { return true }
        }
        // A name nobody could be resolved for (also in scripts without capitals) is backed only by a cited item. The given name alone
        // ("Luis to send…") names them too.
        let stopwords = LanguageProfile(identifier: c.language).stopwords
        for name in c.unresolvedNames {
            let key = TextKeys.norm(name)
            guard key.count >= 2 else { continue }
            let parts = key.split(separator: " ").map(String.init)
            let keys = [key] + parts.enumerated().compactMap { index, part -> String? in
                (index == 0 ? part.count >= 3 : part.count >= 4) && !stopwords.contains(part) && parts.count > 1 ? part : nil
            }
            for candidate in keys where nameIsIn(norm, candidate) && !nameIsIn(corpusNorm, candidate) {
                if c.resolvedNames.contains(where: { nameIsIn(TextKeys.norm($0), candidate) }) { continue }
                return true
            }
        }
        return false
    }

    private static func nameIsIn(_ text: String, _ name: String) -> Bool {
        name.unicodeScalars.contains(where: TextKeys.isNoSpaceScript) ? text.contains(name) : PromptText.containsNormalizedWords(text, name)
    }

    // MARK: Status

    static func hasUnbackedStatus(_ text: String, cited: [BriefItem], corpusNorm: String) -> Bool {
        let norm = TextKeys.norm(text)
        let hasDecision = cited.contains { $0.kind == .decision && !$0.unconfirmed }
        for word in BriefStatusWords.claims(in: norm, BriefStatusWords.decided) {
            let inCorpus = BriefStatusWords.isCJK(word) ? corpusNorm.contains(word) : PromptText.containsNormalizedWords(corpusNorm, word)
            if !hasDecision && !inCorpus { return true }
        }
        for word in BriefStatusWords.claims(in: norm, BriefStatusWords.completed) {
            let inCorpus = BriefStatusWords.isCJK(word) ? corpusNorm.contains(word) : PromptText.containsNormalizedWords(corpusNorm, word)
            if !inCorpus { return true }
        }
        return false
    }
}
