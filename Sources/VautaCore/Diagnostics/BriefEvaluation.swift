// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// `llm-eval --tasks brief`: EVALUATION ONLY. Builds the pre-meeting brief of a briefed meeting from the meetings before it, with the
/// app's own brief code, in a throwaway encrypted store, and writes the rendered briefs and the deterministic measurements. Public
/// transcripts and stored minutes (the sets of `eval/`), synthetic calendar, reminder and notes fixtures; no EventKit, no model server, no
/// audio, nothing from a person's data.
///
/// The fixtures are written by a session that sees only the meetings before the briefed one, never that meeting's gold, and are hashed
/// before the gold exists: this task writes their SHA-256 next to the results (`fixtures.sha256`) and never reads the briefed meeting's
/// transcript.
public enum BriefEvaluation {
    /// An arm of the comparison.
    public struct Arm: Sendable, Equatable {
        public let name: String
        /// The search model ranks (needs `--search-model`); otherwise keywords.
        public let semantic: Bool
        /// The model that writes the agenda (or, for `BL`, the whole brief); nil = the deterministic brief only.
        public let provider: String?
        public let baseline: Bool

        public static let all: [Arm] = [
            Arm(name: "K0", semantic: false, provider: nil, baseline: false), Arm(name: "S0", semantic: true, provider: nil, baseline: false),
            Arm(name: "KA", semantic: false, provider: "apple", baseline: false), Arm(name: "SA", semantic: true, provider: "apple", baseline: false),
            Arm(name: "KG", semantic: false, provider: "integrated", baseline: false), Arm(name: "SG", semantic: true, provider: "integrated", baseline: false),
            Arm(name: "BLA", semantic: false, provider: "apple", baseline: true), Arm(name: "BLG", semantic: false, provider: "integrated", baseline: true),
        ]

        public static func named(_ names: [String]) -> [Arm]? {
            let found = names.map { name in all.first { $0.name == name.uppercased() || ($0.name == "BLA" && name.uppercased() == "BL") } }
            return found.contains { $0 == nil } ? nil : found.compactMap { $0 }
        }
    }

    public struct Options: Sendable {
        /// A folder with one `<series>.brief.json` per series (the fixtures).
        public var fixtures: URL?
        public var arms: [Arm] = Arm.all
        /// Stored minutes per provider ("apple", "integrated"): the `minutes_<provider>.jsonl` of the minutes runs. The arms without a model use
        /// the integrated minutes when given, else Apple's.
        public var minutes: [String: URL] = [:]
        /// Only fixtures of this split ("dev" or "test").
        public var split: String?
        public init() {}

        public var needsIntegrated: Bool { arms.contains { $0.provider == "integrated" } }
    }

    // MARK: Fixtures

    public struct Fixture: Decodable, Sendable {
        public struct Attendee: Decodable, Sendable { public let name: String; public let email: String? }
        public struct Event: Decodable, Sendable {
            public let title: String
            /// The people of the series (they were at the earlier meetings too).
            public let attendees: [Attendee]
            /// People who join only the briefed meeting: nobody has met them in an earlier one.
            public let newAttendees: [Attendee]?
            /// `zoom`, `teams`… or absent (an in-person meeting).
            public let service: String?
            public let invitationNotes: String?
            enum CodingKeys: String, CodingKey { case title, attendees, newAttendees = "new_attendees", service, invitationNotes = "invitation_notes" }
        }
        public struct Reminder: Decodable, Sendable {
            public let id: String
            public let title: String
            /// Days from the meeting's start (negative: before).
            public let dueDays: Double?
            public let list: String
            /// A distractor has `false`: showing it counts against the brief.
            public let relevant: Bool
            enum CodingKeys: String, CodingKey { case id, title, dueDays = "due_days", list, relevant }
        }
        public struct Document: Decodable, Sendable { public let name: String; public let text: String; public let relevant: Bool }

        public let series: String
        public let language: String
        public let split: String?
        /// The briefed meeting. Named only so results can be joined with its gold later: its transcript is never read.
        public let briefed: String
        /// The meetings before it, oldest first (transcript sets of `--sets`).
        public let earlier: [String]
        /// "Speaker 2" → the attendee name the stored tasks' owners are mapped to.
        public let speakers: [String: String]?
        public let event: Event
        public let reminders: [Reminder]
        public let notes: [Document]
        public let documents: [Document]
    }

    public enum Failure: Error, CustomStringConvertible {
        case noFixtures, unreadable(String), missingTranscript(String)
        public var description: String {
            switch self {
            case .noFixtures: "no fixtures: --brief-fixtures <folder with *.brief.json>"
            case .unreadable(let name): "the fixture \(name) cannot be read"
            case .missingTranscript(let name): "the transcript set \(name) is not in --sets"
            }
        }
    }

