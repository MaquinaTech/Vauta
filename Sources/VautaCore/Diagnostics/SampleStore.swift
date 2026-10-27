// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import CryptoKit
import Foundation

/// A key store that lives in memory: the snapshot renderer never touches the Keychain.
private final class EphemeralKeyStore: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SymmetricKey?

    func existingKey() throws -> SymmetricKey? { lock.withLock { stored } }

    func createKey() throws -> SymmetricKey {
        lock.withLock {
            let key = SymmetricKey(size: .bits256)
            stored = key
            return key
        }
    }

    func replace(with key: SymmetricKey) throws { lock.withLock { stored = key } }

    func remove() throws { lock.withLock { stored = nil } }
}

/// A store filled with invented meetings, for `Vauta render-ui`.
public struct SampleWorld: Sendable {
    public let store: MeetingStore
    public let directory: URL
    public let content: SampleContent
    public let locale: Locale
    /// Meeting IDs in the order of `content.meetings` (the first is the featured one).
    public let meetingIDs: [Int64]
    /// Segment IDs of the featured meeting, in order.
    public let featuredSegmentIDs: [Int64]
    /// Entity IDs: the user, then the other people.
    public let peopleIDs: [Int64]
    public let projectID: Int64
    public let clientID: Int64

    public var featuredMeetingID: Int64 { meetingIDs[0] }

