// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Why installing or using the search model failed. A category only: never a file's content. The Settings pane maps each
/// case to its message.
public enum SearchModelError: Error, Sendable, Equatable {
    /// A block, a tensor or the assembled file did not match the pinned hash (or the provenance headers disagreed). Nothing
    /// was installed.
    case mismatch
    /// Hugging Face redirected the download to a host that is not on the allowlist. Nothing was downloaded from it.
    case hostNotAllowed
    /// The pinned revision is no longer offered.
    case revisionGone
    /// Hugging Face could not be reached (or kept refusing the signed link).
    case offline
    /// Not enough free space; `needed` bytes.
    case diskFull(needed: Int)
    /// A file the person chose is not one of the files of the model.
    case importWrongFile
    /// The server answered something that is not a range of the file (a status, a length or a range header that differs).
    case unexpectedResponse
    /// A file operation failed.
    case ioError
    /// No Apple silicon GPU, or the kernel self-test failed in this build.
    case unsupported
    /// The GPU kernel self-test failed in this build.
    case selfTestFailed
    /// The tokenizer file could not be read.
    case tokenizerUnreadable
    /// The encoder could not run the batch (kept apart from `unsupported`: the model itself is fine).
    case encoderFailed
}
