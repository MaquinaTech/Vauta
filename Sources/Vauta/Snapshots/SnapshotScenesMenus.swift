// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import SwiftUI

// Notifications and menus, as stand-ins that carry the words the app gives them (see SnapshotMenuMocks.swift): the 13 kinds of
// notification with their buttons, the menus of the panel's footer and of Live Translation, the menu bar, and the menus and
// context menus of the Meetings window and Settings.

extension SnapshotScenes {
    static var vqaMenus: [SnapshotScene] { notificationScenes + panelMenuScenes + menuBarScenes + meetingsMenuScenes + settingsMenuScenes }

    /// A stand-in on a plain surface, as wide as `width` (the card sits at the top left, like a menu opened under its button).
    /// `width` nil: the image is as wide as the mock (a menu), with its 20 pt margin.
    static func mockScene(_ name: String, width: CGFloat? = 420, build: @escaping @MainActor (SnapshotFixture) async -> AnyView) -> SnapshotScene {
        SnapshotScene(name: name, size: CGSize(width: width ?? 420, height: 200), fitHeight: true, isFloating: true, fitWidth: width == nil) { fixture in
            _ = await fixture.makeRecorder()
            let view = await build(fixture)
            guard let width else { return .init(view: AnyView(view.padding(20).fixedSize().background(Color(nsColor: .windowBackgroundColor)))) }
            return .init(view: AnyView(view.padding(20).frame(width: width, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))))
        }
    }

    private static func menuScene(_ name: String, width: CGFloat? = nil, minWidth: CGFloat = 240,
                                  _ entries: @escaping @MainActor (SnapshotFixture) async -> [MockMenuEntry]) -> SnapshotScene {
        mockScene(name, width: width) { fixture in AnyView(MenuMock(entries: await entries(fixture), minWidth: minWidth)) }
    }

    // MARK: Notifications

    private static let sampleDate = SampleWorld.snapshotNow.addingTimeInterval(-3600)

    private static func notificationScene(_ name: String, _ make: @escaping @MainActor (SnapshotFixture) async -> AppNotification) -> SnapshotScene {
        mockScene("notification-\(name)", width: 420) { fixture in AnyView(NotificationMock(notification: await make(fixture))) }
    }

    private static func firstMeetingTitle(_ fixture: SnapshotFixture) async -> String {
        (try? await fixture.world.store.meetings())?.first?.displayTitle ?? "Weekly product sync"
    }

    private static var notificationScenes: [SnapshotScene] {
        [
            notificationScene("minutes-ready") { f in .minutesReady(meetingID: 1, meetingTitle: await firstMeetingTitle(f), startedAt: sampleDate) },
            notificationScene("minutes-ready-no-title") { _ in .minutesReady(meetingID: 1, meetingTitle: nil, startedAt: sampleDate) },
            notificationScene("minutes-failed") { f in .minutesFailed(meetingID: 1, meetingTitle: await firstMeetingTitle(f), startedAt: sampleDate) },
            notificationScene("minutes-failed-no-title") { _ in .minutesFailed(meetingID: 1, meetingTitle: nil, startedAt: sampleDate) },
            notificationScene("suggestion") { f in
                let call = CallDescription(appName: f.content.callApp, family: .zoom, service: nil)
                return .suggestion(callDescription: call.sentence, eventTitle: await firstMeetingTitle(f))
            },
            notificationScene("suggestion-no-title") { f in
                .suggestion(callDescription: CallDescription(appName: f.content.callApp, family: .zoom, service: nil).sentence, eventTitle: nil)
            },
            notificationScene("hangup") { f in .hangup(appName: f.content.callApp) },
            notificationScene("hangup-no-app") { _ in .hangup(appName: nil) },
            notificationScene("recording-stopped-silence") { _ in .recordingStopped(.silence(minutes: 10), meetingID: 1) },
            notificationScene("recording-stopped-sleep") { _ in .recordingStopped(.sleep, meetingID: 1) },
            notificationScene("recording-stopped-locked") { _ in .recordingStopped(.screenLocked, meetingID: 1) },
            notificationScene("recording-stopped-switched") { _ in .recordingStopped(.userSwitched, meetingID: 1) },
            notificationScene("autostop-warning") { _ in .autoStopWarning(secondsLeft: 30) },
            notificationScene("start-failed") { _ in
                .startFailed(.startFailed, reason: String(localized: "Vauta is still opening your data.", comment: "Why a recording didn’t start: the encrypted store isn’t open yet"))
            },
            notificationScene("start-blocked") { _ in .startFailed(.startBlocked, reason: CaptureError.microphoneDeniedMessage) },
            notificationScene("start-needs-model") { f in
                let language = SnapshotMode.catalog?.language(matching: foreignSpeechID(f))?.displayName ?? "French"
                return .startFailed(.startNeedsModel, reason: String(localized: "The speech model for \(language) isn’t installed.", comment: "Capture error; the argument is a language name"))
            },
            notificationScene("server-unreachable") { _ in .serverUnreachable() },
            notificationScene("recording-imported") { _ in .recordingImported(meetingID: 1) },
            notificationScene("voices-unused") { _ in .voicesUnused() },
            notificationScene("brief") { f in .brief(minutesBefore: 5, eventTitle: await firstMeetingTitle(f)) },
            notificationScene("brief-no-title") { _ in .brief(minutesBefore: 5, eventTitle: nil) },
        ]
    }

    // MARK: Panel menus (footer and Live Translation)

    private static var panelMenuScenes: [SnapshotScene] {
        [
            // The audio source menu before a recording: Automatic is on.
            menuScene("panel-menu-audio-source") { _ in
                var entries: [MockMenuEntry] = [.item(String(localized: "Automatic (App in the Call)"), checked: true), .header(String(localized: "Meeting Apps"))]
                entries += MeetingAppFamily.allCases.map { .item($0.displayName) }
                entries += [.separator, .item(String(localized: "All System Audio")), .separator,
                            .note(String(localized: "Applies to the next recording. Automatic records all system audio when no meeting app is using the microphone."))]
                return entries
            },
            menuScene("panel-menu-audio-source-apps") { _ in
                var entries: [MockMenuEntry] = [.item(String(localized: "Automatic (App in the Call)")), .header(String(localized: "Meeting Apps"))]
                entries += MeetingAppFamily.allCases.map { .item($0.displayName, checked: $0 == .zoom || $0 == .teams) }
                entries += [.separator, .item(String(localized: "All System Audio")), .separator,
                            .note(String(localized: "Applies to the next recording. Automatic records all system audio when no meeting app is using the microphone."))]
                return entries
            },
            menuScene("panel-menu-language") { fixture in languageMenu(fixture, more: false) },
            menuScene("panel-menu-language-more") { fixture in languageMenu(fixture, more: true) },
            // Live Translation: "Translate into" (the panel's row), and the same list behind the captions' "Choose Language".
            menuScene("panel-menu-translate-into") { fixture in translateInto(fixture) },
            menuScene("captions-menu-choose-language") { fixture in translateInto(fixture) },
            menuScene("captions-menu-text-size", minWidth: 160) { _ in
                CaptionTextSize.allCases.map { .item($0.title, checked: $0 == .medium) }
            },
        ]
    }

    private static func languageMenu(_ fixture: SnapshotFixture, more: Bool) -> [MockMenuEntry] {
        guard let catalog = SnapshotMode.catalog else { return [] }
        let sort: (SpeechLanguage, SpeechLanguage) -> Bool = { LanguageNameSort.precedes($0.displayName, $1.displayName) }
        let installed = catalog.languages.filter(\.isInstalled).sorted(by: sort)
        let others = catalog.languages.filter { !$0.isInstalled }.sorted(by: sort)
        let note = MockMenuEntry.note(String(localized: "Applies to the next recording. A language that isn’t installed downloads once from Apple."))
        if more {
            // "More Languages" opened: the languages that download on first use.
            return others.map { .item($0.displayName.standaloneCapitalized) }
        }
        var entries: [MockMenuEntry] = []
        if let automatic = catalog.defaultLanguage() {
            entries.append(.item(String(localized: "Automatic – \(automatic.displayName.standaloneCapitalized)", comment: "Language picker: the default, followed by the language it uses; the argument is a language name"), checked: true))
        } else {
            entries.append(.item(String(localized: "Automatic"), checked: true))
        }
        if !installed.isEmpty {
            entries.append(.header(String(localized: "Installed")))
            entries += installed.map { .item($0.displayName.standaloneCapitalized) }
        }
        if !others.isEmpty { entries.append(.item(String(localized: "More Languages"), submenu: true)) }
        return entries + [.separator, note]
    }

    private static func translateInto(_ fixture: SnapshotFixture) -> [MockMenuEntry] {
        let sample = fixture.captionSample
        let automatic = String(localized: "Automatic (\(TranslationPair.name(of: sample.pair.target)))",
                               comment: "Language menu: use the Mac’s language; the argument is that language")
        var entries: [MockMenuEntry] = [.item(automatic, checked: true), .separator]
        entries += sample.targets.map { .item($0.name, symbol: $0.availability == .downloadable ? "arrow.down.circle" : nil) }
        return entries
    }

    // MARK: Menu bar

    private static func recorderText(_ fixture: SnapshotFixture) async -> (record: String, mark: String, translate: String) {
        let recorder = await fixture.makeRecorder()
        return (recorder.recordHotKeyText, recorder.markHotKeyText, recorder.translationHotKeyText)
    }

    private static var menuBarScenes: [SnapshotScene] {
        [
            // The system adds About, Hide, Hide Others and Show All around Vauta's own Settings… and Quit Vauta, in the system's order.
            menuScene("menubar-menu-vauta", minWidth: 240) { fixture in
                let words = SystemWords.applicationMenu(fixture.language)
                return [.item(words.about), .separator, .item(String(localized: "Settings…"), shortcut: "⌘,"), .separator,
                        .item(words.hide, shortcut: "⌘H"), .item(words.hideOthers, shortcut: "⌥⌘H"), .item(words.showAll), .separator,
                        .item(String(localized: "Quit Vauta"), shortcut: "⌘Q")]
            },
            menuScene("menubar-menu-recording", minWidth: 260) { fixture in
                let keys = await recorderText(fixture)
                return [.item(String(localized: "Start Recording"), shortcut: keys.record),
                        .item(String(localized: "Mark a Moment"), shortcut: keys.mark, disabled: true),
                        .item(String(localized: "Live Translation"), shortcut: keys.translate)]
            },
            menuScene("menubar-menu-recording-active", minWidth: 260) { fixture in
                let keys = await recorderText(fixture)
                return [.item(String(localized: "Stop Recording"), shortcut: keys.record),
                        .item(String(localized: "Mark a Moment"), shortcut: keys.mark),
                        .item(String(localized: "Live Translation"), shortcut: keys.translate, checked: true)]
            },
            menuScene("menubar-menu-window", minWidth: 240) { _ in
                [.item(String(localized: "Meetings Window"), shortcut: "⌘0"), .item(String(localized: "Network Activity"), shortcut: "⌥⌘N")]
            },
            menuScene("menubar-menu-help", minWidth: 220) { _ in
                [.item(String(localized: "Set Up Vauta")), .item(String(localized: "Vauta Help"))]
            },
            // The Meetings window adds to File, Edit and View.
            menuScene("menubar-menu-file", minWidth: 260) { _ in
                [.item(String(localized: "Import Recording…"), shortcut: "⇧⌘I"), .item(String(localized: "Export…"), shortcut: "⇧⌘E"),
                 .item(String(localized: "Follow Up…"), shortcut: "⇧⌘U")]
            },
            menuScene("menubar-menu-edit", minWidth: 340) { _ in
                [.item(String(localized: "Copy Minutes"), shortcut: "⇧⌘C"), .item(String(localized: "Copy Minutes as Plain Text")), .separator,
                 .item(String(localized: "Search Meetings"), shortcut: "⌘F"),
                 .item(String(localized: "Speaker Options for Highlighted Passage"), disabled: true),
                 .item(String(localized: "Delete Meeting…"), shortcut: "⌘⌫")]
            },
            // The names Undo and Redo take: the system writes "Undo …" / "Redo …" in front of each.
            menuScene("menubar-menu-edit-undo-names", minWidth: 340) { fixture in
                let undo = SystemWords.undoTitle(fixture.language)
                let names = [SpeakerEditKind.name, .clearName, .merge, .moveLine, .split, .turnOff, .rejectSuggestion, .turnOn].map(\.actionName)
                    + [String(localized: "Add to Reminders", comment: "Edit menu: the name of the action that Undo takes back"),
                       String(localized: "Add to Calendar", comment: "Edit menu: the name of the action that Undo takes back"),
                       String(localized: "Use This Reminder", comment: "Edit menu: the name of the action that Undo takes back")]
                return names.map { .item(String(format: undo, $0)) }
            },
            menuScene("menubar-menu-view", minWidth: 240) { _ in
                MeetingsModel.Mode.allCases.map { .item($0.label, shortcut: "⌘\($0.shortcut)") }
            },
        ]
    }

    // MARK: Meetings window

    private static func entityMenu(_ fixture: SnapshotFixture, persons: Bool) async -> [MockMenuEntry] {
        let people = ((try? await fixture.world.store.entities(.person)) ?? []).filter { !$0.isSelf }
        let projects = (try? await fixture.world.store.entities(.project)) ?? []
        let clients = (try? await fixture.world.store.entities(.client)) ?? []
        let list = persons ? people : projects + clients
        // Like the real menu: every entity linked to the featured meeting is checked.
        let id = fixture.world.featuredMeetingID
        let linked = Set(((try? await fixture.world.store.meetingEntities(id, role: persons ? .attendee : .topic)) ?? []).map(\.id))
        // The menu of projects and clients is shown for a meeting linked to the project only, so the add path is visible: the client is
        // a candidate that is not linked yet (a toggle, checked when linked).
        let unlinked = persons ? Set<Int64>() : Set(clients.map(\.id))
        return list.map { .item($0.displayName, checked: linked.contains($0.id) && !unlinked.contains($0.id), symbol: $0.kind.symbol) }
    }

    private static var meetingsMenuScenes: [SnapshotScene] {
        [
            // The toolbar's Copy Minutes menu (Export and Delete are plain buttons).
            mockScene("meetings-menu-copy-minutes") { _ in
                AnyView(MenuButtonMock(title: String(localized: "Copy Minutes"),
                                       entries: [.item(String(localized: "Copy as Markdown")), .item(String(localized: "Copy as Plain Text"))]))
            },
            // The "+" after the attendees and after the project chips.
            mockScene("meetings-menu-add-attendee") { fixture in AnyView(MenuMock(entries: await entityMenu(fixture, persons: true))) },
            mockScene("meetings-menu-add-project") { fixture in AnyView(MenuMock(entries: await entityMenu(fixture, persons: false))) },
            menuScene("meetings-menu-decision", minWidth: 200) { _ in [.item(String(localized: "Mark as Checked"))] },
            menuScene("meetings-menu-informed", minWidth: 160) { _ in [.item(String(localized: "Clear"))] },
            // The reminder menu of a task (the Tasks table, Open Tasks and the task rows share it), in each of its states.
            menuScene("meetings-menu-task") { _ in [.item(String(localized: "Add to Reminders…"))] },
            menuScene("meetings-menu-task-in-reminders") { _ in
                [.item(String(localized: "Open in Reminders")), .item(String(localized: "Remove from Reminders…"))]
            },
            menuScene("meetings-menu-task-missing") { _ in [.item(String(localized: "Add Again…")), .item(String(localized: "Forget"))] },
            menuScene("meetings-menu-task-done-in-reminders") { _ in
                [.item(String(localized: "Mark Done Here")), .item(String(localized: "Open in Reminders")), .item(String(localized: "Remove from Reminders…"))]
            },
            menuScene("meetings-menu-task-linked") { _ in [.item(String(localized: "Open in Reminders")), .item(String(localized: "Unlink"))] },
            // The minutes bar: the main button writes with the meeting's template, the menu picks another.
            mockScene("meetings-menu-minutes-template") { _ in
                AnyView(MenuButtonMock(title: String(localized: "Try Again"),
                                       entries: [.header(String(localized: "Template"))] + MinutesTemplate.allCases.map { .item($0.displayName, checked: $0 == .general) }))
            },
            mockScene("meetings-menu-minutes-propose") { _ in
                AnyView(MenuButtonMock(title: String(localized: "Propose Decisions and Tasks"),
                                       entries: [.header(String(localized: "Template"))] + MinutesTemplate.allCases.map { .item($0.displayName) }))
            },
            mockScene("meetings-menu-ask-copy") { _ in
                AnyView(MenuButtonMock(title: String(localized: "Copy Answer"), entries: [.item(String(localized: "Copy Answer as Plain Text"))]))
            },
            // A note in the Notes tab.
            menuScene("meetings-menu-note", minWidth: 200) { _ in
                [.item(String(localized: "Edit Note")), .item(String(localized: "Expand Again")), .item(String(localized: "Remove Expansion")), .separator,
                 .item(String(localized: "Delete Note"), destructive: true)]
            },
            menuScene("meetings-menu-note-dismissed", minWidth: 200) { _ in
                [.item(String(localized: "Edit Note")), .item(String(localized: "Expand Again")), .item(String(localized: "Show Expansion")), .separator,
                 .item(String(localized: "Delete Note"), destructive: true)]
            },
            menuScene("meetings-menu-link", minWidth: 200) { _ in
                [.item(String(localized: "Undo Link", comment: "Menu item on a confirmed link to an earlier meeting: it goes back to being a suggestion")),
                 .item(String(localized: "Show", comment: "Button on a link to an earlier meeting: opens that meeting at the item the link is about"))]
            },
            // Text that copy protection covers: no Copy.
            menuScene("meetings-menu-protected-text", minWidth: 160) { _ in
                [.item(String(localized: "Paste", comment: "Context menu of a protected text field")),
                 .item(String(localized: "Select All", comment: "Context menu of a protected text field"))]
            },
        ]
    }

    // MARK: Settings

    private static var settingsMenuScenes: [SnapshotScene] {
        [
            // Settings → Context: the sidebar's context menu for a suggested person, a confirmed one, and a term or recurring meeting.
            menuScene("settings-menu-context-suggested", minWidth: 200) { _ in
                [.item(String(localized: "Confirm")), .item(String(localized: "Merge Into…")), .separator, .item(String(localized: "Dismiss Person"), destructive: true)]
            },
            menuScene("settings-menu-context-person", minWidth: 200) { _ in
                [.item(String(localized: "Merge Into…")), .separator, .item(String(localized: "Delete…"), destructive: true)]
            },
            menuScene("settings-menu-context-term", minWidth: 200) { _ in [.item(String(localized: "Delete…"), destructive: true)] },
            // Settings → Models: the server's model menus.
            menuScene("settings-menu-server-models", minWidth: 300) { _ in
                (SampleWorld.discoveredServers().first?.models ?? []).map { .item($0.id, checked: $0.id == "qwen3-30b-a3b-instruct") }
            },
        ]
    }
}
#endif
