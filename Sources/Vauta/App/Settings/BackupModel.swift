// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AppKit
import Observation
import UniformTypeIdentifiers

/// State of the "Back Up…", "Restore…" and "Verify Backup…" sheets in Settings → Privacy & Security.
@MainActor
@Observable
final class BackupModel {
    enum Sheet: Int, Identifiable {
        case backUp, restore, verify
        var id: Int { rawValue }
    }

    enum Stage: Equatable {
        /// Collecting the password.
        case form
        /// Deriving the key, encrypting, decrypting or replacing: nothing else can be done.
        case working
        /// Restore only: the backup was read; waiting for the user to confirm the replacement.
        case confirm(current: Int, backup: Int)
        /// Finished; the text is shown to the user.
        case done(String)
    }

    /// What the working stage is doing, so the sheet can say it. `checking` reads a backup back as a restore would: the one
    /// just saved, or the one the verify sheet is about.
    enum Work { case encrypting, checking, opening, restoring }

    var sheet: Sheet?
    var stage: Stage = .form
    private(set) var work: Work = .encrypting
    /// Where the last backup was saved (for "Show in Finder").
    private(set) var savedFile: URL?
    var password = ""
    var confirmation = ""
    var error: String?
    /// What to do about `error`, when there is something specific.
    var errorHint: String?
    private(set) var file: URL?
    private var opened: OpenedBackup?
    /// How many meetings the restore replaces and brings in, for the sheet while it works.
    private(set) var counts: (current: Int, backup: Int)?
    /// The context entries (people, projects, glossary terms, recurring meetings) the restore replaces.
    private(set) var currentContext = 0
    /// When the backup being restored was made (from the backup itself; the file's date until it is opened).
    private(set) var backupDate: Date?
    /// The meetings being encrypted, for the sheet while it works.
    private(set) var meetingsToBackUp: Int?
    /// What the backup the verify sheet checked holds; nil until it passed.
    private(set) var verified: BackupContents?
    /// How many meetings the finished restore brought in; nil until one finished.
    private(set) var restoredMeetings: Int?
    /// The opened backup carries settings, so the confirmation says they are replaced too.
    private(set) var backupHasSettings = false
    /// The opened backup holds saved voices (voice fingerprints): the confirmation says restoring brings them back.
    private(set) var backupHasVoices = false
    /// The opened backup carries document sources (folders and files added as knowledge sources): they come back and are indexed again.
    private(set) var backupDocumentSources = 0
    /// The document sources this Mac has now: a backup that has none removes them, and the confirmation says so.
    private(set) var currentDocumentSources = 0
    /// The second line of a finished restore: whether the backup's settings came back (nil: it had none).
    private(set) var restoredNote: String?
    /// The restored settings chose a model server, which isn't in the backup, and this Mac has none: Models is where to set it up.
    private(set) var restoredNeedsServer = false
    /// On a Mac that needs a server (`restoredNeedsServer`): Apple's on-device model can write the minutes meanwhile.
    /// Without it (no Apple Intelligence, or turned off) no minutes are written until a server is set up.
    private(set) var restoredAppleAvailable = true
    /// Called after a restore applied the backup's settings, so panes that keep a copy read them again.
    @ObservationIgnored var onSettingsRestored: (() -> Void)?
    @ObservationIgnored private var backUpTask: Task<Void, Never>?
    @ObservationIgnored private var openTask: Task<Void, Never>?

    static let fileExtension = BackupFileTypes.current

    var strength: BackupPassword.Strength { BackupPassword.strength(of: password) }
    var canBackUp: Bool { BackupPassword.isAcceptable(password) && password == confirmation }

    /// The confirmation has been typed to the password's length and differs (not while it is still being typed).
    var passwordsMismatch: Bool {
        !password.isEmpty && confirmation.count >= password.count && confirmation != password
    }

    /// What the strength line and the mismatch line say about the password now; empty until one is typed.
    /// Announced to VoiceOver when it changes, since the lines appear as the person types.
    var passwordHintMessages: [String] {
        guard !password.isEmpty else { return [] }
        var messages: [String] = []
        switch strength {
        case .tooShort: messages.append(Self.tooShortMessage)
        case .weak: messages.append(Self.weakMessage)
        case .good: messages.append(String(localized: "Good"))
        case .strong: messages.append(String(localized: "Strong"))
        }
        if passwordsMismatch { messages.append(Self.mismatchMessage) }
        return messages
    }

