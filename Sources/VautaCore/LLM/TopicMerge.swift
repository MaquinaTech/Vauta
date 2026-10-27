// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// The user's own headlines come first among the topics of the minutes, word for word. Swift does it, not the model:
/// "Q3 budget +10%" is a topic because the user wrote it.
public enum TopicMerge {
    /// Notes this short are topic names (anything longer is a sentence and stays a note).
    static let maxWords = 6
    static let maxCharacters = 60
    /// At most this many of the topics come from the user's notes, so the model keeps some room.
    static let maxUserTopics = 4

    public static func isHeadline(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= maxCharacters, !t.contains(where: \.isNewline) else { return false }
        if t.unicodeScalars.contains(where: TextKeys.isNoSpaceScript) { return t.count <= 24 }
        return t.split(whereSeparator: \.isWhitespace).count <= maxWords
    }

    /// The notes that may become topics: their expansion is done and checked (a note the transcript does not discuss,
    /// a removed one and one never expanded are not what the meeting was about), at most `maxUserTopics`, the ones with
    /// the most checked sentences and the latest edits first, then returned in meeting order.
    public static func promotable(_ rows: [NoteRow]) -> [String] {
        let candidates = rows.filter { row in
            guard let e = row.expansion, e.state == .done, !row.isStale || e.userEdited else { return false }
            return isHeadline(row.note.text) && !e.sentences.isEmpty
        }
        let ranked = candidates.sorted { a, b in
            let (ka, kb) = (a.expansion?.sentences.filter { !$0.unconfirmed }.count ?? 0, b.expansion?.sentences.filter { !$0.unconfirmed }.count ?? 0)
            if ka != kb { return ka > kb }
            return (a.note.editedAt ?? .distantPast, a.note.t) > (b.note.editedAt ?? .distantPast, b.note.t)
        }
        return ranked.prefix(maxUserTopics).sorted { ($0.note.t, $0.note.id) < ($1.note.t, $1.note.id) }.map(\.note.text)
    }

    /// `notes` in meeting order. A model topic already said by a headline (it is contained in it once normalized) is
    /// replaced by the headline; a short headline never removes a longer, different topic. The total stays within `limit`.
    public static func withUserNotes(_ topics: [String], notes: [String], limit: Int = 8) -> [String] {
        var headlines: [String] = []
        var keys: [String] = []
        for note in notes where isHeadline(note) {
            let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = TextKeys.norm(text)
            guard !key.isEmpty, !keys.contains(key), headlines.count < maxUserTopics else { continue }
            headlines.append(text)
            keys.append(key)
        }
        let rest = topics.filter { topic in
            let key = TextKeys.norm(topic)
            return !keys.contains { !key.isEmpty && $0.contains(key) }
        }
        return Array((headlines + rest).prefix(limit))
    }
}
