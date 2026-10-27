// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Durable file writes for the store.
///
/// On macOS `fsync()` only hands data to the drive, which may keep it in its
/// volatile cache and reorder it. `F_FULLFSYNC` asks the drive to flush that
/// cache (slow, but the only way to survive a power cut); `F_BARRIERFSYNC`
/// only guarantees that earlier writes reach stable storage before later ones
/// (cheap, ordering without immediate durability). Both fall back to `fsync()`
/// on file systems that do not support them.
enum AtomicFile {
    enum Sync {
        /// `F_FULLFSYNC`: durable on return.
        case full
        /// `F_BARRIERFSYNC`: ordered with respect to later writes.
        case barrier
    }

    /// Writes all bytes, retrying on EINTR and short writes.
    static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw StoreError(.fileSystem, detail: "write: errno \(errno)")
                }
                offset += n
            }
        }
    }

    static func sync(_ fd: Int32, _ mode: Sync) throws {
        let command = mode == .full ? F_FULLFSYNC : F_BARRIERFSYNC
        guard fcntl(fd, command) == 0 || fsync(fd) == 0 else {
            throw StoreError(.fileSystem, detail: "sync: errno \(errno)")
        }
    }

    /// Makes a rename, creation or unlink inside `directory` durable.
    static func syncDirectory(_ directory: URL, _ mode: Sync) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw StoreError(.fileSystem, detail: "open directory: errno \(errno)") }
        defer { close(fd) }
        try sync(fd, mode)
    }

    /// Replaces `file` atomically: a 0600 temporary file named `tempPrefix` +
    /// UUID in the same directory, written and flushed with `F_FULLFSYNC`,
    /// renamed over `file`, then the directory is flushed so the rename itself
    /// survives a power cut. The known prefix lets crash recovery remove only
    /// its own orphaned temporaries.
    static func write(_ data: Data, to file: URL, tempPrefix: String) throws {
        let directory = file.deletingLastPathComponent()
        let tmp = directory.appendingPathComponent(tempPrefix + UUID().uuidString).path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StoreError(.fileSystem, detail: "create temporary file: errno \(errno)") }
        var renamed = false
        defer {
            close(fd)
            if !renamed { unlink(tmp) }
        }
        try writeAll(fd, data)
        guard fchmod(fd, 0o600) == 0 else { throw StoreError(.fileSystem, detail: "fchmod: errno \(errno)") }
        try sync(fd, .full)
        guard rename(tmp, file.path) == 0 else { throw StoreError(.fileSystem, detail: "rename: errno \(errno)") }
        renamed = true
        try syncDirectory(directory, .full)
    }
}