    static var tooShortMessage: String { String(localized: "Too short. Use at least \(BackupPassword.minimumLength) characters.") }
    static var mismatchMessage: String { String(localized: "The passwords don’t match.") }
    static var weakMessage: String { String(localized: "Weak: add more words or characters.") }

    /// Why "Choose Location…" can't be used yet; nil when it can.
    var backUpBlocker: String? {
        if strength == .tooShort { return Self.tooShortMessage }
        // Long enough but trivially repetitive (`111111111111`).
        if !BackupPassword.isAcceptable(password) { return Self.weakMessage }
        if password != confirmation { return Self.mismatchMessage }
        return nil
    }

    func reset() {
        sheet = nil
        stage = .form
        password = ""
        confirmation = ""
        error = nil
        errorHint = nil
        file = nil
        opened = nil
        counts = nil
        currentContext = 0
        backupDate = nil
        meetingsToBackUp = nil
        restoredMeetings = nil
        verified = nil
        backupHasSettings = false
        backupHasVoices = false
        backupDocumentSources = 0
        currentDocumentSources = 0
        restoredNote = nil
        restoredNeedsServer = false
        restoredAppleAvailable = true
        savedFile = nil
        backUpTask?.cancel()
        backUpTask = nil
        openTask?.cancel()
        openTask = nil
        resets += 1
    }

    /// How many times the sheet was reset: a file panel that returns after a reset (the relock closed the sheet while the
    /// panel was open) must not carry on with a backup or restore nobody is looking at.
    private var resets = 0

    #if VAUTA_DIAGNOSTICS
    /// For `Vauta render-ui`: the file the restore sheet would be about, or the one a backup was saved to.
    func installSnapshotFile(restoring: URL? = nil, saved: URL? = nil, date: Date? = nil) {
        file = restoring
        savedFile = saved
        backupDate = date
    }

    func installSnapshotContext(_ entries: Int) { currentContext = entries }

    func installSnapshotRestored(meetings: Int) { restoredMeetings = meetings }

    func installSnapshotBackupHasSettings() { backupHasSettings = true }

    func installSnapshotBackupHasVoices() { backupHasVoices = true }

    func installSnapshotBackupDocumentSources(_ count: Int) { backupDocumentSources = count }

    func installSnapshotCurrentDocumentSources(_ count: Int) { currentDocumentSources = count }

    func installSnapshotRestoredNote(_ note: String?, needsServer: Bool, appleAvailable: Bool = true) {
        restoredNote = note
        restoredNeedsServer = needsServer
        restoredAppleAvailable = appleAvailable
    }

    func installSnapshotMeetingsToBackUp(_ count: Int) { meetingsToBackUp = count }

    func installSnapshotError(_ failure: Error) {
        error = Self.message(failure)
        errorHint = Self.hint(for: failure)
    }

    func installSnapshotWork(_ work: Work) { self.work = work }

    func installSnapshotCounts(current: Int, backup: Int) { counts = (current, backup) }
    #endif

    // MARK: Back up

    func beginBackUp() {
        reset()
        sheet = .backUp
    }

    /// Starts the backup as a task the sheet can cancel while it encrypts.
    func startBackUp(_ recorder: RecorderModel) {
        guard backUpTask == nil, stage == .form else { return }
        backUpTask = Task { [weak self] in
            await self?.backUp(recorder)
            self?.backUpTask = nil
        }
    }

    /// Cancel while encrypting: back to the form with what was typed; nothing is written (the file is only
    /// written after the encryption finished, and a new file is removed again if the cancel came during the write).
    func cancelBackUp() {
        backUpTask?.cancel()
        backUpTask = nil
        meetingsToBackUp = nil
        if stage == .working { stage = .form }
    }