    /// The simulated "now" of every rendered scene: Monday 19 October 2026, 10:00 local time. The featured meeting is the Tuesday before it
    /// (13 October), so its "Thursday" (the beta, 15 October) comes before "the 28th" (the public launch), "next Monday" is the day being
    /// rendered, and the next weekly sync is tomorrow. Scenes read it through `AppClock`, never the system clock.
    public static var snapshotNow: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 10, minute: 0)) ?? Date(timeIntervalSince1970: 1_792_400_400)
    }

    /// The day of the featured meeting: the most recent Tuesday before `now` (the Tuesday of the week before a Monday).
    public static func featuredDay(now: Date = AppClock.now, calendar: Calendar = .current) -> Date {
        var day = calendar.startOfDay(for: now)
        repeat { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day } while calendar.component(.weekday, from: day) != 3
        return day
    }

    /// The day and hour sample meeting `index` of `content` started, as the sidebar shows it.
    static func meetingStart(_ content: SampleContent, index: Int, now: Date = AppClock.now) -> Date {
        let meeting = content.meetings[index]
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -meeting.daysAgo, to: featuredDay(now: now, calendar: calendar)) ?? now
        return calendar.date(bySettingHour: meeting.hour, minute: 0, second: 0, of: day) ?? day
    }

    /// The day and hour a sample meeting started, as the sidebar shows it.
    public func startDate(ofMeeting index: Int, now: Date = AppClock.now) -> Date { Self.meetingStart(content, index: index, now: now) }

    /// The task of the previous meeting that repeats in the featured one (the task chain scenes).
    public var chainTaskText: String { content.meetings[1].tasks[0].text }

    /// A day `days` after the meeting `index` (a task due "by Wednesday" is one day after the Tuesday sync).
    public func dueDate(ofMeeting index: Int, afterDays days: Int, now: Date = AppClock.now) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: startDate(ofMeeting: index, now: now)) ?? now
    }

    /// The next time the weekly sync repeats (the featured meeting's weekday and hour), the first one after `now` (a sync that falls tomorrow is the next one).
    public func nextWeeklyStart(now: Date = AppClock.now) -> Date {
        let calendar = Calendar.current
        let hour = content.meetings[0].hour
        var day = calendar.date(byAdding: .day, value: 7, to: startDate(ofMeeting: 0, now: now)) ?? now
        while calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day).map({ $0 <= now.addingTimeInterval(3_600) }) ?? false {
            day = calendar.date(byAdding: .day, value: 7, to: day) ?? day
        }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
    }

    /// The featured meeting began `minutes` minutes ago: a meeting that is being recorded now (its passages stop a few minutes in, the sidebar
    /// says "Recording" with today's time). `restoreTranscript` puts the sample's own start back.
    public func startFeaturedMeeting(minutesAgo minutes: Int) async throws {
        try await store.setMeetingStartForSnapshots(featuredMeetingID, to: AppClock.now.addingTimeInterval(-Double(minutes) * 60))
    }

    /// Stores a translation of every line the others say in the featured meeting (the real
    /// translation of the line into another language), for the transcript with translations.
    public func seedFeaturedTranslations() async throws {
        let segments = try await store.segments(of: featuredMeetingID)
        let texts = content.featuredTranslations
        for (index, segment) in segments.enumerated() where segment.channel == .others && index < texts.count {
            try await store.saveTranslation(texts[index], language: content.featuredTranslationLanguage, of: segment.id)
        }
    }

    /// A translated meeting as it really is: the others speak another language (their lines are the
    /// foreign text), and each has its stored translation in the interface language `language`.
    public func useForeignSourceTranscript(translatedInto language: String) async throws {
        try await restoreTranscript()
        // The meeting is transcribed in the language the others speak, as the header says.
        try await store.setMeetingLocaleForSnapshots(featuredMeetingID, to: content.featuredTranslationLanguage == "es" ? "es-ES" : "en-US")
        let segments = try await store.segments(of: featuredMeetingID)
        let own = content.meetings[0].lines
        let foreign = content.featuredTranslations
        for (index, segment) in segments.enumerated() where segment.channel == .others && index < foreign.count && index < own.count {
            try await store.replaceSegmentTextForSnapshots(segment.id, with: foreign[index])
            try await store.saveTranslation(own[index].text, language: language, of: segment.id)
        }
    }

    /// Back to the featured meeting as it was created, without translations.
    public func restoreTranscript() async throws {
        // No speakers either: only the speaker scenes add them. Nor marks on the minutes.
        try await resetSpeakerSamples()
        try await clearQuestions()
        try await clearVerificationMarks()
        try await restoreSampleMinutes()
        try await restoreTaskOwners()
        try await store.removeAllTranslationsForSnapshots()
        try await store.setMeetingLocaleForSnapshots(featuredMeetingID, to: locale.identifier(.bcp47))
        try await store.setMeetingStartForSnapshots(featuredMeetingID, to: startDate(ofMeeting: 0))
        let segments = try await store.segments(of: featuredMeetingID)
        let own = content.meetings[0].lines
        for (index, segment) in segments.enumerated() where index < own.count && segment.text != own[index].text {
            try await store.replaceSegmentTextForSnapshots(segment.id, with: own[index].text)
        }
    }

    /// Fake encrypted copies like the ones the migration from the earlier version keeps, for Settings → Status:
    /// files set aside next to the store and/or an earlier version's folder beside the `Vauta` one.
    public func stageLeftovers(setAside: Int, oldFolder: Bool) throws {
        let fm = FileManager.default
        for index in 0..<setAside {
            let stamp = Int(AppClock.now.timeIntervalSince1970) - 5 * 86_400 - index
            let name = (index == 0 ? StoreFiles.snapshot : StoreFiles.journal) + StoreFiles.asideInfix + String(stamp)
            try Data(count: index == 0 ? 3_400_000 : 120_000).write(to: directory.appendingPathComponent(name))
        }
        if oldFolder {
            let old = directory.deletingLastPathComponent().appendingPathComponent(StoreFiles.Legacy.directory, isDirectory: true)
            try fm.createDirectory(at: old, withIntermediateDirectories: true)
            try Data(count: 3_100_000).write(to: old.appendingPathComponent(StoreFiles.Legacy.snapshot))
        }
    }

    /// Removes what `stageLeftovers` created.
    public func clearLeftovers() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where StoreFiles.isAside(name) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        try? fm.removeItem(at: directory.deletingLastPathComponent().appendingPathComponent(StoreFiles.Legacy.directory, isDirectory: true))
    }

    /// Removes every stored translation, so a scene without them shows the plain transcript.
    public func removeTranslations() async throws {
        try await store.removeAllTranslationsForSnapshots()
    }

    /// Opens an encrypted store in `directory` (a temporary one) with an
    /// in-memory key and fills it with the sample meetings of `language`.
    public static func make(language: String, directory: URL) async throws -> SampleWorld {
        let content = SampleContent.forLanguage(language)
        // The language the sample meetings are spoken in (their text is in the interface language): each
        // interface language is also its own speech language, so the chip, the transcript and the consent
        // reminder of a scene agree. A scene that needs a mismatch sets it itself.
        let locale = Locale(identifier: ["es": "es-ES", "ja": "ja-JP", "fr": "fr-FR", "de": "de-DE", "it": "it-IT", "pt": "pt-BR", "ko": "ko-KR",
                                         "zh": "zh-CN"][language.split(separator: "-").first.map(String.init) ?? language] ?? "en-US")
        let spoken = locale
        let store = try MeetingStore(directory: directory, keyStore: EphemeralKeyStore())

        // People, project, client, glossary.
        let selfID = try await store.selfEntity()
        var peopleIDs = [selfID]
        for person in content.people.dropFirst() {
            peopleIDs.append(try await store.saveEntity(EntityDraft(kind: .person, name: person.name, note: person.note, aliases: person.aliases)))
        }
        let projectID = try await store.saveEntity(EntityDraft(kind: .project, name: content.project.name, note: content.project.note,
                                                               aliases: content.project.aliases))
        let clientID = try await store.saveEntity(EntityDraft(kind: .client, name: content.client.name, note: content.client.note))
        for term in content.glossary {
            _ = try await store.saveGlossary(GlossaryTerm(term: term.term, expansion: term.expansion))
        }

        // Meetings, oldest first.
        var ids = [Int64](repeating: 0, count: content.meetings.count)
        var featuredSegments: [Int64] = []
        let calendar = Calendar.current
        let now = AppClock.now
        for index in content.meetings.indices.reversed() {
            let meeting = content.meetings[index]
            let start = meetingStart(content, index: index, now: now)
            let id = try await store.startMeeting(at: start, locale: spoken)
            ids[index] = id
            for (i, line) in meeting.lines.enumerated() {
                let begin = Double(i) * 38
                try await store.append(Segment(channel: line.mine ? .me : .others, start: begin, end: begin + 30,
                                               text: line.text, isFinal: true), to: id)
            }
            try await store.setTitle(meeting.title, of: id)
            try await store.setMeetingEntities(id, role: .attendee, meeting.attendees.map { peopleIDs[$0] })
            try await store.setMeetingEntities(id, role: .topic, [projectID] + (index <= 2 ? [clientID] : []))
            try await store.endMeeting(id, at: start.addingTimeInterval(Double(meeting.minutes) * 60))

            let segments = try await store.segments(of: id)
            if index == 0 { featuredSegments = segments.map(\.id) }
            func segmentID(_ i: Int) -> Int64 { segments[min(i, segments.count - 1)].id }
            func offset(_ i: Int) -> Double { Double(i) * 38 }
            var minutes = ValidatedMinutes()
            minutes.summary = meeting.summary
            minutes.topics = meeting.topics
            minutes.openQuestions = meeting.questions
            minutes.decisions = meeting.decisions.map { .init(text: $0.0, segment: segmentID($0.1), t: offset($0.1)) }
            minutes.tasks = meeting.tasks.map {
                .init(text: $0.text, owner: $0.owner.map { peopleIDs[$0] },
                      due: $0.dueInDays.flatMap { calendar.date(byAdding: .day, value: $0, to: start) },
                      segment: segmentID($0.segment), t: offset($0.segment))
            }
            try await store.applyMinutes(minutes, to: id)
            if index == 0 {
                _ = try await store.addMark(id, at: offset(4), label: nil)
                for (n, text) in content.notes.enumerated() { _ = try await store.addNote(id, at: offset(6 + n * 4), text: text) }
                try await store.setMinutesTemplate(.general, for: id)
                // The user told the participants about 90 seconds in (consent helper).
                try await store.markParticipantsInformed(id, at: start.addingTimeInterval(95))
            }
        }
        return SampleWorld(store: store, directory: directory, content: content, locale: locale, meetingIDs: ids,
                           featuredSegmentIDs: featuredSegments, peopleIDs: peopleIDs, projectID: projectID, clientID: clientID)
    }
}
#endif

