// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import SwiftUI

/// "Back Up…": password, confirmation and a strength hint, then the save panel.
struct BackUpSheet: View {
    let recorder: RecorderModel
    @Bindable var model: BackupModel
    @FocusState private var focus: Field?
    @AccessibilityFocusState private var doneFocused: Bool
    @ViewLocalState private var hintAnnouncement: Task<Void, Never>?

    private enum Field { case password, confirmation, location }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if case .done = model.stage {
                // The finished sheet names its result.
                SheetHeader(Text("Backup Saved", comment: "Backup sheet title once the backup file is saved"), symbol: "arrow.up.doc")
            } else {
                SheetHeader(Text("Back Up Meetings, Context and Settings"), symbol: "arrow.up.doc")
            }
            switch model.stage {
            case .form, .working:
                // The form stays on screen while working, so the sheet keeps its height.
                Text("Your meetings, context and settings go into one file, encrypted with a password you choose. Restore it on this Mac or another.")
                    .fixedSize(horizontal: false, vertical: true)
                // The labels are beside the fields; the fields have an empty prompt so nothing repeats them.
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Password").gridColumnAlignment(.leading)
                        SecureField(text: $model.password, prompt: Text(verbatim: "")) { Text("Password") }
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .password)
                    }
                    GridRow {
                        Text("Repeat password")
                        SecureField(text: $model.confirmation, prompt: Text(verbatim: "")) { Text("Repeat password") }
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .focused($focus, equals: .confirmation)
                            .onSubmit { start() }
                    }
                }
                .disabled(model.stage == .working)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground()
                // The strength line, the error when there is one, and the warning: one block of lines that follow each other.
                // The room for the tallest of them is kept as a whole (an invisible sizer), so the sheet and its buttons
                // keep their place while the person types and the unused room sits under the warning, as the sheet's margin.
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        PasswordHintSizer()
                        passwordWarning.padding(.top, 8)
                    }
                    .hidden()
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 4) {
                        if model.stage == .working {
                            WorkingLabel(meetings: model.meetingsToBackUp, encrypting: true)
                        } else {
                            // A failed save takes the place of the mismatch line, under the strength.
                            PasswordHint(model: model, error: model.error.map { .init(kind: .error, text: $0, note: model.errorHint) })
                        }
                        // Stacked right under a footnote hint; set apart from a status line.
                        passwordWarning.padding(.top, model.password.isEmpty && model.error == nil && model.stage != .working ? 0 : 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            case .confirm:
                EmptyView()
            case .done(let text):
                // The same order as the restore's last step: the file, then the result; Show in Finder sits by Done.
                if let file = model.savedFile {
                    BackupFileCard(file: file, date: model.backupDate ?? BackupFileCard.creationDate(of: file))
                }
                // A caution, not a result: a neutral icon (the green check is for "Restored …").
                NoticeLabel(Text(verbatim: text), symbol: "key", tint: .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                if case .done = model.stage {
                    if let file = model.savedFile {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    }
                    Button(BackupAnnouncement.doneTitle) { model.reset() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityFocused($doneFocused)
                } else {
                    // While encrypting, Cancel goes back to the form (a large store can take a while).
                    Button("Cancel", role: .cancel) { model.stage == .working ? model.cancelBackUp() : model.reset() }
                        .keyboardShortcut(.cancelAction)
                    Button("Choose Location…") { start() }
                        .keyboardShortcut(.defaultAction)
                        .focused($focus, equals: .location)
                        .disabled(!model.canBackUp || model.stage == .working)
                        // Says why it is off: a greyed button alone doesn't (and VoiceOver wouldn't hear it).
                        .help(model.backUpBlocker ?? "")
                        .accessibilityHint(model.backUpBlocker ?? "")
                }
            }
        }
        .padding(20)
        .frame(width: 440)
        .environment(\.iconColumnAlignment, .leading)
        .defaultFocus($focus, .password)
        .onAppear { focus = .password }
        // The finished sheet closes with Escape too.
        .onExitCommand {
            switch model.stage {
            case .done, .confirm: model.reset()
            default: break
            }
        }
        // After a failure the fields are enabled again with what was typed: the keyboard goes back to them.
        .onChange(of: model.stage) { _, stage in
            // A failed save is about the place, not the password: the keyboard moves to "Choose Location…" (which
            // also clears the selection left in the field), so Return tries again and a keystroke can't replace the password.
            if stage == .form { focus = model.error == nil ? .password : .location }
            BackupAnnouncement.post(for: stage) { doneFocused = true }
            BackupAnnouncement.postWorking(stage, model: model)
        }
        .onChange(of: model.error) { _, error in BackupAnnouncement.post(error: error, hint: model.errorHint) }
        // The strength and match lines change as the person types: VoiceOver hears the new one once typing pauses.
        .onChange(of: model.passwordHintMessages) { _, messages in
            hintAnnouncement?.cancel()
            guard !messages.isEmpty else { return }
            hintAnnouncement = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                AccessibilityNotification.Announcement(messages.joined(separator: " ")).post()
            }
        }
        .onDisappear { hintAnnouncement?.cancel() }
    }

    private var passwordWarning: some View {
        // One paragraph; the second sentence says what the file leaves out, before the backup, not after the restore.
        SheetFootnote(joining: String(localized: "Vauta can’t recover this password. Without it, the backup can’t be opened.",
                                      comment: "Backup sheet: warning under the password fields"),
                      String(localized: "The model server and its key stay on this Mac.", comment: "Backup sheet: footnote under the password fields; the file doesn’t carry them"))
    }

    private func start() {
        guard model.stage == .form else { return }
        guard model.canBackUp else {
            // Return in the last field with a password that isn't acceptable yet: say why instead of doing nothing.
            if let reason = model.backUpBlocker { AccessibilityNotification.Announcement(reason).post() }
            NSSound.beep()
            return
        }
        model.startBackUp(recorder)
    }
}

