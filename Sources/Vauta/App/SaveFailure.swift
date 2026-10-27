// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import VautaCore

/// Turns a failed write into what happened plus what to do about it, in plain words.
/// The system's own text goes to a tooltip, never into the sentence.
enum SaveFailure {
    enum Cause: Equatable {
        case diskFull, noPermission, other
    }

    static func cause(of error: Error) -> Cause {
        var errno: Int32?
        if let store = error as? StoreError, let detail = store.detail {
            if let range = detail.range(of: #"errno (\d+)"#, options: .regularExpression) {
                errno = Int32(detail[range].dropFirst(6))
            }
            if detail.localizedCaseInsensitiveContains("disk is full") { return .diskFull }
        }
        var current: NSError? = error as NSError
        while let ns = current {
            if ns.domain == NSPOSIXErrorDomain { errno = Int32(ns.code) }
            if ns.domain == NSCocoaErrorDomain {
                if ns.code == NSFileWriteOutOfSpaceError { return .diskFull }
                if ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError { return .noPermission }
            }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        switch errno {
        case ENOSPC, EDQUOT: return .diskFull
        case EACCES, EPERM, EROFS: return .noPermission
        default: return .other
        }
    }

    /// The cause and the next step, as sentences.
    static func nextStep(for error: Error) -> String {
        switch cause(of: error) {
        case .diskFull:
            String(localized: "The disk is full. Free up space.", comment: "Save error: what to do when the disk is full")
        case .noPermission:
            String(localized: "Vauta isn’t allowed to write its data. Check the permissions of its data folder.",
                   comment: "Save error: what to do when macOS refuses the write")
        case .other:
            String(localized: "If it keeps happening, restart Vauta.", comment: "Save error: what to do when the cause is unknown")
        }
    }

    /// The same failure as a banner: a title (the sentence without its full stop), what to do under it, and whether
    /// freeing space is the fix.
    static func parts(_ what: String, _ error: Error) -> (title: String, detail: String, isDiskFull: Bool) {
        let body = what.dropLast()
        let single = !body.contains(". ") && !body.contains("。")
        var title = what
        if single, let last = title.last, last == "." || last == "。" { title.removeLast() }
        switch cause(of: error) {
        case .diskFull:
            return (title, String(localized: "The disk is full. Free up space, then try again.",
                                  comment: "Panel warning under the title when a save failed because the disk is full"), true)
        default:
            return (title, nextStep(for: error), false)
        }
    }

    /// `what` is a complete sentence ("The note couldn’t be saved."); the step follows it.
    static func message(_ what: String, _ error: Error) -> String {
        [what, nextStep(for: error)].joinedAsSentences()
    }
}
