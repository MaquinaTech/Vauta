// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
internal import VautaMLX

/// `llm-eval --tasks actions` (Part A): EVALUATION ONLY. Runs the app's own follow-up code over public transcripts and the stored minutes
/// of the minutes runs, in a throwaway encrypted store, and writes what a blind judge reads plus the deterministic measurements.
/// It never touches EventKit: every write goes to `FakeActionWriter`. No model server, no audio, nothing from a person's data.
///
/// Arms (Part A):
/// - `ET1` the one-email draft and `ETO` the per-owner drafts, from the stored minutes of each backend; `EBL` the same backend's own
///   follow-up email from the same minutes, with no template and no verifier (the baseline);
/// - `FD` the follow-up detector as the app runs it (the last tenth of the transcript, and the tasks and cited segments of one backend's
///   stored minutes), `FDX` the detector reading every segment (the ceiling of what the rules could find), `FBL` the backend extracting the next meeting from the same closing lines;
/// - `RP` the deterministic replay scenarios (duplicates, due day, undo, crash recovery) with the fake writer.
///
/// Outputs carry blind labels, never arm names: `emails/<meeting>.<label>.txt`, `followups/<meeting>.<label>.json`; `sealed/key.json`
/// maps labels to arms and its SHA-256 is written next to it. `replay.jsonl` has the counts of the replay scenarios.
public enum ActionsEvaluation {
    public enum Kind: String, Sendable, CaseIterable {
        case et1 = "ET1", eto = "ETO", ebl = "EBL", fd = "FD", fdx = "FDX", fbl = "FBL", rp = "RP"

        /// Needs a backend's stored minutes (and, for the baselines, its model).
        var usesMinutes: Bool { [.et1, .eto, .ebl, .fd, .fdx, .rp].contains(self) }
        var usesModel: Bool { self == .ebl || self == .fbl }
    }

    public struct Options: Sendable {
        /// A folder with one `<meeting>.actions.json` per meeting (sealed fixtures); optional.
        public var fixtures: URL?
        public var kinds: [Kind] = Kind.allCases
        /// Stored minutes per provider ("apple", "integrated"): the `minutes_<provider>.jsonl` of the minutes runs.
        public var minutes: [String: URL] = [:]
        /// Seed the tasks owned by a speaker label with the person the fixture says that speaker is. Off by default: the app's default email
        /// names nobody for a speaker nobody has named.
        public var nameSpeakers = false
        public init() {}

        public static func kinds(named names: [String]) -> [Kind]? {
            let found = names.map { name in Kind.allCases.first { $0.rawValue == name.uppercased() } }
            return found.contains { $0 == nil } ? nil : found.compactMap { $0 }
        }

        /// Whether any chosen arm calls a model.
        public var needsModel: Bool { kinds.contains { $0.usesModel } }
    }

    /// The invented side of a meeting: who was there (with addresses at `example.org`), who "Speaker 2" is, the closing lines that name the
    /// next meeting, and the reminders that were already in the person's list. Written without seeing the detector's words.
    public struct Fixture: Decodable, Sendable {
        public struct Person: Decodable, Sendable { public let name: String; public let email: String? }
        public let meeting: String
        /// ISO 8601, e.g. "2026-10-12T10:00:00+02:00".
        public let startedAt: String
        public let timeZone: String
        public let attendees: [Person]
        public let you: Person?
        public let speakers: [String: String]?
        public let closing: [String]?
        public let existingReminders: [String]?
        enum CodingKeys: String, CodingKey {
            case meeting, startedAt = "started_at", timeZone = "time_zone", attendees, you, speakers, closing, existingReminders = "existing_reminders"
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        public var description: String {
            switch self {
            case .unreadable(let name): "the fixture \(name) cannot be read"
            }
        }
    }

    static let referenceStart = Date(timeIntervalSince1970: 1_792_400_000)   // a Monday, 09:33 UTC

    static func loadFixtures(_ o: Options) throws -> (fixtures: [String: Fixture], manifest: String) {
        guard let folder = o.fixtures else { return ([:], "") }
        var out: [String: Fixture] = [:]
        var manifest = ""
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix(".actions.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            guard let data = FileManager.default.contents(atPath: file.path), let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
                throw Failure.unreadable(file.lastPathComponent)
            }
            out[fixture.meeting] = fixture
            manifest += SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + "  " + file.lastPathComponent + "\n"
        }
        return (out, manifest)
    }

    /// A meeting in a throwaway store: the transcript (and the fixture's closing lines), the people, and one backend's stored minutes.
    struct Seeded {
        let store: MeetingStore
        let meetingID: Int64
        let start: Date
        let zone: TimeZone
        let locale: Locale
        let tasks: [TaskItem]
        /// Stored items whose citation did not map to a segment of the seeded transcript: seeded one by one, without a segment.
        var unmapped = 0
    }