/// What VoiceOver hears when the form is replaced by its result: the sheet swaps its content, so the
/// focused control disappears and nothing else would say what happened.
enum BackupAnnouncement {
    /// The finished sheets' default button. Its own key: "Done" is also a task status, translated as an
    /// adjective in several languages.
    static var doneTitle: String {
        String(localized: "button.done", defaultValue: "Done",
               comment: "Button that closes a finished setup sheet (not the task status)")
    }

    /// A finished stage: focus moves to the Done button once it exists (a focus set in the same update that creates the
    /// button is dropped), then the result is announced with high priority so the focus change cannot cut it off.
    @MainActor
    static func post(for stage: BackupModel.Stage, note: String? = nil, moveFocus: @escaping @MainActor () -> Void) {
        guard case .done(let text) = stage else { return }
        announceResult([text, note].compactMap { $0 }.joined(separator: " "), moveFocus: moveFocus)
    }

    /// Moves focus to the button of a finished sheet after a short delay, then announces `text` with high priority.
    @MainActor
    static func announceResult(_ text: String, moveFocus: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            moveFocus()
            var spoken = AttributedString(text)
            spoken.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(spoken).post()
        }
    }

    /// A long step starting (encrypting, opening, replacing): the focused button is disabled by then, so without this
    /// a VoiceOver user would hear nothing for what can take a minute.
    @MainActor
    static func postWorking(_ stage: BackupModel.Stage, model: BackupModel) {
        guard stage == .working else { return }
        AccessibilityNotification.Announcement(model.workingMessage).post()
    }

    @MainActor
    static func post(error: String?, hint: String?) {
        guard let error else { return }
        AccessibilityNotification.Announcement([error, hint].compactMap { $0 }.joined(separator: " ")).post()
    }
}

/// A footnote under a sheet's form: callout, secondary (the same in every sheet).
struct SheetFootnote: View {
    let text: String

    init(_ text: String) { self.text = text }

    /// Two sentences as one paragraph (never one sentence per line).
    init(joining first: String, _ second: String) {
        self.text = String(localized: "\(first) \(second)", comment: "Two sentences in a row (for example an error and what to do about it). Japanese and Chinese: no space between %1$@ and %2$@")
    }

