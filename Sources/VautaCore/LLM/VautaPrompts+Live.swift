// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

extension VautaPrompts {
    /// The transcript so far, as the live-notes material (it only grows at the end).
    public static func liveTranscriptMessage(_ lines: [String]) -> ChatMessage {
        .user("<<<TRANSCRIPT IN PROGRESS\n" + lines.joined(separator: "\n") + "\n>>>")
    }

    /// The user's latest notes for the live pass (empty when there are none), cut to what the window can spare.
    public static func liveUserNotesBlock(_ notes: [String], count: Int = 12, characters: Int = 200) -> String {
        guard !notes.isEmpty else { return "" }
        return "The user already wrote these notes (do not repeat them):\n"
            + notes.suffix(count).map { "- \(PromptText.defang(PromptText.clip(SingleLineText.flatten($0), characters)))" }.joined(separator: "\n") + "\n"
    }

    public static func liveInstruction(sinceID: Int64, previous: [String], language: OutputLanguage,
                                       userNotes: [String] = [], userNoteCount: Int = 12, userNoteCharacters: Int = 200, delta: String = "",
                                       harness: LiveHarness = .legacy) -> ChatMessage {
        var text = delta.isEmpty ? "" : delta + "\n"
        text += liveUserNotesBlock(userNotes, count: userNoteCount, characters: userNoteCharacters)
        if !previous.isEmpty {
            text += "Notes you already took (do not repeat them):\n"
                + previous.suffix(12).map { "- \(PromptText.defang($0))" }.joined(separator: "\n") + "\n"
        }
        if harness.contains(.shape) {
            // Empty shapes: nothing to copy ("…", "Me | name | null"), and what each list is for.
            text += """
                Take notes ONLY on the new segments (ID > \(sinceID)). Very brief, in your own words (never copy a line of the transcript).
                "points" are what matters; "decisions" only what the speakers agreed; "tasks" only what somebody will do (the "owner" is a name \
                said in the transcript, "Me" only when the line is spoken by Me, otherwise null). Leave out what the notes above already say.
                Shape: {"points": [{"text": "", "seg": 0}], "decisions": [{"text": "", "seg": 0}], "tasks": [{"text": "", "owner": null, "seg": 0}]}. \
                "seg" is the number of the segment the note is about. Use empty lists when there is nothing new.
                \(language.instruction) JSON keys stay in English.
                """
        } else {
            text += """
                Take notes ONLY on the new segments (ID > \(sinceID)). Very brief: what matters, decisions and tasks.
                JSON: {"points": [{"text": "…", "seg": 123}], "decisions": [{"text": "…", "seg": 123}], \
                "tasks": [{"text": "…", "owner": "Me | name | null", "seg": 123}]}. Use empty lists when there is nothing new.
                \(language.instruction) JSON keys stay in English.
                """
        }
        return .user(text)
    }

    /// Live notes as the model writes them: English keys, or the legacy Spanish ones.
    struct RawLiveNotes: Decodable {
        struct Note: Decodable {
            let text: String?, owner: String?, seg: Int64?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: AnyKey.self)
                text = c.text("text", "texto")
                owner = c.text("owner", "responsable")
                seg = c.id("seg", "segment")
            }
        }
        let points: [Note], decisions: [Note], tasks: [Note]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyKey.self)
            points = c.list(Note.self, "points", "puntos") ?? []
            decisions = c.list(Note.self, "decisions", "decisiones") ?? []
            tasks = c.list(Note.self, "tasks", "tareas") ?? []
        }
    }

    /// Live notes: only those citing an existing segment are kept. With a `check` (`LiveHarness`), a note that copies its cited line, repeats an
    /// earlier note, or says nothing is dropped, and "Me" stays as an owner only on the user's own line.
    public static func validateLive(_ content: String, segments: Set<Int64>, check: LiveCheck? = nil) throws -> LiveNotesBatch {
        let raw = try ModelOutput.decodeObject(RawLiveNotes.self, from: content)
        var kept: [LiveCheck.Earlier] = []
        func valid(_ n: RawLiveNotes.Note, _ kind: LiveCheck.Kind) -> (text: String, seg: Int64)? {
            guard let seg = n.seg, segments.contains(seg) else { return nil }
            let text = PromptText.clip(n.text ?? "", 300)
            guard !text.isEmpty else { return nil }
            if let check, check.harness.contains(.copies) || check.harness.contains(.repeats) {
                if LiveCheck.isEmpty(text) || check.copiesItsLine(text, segment: seg) || check.repeatsEarlier(text, kind: kind, segment: seg, kept: kept) { return nil }
            }
            kept.append(.init(kind: kind, text: text, segment: seg))
            return (text, seg)
        }
        var out = LiveNotesBatch()
        out.points = raw.points.compactMap { valid($0, .point) }.prefix(8).map { .init(text: $0.text, segment: $0.seg) }
        out.decisions = raw.decisions.compactMap { valid($0, .decision) }.prefix(5).map { .init(text: $0.text, segment: $0.seg) }
        out.tasks = raw.tasks.compactMap { n in valid(n, .task).map { (n, $0) } }.prefix(5).map { n, v in
            let owner = n.owner.map { PromptText.clip($0, 80) }.flatMap { o in
                ["", "null", "none"].contains(o.lowercased()) ? nil : o
            }
            return .init(text: v.text, owner: check.map { $0.owner(owner, segment: v.seg) } ?? owner, segment: v.seg)
        }
        return out
    }

    /// Live notes as one line each, for the next live request and as hints
    /// for the final minutes.
    public static func liveNoteLines(_ batch: LiveNotesBatch) -> [String] {
        batch.points.map(\.text) + batch.decisions.map { "Decision: \($0.text)" }
            + batch.tasks.map { t in t.owner.map { "Task: \(t.text) (owner: \($0))" } ?? "Task: \(t.text)" }
    }
}
