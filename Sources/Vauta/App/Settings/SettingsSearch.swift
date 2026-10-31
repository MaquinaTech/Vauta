// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// A setting that Settings search finds: its name as its pane shows it, and the pane.
struct SettingsSearchEntry: Identifiable, Hashable {
    let pane: SettingsModel.Pane
    /// The key of the name in `Localizable.strings` (the English name), so the result reads as the setting does on screen.
    let key: String

    var id: String { "\(pane.rawValue)|\(key)" }
    var title: String { key == pane.rawValue ? pane.title : Bundle.main.localizedString(forKey: key, value: key, table: nil) }
}

/// Settings search, in the sidebar: the panes and the settings whose names have every word typed, in any case and with or
/// without accents, in the language of the app. Choosing a result opens its pane. Each name is one the pane shows (a test
/// keeps them in the strings table), so a result never names something the person won't find there.
enum SettingsSearch {
    /// The settings of each pane, in the order the pane shows them: section titles and the names of the settings in them.
    static let index: [SettingsModel.Pane: [String]] = [
        .general: ["Startup", "Open Vauta at login", "Keyboard shortcuts", "Start or stop recording", "Mark a moment", "Take a note",
                   "Pause or resume recording", "Turn Live Translation on or off", "Open the notepad when recording starts", "Notifications", "When minutes are ready",
                   "When something needs your attention", "Show meeting titles in notifications", "Show follow-up after meetings"],
        .recording: ["Live answers", "Answer questions asked in the meeting", "Keep detected questions with the meeting",
                     "Hide answers when someone answers aloud", "Starting and stopping", "Suggest recording when a call starts",
                     "Stop recording after a silence of", "Stop recording when the screen locks", "Meeting audio", "All system audio",
                     "Only the apps I choose", "Informing participants", "Remind me to inform participants", "Transcription language",
                     "Speech models", "Custom vocabulary"],
        .speakers: ["Speaker separation", "Separate speakers", "Voice recognition", "Recognize voices across meetings", "Saved voices"],
        .translation: ["Live Translation", "Languages", "Translate into", "Captions", "Text size", "Show the original words under each caption",
                       "Read captions aloud with VoiceOver", "Transcripts", "Show translations in transcripts", "Better translations",
                       "Improve finished sentences with your model server", "Translation model"],
        .models: ["Provider", "Write minutes with", "Apple Intelligence on this Mac", "A model server on this Mac", "A model server on your network",
                  "Integrated model", "Minutes", "Minutes language", "Default template", "Meetings without minutes", "Search by meaning",
                  "Ask finds passages with", "Server", "Address", "Fast model", "Main model", "Context length", "Key (optional)",
                  "Test Connection", "Find Model Servers", "Set Up a Model Server…", "Paste Configuration", "Certificate pins (optional)",
                  "Private certificate authority (optional)"],
        .privacy: ["Keeping meetings", "Minutes, decisions, notes and tasks", "Protect meeting text from copying", "Lock Meetings again",
                   "Back up or restore", "Back Up…", "Restore…", "Verify a backup", "Verify Backup…", "Erase meetings and context", "Network activity",
                   "How Vauta protects your meetings"],
        .context: ["People", "Projects", "Clients", "Systems", "Glossary", "Recurring Meetings"],
        .documents: ["Sources", "Index"],
        .calendar: ["Calendars Vauta reads", "Use Calendar to suggest and name meetings", "Meeting suggestions", "Pre-meeting brief",
                    "Prepare a brief before meetings", "Notify me before a meeting", "Reminders in the brief", "Show related reminders in the brief",
                    "Reminder lists Vauta reads", "After meetings", "Default list", "Default calendar", "Alert on the due day", "Time of the alert",
                    "Include the meeting’s name in notes"],
        .status: ["Checklist", "Diagnostics", "Copy Diagnostics"],
        .about: ["Credits and Licenses", "License", "Source code", "Third-party software"],
    ]

    /// What `query` finds: the panes whose names have its words, then the settings, pane by pane. Nothing for an empty query.
    static func results(for query: String, title: (SettingsSearchEntry) -> String = \.title) -> [SettingsSearchEntry] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        func matches(_ text: String) -> Bool {
            words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil }
        }
        let panes = SettingsModel.Pane.allCases.map { SettingsSearchEntry(pane: $0, key: $0.rawValue) }.filter { matches(title($0)) }
        let settings = SettingsModel.Pane.allCases.flatMap { pane in
            (index[pane] ?? []).map { SettingsSearchEntry(pane: pane, key: $0) }.filter { matches(title($0)) }
        }
        return panes + settings
    }
}