    /// Asks where to save, then encrypts and writes the backup.
    private func backUp(_ recorder: RecorderModel) async {
        guard let store = recorder.store, canBackUp else { return }
        let resetsBefore = resets
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Backup", comment: "Save panel title for a backup")
        panel.nameFieldStringValue = Self.defaultFileName()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let type = UTType(filenameExtension: Self.fileExtension) { panel.allowedContentTypes = [type] }
        panel.allowsOtherFileTypes = true
        guard await Self.present(panel), let url = panel.url else { return }
        guard !Task.isCancelled, resets == resetsBefore, sheet == .backUp else { return }
        error = nil
        errorHint = nil
        work = .encrypting
        stage = .working
        meetingsToBackUp = try? await store.stats().meetings
        do {
            let written = try await save(store, to: url)
            guard !Task.isCancelled else { return discard(written, at: url) }
            // Read back from the disk and opened as a restore would: a backup that couldn't be restored is worse than none.
            work = .checking
            do {
                _ = try await Self.check(url, password: password)
            } catch {
                guard !Task.isCancelled else { return discard(written, at: url) }
                // The file is useless and would look like a backup: it goes, and the sheet says so.
                let removed = (try? FileManager.default.removeItem(at: url)) != nil
                self.error = Self.uncheckedMessage
                errorHint = removed ? Self.uncheckedRemovedHint : Self.uncheckedKeptHint
                stage = .form
                return
            }
            guard !Task.isCancelled else { return discard(written, at: url) }
            savedFile = url
            // The passwords are kept after a failure (the user only has to choose another place); gone once it worked.
            password = ""
            confirmation = ""
            stage = .done(Self.savedMessage)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = Self.message(error)
            errorHint = Self.hint(for: error)
            stage = .form
        }
    }

    /// The file a backup wrote: whether it replaced one, and its file number, which another backup written there since would
    /// not have (an atomic write makes a new file).
    private struct Written {
        let replaced: Bool
        let fileNumber: Int?
    }

    /// Encrypts the store and writes the backup to `url`. The encrypted bytes are let go when this returns, before the check
    /// reads the file back.
    private func save(_ store: MeetingStore, to url: URL) async throws -> Written {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        // The settings go inside the encrypted file with the meetings; the server key stays in the Keychain.
        let data = try await store.createBackup(password: password, appVersion: version, preferences: BackupPreferences(from: .standard))
        try Task.checkCancellation()
        let replaces = FileManager.default.fileExists(atPath: url.path)
        // Off the main actor: a large backup would freeze the spinner and the Cancel button while it is written.
        try await Task.detached(priority: .userInitiated) { try Self.write(data, to: url) }.value
        return Written(replaced: replaces, fileNumber: Self.fileNumber(url))
    }

