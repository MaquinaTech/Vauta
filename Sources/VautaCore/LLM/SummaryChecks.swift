// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Swift reads the summary the model wrote and removes what the model should not have written, with no model: citations the person cannot
/// use (segment numbers, `[S12]` tags), a sentence said twice, a transcript label ("Me discussed…") as the subject, and the meeting's own
/// date. `fromDigest`: the summary was written from the notes of `MinutesDigest` (Apple's model, long meetings), whose labels ("Background",
/// "Notes") the model may copy; the integrated model never sees them. Figures that the transcript never says are counted, not removed (the count is in the diagnostics). Sentences only disappear
/// or lose a phrase; nothing is added. A summary that would end up empty is left as written.
enum SummaryChecks {
    /// `settled`: the texts of what the meeting settled (the digest's outcomes and the minutes' own decisions and tasks): an open question
    /// that repeats one of them is not open.
    static func apply(_ minutes: ValidatedMinutes, segments: [CitableSegment], meetingDate: Date, timeZone: TimeZone, proseLanguage: String?,
                      settled: [String] = [], maxSentences: Int? = SummaryChecks.maxSentences, restatedQuestions: Bool = true, fromDigest: Bool = true) -> ValidatedMinutes {
        var out = minutes
        if restatedQuestions { dropRestatedQuestions(&out, settled: settled + minutes.decisions.map(\.text) + minutes.tasks.map(\.text)) }
        let original = minutes.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty else { return out }
        let transcript = segments.map(\.text).joined(separator: " ")
        let yearSaid = transcript.contains(year(of: meetingDate, timeZone: timeZone))
        let english = (proseLanguage ?? "en").lowercased().hasPrefix("en")
        var kept: [String] = []
        var keys: [Set<String>] = []
        for raw in sentences(original) {
            var sentence = removingNoteLabels(raw)
            if mentionsBlock(sentence, labels: fromDigest) { out.counts["summary.droppedBlock", default: 0] += 1; continue }
            if hasPlaceholder(sentence) { out.counts["summary.droppedPlaceholder", default: 0] += 1; continue }
            sentence = sentence.replacingOccurrences(of: #"\s*\(Me\)"#, with: "", options: .regularExpression)
            let stripped = removingSegmentAttributions(sentence)
            if stripped != sentence { out.counts["summary.segmentPhrase", default: 0] += 1; sentence = stripped }
            if mentionsSegment(sentence) { out.counts["summary.droppedSegment", default: 0] += 1; continue }
            let day = isoDay(meetingDate, timeZone: timeZone)
            if !yearSaid {
                let yearText = year(of: meetingDate, timeZone: timeZone)
                if sentence.contains(day) {
                    sentence = removingDate(day, from: sentence)
                    out.counts["summary.dateRemoved", default: 0] += 1
                } else if sentence.contains(yearText) {
                    // The meeting's year the transcript never writes as digits (the model copied the date it was given, or the speakers said it in
                    // words): only the year goes, with the preposition before it ("the budget for 2026 was approved" becomes "the budget was
                    // approved"; "due on November 3, 2026" becomes "due on November 3"), so the outcome stays. An ISO date ("2026-11-03") and a
                    // figure that equals the year ("2026 euros") are left as written.
                    // A full date of the meeting's own day goes with its sentence (the model copied today's date); a sentence left with almost
                    // nothing goes too.
                    let dates = removingYear(yearText, fromDatesIn: sentence, meetingDate: meetingDate, timeZone: timeZone)
                    let trimmed = removingYear(yearText, from: dates.text)
                    if dates.ownDay || trimmed.split(whereSeparator: \.isWhitespace).count < 4 {
                        out.counts["summary.droppedDate", default: 0] += 1
                        continue
                    }
                    sentence = trimmed
                    out.counts["summary.yearRemoved", default: 0] += 1
                }
            }
            if english {
                if startsWithLabel(sentence) { out.counts["summary.droppedLabelSubject", default: 0] += 1; continue }
                if let rewritten = rewritingWe(sentence) { sentence = rewritten; out.counts["summary.weRewritten", default: 0] += 1 }
            }
            let key = contentKey(sentence)
            if key.count >= 4, keys.contains(where: { jaccard($0, key) >= 0.8 }) { out.counts["summary.droppedRepeat", default: 0] += 1; continue }
            keys.append(key)
            kept.append(sentence)
        }
        // Apple's digest rule asks for 5 to 8 sentences with the results first, so what runs past the cap is the padding the model adds at the
        // end. The integrated request asks for 5 to 10 sentences ending with the outcomes: it has no cap (`maxSentences` nil), the end is the content.
        if let maxSentences, kept.count > maxSentences { out.counts["summary.droppedExtra"] = kept.count - maxSentences; kept = Array(kept.prefix(maxSentences)) }
        if kept.isEmpty { out.counts["summary.checksEmptied"] = 1 } else { out.summary = kept.joined(separator: " ") }
        let missing = figuresNotSaid(in: out.summary, transcript: transcript)
        if missing > 0 { out.counts["summary.figureNotInTranscript"] = missing }
        return out
    }

    static let maxSentences = 9

    // MARK: Block notes

    /// A block's summary as the digest shows it: no segment numbers or tags, and no sentence that only says nothing was settled.
    static func cleaningBlockSummary(_ text: String) -> String {
        sentences(removingSegmentAttributions(text)).filter { !mentionsSegment($0) && !saysNothingWasSettled($0) }.joined(separator: " ")
    }

    private static let nothingSettled = [
        "no decisions", "no decision", "no tasks", "no se tomaron decisiones", "no se tomo ninguna decision", "sin decisiones", "no hay decisiones", "no se tomaron decisiones ni tareas",
        "aucune decision", "pas de decision", "keine entscheidung", "keine beschlusse", "nessuna decisione", "nenhuma decisao", "nao foram tomadas decisoes",
    ]

    /// "No decisions were made in this block": the model noting what a block lacks, which the summary must not repeat as a result.
    static func saysNothingWasSettled(_ sentence: String) -> Bool {
        let norm = TextKeys.norm(sentence)
        return nothingSettled.contains { norm.contains($0) }
    }

    // MARK: Open questions

    /// An open question that says what a decision or a task says (the model copied an outcome into the list of open questions).
    static func dropRestatedQuestions(_ minutes: inout ValidatedMinutes, settled: [String]) {
        let keys = settled.map(contentKey).filter { $0.count >= 3 }
        guard !minutes.openQuestions.isEmpty, !keys.isEmpty else { return }
        let before = minutes.openQuestions.count
        minutes.openQuestions = minutes.openQuestions.filter { question in
            let q = contentKey(question)
            guard q.count >= 3 else { return true }
            return !keys.contains { jaccard($0, q) >= 0.6 || Double(q.intersection($0).count) / Double(q.count) >= 0.85 }
        }
        if minutes.openQuestions.count < before { minutes.counts["summary.droppedRestatedQuestion"] = before - minutes.openQuestions.count }
    }

    // MARK: Sentences

    /// The sentences of a text, each with its closing mark. A full stop between digits ("12.5") or without a space after it does not end one.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (i, c) in chars.enumerated() {
            current.append(c)
            let wide = "。！？".contains(c)
            guard wide || ".!?".contains(c) else { continue }
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if wide || next == nil || next!.isWhitespace {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                current = ""
            }
        }
        let rest = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    // MARK: Labels of the digest

