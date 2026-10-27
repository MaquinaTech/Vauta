// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A single-event iCalendar file (RFC 5545) that Calendar opens and asks where to put. It is the way a follow-up event reaches Calendar
/// when Vauta has no full Calendar access (no new permission prompt is ever raised for it).
///
/// Times are written in UTC (`…Z`) so no `VTIMEZONE` is needed; an all-day event uses `VALUE=DATE`. There is no `ATTENDEE`, no
/// organizer, no alarm and no attendee name anywhere: the description names the meeting only.
public enum ICSFile {
    public static func render(title: String, day: DueDay, minuteOfDay: Int?, durationMinutes: Int, timeZone: TimeZone, description: String?,
                              uid: String = UUID().uuidString, stamp: Date = .now) -> String {
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Vauta//Follow-up//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH", "BEGIN:VEVENT",
                     "UID:\(uid)@vauta", "DTSTAMP:\(utc(stamp))"]
        if let minuteOfDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let start = calendar.date(from: day.floatingComponents(minuteOfDay: minuteOfDay)) ?? day.utcNoon
            lines.append("DTSTART:\(utc(start))")
            lines.append("DTEND:\(utc(start.addingTimeInterval(Double(max(1, durationMinutes)) * 60)))")
        } else {
            lines.append("DTSTART;VALUE=DATE:\(compact(day))")
            lines.append("DTEND;VALUE=DATE:\(compact(day.adding(days: 1)))")   // exclusive
        }
        lines.append("SUMMARY:\(escape(TextSanitizer.oneLine(title, limit: 300)))")
        if let description, !description.isEmpty { lines.append("DESCRIPTION:\(escape(description))") }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func compact(_ day: DueDay) -> String { String(format: "%04d%02d%02d", day.year, day.month, day.day) }

    static func utc(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// TEXT escaping: backslash, semicolon, comma and line breaks.
    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "\\": out += "\\\\"
            case ";": out += "\\;"
            case ",": out += "\\,"
            case "\n", "\r\n", "\r": out += "\\n"
            default: out.append(ch)
            }
        }
        return out
    }

    /// Content lines are folded at 75 octets, never inside a UTF-8 sequence; a continuation starts with one space.
    static func fold(_ line: String) -> String {
        var out = "", count = 0
        var first = true
        for ch in line {
            let size = String(ch).utf8.count
            let limit = first ? 75 : 74   // the leading space of a continuation counts
            if count + size > limit {
                out += "\r\n "
                count = 0
                first = false
            }
            out.append(ch)
            count += size
        }
        return out
    }
}

/// The short-lived `.ics` files handed to Calendar: a folder in the app's caches, excluded from backup, emptied at every launch and
/// cleared ten minutes after a hand-off.
public enum ICSHandoff {
    public static let folderName = "Handoff"
    public static let lifetime: TimeInterval = 600

    public static func folder(in caches: URL) -> URL { caches.appendingPathComponent(folderName, isDirectory: true) }

    @discardableResult
    public static func write(_ content: String, in caches: URL) throws -> URL {
        let directory = folder(in: caches)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folderURL = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folderURL.setResourceValues(values)
        var file = directory.appendingPathComponent("Follow-up-\(UUID().uuidString.prefix(8)).ics")
        try Data(content.utf8).write(to: file, options: .atomic)
        try? file.setResourceValues(values)
        return file
    }

    /// Removes the files older than `lifetime` (or all of them with `everything`, as at launch). Returns how many went.
    @discardableResult
    public static func purge(in caches: URL, everything: Bool = false, now: Date = .now) -> Int {
        let directory = folder(in: caches)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        var removed = 0
        for url in urls {
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if everything || now.timeIntervalSince(created) >= lifetime, (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}

extension ActionService {
    /// Hands an event to Calendar as an `.ics` file when there is no full Calendar access. The ledger row is `handed_off` (no
    /// identifier: Calendar owns the event from here, and Vauta can only forget the row). The caller opens the returned file.
    public func handOffEvent(followUp: FollowUp, draft: EventDraft, meetingTitle: String, meetingDate: Date, caches: URL) async -> (outcome: AddOutcome, file: URL?) {
        if let live = try? await store.liveAction(target: .ics, source: .followUp, sourceID: followUp.id) { return (.duplicate(.alreadyAdded(live)), nil) }
        let write = draft.write()
        let key = Self.key(.followUp, followUp.id, .ics)
        handingOff.insert(key)
        defer { handingOff.remove(key) }
        let intent: ActionIntent
        do {
            intent = try await store.beginAction(target: .ics, source: .followUp, sourceID: followUp.id, containerID: nil, titleHash: draft.titleHash)
        } catch ActionLedgerError.alreadyLive(let live) {
            return (.duplicate(.alreadyAdded(live)), nil)
        } catch {
            return (.failed, nil)
        }
        // The file carries the notes the editor showed (the meeting's name only if the person kept it, attendee names only if asked).
        let description = write.notes ?? ActionText.eventNote(meeting: TextSanitizer.oneLine(meetingTitle, limit: 200), date: ActionText.date(meetingDate, timeZone: draft.timeZone))
        let content = ICSFile.render(title: write.title, day: write.day, minuteOfDay: write.minuteOfDay, durationMinutes: write.durationMinutes,
                                     timeZone: write.timeZone, description: description)
        do {
            let file = try ICSHandoff.write(content, in: caches)
            try await store.completeAction(intent.action.id, itemID: nil, externalID: nil, state: .handedOff)
            guard let row = try await store.action(intent.action.id) else { return (.failed, nil) }
            return (.added(row), file)
        } catch {
            try? await store.abortAction(intent)
            return (.failed, nil)
        }
    }
}