#if VAUTA_DIAGNOSTICS
extension SampleWorld {
    /// Servers "found on this Mac" for Settings → Models.
    public static func discoveredServers() -> [DiscoveredServer] {
        [
            DiscoveredServer(kind: .lmStudio, baseURL: URL(string: "http://127.0.0.1:1234/v1")!, version: "0.3.30", models: [
                DiscoveredModel(id: "qwen3-30b-a3b-instruct", kind: .chat, contextLength: 32768, maxContextLength: 262144,
                                parameterBillions: 30, loaded: true),
                DiscoveredModel(id: "gemma-3-12b-it", kind: .chat, contextLength: 16384, maxContextLength: 131072,
                                parameterBillions: 12, loaded: false),
                DiscoveredModel(id: "text-embedding-nomic-embed-text-v1.5", kind: .embedding, contextLength: 2048, maxContextLength: 8192,
                                loaded: true),
            ]),
            DiscoveredServer(kind: .ollama, baseURL: URL(string: "http://127.0.0.1:11434/v1")!, version: "0.12.3", models: [
                DiscoveredModel(id: "llama3.2:3b", kind: .chat, contextLength: 8192, maxContextLength: 131072, parameterBillions: 3),
                DiscoveredModel(id: "nomic-embed-text:latest", kind: .embedding, maxContextLength: 8192),
            ]),
        ]
    }

