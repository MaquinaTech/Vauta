// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import SwiftUI

/// Settings → Privacy & Security: locking, copy protection, retention and erasing.
struct PrivacyPane: View {
    @Bindable var recorder: RecorderModel
    @Bindable var preferences: Preferences
    @Bindable var model: SettingsModel
    /// Old copies of the meetings from the earlier-version migration exist: only then does the erase description mention them.
    @ViewLocalState private var hasOldCopies = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $preferences.relockPolicy) {
                    ForEach(Preferences.RelockPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                } label: {
                    Text("Lock Meetings again", comment: "Settings → Privacy relock picker")
                    Text(description: String(localized: "Meetings and Context ask for Touch ID or your password. They always lock when the screen locks or the Mac sleeps.",
                         comment: "Settings → Privacy"))
                }
                Toggle(isOn: $preferences.copyProtection) {
                    Text("Protect meeting text from copying")
                    Text(description: String(localized: "Blocks copying, dragging and sharing transcripts and minutes from Vauta’s windows, so meeting text doesn’t end up in other apps or clipboard managers by accident. Turn it off to paste minutes into email or documents.",
                         comment: "Settings → Privacy copy protection explanation"))
                }
            } header: {
                Text("Access")
            }

            Section {
                Picker(selection: Binding(get: { KnowledgeRetention(days: recorder.knowledgeRetentionDays) },
                                          set: { value in Task { await model.requestRetention(value, recorder) } })) {
                    ForEach(KnowledgeRetention.allCases) { option in
                        Text(option.pickerName).tag(option)
                    }
                } label: {
                    Text("Minutes, decisions, notes and tasks", comment: "Settings → Privacy retention picker: what the choice applies to")
                    Text(description: String(localized: "Transcripts are always deleted after \(MeetingStore.retentionDays) days. If you keep minutes, Vauta first writes the minutes of meetings that don’t have them.",
                         comment: "Settings → Privacy retention explanation; argument is a number of days"))
                }
            } header: {
                Text("Keeping meetings")
            }

            Section {
                PrivacyPromise.audioNeverSaved
                PrivacyPromise.transcriptsEncryptedDetailed
                PrivacyPromise.nothingLeaves
                PrivacyPromise.noAnalytics
            } header: {
                Text("How Vauta protects your meetings")
            }
            .labelStyle(PromiseLabelStyle())

            // One card for the actions on the user's data (a section per row repeated its header in the row title
            // and the button): a title with its description, and the control at the trailing edge.
            Section {
                LabeledContent {
                    Button("Open Network Activity") { recorder.showWindow("network-activity") }
                } label: {
                    Text("Network activity", comment: "Settings → Privacy; title of the row that opens the network audit")
                    Text(description: String(localized: "A live list of every connection Vauta makes: where it goes, when and how much. Never the content. Use it to see for yourself that nothing leaves your Mac except what you set up.",
                         comment: "Settings → Privacy network audit explanation"))
                }

                // One place for the recording, whatever the rows below would say about it.
                if recorder.blocksDataReplacement {
                    DataReplacementBlocker(recorder: recorder, message: String(localized: "Restoring and erasing aren’t possible while recording.",
                                                                                comment: "Settings → Privacy; above the rows it is about (backup and erase) while a recording runs"), inline: true)
                }

                LabeledContent {
                    HStack {
                        if !recorder.storeAvailable {
                            Button(SettingsModel.Pane.status.openTitle) { model.pane = .status }
                        }
                        Button("Back Up…") { Task { if await recorder.authorizeHistory(for: .backUp) { model.backup.beginBackUp() } } }
                            .disabled(!recorder.storeAvailable)
                            .help(recorder.storeAvailable ? "" : unavailableText)
                        Button("Restore…") { Task { if await recorder.authorizeHistory(for: .restore) { await model.backup.beginRestore() } } }
                            .disabled(!recorder.storeAvailable || recorder.blocksDataReplacement)
                            .help(recorder.storeAvailable ? "" : unavailableText)
                    }
                } label: {
                    Text("Back up or restore", comment: "Settings → Privacy; title of the backup row")
                    Text(description: !recorder.storeAvailable
                         ? unavailableText
                         : String(localized: "One encrypted file with all your meetings, context and settings, protected by a password. Use it to move to a new Mac or keep an offline copy: Time Machine doesn’t include Vauta’s data.", comment: "Settings → Privacy backup"))
                }

                LabeledContent {
                    Button("Verify Backup…") { Task { await model.backup.beginRestore(verifying: true) } }
                } label: {
                    Text("Verify a backup", comment: "Settings → Privacy; title of the row that checks a backup file without restoring it")
                    Text(description: String(localized: "Opens a backup with its password, as Restore would, and shows what it holds. Nothing on this Mac changes. Each backup is also checked right after it’s saved.",
                         comment: "Settings → Privacy; explanation of Verify Backup"))
                }

                LabeledContent {
                    Button("Erase Meetings and Context…", role: .destructive) { Task { if await recorder.authorizeHistory(for: .erase) { await model.presentErase(recorder) } } }
                        .disabled(!recorder.storeAvailable || recorder.blocksDataReplacement)
                } label: {
                    Text("Erase meetings and context", comment: "Settings → Privacy; title of the erase row")
                    Text(description: !recorder.storeAvailable ? unavailableText : eraseDescription)
                }
                if let error = model.eraseError {
                    FeedbackLabel(feedback: .init(kind: .error, text: error))
                } else if model.eraseDone {
                    FeedbackLabel(feedback: .init(kind: .success,
                                                  text: String(localized: "All meetings and context were erased.", comment: "Settings → Privacy; shown after erasing everything")))
                }
            } header: {
                Text("Your data", comment: "Settings → Privacy; section with network activity, backup and erase")
            }
        }
        .formStyle(.grouped)
        .task(id: model.eraseDone) { hasOldCopies = await recorder.storeLeftovers().map { !$0.isEmpty } ?? false }
        .sheet(isPresented: Binding(get: { model.pendingRetention != nil }, set: { if !$0 { model.pendingRetention = nil } })) {
            if let change = model.pendingRetention {
                RetentionConfirmSheet(change: change, count: model.pendingRetentionCount) {
                    model.confirmRetention(recorder)
                } cancel: {
                    model.pendingRetention = nil
                }
            }
        }
        .sheet(item: Binding(get: { model.backup.sheet }, set: { if $0 == nil { model.backup.reset() } })) { sheet in
            switch sheet {
            case .backUp: BackUpSheet(recorder: recorder, model: model.backup)
            case .restore: RestoreSheet(recorder: recorder, model: model.backup, showContext: { model.pane = .context }, showModels: { model.pane = .models })
            case .verify: VerifyBackupSheet(model: model.backup)
            }
        }
        // The sheets are only reachable after Touch ID: when Meetings relock they close, and a running restore finishes.
        // Verifying reads nothing of this Mac's data, so it needs no Touch ID and stays open.
        .onChange(of: recorder.historyUnlocked) { _, unlocked in
            guard !unlocked, model.backup.sheet != .verify else { return }
            switch model.backup.stage {
            case .form, .confirm: model.backup.reset()
            case .working, .done: break
            }
        }
        .sheet(isPresented: $model.showErase) {
            EraseEverythingSheet(recorder: recorder, model: model, isPresented: $model.showErase)
        }
    }
}