    /// "Agreed: eight buttons…" → "Eight buttons…": the model copied a label of the notes it was given.
    static func removingNoteLabels(_ sentence: String) -> String {
        let pattern = #"^(?:Agreed|Rejected|Tasks?|Proposed only|Proposed, (?:but )?not confirmed|Results?|Background)\s*:\s*"#
        guard let range = sentence.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return sentence }
        var rest = String(sentence[range.upperBound...])
        if let first = rest.first, first.isLowercase { rest = first.uppercased() + rest.dropFirst() }
        return rest
    }

    /// "Block 15 covered…", "The background covered…": the notes the model was given, which the person never sees.
    static func mentionsBlock(_ sentence: String, labels: Bool = true) -> Bool {
        sentence.range(of: #"\b(?:blocks?|bloques?|blocs?|blöcke?|blocchi?)\s+\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
            || (labels && sentence.range(of: #"^(?:the\s+|this\s+|el\s+|este\s+|la\s+|le\s+|ce\s+|der\s+|dieser\s+)?(?:background|(?:background )?notes|blocks?|bloques?|blocs?|block|el contexto|los antecedentes)\b"#, options: [.regularExpression, .caseInsensitive]) != nil)
    }

    /// The date format of the prompt ("YYYY-MM-DD") copied into the text: a due day the model did not know.
    static func hasPlaceholder(_ sentence: String) -> Bool {
        sentence.range(of: #"\b(?:YYYY|AAAA|JJJJ)-MM-(?:DD|TT|JJ)\b"#, options: .regularExpression) != nil
    }

    // MARK: Segment numbers

    private static let segmentWord = #"(?:segments?|segmentos?|segmento|segment|segmentes?|segmente|segmenti|セグメント|세그먼트)"#
    private static let number = #"\d+(?:\s*(?:,|and|y|e|et|und|to|a|-|–)\s*\d+)*"#

    /// ", according to segment 23" / "como indica el segmento 23" / "(segments 24 and 26)": the attribution goes, the sentence stays.
    static func removingSegmentAttributions(_ text: String) -> String {
        let lead = #"(?:according to|as (?:stated|shown|noted|indicated|said|seen) in|see|per|based on|from|según|segun|como (?:indica|señala|senala|se ve en|consta en|dice)|de acuerdo con|conforme a|selon|d'après|gemäß|laut|secondo|conforme)"#
        let article = #"(?:the|el|la|los|las|le|les|der|die|das|il|lo|gli)?"#
        var out = text
        let patterns = [
            #"\s*[,;(]?\s*"# + lead + #"\s+"# + article + #"\s*"# + segmentWord + #"\s*#?"# + number + #"\s*\)?"#,
            #"\s*\(\s*"# + segmentWord + #"\s*#?"# + number + #"\s*\)"#,
            // "…a favor en el segmento [S22]", "in segment 7"
            #"\s*(?:\b(?:en|in|at|on|dans|im|nel|em)\s+)(?:(?:el|la|los|las|the|le|les|der|il)\s+)?"# + segmentWord + #"\s*#?\[?\s*S?\d+\s*\]?(?:\s*(?:,|and|y|e|et|und)\s*\[?\s*S?\d+\s*\]?)*"#,
            #"\s*\[\s*S\d+(?:\s*[,–-]\s*S?\d+)*\s*\]"#,
        ]
        for pattern in patterns {
            out = out.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        out = out.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        out = out.replacingOccurrences(of: #"([,;])\s*([.!?])"#, with: "$2", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A segment number or an `[S12]` tag still in the sentence.
    static func mentionsSegment(_ sentence: String) -> Bool {
        sentence.range(of: segmentWord + #"\s*#?\d+"#, options: [.regularExpression, .caseInsensitive]) != nil
            || sentence.range(of: #"\[\s*S\d+\s*\]"#, options: .regularExpression) != nil
    }

    // MARK: Date

    private static func isoDay(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func year(of date: Date, timeZone: TimeZone) -> String { String(isoDay(date, timeZone: timeZone).prefix(4)) }

    /// "January 1, 2005", "1 de enero de 2005", "01/01/2005": a full date with the year. The year goes and the day and month stay
    /// ("due on November 3, 2026" becomes "due on November 3"), unless the date is the meeting's own day (`ownDay`), which the caller drops with its sentence.
    static func removingYear(_ year: String, fromDatesIn text: String, meetingDate: Date, timeZone: TimeZone) -> (text: String, ownDay: Bool) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let own = calendar.dateComponents([.month, .day], from: meetingDate)
        let y = NSRegularExpression.escapedPattern(for: year)
        // keep: the group that stays; day and month: the groups that say it (a month is a number or a name).
        let patterns: [(regex: String, keep: Int, day: Int, month: Int)] = [
            (#"((\d{1,2})\s*[/.\-]\s*(\d{1,2}))\s*[/.\-]\s*"# + y + #"(?!\d)"#, 1, 2, 3),
            (#"(\b(\p{L}+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?)\s*,?\s*"# + y + #"(?!\d)"#, 1, 3, 2),
            (#"(\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:de\s+|of\s+)?(\p{L}+)\.?)\s*,?\s*(?:de\s+|del\s+)?"# + y + #"(?!\d)"#, 1, 2, 3),
        ]
        var out = text, ownDay = false
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: [.caseInsensitive]) else { continue }
            // Last match first, so the ranges stay valid while the text changes.
            for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                func group(_ i: Int) -> String? { Range(match.range(at: i), in: out).map { String(out[$0]) } }
                guard let keep = group(pattern.keep), let dayText = group(pattern.day), let monthText = group(pattern.month), let day = Int(dayText),
                      let whole = Range(match.range, in: out) else { continue }
                let month = Int(monthText) ?? monthNumber(monthText)
                // A word before a number is not a date unless it is a month ("Phase 2 2026").
                guard let month else { continue }
                // The numeric form may be day first or month first.
                let isOwn = (day == own.day && month == own.month) || (index == 0 && month == own.day && day == own.month)
                if isOwn { ownDay = true }
                out.replaceSubrange(whole, with: keep)
            }
        }
        return (out, ownDay)
    }

    /// 1 to 12 for a month name in the app's languages (full or abbreviated, accents and case ignored), else nil.
    static func monthNumber(_ word: String) -> Int? {
        let key = TextKeys.norm(word)
        guard key.count >= 3 else { return nil }
        for identifier in ["en", "es", "fr", "de", "it", "pt-BR"] {
            let locale = Locale(identifier: identifier)
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            for names in [calendar.monthSymbols, calendar.shortMonthSymbols] {
                for (i, name) in names.enumerated() {
                    let norm = TextKeys.norm(name).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    if norm == key || (key.count == 3 && norm.hasPrefix(key)) { return i + 1 }
                }
            }
        }
        return nil
    }

    /// "The budget for 2026 was approved" → "The budget was approved": the year and the word before it.
    static func removingYear(_ year: String, from text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: year)
        var out = text.replacingOccurrences(of: #"\s*(?:\b(?:of|in|for|from|during|by|el|en|de|del|para|durante|am|im|für|pour|dans|em|per)\s+)?(?<![\d$€£¥]|\d-)"# + escaped + #"(?!\d|-\d|\s*(?:%|€|\$|£|euros?|dollars?|dólares|dolares|pesos?|pounds?|usd|eur|gbp|people|persons?|personas|units?|unidades|hours?|horas|users?|usuarios|licen[cs]es?|licencias|items?|dollar|k\b))(?:['’]s)?"#, with: "", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        if let first = out.first, first.isLowercase { out = first.uppercased() + out.dropFirst() }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removingDate(_ day: String, from text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: day)
        var out = text.replacingOccurrences(of: #"\s*(?:\b(?:on|of|from|dated|el|del|en|am|le|il)\s+)?"# + escaped, with: "", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        if let first = out.first, first.isLowercase { out = first.uppercased() + out.dropFirst() }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Subject

    /// "Me discussed…", "Me and Speaker 2 agreed…": the label of the user's own channel taken for a word.
    static func startsWithLabel(_ sentence: String) -> Bool {
        sentence.range(of: #"^Me\s+(?:and\s+|,\s*|[a-z])"#, options: .regularExpression) != nil
    }

    /// "We agreed…" → "The group agreed…", for a past-tense verb; other uses of "We" stay.
    static func rewritingWe(_ sentence: String) -> String? {
        guard let match = sentence.firstMatch(of: /^We\s+(\p{Ll}+)/), isPastTense(String(match.output.1)) else { return nil }
        return "The group " + sentence.dropFirst(3)
    }

    private static let irregularPast: Set<String> = ["agreed", "decided", "chose", "met", "went", "set", "made", "took", "ran", "had", "were", "did", "saw", "got", "held", "said", "found", "kept", "left", "built", "sent", "gave", "put", "came", "began", "spent", "heard"]
    private static let notPast: Set<String> = ["need", "feed", "speed", "proceed", "succeed", "exceed", "indeed", "bleed", "breed", "seed", "weed", "heed"]
    private static func isPastTense(_ word: String) -> Bool { (word.hasSuffix("ed") && !notPast.contains(word)) || irregularPast.contains(word) }

    // MARK: Repeats

    static func contentKey(_ sentence: String) -> Set<String> {
        Set(TextKeys.norm(sentence).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 4 || $0.contains(where: \.isNumber) })
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    // MARK: Figures

    private static let spelled: [String: String] = [
        "zero": "0", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
        "eleven": "11", "twelve": "12", "fifteen": "15", "twenty": "20", "thirty": "30", "forty": "40", "fifty": "50", "hundred": "100", "thousand": "1000",
        "dos": "2", "tres": "3", "cuatro": "4", "cinco": "5", "seis": "6", "siete": "7", "ocho": "8", "nueve": "9", "diez": "10",
        "doce": "12", "quince": "15", "veinte": "20", "treinta": "30", "cuarenta": "40", "cincuenta": "50", "cien": "100", "mil": "1000",
    ]

    private static func numbers(in text: String) -> Set<String> {
        var out = Set<String>()
        let norm = TextKeys.norm(text)
        for m in norm.matches(of: /\d+(?:[.,]\d+)*/) { out.insert(String(m.output).replacingOccurrences(of: ",", with: ".")) }
        for word in norm.split(whereSeparator: { !$0.isLetter }) { if let n = spelled[String(word)] { out.insert(n) } }
        return out
    }

    /// How many figures of the summary the transcript never says, as digits or as a common spelled-out number.
    static func figuresNotSaid(in summary: String, transcript: String) -> Int {
        let said = numbers(in: transcript)
        return numbers(in: summary).filter { !said.contains($0) }.count
    }
}