    /// Speech languages as if the nine interface languages were installed (and a few more available).
    /// `notInstalled`: languages to treat as missing too (the scenes about a missing speech model show the interface language's own).
    /// `rendering`: the language the interface is shown in (a BCP-47 tag such as "de" or "pt-BR"): its own speech model is installed too, so a
    /// scene in German does not say that only English, Spanish and Japanese are on this Mac.
    public static func speechCatalog(notInstalled: Set<String> = [], rendering: String? = nil) -> SpeechLanguageCatalog {
        func locales(_ ids: [String]) -> [Locale] { ids.map { Locale(identifier: $0) } }
        let speech = ["en-US", "es-ES", "ja-JP", "fr-FR", "de-DE", "it-IT", "pt-BR", "ko-KR", "zh-CN"]
        let installed = (installedSpeechIDs(rendering: rendering)).filter { !notInstalled.contains($0) }
        return SpeechLanguageCatalog(speech: locales(speech), dictation: locales(speech + ["nl-NL", "sv-SE", "tr-TR"]),
                                     installedSpeech: locales(installed), installedDictation: locales(installed))
    }

    /// The speech models the sample Mac has: English, Spanish and Japanese, and the model of the language being rendered.
    public static func installedSpeechIDs(rendering: String?) -> [String] {
        var ids = ["en-US", "es-ES", "ja-JP"]
        let speech = ["fr-FR", "de-DE", "it-IT", "pt-BR", "ko-KR", "zh-CN"]
        if let code = rendering?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first,
           let own = speech.first(where: { $0.hasPrefix(code + "-") }) { ids.append(own) }
        return ids
    }
}
#endif