extension PrivacyPane {
    /// Why the backup and erase controls are off while the encrypted store is not open.
    fileprivate var unavailableText: String {
        String(localized: "Available once Vauta can open your data. Status shows what went wrong.",
               comment: "Settings → Privacy; the backup and erase controls are disabled because the encrypted store did not open")
    }

    /// What "Erase everything" removes. The old copies from an earlier version are named only while there are some (as in Status).
    fileprivate var eraseDescription: String {
        hasOldCopies
            ? String(localized: "Removes every meeting, the context and the encryption key from this Mac, including old copies from an earlier version. You can’t undo this.", comment: "Settings → Privacy erase, when old copies from an earlier version still exist")
            : String(localized: "Removes every meeting, the context and the encryption key from this Mac. You can’t undo this.", comment: "Settings → Privacy erase")
    }
}

extension KnowledgeRetention {
    /// The option as the picker shows it: the row's label already says what it applies to.
    var pickerName: String {
        switch self {
        case .withTranscript: String(localized: "Delete with the transcript", comment: "Knowledge retention option in the picker")
        case .oneYear: String(localized: "Keep for 1 year", comment: "Knowledge retention option in the picker")
        case .twoYears: String(localized: "Keep for 2 years", comment: "Knowledge retention option in the picker")
        case .untilDeleted: String(localized: "Keep until I delete them", comment: "Knowledge retention option in the picker")
        }
    }
}

extension Preferences.RelockPolicy {
    var displayName: String {
        switch self {
        case .oneMinute: String(localized: "After 1 minute", comment: "Relock option")
        case .fiveMinutes: String(localized: "After 5 minutes", comment: "Relock option")
        case .fifteenMinutes: String(localized: "After 15 minutes", comment: "Relock option")
        case .thirtyMinutes: String(localized: "After 30 minutes", comment: "Relock option")
        case .untilScreenLocks: String(localized: "When the screen locks", comment: "Relock option")
        }
    }
}

