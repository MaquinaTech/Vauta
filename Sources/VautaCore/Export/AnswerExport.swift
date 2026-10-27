// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// An Ask answer as text to copy: the question, the answer and each claim
/// with its sources ("Weekly sync · 12:34"), so the copied text can be checked.
public struct AnswerExport: Sendable, Equatable {
    public struct Claim: Sendable, Equatable {
        public var text: String
        public var verified: Bool
        /// Human-readable sources, e.g. "Weekly sync · 12:34".
        public var sources: [String]
        /// The documents the claim cites, structured for the JSON form: the file's name (never its path), where in it, and the
        /// words the claim quoted.
        public var documents: [Document]

        public struct Document: Sendable, Equatable {
            public var name: String
            public var locator: String
            public var quote: String

            public init(name: String, locator: String, quote: String) {
                self.name = name
                self.locator = locator
                self.quote = quote
            }
        }

        public init(text: String, verified: Bool, sources: [String], documents: [Document] = []) {
            self.text = text
            self.verified = verified
            self.sources = sources
            self.documents = documents
        }
    }

    public var question: String
    public var answer: String
    public var claims: [Claim]
    /// Set when the answer is unverified (it says it found something and none of its claims checks out, or it has no claim): the
    /// warning the screen shows, so the copied and exported text does not read as a plain answer.
    public var unverifiedNote: String?
    /// How a verified answer qualifies itself when it is copied: some claims are not verified, or the moments only touch the topic.
    public enum Caveat: Sendable, Equatable { case partlyVerified, relatedOnly }
    public var caveat: Caveat?
    /// The note the screen shows under the claims for that caveat.
    public var caveatNote: String?
    /// Set when the answer's text reached its length limit and may stop in the middle: the note the screen shows about it.
    public var incompleteNote: String?

    public init(question: String, answer: String, claims: [Claim], unverifiedNote: String? = nil, caveat: Caveat? = nil, caveatNote: String? = nil,
                incompleteNote: String? = nil) {
        self.question = question
        self.answer = answer
        self.claims = claims
        self.unverifiedNote = unverifiedNote
        self.caveat = caveat
        self.caveatNote = caveatNote
        self.incompleteNote = incompleteNote
    }

    /// Builds the export from a verified answer; `source` names a cited segment
    /// (nil drops a citation that can no longer be resolved).
    public init(question: String, answer: VerifiedAnswer, unverifiedNote: String? = nil, partlyVerifiedNote: String? = nil,
                relatedNote: String? = nil, endsIncompleteNote: String? = nil, source: (Int64) -> String?) {
        // A cited document is named by its file and place ("Onboarding.pdf · p. 4"), never by its path: a path reveals the
        // person's folders.
        self.init(question: question, answer: answer.answer,
                  claims: answer.claims.map { Claim(text: $0.text, verified: $0.verified, sources: $0.citations.compactMap(source) + $0.documents.map(\.label),
                                 documents: $0.documents.map { .init(name: $0.fileName, locator: $0.locator.shortLabel, quote: $0.quote ?? "") }) },
                  unverifiedNote: answer.isUnverified ? unverifiedNote : nil,
                  caveat: answer.kind == .partlyVerified ? .partlyVerified : answer.kind == .related ? .relatedOnly : nil,
                  caveatNote: answer.kind == .partlyVerified ? partlyVerifiedNote : answer.kind == .related ? relatedNote : nil,
                  incompleteNote: answer.endsIncomplete ? endsIncompleteNote : nil)
    }

    /// An unverified answer starts with "Not verified: ", so a copy of it never reads as a plain answer.
    private var shownAnswer: String {
        guard !answer.isEmpty else { return answer }
        if unverifiedNote != nil {
            return String(localized: "Not verified: \(answer)", comment: "Copied answer: an answer none of whose claims could be checked starts with this; the argument is the answer")
        }
        switch caveat {
        case .partlyVerified?:
            return String(localized: "Partly verified: \(answer)", comment: "Copied answer: an answer some of whose claims could not be checked starts with this; the argument is the answer")
        case .relatedOnly?:
            return String(localized: "Only related: \(answer)", comment: "Copied answer: an answer whose quoted moments only touch the topic starts with this; the argument is the answer")
        case nil:
            return answer
        }
    }

    public func markdown() -> String {
        var blocks = ["**\(Markdown.inline(question))**"]
        blocks.append(contentsOf: Markdown.paragraphs(shownAnswer))
        if !claims.isEmpty {
            blocks.append(claims.map { "- " + Markdown.inline(claimLine($0)) }.joined(separator: "\n"))
        }
        if let note = unverifiedNote ?? caveatNote { blocks.append("_\(Markdown.inline(note))_") }
        if let note = incompleteNote { blocks.append("_\(Markdown.inline(note))_") }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// The answer as JSON: `{"question", "answer", "verified" (false only when unverified), "note", "incompleteNote" (only when the text may stop in the middle), "claims": [{"text", "verified", "sources", "documents": [{"name", "locator", "quote"}]}]}`.
    public func json() -> Data {
        struct Wire: Encodable {
            struct Doc: Encodable { let name, locator, quote: String }
            struct Item: Encodable { let text: String, verified: Bool, sources: [String], documents: [Doc] }
            let question, answer: String
            let verified: Bool?
            let note: String?
            let incompleteNote: String?
            let claims: [Item]
        }
        let wire = Wire(question: question, answer: answer, verified: unverifiedNote == nil ? nil : false, note: unverifiedNote ?? caveatNote, incompleteNote: incompleteNote, claims: claims.map { claim in
            .init(text: claim.text, verified: claim.verified, sources: claim.sources,
                  documents: claim.documents.map { .init(name: $0.name, locator: $0.locator, quote: $0.quote) })
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(wire)) ?? Data("{}".utf8)
    }

    public func plainText() -> String {
        var blocks = [question, shownAnswer]
        if !claims.isEmpty { blocks.append(claims.map { "- " + claimLine($0) }.joined(separator: "\n")) }
        if let note = unverifiedNote ?? caveatNote { blocks.append(note) }
        if let note = incompleteNote { blocks.append(note) }
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    private func claimLine(_ c: Claim) -> String {
        let status = c.verified
            ? String(localized: "verified", comment: "Copied answer: the claim's quote was found in the transcript")
            : String(localized: "not verified", comment: "Copied answer: the claim's quote was not found in the transcript")
        let sources = c.sources.joined(separator: "; ")
        return sources.isEmpty
            ? String(localized: "\(c.text) (\(status))", comment: "Copied answer: a claim and its verification status")
            : String(localized: "\(c.text) (\(status): \(sources))",
                     comment: "Copied answer: a claim, its verification status and its sources (meeting and time)")
    }
}