#if VAUTA_DIAGNOSTICS
extension SampleContent {
    /// The final segments of the recording shown in the menu-bar panel.
    public var liveSegments: [Segment] {
        liveTranscript.dropLast().enumerated().map { i, line in
            Segment(channel: line.mine ? .me : .others, start: Double(i) * 12, end: Double(i) * 12 + 9, text: line.text, isFinal: true)
        }
    }

    /// The provisional (still being recognized) segment.
    public var liveVolatileSegment: Segment? {
        liveTranscript.last.map { line in
            Segment(channel: line.mine ? .me : .others, start: Double(liveTranscript.count - 1) * 12,
                    end: Double(liveTranscript.count - 1) * 12 + 5, text: line.text, isFinal: false)
        }
    }
}
#endif

#if VAUTA_DIAGNOSTICS
extension Entity {
    /// The same person as a pending attendee suggested by the calendar (snapshots only; nothing is stored).
    public var snapshotPending: Entity {
        Entity(id: id, kind: kind, name: name, note: note, email: email, source: "calendar", confirmed: false,
               aliases: aliases, lastSeen: lastSeen, mentionCount: mentionCount, isSelf: false)
    }
}
#endif

#if VAUTA_DIAGNOSTICS
extension MeetingStore {
    func setMeetingLocaleForSnapshots(_ id: Int64, to identifier: String) throws {
        try run("UPDATE meetings SET locale = ? WHERE id = ?", [.text(identifier), .integer(id)])
    }

    func setMeetingStartForSnapshots(_ id: Int64, to date: Date) throws {
        // The "participants informed" time keeps its offset from the start.
        try run("UPDATE meetings SET participants_informed_at = participants_informed_at + (? - started_at), started_at = ? WHERE id = ?",
                [.real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970), .integer(id)])
    }

    func removeAllTranslationsForSnapshots() throws {
        try run("DELETE FROM segment_translations", [])
    }

    /// Replaces a segment's text and keeps the (external-content) full-text index in step.
    func replaceSegmentTextForSnapshots(_ id: Int64, with text: String) throws {
        guard let old = try db.query("SELECT text FROM segments WHERE id = ?", [.integer(id)]).first?.string(0) else { return }
        try run("INSERT INTO segments_fts(segments_fts, rowid, text) VALUES ('delete', ?, ?)", [.integer(id), .text(old)])
        try run("UPDATE segments SET text = ? WHERE id = ?", [.text(text), .integer(id)])
        try run("INSERT INTO segments_fts(rowid, text) VALUES (?, ?)", [.integer(id), .text(text)])
    }
}
#endif

#if VAUTA_DIAGNOSTICS
extension SampleWorld {
    /// One ambiguous name and one likely recognition error for the featured meeting (snapshots only; nothing is stored).
    public var sampleSuggestions: [Suggestion] {
        let first = content.people[1], third = content.people[3]
        let ambiguous = Suggestion(
            id: 1, meetingID: featuredMeetingID, segmentID: featuredSegmentIDs.indices.contains(3) ? featuredSegmentIDs[3] : nil, t: 3 * 38,
            kind: .ambiguous, surface: first.aliases.first ?? first.name,
            candidates: [SuggestionCandidate(entityID: peopleIDs[1], glossaryID: nil, label: first.name, score: 3.5),
                         SuggestionCandidate(entityID: peopleIDs[3], glossaryID: nil, label: third.name, score: 2.5)],
            occurrences: 2)
        let term = content.glossary[0]
        let correction = Suggestion(
            id: 2, meetingID: featuredMeetingID, segmentID: featuredSegmentIDs.indices.contains(6) ? featuredSegmentIDs[6] : nil, t: 6 * 38,
            kind: .correction, surface: term.term.map(String.init).joined(separator: " "),
            candidates: [SuggestionCandidate(entityID: nil, glossaryID: 1, label: "\(term.term): \(term.expansion)", score: 3)],
            occurrences: 1)
        return [ambiguous, correction]
    }
}
#endif