    var body: some View {
        // Several sentences flow as one paragraph (as every note in the panes), the last words kept together.
        WordWrappedText(text: Self.keepingLastWordsTogether(text))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Keeps a number with its unit ("1 year") and the last two words together with no-break spaces, so a line never
    /// breaks inside a quantity and the last line never holds a single word (a widow). Only the last two words are
    /// joined, and only while that run is short: a longer one would pull a long tail down and leave the line above
    /// ragged. Korean and the languages written without spaces are left as they are (a long no-break run there
    /// makes the line break inside a word).
    static func keepingLastWordsTogether(_ text: String) -> String {
        let scalars = text.unicodeScalars
        let spaceless = scalars.contains { (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value)
            || (0xAC00...0xD7AF).contains($0.value) || (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) }
        if spaceless { return text }
        var characters = Array(text)
        // A number and the word after it ("1 year", "90 días").
        for index in characters.indices.dropFirst() where characters[index] == " " && characters[index - 1].isNumber
            && index + 1 < characters.count && characters[index + 1] != " " {
            characters[index] = "\u{00A0}"
        }
        // A short preposition stays with the word it governs ("serveur de modèles", "server di modelli"): the line
        // never ends on "de" and the compound noun is never split.
        let prepositions: Set<String> = ["de", "di", "du", "des", "da", "del"]
        var wordStart = 0
        for index in characters.indices where characters[index] == " " {
            if prepositions.contains(String(characters[wordStart..<index]).lowercased()), index + 1 < characters.count {
                characters[index] = "\u{00A0}"
            }
            wordStart = index + 1
        }
        // A short closing sentence ("You can’t undo this.") is kept whole: it never starts a line with one word.
        if characters.count > 1 {
            let body = characters[..<(characters.count - 1)]
            var sentenceStart = 0
            if let stop = body.indices.last(where: { index in
                index + 1 < body.endIndex && " ".contains(characters[index + 1]) && ".!?".contains(characters[index])
            }) { sentenceStart = stop + 2 }
            if sentenceStart < characters.count, characters.count - sentenceStart <= 24 {
                for index in sentenceStart..<characters.count where characters[index] == " " { characters[index] = "\u{00A0}" }
                return String(characters)
            }
        }
        // The last three words when they are short ("can’t be opened."), else the last two: the last line is never a
        // pair of words after a long first line.
        if let last = characters.lastIndex(of: " ") {
            let before = characters[..<last]
            let second = before.lastIndex(of: " ")
            let start = second.map { $0 + 1 } ?? 0
            if let second, characters.count - start <= 24 {
                characters[last] = "\u{00A0}"
                let third = characters[..<second].lastIndex(of: " ")
                if let third, characters.count - (third + 1) <= 18 { characters[second] = "\u{00A0}" }
            } else if characters.count - start <= 24 {
                characters[last] = "\u{00A0}"
            }
        }
        return String(characters)
    }
}

/// Why the store can't be replaced or erased right now, and the way out: a running recording is stopped from here;
/// one that is starting or being saved is waited for, and the action unlocks by itself when it ends.
struct DataReplacementBlocker: View {
    let recorder: RecorderModel
    /// What to say while a recording runs.
    let message: String
    /// A row of a Settings card (the button at the trailing edge) or a line of a sheet (the button under the text).
    let inline: Bool

    var body: some View {
        switch recorder.phase {
        case .recording:
            if inline {
                HStack {
                    NoticeLabel(Text(message), status: .info)
                    Spacer()
                    Button("Stop Recording") { recorder.stop() }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // The way out is a button; the sheet then enables the action on its own.
                    NoticeLabel(Text(message), status: .info)
                    Button("Stop Recording") { recorder.stop() }
                        .padding(.leading, 28)
                }
            }
        case .stopping:
            waiting(String(localized: "Saving the recording…", comment: "Shown while a stopped recording is still being written, instead of the Stop Recording button"))
        case .starting:
            waiting(String(localized: "Starting the recording…", comment: "Shown while a recording is starting, instead of the Stop Recording button"))
        default:
            EmptyView()
        }
    }

    private func waiting(_ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            ProgressView().controlSize(.small)
        }
        .labelStyle(AlignedIconLabelStyle())
        .font(.callout)
    }
}