/// Shows what a shorter retention deletes before it is applied.
struct RetentionConfirmSheet: View {
    let change: RetentionChange
    let count: Int?
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(Text("Delete older meetings now?"), symbol: "trash", tint: .red)
            if let count {
                Text("\(count) meetings are older than the new limit. Their minutes, decisions, notes and tasks will be deleted now.")
            } else {
                Text("Meetings older than the new limit will be deleted now, with their minutes, decisions, notes and tasks.")
            }
            SheetFootnote(joining: String(localized: "New setting: \(change.to.displayName).", comment: "Retention sheet footnote; the argument is the new retention option"),
                          String(localized: "You can’t undo this.", comment: "Footnote of a sheet that deletes something for good"))
            HStack {
                Spacer()
                // Cancel is the default (Return) for anything deleted for good; Escape also cancels.
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.defaultAction)
                Button("Delete Meetings", role: .destructive, action: confirm)
                    .destructiveSheetButton()
            }
        }
        .onExitCommand(perform: cancel)
        .padding(20)
        .frame(width: 440)
    }
}

/// "Erase everything", confirmed by typing a word.
struct EraseEverythingSheet: View {
    let recorder: RecorderModel
    let model: SettingsModel
    @Binding var isPresented: Bool
    @ViewLocalState private var typed: String
    @ViewLocalState private var meetings: Int?
    @ViewLocalState private var leftoverBytes: Int64?
    @ViewLocalState private var documentSources: Int?
    @FocusState private var confirmFocused: Bool

    init(recorder: RecorderModel, model: SettingsModel, isPresented: Binding<Bool>, typedWord: String = "") {
        _meetings = ViewLocalState(initialValue: model.eraseMeetings)
        _leftoverBytes = ViewLocalState(initialValue: model.eraseLeftoverBytes)
        _documentSources = ViewLocalState(initialValue: model.eraseDocumentSources)
        self.recorder = recorder
        self.model = model
        _isPresented = isPresented
        _typed = ViewLocalState(initialValue: typedWord)
    }