    /// A cancel once the file is written removes it only when it replaced nothing: a backup it replaced is already gone, and
    /// the new one is complete (though not checked). A file another backup wrote there since the cancel is left alone.
    private func discard(_ written: Written, at url: URL) {
        guard !written.replaced, let number = written.fileNumber, Self.fileNumber(url) == number else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private nonisolated static func fileNumber(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? Int
    }

    /// Reads a backup from the disk and opens it as a restore would, keeping nothing (`MeetingStore.checkBackup`).
    nonisolated static func check(_ url: URL, password: String) async throws -> BackupContents {
        try await MeetingStore.checkBackup(read(url), password: password)
    }

    /// Reads a backup file (one chosen in a file panel, or just saved), off the main actor: a large backup would freeze the
    /// spinner and the Cancel button. Only a file on this Mac is read.
    nonisolated static func read(_ url: URL) async throws -> Data {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        return try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url, options: .uncached) }.value
    }

    /// Writes the backup atomically (a temporary file, then a rename), so a file it replaces is either kept whole or
    /// replaced whole. Where an atomic write is refused (some volumes), a plain write is tried only for a new file, which
    /// is removed again if that write fails: an existing backup is never rewritten in place.
    nonisolated static func write(_ data: Data, to url: URL) throws {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            guard !FileManager.default.fileExists(atPath: url.path) else { throw error }
            do {
                try data.write(to: url, options: .withoutOverwriting)
            } catch let plain {
                if (plain as NSError).code != NSFileWriteFileExistsError { try? FileManager.default.removeItem(at: url) }
                throw error
            }
        }
    }

    /// What the finished backup sheet says under its title (which already says the backup was saved).
    static var savedMessage: String {
        String(localized: "Keep the password. Without it, the backup can’t be opened, and nobody can recover it.",
               comment: "Backup sheet: shown after a successful backup; the title already says it was saved")
    }

    /// The file name offered by the save panel, in the interface language.
    static func defaultFileName(day: String = dayStamp()) -> String {
        return String(localized: "Vauta Backup \(day)", comment: "Default file name of a backup; the argument is the date as yyyy-MM-dd") + "." + fileExtension
    }

    /// Shows a panel as a sheet of the window in front (the Settings window, or the backup sheet), like the
    /// export; a window that already has a sheet falls back to the app-modal panel.
    private static func present(_ panel: NSSavePanel) async -> Bool {
        if let window = NSApp.keyWindow, window.attachedSheet == nil {
            return await panel.beginSheetModal(for: window) == .OK
        }
        return panel.runModal() == .OK
    }

    // MARK: Restore

    /// Asks which backup to restore, or only to verify (`verifying`); the sheet then asks for its password.
    func beginRestore(verifying: Bool = false) async {
        reset()
        let resetsBefore = resets
        guard let url = await chooseBackupFile(), resets == resetsBefore else { return }
        file = url
        backupDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        sheet = verifying ? .verify : .restore
    }

    /// From the password step: picks another file without leaving the sheet (a wrong file, or a damaged one). The
    /// password and the last failure belong to the old file, so they go.
    func chooseAnotherFile() async {
        guard stage == .form else { return }
        let resetsBefore = resets
        guard let url = await chooseBackupFile(), resets == resetsBefore, stage == .form else { return }
        file = url
        backupDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        password = ""
        error = nil
        errorHint = nil
    }

    private func chooseBackupFile() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Backup", comment: "Open panel title for restoring a backup")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Both extensions are offered first; any other file can still be chosen (renamed or sent by mail).
        panel.allowedContentTypes = BackupFileTypes.accepted.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        guard await Self.present(panel) else { return nil }
        return panel.url
    }

    /// Starts opening the backup as a task the sheet can cancel (nothing is replaced while it runs).
    func startOpen(_ recorder: RecorderModel) {
        guard openTask == nil, stage == .form else { return }
        openTask = Task { [weak self] in
            await self?.openBackup(recorder)
            self?.openTask = nil
        }
    }

    /// Starts the verify sheet's check as a task the sheet can cancel. It needs no store: nothing of this Mac is read.
    func startVerify() {
        guard openTask == nil, stage == .form else { return }
        openTask = Task { [weak self] in
            await self?.verify()
            self?.openTask = nil
        }
    }

    /// Cancel while opening or checking: back to the form with the password typed; nothing was changed.
    func cancelOpen() {
        openTask?.cancel()
        openTask = nil
        if stage == .working && (work == .opening || work == .checking) { stage = .form }
    }

    /// The verify sheet: opens the chosen backup as a restore would and keeps nothing; the sheet shows what it holds.
    private func verify() async {
        guard let file, !password.isEmpty else { return }
        error = nil
        errorHint = nil
        work = .checking
        stage = .working
        do {
            let contents = try await Self.check(file, password: password)
            guard !Task.isCancelled else { return }
            verified = contents
            backupDate = contents.createdAt
            password = ""
            stage = .done(Self.checkedMessage)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = Self.message(error)
            errorHint = Self.hint(for: error)
            stage = .form
        }
    }

    /// Decrypts and checks the chosen backup (nothing is replaced yet).
    func openBackup(_ recorder: RecorderModel) async {
        guard let file, let store = recorder.store, !password.isEmpty else { return }
        error = nil
        errorHint = nil
        work = .opening
        stage = .working
        do {
            let data = try await Self.read(file)
            let backup = try await MeetingStore.openBackup(data, password: password)
            let current = try await store.stats().meetings
            let context = try await store.contextEntryCount()
            guard !Task.isCancelled else { return }
            currentContext = context
            opened = backup
            backupHasSettings = !(backup.preferences?.isEmpty ?? true)
            backupHasVoices = backup.savedVoices > 0
            backupDocumentSources = backup.documentSources
            currentDocumentSources = (try? await store.documentSourceCount()) ?? 0
            backupDate = backup.manifest.createdAt
            counts = (current, backup.meetings)
            // Read: the password isn't needed any more. After a failure it stays, for the next try.
            password = ""
            stage = .confirm(current: current, backup: backup.meetings)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = Self.message(error)
            errorHint = Self.hint(for: error)
            stage = .form
        }
    }

    /// Replaces the store with the opened backup and reloads what the app shows.
    func restore(_ recorder: RecorderModel) async {
        guard let opened, let store = recorder.store else { return }
        guard !recorder.blocksDataReplacement else {
            // A recording can start (shortcut, call suggestion) while the sheet is open.
            error = Self.stopRecordingMessage
            errorHint = nil
            return
        }
        error = nil
        errorHint = nil
        work = .restoring
        stage = .working
        recorder.isRestoring = true
        defer { recorder.isRestoring = false }
        await recorder.llm?.pauseForRestore()
        recorder.history?.prepareForRestore()
        // Stops a running context re-analysis before the store changes under it.
        recorder.context?.purge()
        var settingsRestored = false
        do {
            let summary = try await store.restore(opened)
            self.opened = nil
            restoredMeetings = summary.restoredMeetings
            await recorder.history?.storeWasReplaced()
            await recorder.context?.reload()
            // The sources come back with their bookmarks; the index of their text is built again.
            recorder.documents?.dataReplaced()
            recorder.brief.erased()
            // A backup from before the settings were included has none: the settings of this Mac stay as they are.
            settingsRestored = restoreSettings(from: opened, recorder)
            // The templates are the backup's now: a default this Mac kept (a backup without settings) names one of this Mac's, which
            // may be another template of the backup under the same id.
            if !settingsRestored, recorder.preferences.minutesTemplate.isCustom { recorder.preferences.minutesTemplate = .general }
            await recorder.settingsModel?.minutesTemplates.reload(recorder)
            // The backup may hold voice summaries this Mac's settings do not allow: they go before anything reads them.
            await recorder.maintainVoices()
            stage = .done(Self.restoredMessage(meetings: summary.restoredMeetings))
        } catch {
            self.error = Self.message(error)
            // The sheet goes back to an empty password field: say that the backup must be opened again.
            errorHint = Self.hint(for: error)
                ?? String(localized: "Enter the backup password again to retry.", comment: "Restore sheet: shown under the error after a failed restore, when the password field is empty again")
            // The opened backup may already be consumed: open the file again to retry.
            self.opened = nil
            stage = .form
            await recorder.context?.reload()
        }
        await recorder.llm?.resumeAfterRestore()
        // The model providers (Apple's model, a server, search by meaning) may have changed with the settings.
        if settingsRestored { await recorder.llm?.configurationChanged() }
    }

    /// Writes the settings of the backup to UserDefaults and makes the running app use them. Returns whether the backup had any.
    /// A model server the backup chose is not applied on a Mac that has none (the server isn't in the backup): the
    /// provider this Mac already uses stays, so minutes keep working, and the result says where to set the server up.
    private func restoreSettings(from backup: OpenedBackup, _ recorder: RecorderModel) -> Bool {
        guard var settings = backup.preferences, !settings.isEmpty else { return false }
        let providerKeys = ["modelProviderChat", "modelProviderEmbeddings"]
        let usedServer = providerKeys.contains { settings.values[$0] == .string("server") }
        if usedServer && recorder.serverConfig == nil {
            var values = settings.values
            for key in providerKeys { values[key] = nil }
            settings = BackupPreferences(values: values)
            restoredNeedsServer = true
            restoredAppleAvailable = AppleChatModel().availability == .available
        }
        _ = settings.apply(to: .standard)
        recorder.reloadSettingsFromDefaults()
        onSettingsRestored?()
        // The two sentences are separate lines of the result (each language spaces and ends its own).
        restoredNote = usedServer && !restoredNeedsServer
            ? String(localized: "Your settings were restored too. The model server and its key aren’t included.",
                     comment: "Backup sheet: under the restore result when the backup carried the settings")
            : String(localized: "Your settings were restored too.", comment: "Backup sheet: under the restore result when the backup carried the settings and no model server")
        return true
    }

    static func dayStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: .now)
    }
}
