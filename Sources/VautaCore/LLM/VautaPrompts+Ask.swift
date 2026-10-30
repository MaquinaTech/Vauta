// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension VautaPrompts {
    /// Passages retrieved from several meetings, as delimited material.
    /// `ordered` (`AskHarness.order`): oldest first, and with two or more meetings each heading says the place of its meeting among
    /// them ("Meeting 2 of 3"), so "the first meeting" and "the last one" can be counted.
    public static func passagesMessage(_ passages: [RetrievedPassage], timeZone: TimeZone = .current, ordered: Bool = false) -> ChatMessage {
        guard ordered else {
            return .user("<<<EXCERPTS FROM YOUR MEETINGS\n" + passages.map { p in
                "## \(PromptText.defang(p.meeting.displayTitle)) (\(PromptText.day(p.meeting.startedAt, timeZone: timeZone)))\n"
                    + p.segments.map(line).joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n>>>")
        }
        let sorted = passages.sorted { ($0.meeting.startedAt, $0.meeting.id, $0.start) < ($1.meeting.startedAt, $1.meeting.id, $1.start) }
        var order: [Int64] = []
        for p in sorted where !order.contains(p.meeting.id) { order.append(p.meeting.id) }
        let several = order.count > 1
        func heading(_ p: RetrievedPassage) -> String {
            let place = several ? (order.firstIndex(of: p.meeting.id) ?? 0) + 1 : 0
            let label = !several ? "" : "Meeting \(place) of \(order.count)\(place == 1 ? ", the oldest" : place == order.count ? ", the most recent" : ""): "
            return "## \(label)\(PromptText.defang(p.meeting.displayTitle)) (\(PromptText.day(p.meeting.startedAt, timeZone: timeZone)))"
        }
        return .user("<<<EXCERPTS FROM YOUR MEETINGS" + (several ? " (oldest meeting first)" : "") + "\n" + sorted.map { p in
            heading(p) + "\n" + p.segments.map(line).joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n>>>")
    }

    /// About time: the model reads the meeting up to the moment of the question. Stronger wordings (the meeting is still going on; check
    /// first that the thing has really been said) were tried on the ten questions whose answer comes later and moved nothing; this one
    /// is the shortest. It must not hand the model a sentence to repeat: Apple's model answered "It has not been said yet." to nearly
    /// every question when the prompt said so.
    static let timeRule = """
        - Only what has been said up to now counts. If the answer may come later (a presentation, a vote or a decision that has not happened \
        yet in the material), do not answer with earlier material: found is false.
        """

    /// The rule above is for a meeting in progress: the material ends at the moment of the question. For a finished meeting or the
    /// whole library the material is complete, and "may come later" would only make the model refuse questions about plans.
    static let finishedRule = """
        - The material is complete. Answer from what it says, including plans and things still to happen if the material says so.
        """

    /// The rule for a question about a decision, a vote or an agreement.
    static let proposalRule = """
        - A proposal, a motion sent to a committee and a decision are different things. Say a thing was decided, approved or agreed \
        only if the material says it was; otherwise say it was proposed or sent on.
        """

    /// The rule for any other question (`AskHarness.factRule`): the facts, as the material states them. It says nothing about proposals,
    /// which Apple's model wrote into answers about a figure or a name.
    static let factsRule = """
        - Answer with the facts the material states (names, figures, reasons, dates), as it states them.
        """

    /// The question goes last, after the material (so the prefix stays cached).
    /// `language`: the language of the question. `documents`: the material also has excerpts of the person's documents. `live`: the
    /// meeting is being recorded and the question is about it, so the material ends now (see `timeRule`). `laterGuard`: the integrated
    /// model's live answer has three words for `found` (below). `shortAnswer`: a model with a small window (Apple's): at most three
    /// sentences and three claims.
    ///
    /// The keys are described in words and the shape shows empty strings, never sample text: a model (Apple's, mostly) writes
    /// back what it is shown. Everything the model must know about the answer's shape is here, for all three providers; the
    /// integrated model's grammar and a server's `response_format` enforce the same shape.
    public static func askInstruction(_ question: String, language: OutputLanguage, documents: Bool = false, live: Bool = false,
                                      laterGuard: Bool = false, shortAnswer: Bool = false, claimCap: Int? = nil, heard: Bool = false,
                                      decisionRule: Bool = true) -> ChatMessage {
        .user(askQuestionBlock(question, heard: heard) + "\n" + askRulesText(language: language, documents: documents, live: live, laterGuard: laterGuard, shortAnswer: shortAnswer, claimCap: claimCap, decisionRule: decisionRule))
    }

    /// The integrated model's layout: the rules are part of the second message of the kept prefix (the list of people, which they
    /// follow), so they are read before the transcript and a transcript that grows never invalidates them. They do not depend on the
    /// language of the question (that line is in the question message), only on the documents and on live or finished, which are
    /// stable for a session. The question is the last message, so a question costs its own tokens.
    ///
    /// `timeless`: the rules of the kept prefix. They say nothing about time and use the boolean `found`: whether the meeting is
    /// still recorded or already finished is not a property of the prefix (it is the same one from the first tick to the minutes
    /// and the questions after them), so each question brings its own time rule (`askTimingRules`).
    public static func askRulesBody(documents: Bool = false, live: Bool = false, laterGuard: Bool = false, afterMaterial: Bool = false,
                                    timeless: Bool = false) -> String {
        (afterMaterial ? "How to answer the question about the material above (the question follows):\n"
                       : "If you are asked a question about the transcript that follows, answer it by these rules (the question comes after the transcript):\n")
            + askRulesText(language: nil, documents: documents, live: live, laterGuard: laterGuard, shortAnswer: false, timeless: timeless)
    }

    /// What the question message adds to a timeless prefix: the rule about time (see `timeRule`, `finishedRule`) and, for a live
    /// answer with the three words, what `found` means for this question.
    public static func askTimingRules(live: Bool, laterGuard: Bool) -> String {
        (live ? timeRule : finishedRule)
            + (laterGuard ? "\nFor this question \(laterFound); where the shape shows true, write \"yes\". If it is not \"yes\", \"claims\" is []." : "")
    }

    /// The question, with what changed since the prefix was read (`delta`: names, new people) and the language to answer in. The rules
    /// (JSON keys in English, how to write quotation marks) are in the kept prefix: they do not depend on the language.
    public static func askQuestionMessage(_ question: String, language: OutputLanguage, delta: String = "", timing: String = "", heard: Bool = false) -> ChatMessage {
        .user((delta.isEmpty ? "" : delta + "\n") + askQuestionBlock(question, heard: heard) + "\n\(language.instruction)"
              + (timing.isEmpty ? "" : "\n" + timing)
              + "\nAnswer it now, following the rules given above.")
    }

    /// `heard`: a question that someone asked aloud in the meeting (rewritten by the model, so untrusted), not one the user typed.
    private static func askQuestionBlock(_ question: String, heard: Bool = false) -> String {
        """
        \(heard ? "A question heard in the meeting" : "The user's question") (answer only with what is in the material above):
        <<<QUESTION
        \(PromptText.defang(PromptText.clip(question, 1000)))
        >>>
        """
    }

    /// The meaning of `found` on a live answer of the integrated model: three words, so a question about something that has not
    /// happened yet is not forced into "yes" or "no". There is no sentence for the model to copy.
    static let laterFound = """
        "found": "yes" if what has been said so far answers it; "not_yet" if the question is about something that has not happened yet in \
        the meeting (a presentation, a vote, a decision still to come), even if earlier remarks are related; "no" if the meeting does not touch it
        """

    private static func askRulesText(language: OutputLanguage?, documents: Bool, live: Bool, laterGuard: Bool, shortAnswer: Bool, claimCap: Int? = nil, timeless: Bool = false, decisionRule: Bool = true) -> String {
        let ids = "[]"
        let laterGuard = laterGuard && !timeless
        let live = live && !timeless
        let cites = documents ? "the tags of the segments (S and the number) or excerpts (D and the number)" : "the numbers of the segments"
        let items = documents ? "cited item" : "cited segment"
        let missing = documents ? "the user's meetings or documents" : "the user's meetings"
        let foundLine = laterGuard
            ? "\(laterFound);"
            : "\"found\": true if the material answers the question, false if it does not\(live ? " (or the answer comes later in the meeting)" : "");"
        let foundShape = laterGuard ? "\"yes\"" : "true"
        let yesWord = laterGuard ? "\"found\" is \"yes\"" : "\"found\" is true", noWord = laterGuard ? "\"found\" is \"no\"" : "\"found\" is false"
        let claimsLine = laterGuard
            ? "\"claims\": if found is \"yes\", one or more claims, each one concrete fact of the answer with \(cites) that support it and a quote copied verbatim from one of them; otherwise an empty list."
            : "\"claims\": if found is true, one or more claims, each one concrete fact of the answer with \(cites) that support it and a quote copied verbatim from one of them; if found is false, an empty list."
        return """
            Rules:
            \(timeless ? "" : (live ? timeRule : finishedRule) + "\n")\(decisionRule ? proposalRule : factsRule)
            - \(yesWord) only if the material says the answer. An answer that says the material does not specify, mention or say it is a \
            refusal: \(noWord). If the material answers only a part of the question, answer that part.
            - Write the answer as plain sentences. Never put segment numbers, [S…] tags or times inside "answer" or in a claim's "text"; \
            they go in "citations" only.
            \(shortAnswer ? "- Answer in at most 3 sentences and at most \(claimCap ?? 3) claims.\n" : claimCap.map { "- Write at most \($0) claims.\n" } ?? "")\
            Reply with one JSON object whose keys come in this order:
            \(foundLine)
            "answer": the answer to the question, in a few sentences;
            \(claimsLine)
            Shape: {"found": \(foundShape), "answer": "", "claims": [{"text": "", "citations": \(ids), "quote": ""}]}
            The "quote" is a phrase of 4 to 15 words copied word for word from ONE \(items), exactly as written there (keep repeated words, \
            do not join two segments or correct the wording), in the language of the material. If found is \(laterGuard ? "\"no\" or \"not_yet\"" : "false"), "answer" says, in \
            the language of the question, that you cannot find it in \(missing)\(laterGuard ? " (or that it has not come up yet)" : ""), and "claims" is [].
            \(language.map { "\($0.instruction) JSON keys stay in English. Inside text, write quotation marks as « » or ' '." } ?? "Answer in the language of the question. JSON keys stay in English. Inside text, write quotation marks as « » or ' '.")
            """
    }

    /// An answer as the model writes it: English keys, or the legacy Spanish ones.
    struct RawAnswer: Decodable {
        struct Claim: Decodable {
            let text: String?, citations: [Int64], quote: String?
            /// `D<number>` citations of excerpts from documents (the number is per request).
            let documentCitations: [Int]
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                text = c.text("text", "texto")
                citations = c.ids("citations", "citas")
                quote = c.text("quote", "cita_literal", "cita")
                documentCitations = Self.documentIDs(c)
            }

            private static func documentIDs(_ c: KeyedDecodingContainer<AnyKey>) -> [Int] {
                for key in ["citations", "citas"] {
                    guard let list = try? c.decodeIfPresent([Lossy<String>].self, forKey: AnyKey(key)) else { continue }
                    return list.compactMap { item -> Int? in
                        guard let s = item.value?.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")), let first = s.first, first == "D" || first == "d" else { return nil }
                        return Int(s.dropFirst().prefix { $0.isASCII && $0.isNumber })
                    }
                }
                return []
            }
        }
        let found: Bool?
        /// `"found": "not_yet"`: the question is about something that has not happened yet (a live answer).
        let notYet: Bool
        let answer: String?
        let claims: [Claim]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            let word = c.text("found", "encontrado")?.trimmingCharacters(in: .whitespaces).lowercased()
            notYet = word.map { ["not_yet", "not yet", "later", "todavia", "todavía"].contains($0) } ?? false
            found = notYet ? false : c.flag("found", "encontrado")
            answer = c.text("answer", "respuesta")
            claims = c.list(Claim.self, "claims", "afirmaciones") ?? []
        }
    }

    /// Each claim must cite segments (or excerpts of documents, `D1`, `D2`…) that were sent and its verbatim quote must
    /// appear (normalized) in one of them. `documents` maps the per-request IDs to the passages that were sent: an ID that
    /// is not in it is dropped, so a model cannot cite a passage it was not given. A claim that rests only on a document
    /// is also checked for its figures: "1.2M" in the claim must be in the passage.
    ///
    /// The model's `found` decides between an answer and a refusal, and the shape is held to:
    /// - `found` true needs a claim that cites something that was sent; otherwise the reply is rejected (`invalidResponse`, which the
    ///   service answers with one more request). Its claims may all fail verification: it is then shown as unverified, not refused.
    /// - `found` false is a refusal: no claims, and no text of the model's (the app writes the refusal in the person's language);
    ///   a long answer written under `found` false is kept in `withheld` only.
    /// - A reply with no `found` key is an answer when it has a claim, and rejected when it has none (it cannot be told from an
    ///   uncited answer, which is what the shape rules out).
    ///
    /// `keepCutAnswer`: on the integrated model a live answer that was cut inside its first claim ends with a claim whose quote is
    /// only the grammar's closing filler; the sentence before it was written in full, so it is kept as an unverified answer.
    ///
    /// `pool`: the segments that were visible when the question was asked. A quote that is not in the segment the model cited but is
    /// in another one of the pool (word for word, ignoring case, punctuation, spacing and filler words) is verified against that
    /// segment, the nearest occurrence to the one cited (`QuoteAnchor`). `language`: the transcript's language code, for the filler words;
    /// `answerLanguage`: the language the answer is written in (the question's), for numbers written as words. `languages`: the
    /// transcription language of each sent segment when the answer spans meetings (the library); a segment it lacks uses `language`.
    public static func verifyAnswer(_ content: String, sent: [Int64: CitableSegment], documents: [String: DocumentPassage] = [:],
                                    keepCutAnswer: Bool = false, answerCapBytes: Int = OutputSchemas.answerBytes, pool: QuoteAnchor.Pool? = nil, language: String? = nil,
                                    answerLanguage: String? = nil, languages: [Int64: String] = [:]) throws -> VerifiedAnswer {
        let raw = try ModelOutput.decodeObject(RawAnswer.self, from: content)
        var claims: [VerifiedAnswer.Claim] = []
        var cut = 0
        var dropped = max(0, raw.claims.count - 12)
        let codes = Set(sent.keys.map { "S\($0)" }).union(documents.keys)
        for a in raw.claims.prefix(12) {
            guard let text = a.text.map({ MinutesText.cleanProse(PromptText.clip($0, 600), codes: codes, language: answerLanguage ?? language) }), !text.isEmpty else { dropped += 1; continue }
            // A claim with no quote is what the grammar writes to close a claim when the cap fires inside its text (the shortest valid
            // ending: the smallest segment number and filler for the quote). The model never chose that citation: the claim is dropped.
            // A quote or a sentence of only dots and punctuation ("........") is the same filler. The cut is counted: the answer is
            // flagged as cut short even when other claims were finished.
            guard AnswerText.hasWords(a.quote ?? ""), AnswerText.hasWords(text) else { cut += 1; dropped += 1; continue }
            let cited = a.citations.filter { sent[$0] != nil }
            let citedDocs = a.documentCitations.compactMap { n in documents["D\(n)"] }
            let quote = TextKeys.norm(a.quote ?? "")
            var matching = cited.filter { id in
                QuoteAnchor.resolve(quote: a.quote, cited: id, citedText: sent[id]?.text, pool: nil, language: languages[id] ?? language) != nil
            }
            var anchoredFrom: Int64?
            if matching.isEmpty, let pool {
                // Any segment the model cited that was visible (sent or not) holds the quote as it is; else the nearest occurrence to the first.
                matching = a.citations.filter { id in
                    QuoteAnchor.resolve(quote: a.quote, cited: id, citedText: sent[id]?.text ?? pool.segment(id)?.text, pool: nil, language: languages[id] ?? language) != nil
                }
                if matching.isEmpty, let first = a.citations.first,
                   let found = QuoteAnchor.resolve(quote: a.quote, cited: first, citedText: sent[first]?.text, pool: pool, language: languages[first] ?? language) {
                    matching = [found.segment]
                    if case .reanchored = found.how { anchoredFrom = first }
                }
            }
            let matchingDocs = citedDocs.filter { quote.count >= 8 && TextKeys.norm(body(of: $0)).contains(quote) }
            var verified = !matching.isEmpty
            if verified {
                // The quote alone is not enough: the claim's figures must be in the segments that hold it too, with digits or in
                // words ("ninety one percent" for 91 %), as for the minutes. A claim of "50.000" over a segment that says "5.000" is
                // not verified.
                let backing = matching.compactMap { sent[$0]?.text ?? pool?.segment($0)?.text }.joined(separator: "\n")
                let spoken = Array(Set(matching.compactMap { languages[$0] ?? language }))
                verified = MinutesVerifier.figuresAreInSegment(item: withoutCodes(text, codes), segment: backing, spokenIn: spoken)
            }
            if !matchingDocs.isEmpty, !verified {
                // A document backs it: the figures of the claim must be in the passage too.
                verified = MinutesVerifier.figuresAreInSegment(item: withoutCodes(text, codes), segment: matchingDocs.map(body(of:)).joined(separator: "\n"))
            }
            // What backs a verified claim is shown; what was merely cited alongside it is not. An unverified claim shows what it cited.
            let shownDocs = (matchingDocs.isEmpty ? (verified ? [] : citedDocs) : matchingDocs).map { DocumentCitation($0, quote: a.quote) }
            let shownSegments = matching.isEmpty ? (verified ? [] : cited) : matching
            claims.append(.init(id: "claim-\(claims.count)", text: text, citations: shownSegments, verified: verified,
                                documents: Array(NSOrderedSet(array: shownDocs)) as? [DocumentCitation] ?? shownDocs,
                                reanchoredFrom: anchoredFrom, figureMissing: !verified && !(matching.isEmpty && matchingDocs.isEmpty)))
        }
        let sentence = MinutesText.cleanProse(PromptText.clip(raw.answer ?? "", 2000), codes: codes, language: answerLanguage ?? language)
        let hasCitedClaim = claims.contains { !$0.citations.isEmpty || !$0.documents.isEmpty }
        if raw.notYet {
            return VerifiedAnswer(answer: "", claims: [], found: false, withheld: AnswerText.isPlaceholder(sentence) ? "" : sentence, notYet: true)
        }
        if raw.found == false {
            return VerifiedAnswer(answer: "", claims: [], found: false, withheld: AnswerText.isPlaceholder(sentence) ? "" : sentence)
        }
        // Found (said so, or implied by a claim) needs at least one claim that cites something that was sent. A reply that gives
        // nothing to check (a server with no JSON schema, Apple's free text, a reply with no `found` and no claims) breaks the
        // shape: it is rejected, and the service asks once more. It is neither shown as found nor turned into a refusal.
        // Found, but no claim verified and the sentence only says the material does not specify it: the prose and `found` must agree,
        // so it is a refusal. An answer with at least one verified claim is never turned into a refusal: "No, the price is not stated"
        // backed by a quote is a correct negative answer.
        if !claims.contains(where: \.verified), AnswerText.declaresNothingFound(sentence) {
            return VerifiedAnswer(answer: "", claims: [], found: false)
        }
        guard hasCitedClaim else {
            if keepCutAnswer, raw.found == true, cut > 0, !AnswerText.isPlaceholder(sentence) {
                return VerifiedAnswer(answer: sentence, claims: [], found: true, cutShort: true, droppedClaims: dropped)
            }
            throw LLMError.invalidResponse(raw.found == nil ? "no found and no claim" : "found without a claim that cites what was sent")
        }
        let text = AnswerText.isPlaceholder(sentence) ? claims.map(\.text).joined(separator: " ") : sentence
        // The integrated model's grammar closes a string at its byte cap and the whole object at the token or time cap: a claim of
        // filler, or a sentence that stops in the middle, is a length cut-off even though the JSON is whole.
        // The byte check runs on the whole sentence: `sentence` is clipped to 2000 characters, which a Latin-script answer near the
        // 3000-byte cap never reaches the 90% mark under.
        let whole = MinutesText.cleanProse(raw.answer ?? "", codes: codes, language: answerLanguage ?? language)
        let cutShort = keepCutAnswer && (cut > 0 || AnswerText.endsMidSentence(whole, capBytes: answerCapBytes))
        return VerifiedAnswer(answer: text, claims: claims, found: true, cutShort: cutShort, droppedClaims: dropped)
    }

    /// A claim's text without the citation codes it names ("said in segment S73"): their numbers are not figures.
    static func withoutCodes(_ text: String, _ codes: Set<String>) -> String {
        text.replacing(/\b[SD]\d+\b/) { match in codes.contains(String(match.output)) ? "" : String(match.output) }
    }

    /// A passage without its context line (the title and heading path): a quote must come from the text itself.
    public static func body(of passage: DocumentPassage) -> String {
        guard let newline = passage.text.firstIndex(of: "\n") else { return passage.text }
        return String(passage.text[passage.text.index(after: newline)...])
    }
}