    private var word: String { String(localized: "erase", comment: "Word the user types to confirm erasing everything; lowercase") }
    /// The plain ASCII word every language accepts, so no input method is needed (nor an accented key, as in “löschen”).
    private static let plainWord = "erase"
    private func matches(_ candidate: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(candidate, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current) == .orderedSame
    }
    private var confirmed: Bool { matches(word) || matches(Self.plainWord) }
    private var needsPlainWord: Bool { !word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).elementsEqual(Self.plainWord) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.erasing {
                // While it runs the title says what is happening, not the question already answered.
                SheetHeader(Text("Erasing Meetings and Context", comment: "Erase sheet title while everything is being erased"), symbol: "trash", tint: .red)
            } else {
                SheetHeader(Text("Erase all meetings and context?"), symbol: "trash", tint: .red)
            }
            // The question stays on screen while it works (dimmed, the spinner line below), so the sheet does not shrink
            // under the pointer and the buttons stay where they were.
            confirmation(live: !model.erasing, working: model.erasing)
            .allowsHitTesting(!model.erasing)
            HStack {
                Spacer()
                // Erasing can't be stopped once it runs: Cancel (and Escape) wait until it ends.
                // Until the word is typed Return does nothing in the sheet (the field says so); then the typed word is
                // the confirmation and Erase takes Return. Escape always cancels (onExitCommand), so a mistyped word followed
                // by Return never closes the sheet.
                let canErase = !model.erasing && confirmed && !recorder.blocksDataReplacement
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(canErase ? .cancelAction : nil)
                    .disabled(model.erasing)
                // One button, so it keeps its identity (and keyboard focus) while the word is typed.
                // Red only while it can be used: blocked or working, it is the system's plain disabled button (as the restore's).
                Button("Erase Meetings and Context", role: .destructive, action: erase)
                    .destructiveSheetButton()
                    .keyboardShortcut(canErase ? .defaultAction : nil)
                    .disabled(!canErase)
            }
        }
        .onExitCommand { if !model.erasing { isPresented = false } }
        .padding(20)
        .frame(width: 440)
        .onAppear { confirmFocused = true }
        .interactiveDismissDisabled(model.erasing)
        .task {
            if meetings == nil { meetings = await recorder.storeStats()?.meetings }
            if leftoverBytes == nil { leftoverBytes = await recorder.storeLeftovers()?.totalBytes }
        }
    }

    /// Where the translated word needs another keyboard, the plain English one is offered too.
    private var promptText: String {
        needsPlainWord
            ? String(localized: "Type “\(word)” or “\(Self.plainWord)” to confirm", comment: "Erase confirmation field when the word is not typed with a plain keyboard; the arguments are the confirmation word in this language and in English")
            : String(localized: "Type “\(word)” to confirm", comment: "Erase confirmation field; argument is the confirmation word")
    }

    /// Return in the field: erase once the word matches; otherwise say what to type.
    private func submit() {
        if confirmed, !model.erasing, !recorder.blocksDataReplacement {
            erase()
        } else if !model.erasing {
            NSSound.beep()
            AccessibilityNotification.Announcement(promptText).post()
        }
    }

    private func field(_ prompt: String, enabled: Bool = true) -> some View {
        TextField(text: $typed, prompt: Text(verbatim: "")) { Text(prompt) }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .onSubmit(submit)
            // Disabled while it works: no focus, so no text selection stays drawn.
            .disabled(!enabled)
    }

    /// The question: what is erased, the word to type, and what is kept. While it works: the same, dimmed, with the spinner line.
    private func confirmation(live: Bool, working: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Nothing is hidden while it works: the description is dimmed like the field and the footnotes, and the
            // spinner line takes the footnotes' place below.
            VStack(alignment: .leading, spacing: 8) {
                if meetings == 0 {
                    Text("This erases every person, project and glossary term. There are no meetings.", comment: "Erase sheet when the history is empty but there is context")
                } else if let meetings {
                    Text("This erases \(meetings) meetings with their transcripts, minutes, notes and tasks, every person, project and glossary term, and the encryption key.")
                } else {
                    Text("This erases every meeting with its transcript, minutes, notes and tasks, every person, project and glossary term, and the encryption key.")
                }
                // What the pane's row says it removes: the old copies from an earlier version, while there are some.
                if let leftoverBytes, leftoverBytes > 0 {
                    let size = ByteSize.string(leftoverBytes)
                    Text("It also deletes the old copies from an earlier version (\(size)).", comment: "Erase sheet, when old copies from the earlier-version migration exist; the argument is a file size")
                }
                // The folders and files added as knowledge sources, and the index of their text: your files are not touched.
                if let documentSources, documentSources > 0 {
                    Text("It also removes your document sources and their index. Your files aren’t touched.",
                         comment: "Erase sheet, when the person added document sources: they and the index of their text are removed; the files themselves are not")
                }
            }
            .opacity(working ? 0.5 : 1)
            // A visible label beside the field: a placeholder disappears as soon as the user types.
            let prompt = promptText
            // The backup sheet's card, with the label above the field (it is too long to sit beside it).
            VStack(alignment: .leading, spacing: 8) {
                Text(prompt)
                // Return erases only once the word is typed (the button takes Return then); Touch ID is asked in erase().
                if live {
                    field(prompt).focused($confirmFocused)
                } else {
                    field(prompt, enabled: !working)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
            .opacity(working ? 0.5 : 1)
            if recorder.blocksDataReplacement && !working {
                DataReplacementBlocker(recorder: recorder, message: String(localized: "Stop the recording to erase.", comment: "Erase sheet: a recording is running"), inline: false)
            }
            // Next to the button it is about (as in the backup sheets). While it works the spinner line takes their place
            // (the footnotes stay underneath, invisible, so the sheet and its buttons keep their place).
            ZStack(alignment: .topLeading) {
                SheetFootnote(joining: String(localized: "Your preferences and model server settings are kept.", comment: "Erase everything sheet footnote"),
                              String(localized: "You can’t undo this.", comment: "Footnote of a sheet that deletes something for good"))
                .opacity(working ? 0 : 1)
                .accessibilityHidden(working)
                if working {
                    // The title says what is happening; this line says what to do meanwhile. Erasing is as long and as
                    // impossible to stop as a restore.
                    BusyRow(title: BusyRow.quitNote)
                }
            }
        }
    }

    private func erase() {
        guard !recorder.blocksDataReplacement else { return }
        Task {
            // Same protection as the Meetings window: only the Mac's owner can erase.
            guard await recorder.authorizeHistory(for: .erase) else { return }
            // The sheet's content swaps to the progress: say that it started, as the end is said.
            AccessibilityNotification.Announcement(String(localized: "Erasing all meetings and context…", comment: "Erase sheet while everything is erased")).post()
            _ = await model.eraseEverything(recorder)
            isPresented = false
            // The sheet closes and the result appears in the pane: say it, since nothing else would.
            if let error = model.eraseError {
                AccessibilityNotification.Announcement(error).post()
            } else if model.eraseDone {
                AccessibilityNotification.Announcement(String(localized: "All meetings and context were erased.", comment: "Settings → Privacy; shown after erasing everything")).post()
            }
        }
    }
}