    /// `into`: a store that already holds earlier meetings (the links evaluation seeds a whole series in one store); `startedAt` overrides the
    /// fixture's date.
    static func seed(name: String, transcript: MinutesEvaluation.Transcript, fixture: Fixture?, minutes: BriefEvaluation.StoredMinutes?, directory: URL, nameSpeakers: Bool = false,
                     into existing: MeetingStore? = nil, startedAt: Date? = nil) async throws -> Seeded {
        let zone = fixture.flatMap { TimeZone(identifier: $0.timeZone) } ?? TimeZone(identifier: "Europe/Madrid")!
        let start = startedAt ?? fixture.flatMap { ISO8601DateFormatter().date(from: $0.startedAt) } ?? referenceStart
        let locale = Locale(identifier: transcript.language == "es" || name.hasPrefix("es_") ? "es-ES" : "en-US")
        let store = try existing ?? MeetingStore(directory: directory.appendingPathComponent("store"), keyStore: MemoryKeyStore())
        let id = try await store.startMeeting(at: start, locale: locale, outputLocale: locale, timeZone: zone)
        var unmapped = 0
        var last = 0.0
        var dbID: [Int64: Int64] = [:]
        for l in LLMEvaluation.replayLines(transcript) {
            dbID[l.id] = try await store.append(Segment(channel: .others, start: l.start, end: l.end, text: l.stored, isFinal: true), to: id)
            last = l.end
        }
        for (i, line) in (fixture?.closing ?? []).enumerated() {
            let begin = last + 2 + Double(i) * 10
            _ = try await store.append(Segment(channel: .others, start: begin, end: begin + 8, text: line, isFinal: true), to: id)
        }
        if let fixture {
            var attendees = fixture.attendees.map { CalendarMeeting.Attendee(name: $0.name, email: $0.email, isCurrentUser: false) }
            if let you = fixture.you { attendees.append(.init(name: you.name, email: you.email, isCurrentUser: true)) }
            _ = try await store.applyCalendar(CalendarMeeting(title: name, attendees: attendees, seriesKey: nil), to: id)
        }
        try await store.endMeeting(id, at: start.addingTimeInterval(last + 60))
        if let m = minutes {
            let people = try await store.entities(.person)
            // The minutes go in as the app writes them (`StoredMinutes.seed`), so the email is the one the app's default settings would draft.
            func owner(of t: BriefEvaluation.StoredMinutes.Task) -> Int64? {
                guard let label = t.owner, !label.isEmpty else { return nil }
                // A speaker label ("Speaker 2"): in the app the task has an unnamed speaker, and no name goes into an email. The fixture's name for
                // the speaker is used only when the run asks for it (`nameSpeakers`: the person has named every speaker in Context).
                if let person = fixture?.speakers?[label] {
                    guard nameSpeakers else { return nil }
                    return people.first(where: { $0.name == person })?.id
                }
                // A person named in the transcript (owner_kind "person"): by name.
                if t.owner_kind == "person" || t.owner_kind == nil {
                    let key = TextKeys.norm(label)
                    return people.first { TextKeys.norm($0.name) == key }?.id
                }
                return nil
            }
            // A task owned by a speaker label nobody has named is stored, as in the app, with an unnamed speaker row: the email then says
            // "owner to be agreed" when the owner is uncertain, and names nobody.
            var speakerRows: [String: Int64] = [:]
            func ownerSpeaker(of t: BriefEvaluation.StoredMinutes.Task) async -> Int64? {
                guard t.owner_kind == "speaker", let label = t.owner, !label.isEmpty, owner(of: t) == nil else { return nil }
                if let known = speakerRows[label] { return known }
                guard let row = try? await store.addSpeaker(meetingID: id, channel: .others) else { return nil }
                speakerRows[label] = row.speaker.id
                return row.speaker.id
            }
            unmapped = try await m.seed(into: store, meeting: id, segments: dbID, zone: zone, owner: owner(of:), ownerSpeaker: ownerSpeaker(of:))
        }
        return Seeded(store: store, meetingID: id, start: start, zone: zone, locale: locale, tasks: try await store.tasks(id), unmapped: unmapped)
    }

    // MARK: Blind labels

    /// A label that says nothing about the arm: a hash of the run's salt, the meeting and the arm.
    struct Labels {
        let salt = UUID().uuidString
        var key: [String: [String: String]] = [:]

        mutating func label(meeting: String, kind: Kind, provider: String) -> String {
            let digest = SHA256.hash(data: Data("\(salt)|\(meeting)|\(kind.rawValue)|\(provider)".utf8)).map { String(format: "%02x", $0) }.joined()
            let label = String(digest.prefix(8))
            key[label] = ["meeting": meeting, "arm": kind.rawValue, "provider": provider]
            return label
        }
    }
}

extension MeetingStore {
    /// Evaluation only: the flags of an item seeded without a cited segment.
    func flagForEvaluation(decision id: Int64, reason: String? = nil) async throws {
        try run("UPDATE decisions SET unconfirmed = 1, unconfirmed_reason = ? WHERE id = ?", [reason.flatMap { $0.isEmpty ? nil : SQLiteValue.text($0) }, .integer(id)])
        try await commitEdit()
    }

    func flagForEvaluation(task id: Int64, unconfirmed: Bool, ownerUncertain: Bool, reason: String? = nil) async throws {
        try run("UPDATE tasks SET unconfirmed = ?, owner_uncertain = ?, unconfirmed_reason = ? WHERE id = ?", [.integer(unconfirmed ? 1 : 0), .integer(ownerUncertain ? 1 : 0), unconfirmed ? reason.flatMap { $0.isEmpty ? nil : SQLiteValue.text($0) } : nil, .integer(id)])
        try await commitEdit()
    }
}
