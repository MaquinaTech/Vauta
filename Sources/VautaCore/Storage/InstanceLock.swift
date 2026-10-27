// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Exclusive lock (flock) on a file in the store directory. Two instances
/// would overwrite each other's vauta.db.enc, and one's crash recovery would
/// close the other's meeting in progress. Released on deinit or process exit.
final class InstanceLock: @unchecked Sendable {
    private let fd: Int32

    init(_ url: URL) throws {
        fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError(.fileSystem, detail: "lock file: errno \(errno)") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            // No close(fd) here: all properties are initialized, so a throw runs `deinit`, which closes it.
            // Closing here too closed the same number twice, and by then another thread may own it.
            throw code == EWOULDBLOCK ? StoreError.alreadyOpen : StoreError(.fileSystem, detail: "flock: errno \(code)")
        }
    }

    deinit { close(fd) }
}
