// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// What leaves Vauta by hand-off: the `.ics` file, the mail draft's route, the recipients and the clipboard marks.
@Suite("Actions: hand-offs")
struct ActionsHandoffTests {
    static let madrid = TimeZone(identifier: "Europe/Madrid")!

    // MARK: .ics

    @Test func aTimedEventIsWrittenInUTCWithNoZoneAndNoAttendee() {
        let ics = ICSFile.render(title: "Follow-up: Weekly sync", day: DueDay("2026-10-21")!, minuteOfDay: 600, durationMinutes: 30, timeZone: Self.madrid,
                                 description: "Follow-up of “Weekly sync”, 12 Oct 2026.", uid: "fixed", stamp: Date(timeIntervalSince1970: 1_792_000_000))
        #expect(ics.hasPrefix("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n") && ics.hasSuffix("END:VEVENT\r\nEND:VCALENDAR\r\n"))
        #expect(ics.contains("DTSTART:20261021T080000Z\r\n") && ics.contains("DTEND:20261021T083000Z\r\n"), "10:00 in Madrid in October is 08:00 UTC")
        #expect(ics.contains("UID:fixed@vauta\r\n") && ics.contains("DTSTAMP:2026"))
        for forbidden in ["TZID", "VTIMEZONE", "ATTENDEE", "ORGANIZER", "VALARM", "RRULE", "URL:"] { #expect(!ics.contains(forbidden), "\(forbidden)") }
    }

    @Test func anAllDayEventUsesDatesAndAnExclusiveEnd() {
        let ics = ICSFile.render(title: "Follow-up", day: DueDay("2026-12-31")!, minuteOfDay: nil, durationMinutes: 30, timeZone: Self.madrid, description: nil)
        #expect(ics.contains("DTSTART;VALUE=DATE:20261231\r\n") && ics.contains("DTEND;VALUE=DATE:20270101\r\n"))
        #expect(!ics.contains("DESCRIPTION"))
    }

    @Test func textIsEscapedAndLongLinesAreFoldedWithoutBreakingCharacters() {
        let title = "Budget; legal, ops\\x\nnext line 会議 レビュー " + String(repeating: "終わり", count: 60)
        let ics = ICSFile.render(title: title, day: DueDay("2026-10-21")!, minuteOfDay: 540, durationMinutes: 30, timeZone: Self.madrid, description: "A, B; C\nD")
        #expect(ics.contains("DESCRIPTION:A\\, B\\; C\\nD\r\n"))
        let lines = ics.components(separatedBy: "\r\n")
        for line in lines { #expect(line.utf8.count <= 75, "\(line.prefix(30))") }
        // Unfolded, the summary is the title (flattened to one line) with the escapes.
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "")
        let summary = unfolded.components(separatedBy: "\r\n").first { $0.hasPrefix("SUMMARY:") }!
        #expect(summary.contains("Budget\\; legal\\, ops\\\\x next line 会議 レビュー") && summary.contains("終わり終わり"))
        #expect(!unfolded.contains("\r\n ") && String(data: Data(ics.utf8), encoding: .utf8) == ics, "valid UTF-8 throughout")
    }

    @Test func theHandoffFolderIsExcludedFromBackupAndPurged() throws {
        let caches = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-ics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: caches) }
        let file = try ICSHandoff.write("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n", in: caches)
        #expect(file.deletingLastPathComponent().lastPathComponent == "Handoff" && file.pathExtension == "ics")
        #expect(try ICSHandoff.folder(in: caches).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(ICSHandoff.purge(in: caches) == 0, "a fresh file stays")
        #expect(ICSHandoff.purge(in: caches, now: .now.addingTimeInterval(ICSHandoff.lifetime + 1)) == 1, "ten minutes later it goes")
        _ = try ICSHandoff.write("x", in: caches)
        _ = try ICSHandoff.write("y", in: caches)
        #expect(ICSHandoff.purge(in: caches, everything: true) == 2, "launch empties the folder")
        #expect(ICSHandoff.purge(in: caches.appendingPathComponent("missing"), everything: true) == 0)
    }

    // MARK: Mail

    @Test func aShortDraftBecomesAMailtoWithEncodedFieldsAndCRLF() throws {
        let plan = MailHandoff.plan(to: ["ana@example.com", "luis+x@example.org"], subject: "Weekly sync, 12 Oct: decisions & next steps", body: "Hello,\n\nLine ü #1 100%\n")
        guard case .mailto(let url) = plan else { Issue.record("expected mailto"); return }
        #expect(url.absoluteString.count <= MailHandoff.maximumURLLength)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "ana@example.com,luis+x@example.org")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["subject"] == "Weekly sync, 12 Oct: decisions & next steps")
        #expect(items["body"] == "Hello,\r\n\r\nLine ü #1 100%\r\n")
    }

    @Test func aLongDraftIsCopiedInsteadOfPutInAURL() {
        let body = String(repeating: "- A task that goes on and on and on\n", count: 80)
        #expect(MailHandoff.mailtoURL(to: [], subject: "s", body: body) == nil)
        #expect(MailHandoff.plan(to: [], subject: "s", body: body) == .copyAndOpen)
        let edge = String(repeating: "a", count: MailHandoff.maximumURLLength - "mailto:?subject=s&body=".count)
        #expect(MailHandoff.mailtoURL(to: [], subject: "s", body: edge) != nil)
        #expect(MailHandoff.mailtoURL(to: [], subject: "s", body: edge + "a") == nil, "one character over the limit")
    }

    @Test func noRecipientsIsFine() {
        #expect(MailHandoff.mailtoURL(to: [], subject: "s", body: "b")?.absoluteString == "mailto:?subject=s&body=b")
    }

    // MARK: Recipients

    static func person(_ id: Int64, _ name: String, _ email: String?, isSelf: Bool = false) -> Entity {
        Entity(id: id, kind: .person, name: name, note: nil, email: email, source: "calendar", confirmed: true, aliases: [], lastSeen: nil, mentionCount: 0, isSelf: isSelf)
    }

    @Test func recipientsAreAttendeesWithAStoredAddressNoneTickedAndExternalOnesMarked() {
        let me = Self.person(1, "Maya", "maya@example.com", isSelf: true)
        let result = FollowUpRecipients.candidates(attendees: [
            me, Self.person(2, "Ana", "ana@example.com"), Self.person(3, "Zoe", "zoe@example.org"), Self.person(4, "Bo", nil), Self.person(5, "Broken", "not an address"),
            Self.person(6, "Ana Again", "ANA@example.com"), Self.person(7, "List", "a, b@example.net"),
        ], selfEntity: me)
        #expect(result.recipients.map(\.name) == ["Ana", "Zoe"], "self, no address, a broken address and a duplicate are left out")
        #expect(result.recipients.map(\.isExternal) == [false, true])
        #expect(result.selfDomainKnown)
    }

    @Test func withoutAnAddressOfTheirOwnNobodyIsMarkedExternalAndTheSheetSaysSo() {
        let me = Self.person(1, "Maya", nil, isSelf: true)
        let result = FollowUpRecipients.candidates(attendees: [Self.person(2, "Zoe", "zoe@example.org")], selfEntity: me)
        #expect(result.recipients.map(\.isExternal) == [false] && !result.selfDomainKnown)
        #expect(FollowUpRecipients.candidates(attendees: [Self.person(2, "Zoe", "zoe@example.org")], selfEntity: nil).selfDomainKnown == false)
    }

    @Test func aStoreBuildsTheRecipientsFromTheMeetingsAttendees() async throws {
        let f = try KnowledgeFixture()
        let s = f.store!
        let m = try await f.meeting(["hello"])
        let selfID = try await s.selfEntity()
        try await s.executeForTest("UPDATE entities SET email = 'maya@example.com' WHERE id = ?", [.integer(selfID)])
        let ana = try await s.saveEntity(EntityDraft(kind: .person, name: "Ana", email: "ana@example.org"))
        let bystander = try await s.saveEntity(EntityDraft(kind: .person, name: "Bystander", email: "by@example.com"))
        try await s.executeForTest("INSERT INTO meeting_entities(meeting_id, entity_id, role) VALUES (?, ?, 'attendee'), (?, ?, 'attendee')",
                                   [.integer(m), .integer(selfID), .integer(m), .integer(ana)])
        let result = try await s.followUpRecipients(m)
        #expect(result.recipients.map(\.name) == ["Ana"] && result.recipients[0].isExternal)
        #expect(!result.recipients.contains { $0.entityID == bystander }, "only the meeting's attendees; no address book")
    }

    // MARK: Copy and copy protection

    @Test func theClipboardMarksAreTheConcealedAndTransientTypes() {
        #expect(PasteboardMarks.all == ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"])
    }

    @Test func copyProtectionBlocksTheEmailAndOnlyWarnsForRemindersAndEvents() {
        #expect(!ActionCopyPolicy.emailAllowed(copyProtection: true) && ActionCopyPolicy.emailAllowed(copyProtection: false))
        #expect(ActionCopyPolicy.writeAllowed(copyProtection: true) && ActionCopyPolicy.writeWarns(copyProtection: true))
        #expect(ActionCopyPolicy.writeAllowed(copyProtection: false) && !ActionCopyPolicy.writeWarns(copyProtection: false))
    }
}
