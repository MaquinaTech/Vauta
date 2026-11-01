// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What a card shows and what is stored with the meeting: the answer, its claims and the sources they were verified against. The
/// stored JSON keys never change meaning (`answer`, `claims`, `sources`, `late`); the FTS trigger of the kept questions reads `answer`.
public struct AutoAnswerContent: Codable, Sendable, Equatable {
    public struct Cite: Codable, Sendable, Equatable, Hashable {
        public enum Kind: String, Codable, Sendable { case thisMeeting, pastMeeting, document }
        public var kind: Kind
        /// The cited line (a meeting) and the meeting it belongs to.
        public var segmentID: Int64?
        public var meetingID: Int64?
        /// Seconds into that meeting.
        public var t: Double?
        /// A past meeting's title and start (seconds since 1970).
        public var title: String?
        public var date: Double?
        /// A document's file name (never its path), where in it, and the passage to open.
        public var fileName: String?
        public var locator: String?
        public var sourceID: Int64?
        public var relPath: String?
        public var passageID: Int64?
        public var quote: String?
        /// What the passage viewer needs to open the cited passage again: the passage's key, the file's format and the exact place.
        public var key: String?
        public var format: String?
        public var place: DocumentLocator?

        public init(kind: Kind, segmentID: Int64? = nil, meetingID: Int64? = nil, t: Double? = nil, title: String? = nil, date: Double? = nil,
                    fileName: String? = nil, locator: String? = nil, sourceID: Int64? = nil, relPath: String? = nil, passageID: Int64? = nil,
                    quote: String? = nil, key: String? = nil, format: String? = nil, place: DocumentLocator? = nil) {
            self.key = key
            self.format = format
            self.place = place
            self.kind = kind
            self.segmentID = segmentID
            self.meetingID = meetingID
            self.t = t
            self.title = title
            self.date = date
            self.fileName = fileName
            self.locator = locator
            self.sourceID = sourceID
            self.relPath = relPath
            self.passageID = passageID
            self.quote = quote
        }

        /// The citation of a document in the form the passage viewer opens (nil when the stored citation lacks what it needs).
        public var documentCitation: DocumentCitation? {
            guard kind == .document, let passageID, let sourceID, let relPath, let fileName, let key, let format = format.flatMap(DocumentFormat.init(rawValue:)),
                  let place else { return nil }
            let passage = DocumentPassage(id: passageID, key: key, fileID: 0, sourceID: sourceID, relPath: relPath, fileName: fileName, format: format,
                                          locator: place, text: quote ?? "")
            return DocumentCitation(passage, quote: quote)
        }

        /// What makes two citations the same label: the meeting, or the file.
        public var labelKey: String {
            switch kind {
            case .thisMeeting: "this"
            case .pastMeeting: "meeting:\(meetingID ?? 0)"
            case .document: "doc:\(sourceID ?? 0):\(relPath ?? fileName ?? "")"
            }
        }
    }

    public struct Claim: Codable, Sendable, Equatable {
        public var text: String
        public var cites: [Cite]
        public init(text: String, cites: [Cite]) { self.text = text; self.cites = cites }
    }

    public var answer: String
    public var claims: [Claim]
    /// One citation for each distinct source (this meeting once, each past meeting, each file), in the order of the claims. The
    /// source labels of the card come from these: from verified citations only, never from what was retrieved.
    public var sources: [Cite]
    /// Shown more than 45 seconds after the question: the card says when it was asked.
    public var late: Bool
    /// Claims that rested on a meeting or a document that was deleted afterwards were dropped (stored as a new optional key).
    public var removedSources: Bool
    /// The cited lines of the meetings, as the answer was verified against them, for the previews of the card. In memory only: never
    /// stored (not in `CodingKeys`), so an answer read back from the meeting has none.
    public var lines: [Int64: CitableSegment] = [:]

