// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// An error from the encrypted meeting store.
///
/// `code` is stable and safe to branch on or persist; `errorDescription` is the
/// localized message for people; `detail` carries technical context (errno,
/// OSStatus, SQLite message, underlying error) for diagnostics and is never
/// localized.
public struct StoreError: LocalizedError, CustomStringConvertible, Sendable {
    /// Stable error codes. Raw values never change: they may be persisted or logged.
    public enum Code: String, Sendable, CaseIterable {
        /// A free-form failure (see `init(_ message:)`).
        case general
        /// The meeting is being recorded; the operation must wait until it ends.
        case meetingInProgress
        /// `startMeeting` was called while another meeting is still recording.
        case meetingAlreadyActive
        /// Another Vauta process has the store open.
        case alreadyOpen
        /// The Keychain is locked or access to the key was cancelled (retryable).
        case keychainUnavailable
        /// The Keychain refused to read, write or delete an item.
        case keychainFailure
        /// An encrypted store exists but its key is not in the Keychain.
        case missingKey
        /// History was erased but the new key could not be created yet.
        case newKeyPending
        /// No store exists and the caller asked not to create one.
        case storeNotFound
        /// The store file cannot be decrypted or decoded (wrong key or damaged file).
        case unreadableStore
        /// The store file has an unknown envelope format or version.
        case unsupportedFormat
        /// The store was written by a newer version of Vauta.
        case newerSchema
        /// A schema migration failed; the store was left unchanged.
        case migrationFailed
        /// Reading or writing a file failed.
        case fileSystem
        /// Encrypting data failed.
        case encryption
        /// An SQLite error.
        case database
        /// The meeting was removed in memory but the store could not be written.
        case deleteNotSaved
        /// Data was deleted but the search index could not be compacted yet.
        case compactionFailed
        /// "Erase everything" could not remove the store file; nothing was erased.
        case eraseFailed
        /// The file is not a Vauta backup (wrong or missing header, or cut short).
        case backupInvalid
        /// A backup could not be authenticated: wrong password, or the file was changed or damaged.
        case backupAuthentication
        /// The backup uses a format version this version of Vauta does not know.
        case backupUnsupported
        /// Restoring failed before anything was replaced.
        case restoreFailed
        /// A speaker edit named a speaker that no longer exists.
        case speakerGone
        /// A speaker edit named a segment that no longer exists.
        case segmentGone
        /// A segment cannot be split at that place.
        case cannotSplit
        /// A speaker edit cannot be undone any more: the data moved on.
        case cannotUndo
        /// Several people have the name the user typed for a speaker: the UI asks which one.
        case speakerNameAmbiguous
        /// A speaker edit mixed a speaker with a segment or speaker of another meeting or channel.
        case speakerMismatch
        /// The user turned speakers off for this meeting.
        case speakersOff
        /// "Remember this voice" for a speaker whose voice was not kept (voice recognition was off, the speaker talked too
        /// little, or the meeting is older than the feature).
        case voiceNotAvailable
        /// "Remember this voice" for a speaker nobody named yet.
        case voiceNeedsPerson
    }

    /// Kept for source compatibility: `kind` was the original name of `code`.
    public typealias Kind = Code

    public let code: Code
    /// Technical detail for diagnostics (not localized, never shown alone).
    public let detail: String?
    /// Explicit message for `.general` errors raised by callers outside the store.
    private let message: String?

    public var kind: Code { code }

    public init(_ code: Code, detail: String? = nil) {
        self.code = code
        self.detail = detail
        self.message = nil
    }

    /// A `.general` error with a caller-provided message (validation errors and
    /// similar). Prefer a specific `Code` for anything the UI may branch on.
    public init(_ message: String) {
        self.code = .general
        self.detail = nil
        self.message = message
    }

    /// Wraps an underlying error as the technical detail.
    init(_ code: Code, underlying: any Error) {
        self.init(code, detail: String(describing: underlying))
    }

    static let meetingInProgress = StoreError(.meetingInProgress)
    static let alreadyOpen = StoreError(.alreadyOpen)

