// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// What the code may reach: one writer file for EventKit, no new network destination, the brief's use of the ledger, and the shortcuts.
@Suite("Actions: reach, brief and shortcuts")
struct ActionsScanTests {
    static let writerPath = "Sources/Vauta/App/Actions/EventKitActionWriter.swift"

    static func sources() throws -> [(path: String, code: String)] {
        try NetworkAuditSourceScanTests.sourceFiles().map { ($0.path, NetworkAuditSourceScanTests.code($0.text)) }
    }

    // MARK: EventKit

    /// Every file that imports EventKit, but the writer, is free of EventKit's write calls; the writer is the only one that has them.
    @Test func onlyTheWriterFileSavesOrRemovesAnythingInReminders() throws {
        let write = #"\.(save|remove|commit|reset)\s*\(|\b(saveEvent|saveReminder|saveCalendar|removeEvent|removeReminder|removeCalendar|commit)\s*\("#
        var importing: [String] = []
        for (path, code) in try Self.sources() where code.range(of: #"(?m)^\s*(@\w+\s+)?import\s+EventKit\b"#, options: .regularExpression) != nil {
            importing.append(path)
            if path != Self.writerPath { #expect(code.range(of: write, options: .regularExpression) == nil, "\(path) calls an EventKit write API") }
        }
        #expect(importing.contains(Self.writerPath), "the writer file exists and imports EventKit")
        #expect(importing.contains("Sources/Vauta/App/CalendarWatcher.swift") && importing.count >= 3, "the scan sees the files that use EventKit")
        let writer = try #require(try Self.sources().first { $0.path == Self.writerPath }?.code)
        #expect(writer.contains("store.save(") && writer.contains("store.remove("), "the writer is where the writes are")
    }

    @Test func theCoreNeverImportsEventKit() throws {
        for (path, code) in try Self.sources() where path.hasPrefix("Sources/VautaCore/") {
            #expect(code.range(of: #"import\s+EventKit"#, options: .regularExpression) == nil, "\(path)")
        }
    }

    @Test func theWriterNeverEditsCompletesCreatesListsOrAsksForCalendar() throws {
        let writer = try #require(try Self.sources().first { $0.path == Self.writerPath }?.code)
        let forbidden: [(String, String)] = [
            ("asks for Calendar access", #"requestFullAccessToEvents|requestWriteOnlyAccessToEvents|requestAccess\s*\(\s*to:\s*\.event"#),
            ("creates a list or calendar", #"EKCalendar\s*\(|saveCalendar|removeCalendar"#),
            ("completes a reminder", #"isCompleted\s*=[^=]|completionDate\s*="#),
            ("changes an existing item", #"\.(title|notes|dueDateComponents|startDate|endDate)\s*=\s*[^=]*\bfound\b"#),
            ("saves a batch without commit", #"\.save\([^)]*commit:\s*false"#),
            ("reads notes of foreign items", #"(?<!write)\.notes\b(?!\s*=)"#),
            ("reads attendees or URLs", #"\.attendees\b|\.url\b|\.location\b|\.structuredLocation\b"#),
        ]
        for (name, pattern) in forbidden { #expect(writer.range(of: pattern, options: .regularExpression) == nil, "the writer \(name)") }
        #expect(writer.contains("requestFullAccessToReminders"), "the Reminders prompt exists, and only here")
        for (path, code) in try Self.sources() where path != Self.writerPath && !path.hasSuffix("EventKitBriefSources.swift") {
            #expect(!code.contains("requestFullAccessToReminders") || path.contains("Brief") || path.contains("Settings") || path.contains("Onboarding") || path.contains("CalendarWatcher"), "\(path)")
        }
    }

    @Test func theActionsCodeIsAppleFrameworksOnlyAndTouchesNoNetwork() throws {
        var checked = 0
        for (path, code) in try Self.sources() where path.hasPrefix("Sources/VautaCore/Actions/") || path.hasPrefix("Sources/Vauta/App/Actions/") {
            checked += 1
            #expect(NetworkAuditSourceScanTests.violations(in: code).isEmpty, "\(path)")
            #expect(code.range(of: #"\bProcess\s*\(|NSAppleScript|osascript|NSTask|CNContactStore|MFMailCompose"#, options: .regularExpression) == nil, "\(path)")
        }
        #expect(checked >= 14)
    }

    @Test func noNetworkPurposeWasAddedForPartA() {
        #expect(NetworkPurpose.allCases.map(\.rawValue) == ["minutes", "liveNotes", "notes", "ask", "liveAnswers", "brief", "embeddings", "documents", "translation", "modelDownload",
                                                           "languageModelDownload", "discovery", "connectionTest", "statusCheck", "other"])
    }

    // MARK: The mail draft is never logged

    @Test func theMailOpenerLogsNothingAboutTheDraftExceptAsPrivate() throws {
        let root = NetworkAuditSourceScanTests.packageRoot()
        let text = try String(contentsOf: root.appending(path: "Sources/Vauta/App/Actions/MailHandoffOpener.swift"), encoding: .utf8)
        let code = NetworkAuditSourceScanTests.code(text)
        #expect(code.range(of: #"\bprint\s*\(|NSLog\s*\(|debugPrint"#, options: .regularExpression) == nil)
        for line in code.split(separator: "\n") where line.contains("log.") {
            let interpolations = line.components(separatedBy: "\\(").dropFirst()
            for part in interpolations { #expect(part.contains("privacy: .private") || part.contains("privacy: .public") && part.contains(".count"), "\(line)") }
        }
        #expect(code.contains("absoluteString, privacy: .private"))
    }

    // MARK: Meeting text stays protected in new fields

    @Test func anyEditableFieldAddedToTheActionsViewsUsesTheMeetingTextModifiers() throws {
        let root = NetworkAuditSourceScanTests.packageRoot()
        let directory = root.appending(path: "Sources/Vauta/App/Actions")
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "swift" {
            let code = NetworkAuditSourceScanTests.code(try String(contentsOf: url, encoding: .utf8))
            if code.range(of: #"\b(TextField|TextEditor|SecureField)\s*\("#, options: .regularExpression) != nil {
                #expect(code.contains("writingToolsBehavior(.disabled)"), "\(url.lastPathComponent): Writing Tools off")
                #expect(code.contains("NoCopyText") || code.contains("meetingText"), "\(url.lastPathComponent): the no-Services wrapper")
            }
        }
    }

    // MARK: Shortcuts

    @Test func noKeyboardShortcutCollidesWithinAWindowOrWithTheMenuBar() throws {
        let pattern = try NSRegularExpression(pattern: #"\.keyboardShortcut\(\s*"(.)"\s*(?:,\s*modifiers:\s*(\[[^\]]*\]|\.\w+))?"#)
        func shortcuts(_ code: String) -> [String] {
            pattern.matches(in: code, range: NSRange(code.startIndex..., in: code)).map { m in
                let key = String(code[Range(m.range(at: 1), in: code)!])
                let raw = m.range(at: 2).location == NSNotFound ? ".command" : String(code[Range(m.range(at: 2), in: code)!])
                let mods = raw.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.sorted()
                return key + "+" + mods.joined(separator: "+")
            }
        }
        var groups: [String: [String]] = [:]
        for (path, code) in try Self.sources() where path.hasPrefix("Sources/Vauta/App/") {
            let parts = path.split(separator: "/")
            let group = parts.count > 4 ? String(parts[3]) : "App"
            groups[group, default: []] += shortcuts(code)
        }
        #expect(groups["Meetings"]?.count ?? 0 >= 4, "the scan sees the Meetings window's shortcuts")
        for (group, list) in groups { #expect(Set(list).count == list.count, "\(group) has two equal shortcuts: \(list.sorted())") }
        let commands = try #require(try Self.sources().first { $0.path.hasSuffix("MeetingsCommands.swift") }?.code)
        #expect(commands.contains(#"Button("Follow Up…") { model?.openFollowUp() }"# + "\n" + #"                .keyboardShortcut("u", modifiers: [.command, .shift])"#), "Follow Up… is ⇧⌘U, as designed")
        let app = Set(groups["App"] ?? [])
        for group in ["Meetings", "Context", "Documents", "Notepad", "Onboarding"] {
            #expect(app.isDisjoint(with: groups[group] ?? []), "\(group) takes a menu bar shortcut")
        }
    }

    // MARK: The brief

    @Test func aTaskWithAReminderIsShownOnceAsTheTaskAndTheReminderIsDropped() async throws {
        let (f, composer, _, event) = try await BriefComposerTests.rig()
        let s = f.store!
        let settings = BriefSettings(remindersEnabled: true, reminderListIDs: ["L"])
        let before = try #require(await composer.build(event, settings: settings, environment: BriefEnvironment(), now: BriefFixtures.now).snapshot)
        #expect(before.section(.reminders)?.items.map(\.text).contains("Call Ana about the shell material") == true)
        let task = try #require(try await s.openTasks().first { $0.text == "Book the factory visit" })
        // Vauta created reminder r1 from that task: it is the same thing the brief would list twice.
        _ = try await s.recordLinked(target: .reminder, source: .task, sourceID: task.id, containerID: "L", itemID: "r1", externalID: nil, titleHash: ActionTitle.hash("x"))
        let after = try #require(await composer.build(event, settings: settings, environment: BriefEnvironment(), now: BriefFixtures.now).snapshot)
        #expect(after.section(.reminders) == nil, "the reminder in the ledger is not listed again")
        let shown = after.sections.flatMap(\.items).filter { $0.kind == .task && $0.taskID == task.id }
        #expect(shown.count == 1 && shown[0].inReminders, "the task appears once, marked In Reminders")
        #expect(after.sections.flatMap(\.items).filter { $0.kind == .task && $0.taskID != task.id }.allSatisfy { !$0.inReminders })
    }

    @Test func aReminderIsMatchedByItsExternalIdentifierToo() {
        let reminders = [BriefReminder(id: "local-2", title: "Book the factory visit", due: nil, listID: "L", listName: "Work", externalID: "ext-9"),
                         BriefReminder(id: "local-3", title: "Buy milk", due: nil, listID: "L", listName: "Work", externalID: "ext-10")]
        let ledger = LedgerIdentifiers(itemIDs: ["old-local-id"], externalIDs: ["ext-9"], taskIDs: [1])
        #expect(BriefReminderFilter.eligible(reminders, listIDs: ["L"], event: BriefFixtures.now, ledger: ledger).map(\.id) == ["local-3"])
        #expect(BriefReminderFilter.eligible(reminders, listIDs: ["L"], event: BriefFixtures.now).count == 2, "without a ledger nothing is dropped")
    }

    @Test func theBriefModuleStillCallsNoEventKitWriteAndReadsTheLedgerOnly() throws {
        for (path, code) in try Self.sources() where path.hasPrefix("Sources/VautaCore/Brief/") {
            #expect(code.range(of: #"\.(save|remove|commit)\s*\(|beginAction|completeAction|setActionState"#, options: .regularExpression) == nil, "\(path)")
        }
    }
}