    public static func loadFixtures(_ o: Options) throws -> [(fixture: Fixture, hash: String, file: String)] {
        guard let folder = o.fixtures else { throw Failure.noFixtures }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".brief.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var out: [(Fixture, String, String)] = []
        for file in files {
            guard let data = FileManager.default.contents(atPath: file.path), let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
                throw Failure.unreadable(file.lastPathComponent)
            }
            if let split = o.split, fixture.split != split { continue }
            out.append((fixture, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), file.lastPathComponent))
        }
        guard !out.isEmpty else { throw Failure.noFixtures }
        return out
    }

    // MARK: Stored minutes

    /// One line of `minutes_<provider>.jsonl` (`LLMEvaluation.runMinutes` writes it).
    struct StoredMinutes: Decodable {
        /// The flags and citations are written by `llm-eval` since the extraction phase; older files do not have them.
        struct Decision: Decodable { let text: String; let unconfirmed: Bool?; let citations: [Int64]?; let reason: String? }
        struct Task: Decodable {
            let text: String; let owner: String?; let due: String?
            let unconfirmed: Bool?; let owner_uncertain: Bool?; let owner_kind: String?; let citations: [Int64]?; let reason: String?
        }
        let `case`: String
        let summary: String?
        let decisions: [Decision]?
        let tasks: [Task]?
        let open_questions: [String]?
    }

    static func loadMinutes(_ url: URL?) -> [String: StoredMinutes] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: StoredMinutes] = [:]
        for line in text.split(separator: "\n") {
            if let row = try? JSONDecoder().decode(StoredMinutes.self, from: Data(line.utf8)) { out[row.case] = row }
        }
        return out
    }

    // MARK: Reminders from a fixture

    struct FixtureReminders: BriefReminderSource {
        let reminders: [BriefReminder]
        var access: BriefReminderAccess { get async { .granted } }
        func lists() async -> [BriefReminderList] { Dictionary(grouping: reminders, by: \.listID).keys.sorted().map { BriefReminderList(id: $0, title: $0, source: "Fixture") } }
        func incompleteReminders(in listIDs: Set<String>, limit: Int) async -> [BriefReminder] { Array(reminders.filter { listIDs.contains($0.listID) }.prefix(limit)) }
    }

    // MARK: Rendering (what a blind judge reads)

    /// The brief as plain English text, whatever language the interface is in, with nothing that names the arm.
    public static func render(_ snapshot: BriefSnapshot, calendar: Calendar = .current) -> String {
        func day(_ d: Date?) -> String { d.map { BriefText.isoDay($0, calendar: calendar) } ?? "" }
        var out = ["Meeting: \(snapshot.title) (\(day(snapshot.start)))"]
        for section in snapshot.sections {
            switch section.kind {
            case .people:
                out.append("People:")
                for p in section.items {
                    out.append("- \(p.text)" + (p.meetingsTogether > 0 ? " (last met \(day(p.lastMet)); \(p.meetingsTogether) earlier meetings together)" : " (no earlier meetings)"))
                }
            case .lastTime:
                out.append("Last time:")
                for i in section.items {
                    switch i.kind {
                    case .summary: out.append("- \(day(i.meetingDate)) \(i.source ?? ""): \(i.text)")
                    case .decision: out.append("- Decision: \(i.text)" + (i.unconfirmed ? " [check]" : ""))
                    case .task: out.append("- Open task: \(i.text)" + [i.owner.map { " (\($0))" }, i.due.map { ", due \(day($0))" }].compactMap { $0 }.joined() + (i.overdue ? " [overdue]" : ""))
                    default: out.append("- Open question: \(i.text)")
                    }
                }
            case .openTasks:
                out.append("Open tasks:")
                for i in section.items {
                    out.append("- \(i.isYours ? "[you] " : "")\(i.text)" + [i.owner.map { " (\($0))" }, i.due.map { ", due \(day($0))" }].compactMap { $0 }.joined() + (i.overdue ? " [overdue]" : ""))
                }
            case .relatedMeetings:
                out.append("Related meetings:")
                for i in section.items { out.append("- \(day(i.meetingDate)) \(i.text)") }
            case .documents:
                out.append("Documents and notes:")
                for i in section.items { out.append("- \(i.kind == .note ? "Note" : "File"): \(i.text)" + (i.detail.map { " — \($0)" } ?? "")) }
            case .reminders:
                out.append("Reminders:")
                for i in section.items { out.append("- \(i.text)" + (i.dueBeforeMeeting ? " [due before this meeting]" : "")) }
            case .invitation:
                out.append("From the invitation:")
                for i in section.items { out.append("- \(i.text)") }
            }
        }
        if case .lines(let lines) = snapshot.agenda {
            out.append("Suggested agenda:")
            for l in lines { out.append("- \(l.kind.rawValue.replacingOccurrences(of: "_", with: " ")): \(l.text)") }
        }
        return out.joined(separator: "\n")
    }

    // MARK: Deterministic checks

    struct Checks: Sendable {
        var items = 0
        var linksInvalid = 0
        var wrongAttribution = 0
        var distractorsShown = 0
        var inventedHistory = false
    }

    /// Link validity (every shown item opens something that exists), attribution against the store, distractors shown and invented history.
    static func check(_ snapshot: BriefSnapshot, fixture: Fixture, store: MeetingStore, reminderIDs: Set<String>, minutes: [StoredMinutes] = [],
                      calendar: Calendar = .current) async -> Checks {
        var c = Checks()
        let rendered = render(snapshot, calendar: calendar)
        let sources = Set(((try? await store.documentSources()) ?? []).map(\.id))
        for item in snapshot.items {
            c.items += 1
            switch item.link {
            case .segment(let meeting, let segment):
                let exists = ((try? await store.segments(of: meeting)) ?? []).contains { $0.id == segment }
                if !exists { c.linksInvalid += 1 }
            case .meeting(let meeting, _): if (try? await store.meeting(meeting)) == nil { c.linksInvalid += 1 }
            case .person(let entity): if (try? await store.entity(entity)) == nil { c.linksInvalid += 1 }
            case .passage(_, let source, _), .file(let source, _): if !sources.contains(source) { c.linksInvalid += 1 }
            case .reminder(let id): if !reminderIDs.contains(id) { c.linksInvalid += 1 }
            case .event: break
            case .none: if item.kind != .invitationLine && !(item.kind == .person && item.entityID == nil) && !(item.kind == .task && item.meetingID == nil) { c.linksInvalid += 1 }
            }
            // A decision or task is exactly what the store holds for that meeting (same text, owner and date).
            if let id = item.decisionID, let meeting = item.meetingID {
                let held = ((try? await store.decisions(meeting)) ?? []).first { $0.id == id }
                if held.map({ BriefText.line($0.text) != item.text }) ?? true { c.wrongAttribution += 1 }
            }
            if let id = item.taskID, let meeting = item.meetingID {
                let held = ((try? await store.tasks(meeting)) ?? []).first { $0.id == id }
                if held.map({ BriefText.line($0.text) != item.text || $0.ownerName != item.owner || $0.due != item.due }) ?? true { c.wrongAttribution += 1 }
            }
            // The day printed in the brief is the day the stored minutes wrote (`due`), read from the rendered text, not recomputed from the item.
            if item.kind == .task { c.wrongAttribution += printedDueMismatch(item, rendered: rendered, minutes: minutes) }
            if item.kind == .summary, let id = item.meetingID, let held = (try? await store.meeting(id))?.startedAt,
               !rendered.contains("- \(independentDay(held, calendar)) \(item.source ?? ""): ") { c.wrongAttribution += 1 }
            if item.kind == .summary, let when = item.meetingDate {
                let held = independentDay(when, calendar)
                if BriefText.isoDays(in: item.text).contains(where: { $0 != held }) { c.wrongAttribution += 1 }
            }
            if item.kind == .reminder, fixture.reminders.first(where: { $0.id == reminderIDOf(item) })?.relevant == false { c.distractorsShown += 1 }
            if item.kind == .note || item.kind == .document, fixture.notes.contains(where: { $0.name == item.text && !$0.relevant })
                || fixture.documents.contains(where: { $0.name == item.text && !$0.relevant }) { c.distractorsShown += 1 }
        }
        c.inventedHistory = fixture.earlier.isEmpty && (snapshot.section(.lastTime) != nil || snapshot.section(.openTasks) != nil || snapshot.section(.relatedMeetings) != nil)
        return c
    }

    /// A day formatted without the app's own formatter (a separate `DateFormatter`), so a shift in `BriefText.isoDay` is caught.
    static func independentDay(_ date: Date, _ calendar: Calendar) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// 1 when the printed line of a task shows another due day than the `due` string of the stored minutes it came from (or a day where the
    /// minutes wrote none), else 0. Reads the rendered text and the minutes JSON, never the item's own date.
    static func printedDueMismatch(_ item: BriefItem, rendered: String, minutes: [StoredMinutes]) -> Int {
        guard let source = minutes.lazy.flatMap({ $0.tasks ?? [] }).first(where: { BriefText.line($0.text) == item.text }) else { return 0 }
        let lines = rendered.split(separator: "\n").filter { $0.contains(item.text) }
        guard !lines.isEmpty else { return 1 }
        let written = source.due.map { String($0.trimmingCharacters(in: .whitespaces).prefix(10)) }
        let ok = lines.contains { line in
            guard let range = line.range(of: ", due ") else { return written == nil }
            return written != nil && line[range.upperBound...].hasPrefix(written!)
        }
        return ok ? 0 : 1
    }

    private static func reminderIDOf(_ item: BriefItem) -> String? {
        if case .reminder(let id) = item.link { return id }
        return nil
    }
}