    public var errorDescription: String? {
        if let message { return message }
        return switch code {
        case .general:
            String(localized: "The encrypted store reported an error.", comment: "Generic storage error")
        case .meetingInProgress:
            String(localized: "This meeting is being recorded. Stop the recording first.",
                   comment: "Storage error: an operation is refused while the meeting is recording")
        case .meetingAlreadyActive:
            String(localized: "Another meeting is already being recorded.",
                   comment: "Storage error: a new recording cannot start while another one is active")
        case .alreadyOpen:
            String(localized: "Vauta is already open in another instance.",
                   comment: "Storage error: a second process tried to open the store")
        case .keychainUnavailable:
            String(localized: "Your Keychain is locked or access to Vauta’s key was canceled.",
                   comment: "Storage error: the login keychain could not be used right now")
        case .keychainFailure:
            String(localized: "The Keychain couldn’t complete the operation.",
                   comment: "Storage error: a Keychain read, write or delete failed")
        case .missingKey:
            String(localized: "Your meetings are encrypted, but their key isn’t in the Keychain. Vauta won’t create a new key, so your data isn’t lost.",
                   comment: "Storage error: the encrypted store exists but its key is missing")
        case .newKeyPending:
            String(localized: "Your history was erased, but a new encryption key couldn’t be created in the Keychain. Nothing will be recorded or saved until it is.",
                   comment: "Storage error: erase everything completed but the new key could not be created")
        case .storeNotFound:
            String(localized: "No encrypted store was found.",
                   comment: "Storage error: a read-only open found no store")
        case .unreadableStore:
            String(localized: "The encrypted store couldn’t be decrypted. The key may be different or the file may be damaged.",
                   comment: "Storage error: decrypting or decoding the store failed")
        case .unsupportedFormat:
            String(localized: "The encrypted store file has an unknown format.",
                   comment: "Storage error: the store envelope header or version is unknown")
        case .newerSchema:
            String(localized: "The encrypted store was created by a newer version of Vauta.",
                   comment: "Storage error: the database schema is newer than this app supports")
        case .migrationFailed:
            String(localized: "The encrypted store couldn’t be upgraded. It was left unchanged.",
                   comment: "Storage error: a schema migration failed")
        case .fileSystem:
            String(localized: "Vauta couldn’t read or write your data on the disk.",
                   comment: "Storage error: a file system operation failed")
        case .encryption:
            String(localized: "Vauta couldn’t encrypt your meetings to save them. Try again. If it keeps happening, restart your Mac.",
                   comment: "Storage error: encryption failed")
        case .database:
            String(localized: "The encrypted store reported an error.",
                   comment: "Storage error: an SQLite operation failed")
        case .deleteNotSaved:
            String(localized: "The meeting was removed from the list, but the change couldn’t be saved to disk. It stays on disk until the next successful save.",
                   comment: "Storage error: a meeting was deleted in memory but the store could not be written")
        case .compactionFailed:
            String(localized: "The data was deleted, but the search index couldn’t be compacted. Vauta will retry on the next save.",
                   comment: "Storage error: compaction after a delete failed and will be retried")
        case .eraseFailed:
            String(localized: "The store file couldn’t be deleted. Nothing was erased.",
                   comment: "Storage error: erase everything could not remove the store file")
        case .backupInvalid:
            String(localized: "This file isn’t a Vauta backup, or it is incomplete.",
                   comment: "Backup error: the chosen file has no valid backup header or is cut short")
        case .backupAuthentication:
            String(localized: "Wrong password, or the backup file was changed or damaged.",
                   comment: "Backup error: decrypting the backup failed")
        case .backupUnsupported:
            String(localized: "This backup was made by a newer version of Vauta and can’t be read by this one.",
                   comment: "Backup error: unknown backup format version")
        case .restoreFailed:
            String(localized: "The backup couldn’t be restored. Your current meetings were left unchanged.",
                   comment: "Backup error: restore failed before replacing anything")
        case .speakerGone:
            String(localized: "This speaker no longer exists.",
                   comment: "Speaker edit error: the speaker was removed meanwhile")
        case .segmentGone:
            String(localized: "This line no longer exists.",
                   comment: "Speaker edit error: the transcript segment was removed meanwhile")
        case .cannotSplit:
            String(localized: "This line can’t be split there.",
                   comment: "Speaker edit error: the chosen place leaves one part empty or outside the segment")
        case .cannotUndo:
            String(localized: "This change can no longer be undone.",
                   comment: "Speaker edit error: the transcript changed after the edit, so it can't be reverted")
        case .speakerNameAmbiguous:
            String(localized: "Several people have this name. Choose which one.",
                   comment: "Speaker edit error: the typed name matches more than one person")
        case .speakerMismatch:
            String(localized: "A speaker can only be used in the same meeting and channel.",
                   comment: "Speaker edit error: the speaker and the segment (or the other speaker) belong to different meetings or channels")
        case .speakersOff:
            String(localized: "Speaker separation is off for this meeting.",
                   comment: "Speaker edit error: the user disabled speaker labels for the meeting")
        case .voiceNotAvailable:
            String(localized: "Vauta didn’t keep this speaker’s voice, so it can’t be remembered. Voices are only kept for \(VoiceProfileThresholds.keptSummaryDays) days, for meetings recorded or imported while “Recognize voices across meetings” is on, and only for people who spoke long and clearly enough.",
                   comment: "Remember this voice error: there is no voice summary for this speaker")
        case .voiceNeedsPerson:
            String(localized: "Say who this speaker is before remembering their voice.",
                   comment: "Remember this voice error: the speaker has no name yet")
        }
    }

    public var recoverySuggestion: String? {
        switch code {
        case .keychainUnavailable:
            String(localized: "Unlock your login keychain, then try again.",
                   comment: "Recovery suggestion for a locked keychain")
        case .missingKey:
            String(localized: "If you restored this Mac or changed how Vauta is installed, restore the login keychain item for Vauta and try again.",
                   comment: "Recovery suggestion when the store key is missing")
        case .backupAuthentication:
            String(localized: "Check the password and try again.",
                   comment: "Recovery suggestion when a backup can't be opened: the password may be wrong")
        case .backupUnsupported:
            String(localized: "Update Vauta to the latest version and try again.",
                   comment: "Recovery suggestion when a backup comes from a newer app version")
        case .newerSchema:
            String(localized: "Update Vauta to the latest version.",
                   comment: "Recovery suggestion when the store comes from a newer app version")
        case .alreadyOpen:
            String(localized: "Quit the other copy of Vauta and try again.",
                   comment: "Recovery suggestion when another instance has the store open")
        case .meetingInProgress, .meetingAlreadyActive:
            String(localized: "Stop the current recording and try again.",
                   comment: "Recovery suggestion when a recording is in progress")
        case .newKeyPending, .keychainFailure:
            String(localized: "Unlock your login keychain, then try again.",
                   comment: "Recovery suggestion for keychain write failures")
        default:
            nil
        }
    }

    /// Localized message plus the technical detail, for logs and the CLI.
    public var description: String {
        let text = errorDescription ?? code.rawValue
        guard let detail, !detail.isEmpty else { return text }
        return "\(text) [\(code.rawValue): \(detail)]"
    }
}