/// A spinner and what is being done, with its notes indented under the words in secondary text (one style in every
/// sheet that works: backup, restore and erase).
struct BusyRow: View {
    let title: String
    var notes: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(verbatim: title)
            } icon: {
                ProgressView().controlSize(.small)
            }
            .labelStyle(AlignedIconLabelStyle())
            .font(.callout)
            ForEach(notes, id: \.self) { note in
                SheetFootnote(note).padding(.leading, 28)
            }
        }
    }
}

/// "Encrypting 312 meetings…" with a spinner, and a hint that many meetings take a while.
struct WorkingLabel: View {
    /// Meetings being processed; nil when unknown.
    let meetings: Int?
    /// Encrypting a backup, or restoring one.
    let encrypting: Bool
    /// The restore (not the backup) also says the person may quit once it ends.
    var quitNote = false

    var body: some View {
        BusyRow(title: title, notes: notes)
    }

    private var title: String {
        if let meetings, meetings > 0 {
            if encrypting {
                return String(localized: "Encrypting \(meetings) meetings…", comment: "Backup sheet while working; the argument is a number of meetings")
            }
            return String(localized: "Restoring \(meetings) meetings…", comment: "Restore sheet while replacing the meetings; the argument is a number of meetings")
        }
        return encrypting ? String(localized: "Encrypting the backup…")
                          : String(localized: "Restoring meetings…", comment: "Restore sheet while replacing the meetings")
    }

    private var notes: [String] {
        var notes: [String] = []
        if let meetings, meetings >= 100 {
            notes.append(String(localized: "This can take a minute with many meetings.", comment: "Backup and restore sheets: shown while working on a large store"))
        }
        if quitNote { notes.append(BusyRow.quitNote) }
        return notes
    }
}

extension BusyRow {
    static var quitNote: String {
        String(localized: "Keep Vauta open until this finishes.", comment: "Sheet while everything is erased or restored; the user must not quit before the work ends")
    }
}

/// Takes the room of the tallest thing the hint slot can show (the two-line hint, or the strength row with the
/// mismatch row), without drawing anything. A failed save takes the place of the strength and mismatch rows.
private struct PasswordHintSizer: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            SheetFootnote(String(localized: "Use at least \(BackupPassword.minimumLength) characters. A phrase of several words works well.",
                                 comment: "Backup password hint; the argument is the minimum number of characters"))
            VStack(alignment: .leading, spacing: 4) {
                NoticeLabel(Text(verbatim: BackupModel.tooShortMessage), status: .error)
                NoticeLabel(Text(verbatim: BackupModel.mismatchMessage), status: .error)
            }
        }
    }
}

/// Length and match feedback under the password fields (never by color alone: the icon changes too).
private struct PasswordHint: View {
    let model: BackupModel
    /// A failed save, shown where the mismatch line would be.
    var error: ModelsSettingsModel.Feedback?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.password.isEmpty, let error {
                FeedbackLabel(feedback: error).frame(maxWidth: .infinity, alignment: .leading)
            } else if model.password.isEmpty {
                SheetFootnote(String(localized: "Use at least \(BackupPassword.minimumLength) characters. A phrase of several words works well.",
                                     comment: "Backup password hint; the argument is the minimum number of characters"))
            } else {
                if let error {
                    // A failed save takes the place of the strength and match lines, so the slot never grows.
                    FeedbackLabel(feedback: error).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    let messages = model.passwordHintMessages
                    switch model.strength {
                    case .tooShort:
                        NoticeLabel(Text(verbatim: messages[0]), status: .error)
                    case .weak:
                        // Repetitive passwords are weak and also refused.
                        NoticeLabel(Text(verbatim: messages[0]), status: BackupPassword.isAcceptable(model.password) ? .warning : .error)
                    case .good, .strong:
                        NoticeLabel(Text(verbatim: messages[0]), status: .ok)
                    }
                    // Not while the confirmation is still being typed.
                    if model.passwordsMismatch {
                        NoticeLabel(Text(verbatim: BackupModel.mismatchMessage), status: .error)
                    }
                }
            }
        }
    }
}