    enum CodingKeys: String, CodingKey { case answer, claims, sources, late, removedSources }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        answer = try c.decode(String.self, forKey: .answer)
        claims = try c.decode([Claim].self, forKey: .claims)
        sources = try c.decode([Cite].self, forKey: .sources)
        late = try c.decode(Bool.self, forKey: .late)
        removedSources = try c.decodeIfPresent(Bool.self, forKey: .removedSources) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(answer, forKey: .answer)
        try c.encode(claims, forKey: .claims)
        try c.encode(sources, forKey: .sources)
        try c.encode(late, forKey: .late)
        if removedSources { try c.encode(true, forKey: .removedSources) }
    }

    public init(answer: String, claims: [Claim], late: Bool = false) {
        removedSources = false
        self.answer = answer
        self.claims = claims
        self.late = late
        var seen = Set<String>()
        sources = claims.flatMap(\.cites).filter { seen.insert($0.labelKey).inserted }
    }

    /// The source labels in the order they are shown: this meeting first, then past meetings, then documents.
    public var labels: [Cite] {
        sources.sorted { rank($0.kind) < rank($1.kind) }
    }

    private func rank(_ kind: Cite.Kind) -> Int {
        switch kind {
        case .thisMeeting: 0
        case .pastMeeting: 1
        case .document: 2
        }
    }

    public var usesOnlyThisMeeting: Bool { sources.allSatisfy { $0.kind == .thisMeeting } }

    public func marked(late: Bool) -> AutoAnswerContent {
        var copy = self
        copy.late = late
        return copy
    }
}

/// A question the detector kept, as the card and the meeting page show it.
public struct DetectedQuestion: Sendable, Equatable, Identifiable {
    public enum Outcome: String, Sendable, Codable, CaseIterable {
        case answered, noAnswer = "no_answer", rateLimited = "rate_limited", stale, failed, superseded, stopped
    }

    /// The row id in `detected_questions` (0 until stored).
    public var id: Int64
    public var meetingID: Int64
    public var segmentID: Int64?
    public var t: Double
    public var channel: Channel
    /// The sentence as transcribed.
    public var text: String
    /// The standalone rewrite the model made.
    public var rewrite: String
    public var outcome: Outcome
    public var answer: AutoAnswerContent?
    public var shown: Bool
    public var dismissed: Bool
    public var kept: Bool
    public var createdAt: Date
    /// A past meeting it cited was deleted since: the citation is gone and the card says the source was removed.
    public var sourceRemoved = false

    public init(id: Int64 = 0, meetingID: Int64, segmentID: Int64?, t: Double, channel: Channel, text: String, rewrite: String, outcome: Outcome,
                answer: AutoAnswerContent? = nil, shown: Bool = false, dismissed: Bool = false, kept: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.meetingID = meetingID
        self.segmentID = segmentID
        self.t = t
        self.channel = channel
        self.text = text
        self.rewrite = rewrite
        self.outcome = outcome
        self.answer = answer
        self.shown = shown
        self.dismissed = dismissed
        self.kept = kept
        self.createdAt = createdAt
    }
}

extension AutoAnswerContent {
    /// The sources in words, for an export: "This meeting (12:03)", "Weekly sync, 2026-10-03 (04:10)", "Budget.xlsx · p. 4".
    public func exportSources(timeZone: TimeZone = .current) -> [String] {
        var out: [String] = []
        for cite in labels {
            switch cite.kind {
            case .thisMeeting:
                let times = claims.flatMap(\.cites).filter { $0.kind == .thisMeeting }.compactMap(\.t)
                let clock = Set(times.map { Int($0) }).sorted().map { ExportTimestamp.clock(Double($0)) }.joined(separator: ", ")
                out.append(String(localized: "This meeting (\(clock))", comment: "Exported answer to a question heard in the meeting: it was verified in the meeting itself; the argument is the moments, like 04:10, 12:03"))
            case .pastMeeting:
                let date = cite.date.map { Date(timeIntervalSince1970: $0).formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: timeZone)) } ?? ""
                let clock = cite.t.map { ExportTimestamp.clock($0) } ?? ""
                out.append(String(localized: "\(cite.title ?? ""), \(date) (\(clock))", comment: "Exported answer to a question heard in the meeting: it was verified in a past meeting; the arguments are the meeting's title, its date and the moment"))
            case .document:
                let place = cite.locator.map { $0.isEmpty ? "" : " · " + $0 } ?? ""
                out.append((cite.fileName ?? "") + place)
            }
        }
        return out
    }
}
