// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

/// What the backup, restore and verify sheets say: results, progress and failures.
extension BackupModel {
    /// What the restore sheet says under its title once it worked. The restore replaces the context too, so the result
    /// says it; the settings sentence is the note under it (`restoredNote`), never joined to this one.
    static func restoredMessage(meetings: Int) -> String {
        meetings > 0
            ? String(localized: "Restored \(meetings) meetings and your context from the backup.",
                     comment: "Backup sheet: shown after a successful restore; argument is a number of meetings")
            : String(localized: "Restored your context from the backup.",
                     comment: "Backup sheet: shown after a successful restore of a backup with no meetings")
    }

    /// A backup that was read back and opened as a restore would: after saving one, and in the verify sheet.
    static var checkedMessage: String {
        String(localized: "The backup opens with this password, and nothing in it is damaged.",
               comment: "Backup and verify sheets: the backup file was read back, decrypted and checked as a restore would")
    }

    /// The backup just saved couldn't be read back and opened.
    static var uncheckedMessage: String {
        String(localized: "The backup couldn’t be read back", comment: "Backup sheet: title when the saved file failed the check that reads it back")
    }

    static var uncheckedRemovedHint: String {
        String(localized: "The saved file was damaged, so it was deleted. Choose another location and try again.",
               comment: "Backup sheet: advice when the saved file failed the check and was deleted")
    }

    static var uncheckedKeptHint: String {
        String(localized: "The saved file is damaged: don’t rely on it. Choose another location and try again.",
               comment: "Backup sheet: advice when the saved file failed the check and couldn't be deleted")
    }

    /// What the working stage is doing, in words: the label on screen and what VoiceOver hears when it starts.
    var workingMessage: String {
        switch work {
        case .encrypting:
            if let meetings = meetingsToBackUp, meetings > 0 {
                return String(localized: "Encrypting \(meetings) meetings…", comment: "Backup sheet while working; the argument is a number of meetings")
            }
            return String(localized: "Encrypting the backup…")
        case .checking:
            return String(localized: "Checking the backup…", comment: "Backup sheet after saving, and verify sheet: the backup file is read back and opened as a restore would")
        case .opening:
            return String(localized: "Opening the backup…", comment: "Restore sheet while checking the backup")
        case .restoring:
            if let meetings = counts?.backup, meetings > 0 {
                return String(localized: "Restoring \(meetings) meetings…", comment: "Restore sheet while replacing the meetings; the argument is a number of meetings")
            }
            return String(localized: "Restoring meetings…", comment: "Restore sheet while replacing the meetings")
        }
    }

    static var stopRecordingMessage: String {
        String(localized: "Stop the recording to restore.", comment: "Restore sheet: a recording is running")
    }

    /// The title of a failure: short, with the advice in `hint(for:)`. The system's own sentences ("The file couldn’t be
    /// saved because there isn’t enough space") are explanations that would take two bold lines.
    static func message(_ error: Error) -> String {
        if (error as? StoreError)?.code == .backupAuthentication {
            return String(localized: "Couldn’t open the backup", comment: "Restore sheet: title when the password is wrong or the file was changed or damaged")
        }
        if isOutOfSpace(error) {
            return String(localized: "Not enough space", comment: "Backup sheet: title when the disk is full")
        }
        return error.localizedDescription
    }

    fileprivate static func isOutOfSpace(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSCocoaErrorDomain && ns.code == CocoaError.fileWriteOutOfSpace.rawValue
            || ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC)
    }

    /// What to do about a failure: the error's own suggestion, else the one that fits a failed write.
    /// Nothing for an error that has no useful advice (never "free up space" for a permission error).
    static func hint(for error: Error) -> String? {
        if (error as? StoreError)?.code == .backupAuthentication {
            return String(localized: "The password is wrong, or the file was changed or damaged. Check the password, or choose another file.",
                          comment: "Restore sheet: advice when the backup can't be opened")
        }
        if let suggestion = (error as? LocalizedError)?.recoverySuggestion { return suggestion }
        let ns = error as NSError
        if isOutOfSpace(error) {
            return String(localized: "Choose another location, or free up space and try again.", comment: "Backup sheet: the disk is full")
        }
        let writeErrors: Set<Int> = [CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileWriteVolumeReadOnly.rawValue,
                                     CocoaError.fileWriteInvalidFileName.rawValue, CocoaError.fileWriteFileExists.rawValue,
                                     CocoaError.fileWriteUnknown.rawValue]
        if ns.domain == NSCocoaErrorDomain && writeErrors.contains(ns.code)
            || ns.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM), Int(EROFS)].contains(ns.code) {
            return String(localized: "Choose another location and try again.", comment: "Backup sheet: the file couldn't be written there")
        }
        return nil
    }
}
