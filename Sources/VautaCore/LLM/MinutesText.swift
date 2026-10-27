// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The free-text lists of the minutes (topics, open questions) after the model wrote them. Constrained decoding and the prompts
/// should keep junk out; this is what stops it from reaching the person when they did not (any provider, any server).
enum MinutesText {
    /// A topic as one clean line: no list marker the model copied from markdown or numbering ("- ", "* ", "• ", "1. ", "2) "), no
    /// surrounding quotes or spaces.
    static func topic(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = text.unicodeScalars.first {
            if "-*•·–—▪◦".unicodeScalars.contains(first) {
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let range = text.range(of: #"^\d{1,2}[.)]\s+"#, options: .regularExpression) {
                text.removeSubrange(range)
            } else {
                break
            }
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`").union(.whitespacesAndNewlines))
    }

    /// The sample values the minutes prompts used to show in their JSON shapes: a model (Apple's mostly) may write one back as if it
    /// were content. Compared after `TextKeys.norm`.
    static let promptSamples: Set<String> = Set([
        "questions or issues left unresolved", "3 to 8 short topics", "up to 4 short topics", "3 to 6 topics of a few words each",
        "up to 5 questions or issues left unresolved, one sentence each",
    ].map(TextKeys.norm))

    /// Whether a string is not content but the model talking about its own output or leftovers of the JSON it was writing: a closing
    /// bracket or brace, a code fence, a closing tag, "I will …", or "JSON" used as the word for the model's own reply. Also
    /// strings with fewer than three letters or digits.
    static func isJunk(_ text: String) -> Bool {
        if text.contains("]") || text.contains("}") || text.contains("{") || text.contains("```") || text.contains("</") { return true }
        // A JSON key the model started to write again: a quoted key (`"tasks":`) or a key that opens a list or an object
        // (`decisions: [`). "Open tasks: who owns the rollout?" is a question.
        let keys = "title|summary|topics|decisions|tasks|entities|open_questions"
        if text.range(of: "\"(\(keys))\"\\s*:|\\b(\(keys))\\b\"?\\s*:\\s*[\\[{]", options: .regularExpression) != nil { return true }
        if text.unicodeScalars.filter({ CharacterSet.alphanumerics.contains($0) }).count < 3 { return true }
        let lowered = text.lowercased()
        if Self.promptSamples.contains(TextKeys.norm(text)) { return true }
        if lowered.range(of: #"\bi (will|am going to)\b|\bi['’]ll\b"#, options: .regularExpression) != nil { return true }
        // The same in the other languages the minutes are written in: "I am going to write/generate …".
        if lowered.range(of: #"^(voy a|vamos a|je vais|ich werde|vou|eu vou|vado a|sto per|ora scrivo)\s+(?:\S+\s+){0,3}?(generar|escribir|devolver|producir|crear|écrire|générer|produire|renvoyer|schreiben|erzeugen|generieren|ausgeben|gerar|escrever|devolver|produzir|generare|scrivere|produrre)\b"#, options: .regularExpression) != nil { return true }
        // "JSON" is a word a meeting may use ("should the export be JSON or CSV?"): only the model's own meta-text about its reply is
        // junk.
        if text.range(of: #"\bJSON\b"#, options: .regularExpression) != nil,
           lowered.range(of: #"\b(generate|generating|final|valid|invalid|output|object|correct|fix|repair|format|above|below|here is|here's|aquí|aqui|válido|valido|formato|voici|voilà|valide|gültig|hier ist|ecco)\b"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// The cleaned list: markers stripped (`marker`), junk and repeats dropped, capped at `limit`. `rejected` counts the junk.
    static func list(_ raw: [String], limit: Int, clip: Int, minimum: Int = 1, rejected: inout Int, marker: Bool = false) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for item in raw {
            // An empty string is the shape copied, not junk: skipped without being counted.
            if item.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            // A segment tag the model copied from the transcript ("[S6] What shape…") is not part of the question.
            let cleaned = cleanProse(item)
            let text = PromptText.clip(marker ? topic(cleaned) : cleaned, clip)
            guard text.count >= minimum else { rejected += 1; continue }
            guard !isJunk(text) else { rejected += 1; continue }
            guard seen.insert(TextKeys.norm(text)).inserted else { continue }
            out.append(text)
            if out.count == limit { break }
        }
        return out
    }
}

// MARK: Decisions that are not statements, and the meeting's date restated

extension MinutesText {
    /// Why a decision the model wrote cannot be kept as a decision: too short to say anything, a question, or the transcript line
    /// copied (a decision must be a statement the model wrote). nil when it can.
    static func decisionProblem(text: String, quote: String?, segmentText: String, language: String?) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = QuoteKey.make(trimmed, language: language)
        let noSpace = !key.isEmpty && key.filter { $0.count == 1 && TextKeys.isNoSpaceScript($0.first!) }.count * 2 > key.count
        if noSpace ? trimmed.count < 6 : key.count < 3 { return "tooShort" }
        if trimmed.hasSuffix("?") || trimmed.hasSuffix("？") { return "question" }
        let quoteKey = QuoteKey.make(quote ?? "", language: language)
        if !key.isEmpty, key == quoteKey { return "rawQuote" }
        let segmentKey = QuoteKey.make(segmentText, language: language)
        // A fragment of the line copied (the joke, the aside): the item is a stretch of the segment, or at least 80% of its words are
        // one unbroken stretch of it. Short items are left alone: "approve the budget" may well be said as such.
        if key.count >= (noSpace ? 8 : 4), Double(longestRun(of: key, in: segmentKey)) >= 0.8 * Double(key.count) { return "rawQuote" }
        return nil
    }

    /// The most words of `item` that stand together, in order, in `hay`.
    private static func longestRun(of item: [String], in hay: [String]) -> Int {
        guard !item.isEmpty, !hay.isEmpty else { return 0 }
        var best = 0
        var previous = [Int](repeating: 0, count: hay.count + 1)
        for i in 1...item.count {
            var row = [Int](repeating: 0, count: hay.count + 1)
            for j in 1...hay.count where item[i - 1] == hay[j - 1] {
                row[j] = previous[j - 1] + 1
                best = max(best, row[j])
            }
            previous = row
        }
        return best
    }

    /// The meeting's own date written into the title or the summary ("On 2005-01-01, the team…", "El 1 de enero de 2005, el equipo…")
    /// goes, unless the transcript itself says that day and month. The model is given the date to resolve "tomorrow", not to repeat it.
    static func dropMeetingDate(_ text: String, meetingDate: Date, timeZone: TimeZone, language: String?, segments: [CitableSegment]) -> String {
        var forms: [String] = []
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd"
        iso.timeZone = timeZone
        iso.locale = Locale(identifier: "en_US_POSIX")
        forms.append(iso.string(from: meetingDate))
        var dayMonth: [String] = []
        for code in Array(NSOrderedSet(array: [language.map { String($0.prefix(while: { $0 != "-" && $0 != "_" })) } ?? "en", "en"])) as? [String] ?? ["en"] {
            let locale = Locale(identifier: code)
            for style in [DateFormatter.Style.long, .medium] {
                let f = DateFormatter()
                f.locale = locale
                f.timeZone = timeZone
                f.dateStyle = style
                f.timeStyle = .none
                forms.append(f.string(from: meetingDate))
            }
            for template in ["dMMMM", "dMMM"] {
                let f = DateFormatter()
                f.locale = locale
                f.timeZone = timeZone
                f.setLocalizedDateFormatFromTemplate(template)
                dayMonth.append(TextKeys.norm(f.string(from: meetingDate)))
            }
        }
        // The transcript says that day: the date may be in the summary.
        let said = segments.contains { s in let n = TextKeys.norm(s.text); return dayMonth.contains { !$0.isEmpty && n.contains($0) } }
        guard !said else { return text }
        var out = text
        let prepositions = #"(?:(?:on|el|le|am|il|em|no|a|en|the)\s+)?"#
        for form in Set(forms).sorted(by: { $0.count > $1.count }) where !form.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: form)
            // At the start of the text or of a sentence: "On 2005-01-01, the team…" → "The team…".
            let leading = #"(^|[.!?。！？]\s+)"# + prepositions + escaped + #"\s*[,，:：–—-]?\s*"#
            if let regex = try? NSRegularExpression(pattern: leading, options: [.caseInsensitive]) {
                for m in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                    guard let whole = Range(m.range, in: out), let boundary = Range(m.range(at: 1), in: out) else { continue }
                    let kept = String(out[boundary])
                    var rest = String(out[whole.upperBound...])
                    if let first = rest.first, first.isLowercase { rest = first.uppercased() + rest.dropFirst() }
                    out = String(out[..<whole.lowerBound]) + kept + rest
                }
            }
            out = out.replacingOccurrences(of: #"\s*[\(（]\s*"# + escaped + #"\s*[\)）]"#, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
