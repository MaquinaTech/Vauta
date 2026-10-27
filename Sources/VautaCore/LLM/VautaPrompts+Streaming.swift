// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The integrated model's prompt layout. The transcript is the last message of the kept prefix and is made of lines that never change
/// once written (a stable speaker key, never a name or a "?"): appending lines then diverges only at the closing `>>>`, so the engine
/// continues from its snapshot and a tick of the incremental reading costs the new lines plus 16 tokens. What changes during the
/// meeting (names given to speakers, new people, uncertain labels) goes in the last message with the task, so it never rewinds the
/// prefix. Apple's model and the servers keep the standard layout (`line`, names in the transcript).
public enum PromptLayout: Sendable, Equatable {
    case standard
    case streaming
}

extension VautaPrompts {
    /// "Me", "Me 2 (in the room)", "Speaker 3 (remote)": the key of a speaker in the final speaker labelling. It is NOT written in the
    /// transcript lines (the live clustering and the final one number the voices differently, and the final step can split segments):
    /// it appears only in the speaker list of the last message (`contextDelta`).
    static func streamingSpeakerKey(_ s: CitableSegment) -> String {
        guard let tag = s.speaker else { return s.channel.promptLabel }
        switch (s.channel, tag.ordinal) {
        case (.me, 1): return "Me"
        case (.me, let n): return "Me \(n) (in the room)"
        case (.others, let n): return "Speaker \(n) (remote)"
        }
    }

    /// One transcript line of the streaming layout: `[S12 · 03:12 · Others] text`. The label is the channel only (Me or Others), so a line
    /// never changes once written, whatever the speaker analysis later decides; who spoke each segment goes in the last message.
    public static func streamingLine(_ s: CitableSegment) -> String {
        "[S\(s.id) · \(PromptText.clock(s.start)) · \(s.channel.promptLabel)] \(PromptText.defang(s.text))"
    }

    /// The second message of the streaming layout: the people the meeting may mention, then the rules for answering questions (so the
    /// rules sit before the transcript, which grows). The minutes, the live notes and the answers all start with the same two messages.
    public static func streamingPeopleMessage(_ entities: [CandidateEntity], selfEntity: Int64?, rules: String) -> ChatMessage {
        .user(entitiesMessage(entities, selfEntity: selfEntity).content + "\n\n" + rules)
    }

    /// The transcript message of the streaming layout, the same for live notes, live answers, the minutes, questions about the meeting
    /// and the checks.
    public static func streamingTranscriptMessage(_ segments: [CitableSegment]) -> ChatMessage {
        .user("<<<TRANSCRIPT\n" + segments.map(streamingLine).joined(separator: "\n") + "\n>>>")
    }

    /// What changed since the prefix was read, for the last message: names given to speakers, speakers the system is unsure about, and
    /// people and projects added to the list after it was frozen. Empty when nothing did.
    public static func contextDelta(segments: [CitableSegment], frozen: [CandidateEntity], current: [CandidateEntity], selfEntity: Int64?) -> String {
        var parts: [String] = []
        let known = Set(frozen.map(\.id))
        let added = current.filter { !known.contains($0.id) }
        if !added.isEmpty {
            let lines = entitiesMessage(added, selfEntity: selfEntity).content.split(separator: "\n").dropFirst()
            parts.append("People and projects added since the transcript was read:\n" + lines.joined(separator: "\n"))
        }
        // Who spoke which segment: runs of consecutive segments of the transcript per speaker, with the name when there is one.
        var order: [String] = []
        var runs: [String: [String]] = [:]
        var names: [String: String] = [:]
        var selfKeys = Set<String>()
        var previous: (key: String, first: Int64, last: Int64)?
        func close() {
            guard let p = previous else { return }
            runs[p.key, default: []].append(p.first == p.last ? "S\(p.first)" : "S\(p.first)–\(p.last)")
        }
        for s in segments {
            guard let tag = s.speaker else { close(); previous = nil; continue }
            let key = streamingSpeakerKey(s)
            if !order.contains(key) { order.append(key) }
            if let raw = tag.name {
                let name = labelName(raw)
                if !name.isEmpty, !MeetingStore.isSelfPronoun(TextKeys.norm(name)) { names[key] = name; if tag.isSelf { selfKeys.insert(key) } }
            }
            if let p = previous, p.key == key { previous = (key, p.first, s.id) } else { close(); previous = (key, s.id, s.id) }
        }
        close()
        // The speaker with most lines on the Others channel is not listed when every line of that channel has a speaker: "every other
        // line of Others is …" costs a few words where the list costs a token or two per run (the list is read again at every minutes).
        var rest: String?
        let others = segments.filter { $0.channel == .others }
        if !others.isEmpty, others.allSatisfy({ $0.speaker != nil }) {
            var count: [String: Int] = [:]
            for s in others { count[streamingSpeakerKey(s), default: 0] += 1 }
            if count.count > 1, let top = count.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key { rest = top }
        }
        var legend: [String] = []
        for key in order {
            let named = names[key].map { " is \($0)\(selfKeys.contains(key) ? " (the user)" : "")" } ?? ""
            if key == "Me" {
                if !named.isEmpty { legend.append("- Me\(named).") }
                continue
            }
            if key == rest { legend.append("- Every other line of Others: \(key)\(named).") ; continue }
            legend.append("- \(key)\(named): \((runs[key] ?? []).joined(separator: ", ")).")
        }
        if !legend.isEmpty {
            parts.append("Who spoke (the lines of the transcript say only Me or Others; use these labels for the speakers, and the names where given):\n" + legend.joined(separator: "\n"))
        }
        let unsure = segments.filter { $0.speaker.map { $0.isLowConfidence || $0.overlap } ?? false }.map { "S\($0.id)" }
        if !unsure.isEmpty {
            parts.append("The system is unsure who spoke in these segments (treat the speaker as uncertain): " + unsure.prefix(60).joined(separator: ", ")
                         + (unsure.count > 60 ? ", …" : "") + ".")
        }
        return parts.joined(separator: "\n")
    }
}
