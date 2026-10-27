// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Why installing or using the integrated language model failed. A category only: never a file's content.
public enum IntegratedModelError: Error, Sendable, Equatable {
    /// A block, a tensor or the assembled file did not match the pinned hash (or the provenance headers disagreed). Nothing
    /// was installed.
    case mismatch
    case hostNotAllowed
    case revisionGone
    case offline
    case diskFull(needed: Int)
    /// A file the person chose is not one of the files of the model.
    case importWrongFile
    case unexpectedResponse
    case ioError
    /// This Mac does not meet the requirements (16 GB of memory, an Apple silicon GPU), with the reason.
    case unsupported(String)
    case tokenizerUnreadable
    /// The model could not run a request (memory, GPU).
    case engineFailed(String)
    /// A weight is NaN or infinite.
    case nonFiniteWeights
}
