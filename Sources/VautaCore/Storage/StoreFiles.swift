// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// File names of the store. Vauta was called something else before 0.9.0; installs made
/// with the old name keep their data, which is renamed in place on first open
/// (see `StoreMigration`). The legacy names stay as constants for that.
enum StoreFiles {
    static let snapshot = "vauta.db.enc"
    static let journal = "vauta.journal.enc"
    /// Temporaries of the store's own atomic writes: the only files recovery removes.
    static let tempPrefix = "vauta.db.enc.tmp-"
    static let lock = "vauta.lock"
    static let eraseMarker = "vauta.erasing"
    /// Present only while a document is being read: it names the file by a number (see `DocumentIndexer`), never by its name.
    static let documentsMarker = "vauta.docs.extracting"

    /// Names used by the earlier version. Never delete a file with one of these names
    /// unless its `vauta.*` counterpart is verified (or the user erases everything).
    enum Legacy {
        static let snapshot = "acta.db.enc"
        static let journal = "acta.journal.enc"
        static let tempPrefix = "acta.db.enc.tmp-"
        static let lock = "acta.lock"
        static let eraseMarker = "acta.erasing"
        /// `<Application Support>/Acta`, the directory of the old name.
        static let directory = "Acta"
    }

    static let directory = "Vauta"

    /// Infix of files moved aside instead of deleted: `vauta.db.enc.legacy-<unix time>`.
    static let asideInfix = ".legacy-"

    /// Every name that holds user data (snapshot or journal, either generation of names).
    static let dataNames = [snapshot, journal, Legacy.snapshot, Legacy.journal]

    static func isTemporary(_ name: String) -> Bool { name.hasPrefix(tempPrefix) || name.hasPrefix(Legacy.tempPrefix) }

    /// A file moved aside by a migration (still encrypted with the store key).
    static func isAside(_ name: String) -> Bool {
        dataNames.contains { name.hasPrefix($0 + asideInfix) }
    }

    static func hasStore(in dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent(snapshot).path)
            || fm.fileExists(atPath: dir.appendingPathComponent(Legacy.snapshot).path)
    }

    /// A store, or the marker of an erase that still has to shred its key.
    static func hasStoreOrEraseMarker(in dir: URL) -> Bool {
        let fm = FileManager.default
        return hasStore(in: dir) || [eraseMarker, Legacy.eraseMarker].contains {
            fm.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }
}

/// What a migration did on this open. Empty almost always.
public struct StoreMigrationReport: Sendable, Equatable {
    /// Files renamed from the old name, as `old -> new`.
    public var renamed: [String] = []
    /// Files set aside (never deleted) because both names existed, as `name -> new name`.
    public var setAside: [String] = []

    public var isEmpty: Bool { renamed.isEmpty && setAside.isEmpty }
}

/// Moves a store written under the old name (`acta.*`) to the `vauta.*` names.
///
/// Runs under the instance lock, before anything is read. Safety rules:
///
/// - Nothing is deleted. Every step is one atomic `rename(2)` inside the same
///   directory; files that must make room are renamed to `<name>.legacy-<time>`.
/// - Before the first rename the legacy snapshot is opened with the Keychain
///   key. If that fails (no key, locked keychain, damaged file, unreadable)
///   nothing is touched and the open fails as it always did.
/// - Order: snapshot first, then journal. Every interruption leaves a state this
///   function finishes on the next open (the table below), and the journal's
///   generation (checked on replay) means a journal is never applied to a
///   snapshot it does not belong to.
///
///     state on open                          action
///     only acta.db.enc (+ acta.journal.enc)  verify, rename snapshot, rename journal
///     vauta.db.enc + acta.journal.enc,       rename journal (an earlier run stopped
///       no vauta.journal.enc                   between the two renames)
///     only vauta.*                           nothing
///     both snapshots (unexpected)            keep the one that opens with the key and holds
///                                            more meetings (newer on a tie, vauta.* on a
///                                            further tie); set the other pair aside
///
/// The lock file is not migrated: `vauta.lock` is the lock, and an existing
/// `acta.lock` is also held for as long as the store is open, so an old build
/// running against the same directory still excludes this one.
enum StoreMigration {
    struct Outcome {
        var report = StoreMigrationReport()
        /// Plain renames done now, to undo them if the rest of the open fails.
        var moves: [(from: URL, to: URL)] = []

        /// Puts renamed files back under their old names (best effort).
        func rollback() {
            for move in moves.reversed() where !FileManager.default.fileExists(atPath: move.from.path) {
                rename(move.to.path, move.from.path)
            }
        }
    }

    static func run(in dir: URL, keyStore: any DatabaseKeyStore, now: Date = .now) throws -> Outcome {
        let fm = FileManager.default
        func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: url(name).path) }
        var outcome = Outcome()

        let newSnapshot = exists(StoreFiles.snapshot)
        let oldSnapshot = exists(StoreFiles.Legacy.snapshot)

        switch (newSnapshot, oldSnapshot) {
        case (false, false):
            // No snapshot: a journal of either name cannot be used. Leave it for
            // the store's own recovery (it removes it when it creates a snapshot).
            return outcome

        case (true, false):
            // Only the journal can still be pending (interrupted between the two renames).
            try moveJournalIfPending(dir, &outcome, now: now)
            return outcome

        case (false, true):
            let key = try keyStore.key(createIfMissing: false)
            guard Candidate(url: url(StoreFiles.Legacy.snapshot), key: key) != nil else {
                // Re-run the real open to surface the right error; legacy files stay as they are.
                _ = try SnapshotEnvelope.open(Data(contentsOf: url(StoreFiles.Legacy.snapshot)), key: key)
                throw StoreError(.unreadableStore, detail: "legacy snapshot")
            }
            // A stray vauta.journal.enc without a snapshot belongs to nothing readable: keep it aside.
            if exists(StoreFiles.journal) { try setAside(StoreFiles.journal, dir, &outcome, now: now) }
            try move(StoreFiles.Legacy.snapshot, to: StoreFiles.snapshot, dir, &outcome)
            try moveJournalIfPending(dir, &outcome, now: now)
            return outcome

        case (true, true):
            let key = try keyStore.key(createIfMissing: false)
            let current = Candidate(url: url(StoreFiles.snapshot), key: key)
            let legacy = Candidate(url: url(StoreFiles.Legacy.snapshot), key: key)
            switch (current, legacy) {
            case (nil, nil):
                // Neither opens: report the failure of the current one, touch nothing.
                _ = try SnapshotEnvelope.open(Data(contentsOf: url(StoreFiles.snapshot)), key: key)
                throw StoreError(.unreadableStore, detail: "both snapshots")
            case (.some, nil):
                try keepCurrent(dir, &outcome, now: now)
            case (nil, .some):
                try keepLegacy(dir, &outcome, now: now)
            case let (c?, l?):
                if l.meetings > c.meetings || (l.meetings == c.meetings && l.modified > c.modified) {
                    try keepLegacy(dir, &outcome, now: now)
                } else {
                    try keepCurrent(dir, &outcome, now: now)
                }
            }
            return outcome
        }
    }

    // MARK: Steps

    /// The vauta.* snapshot wins: the old pair is set aside (journal first, so a
    /// crash in between re-decides the same way).
    private static func keepCurrent(_ dir: URL, _ outcome: inout Outcome, now: Date) throws {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(StoreFiles.Legacy.journal).path) {
            try setAside(StoreFiles.Legacy.journal, dir, &outcome, now: now)
        }
        try setAside(StoreFiles.Legacy.snapshot, dir, &outcome, now: now)
    }

    /// The acta.* snapshot wins: the vauta.* pair is set aside, then the old pair moves in.
    private static func keepLegacy(_ dir: URL, _ outcome: inout Outcome, now: Date) throws {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent(StoreFiles.journal).path) {
            try setAside(StoreFiles.journal, dir, &outcome, now: now)
        }
        try setAside(StoreFiles.snapshot, dir, &outcome, now: now)
        try move(StoreFiles.Legacy.snapshot, to: StoreFiles.snapshot, dir, &outcome)
        try moveJournalIfPending(dir, &outcome, now: now)
    }

    /// acta.journal.enc → vauta.journal.enc when only the old one exists. If both
    /// exist, the vauta.* one belongs to the snapshot already in place; the old one is set aside.
    private static func moveJournalIfPending(_ dir: URL, _ outcome: inout Outcome, now: Date) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.appendingPathComponent(StoreFiles.Legacy.journal).path) else { return }
        if fm.fileExists(atPath: dir.appendingPathComponent(StoreFiles.journal).path) {
            try setAside(StoreFiles.Legacy.journal, dir, &outcome, now: now)
        } else {
            try move(StoreFiles.Legacy.journal, to: StoreFiles.journal, dir, &outcome)
        }
    }

    private static func move(_ old: String, to new: String, _ dir: URL, _ outcome: inout Outcome) throws {
        let from = dir.appendingPathComponent(old), to = dir.appendingPathComponent(new)
        guard rename(from.path, to.path) == 0 else {
            throw StoreError(.fileSystem, detail: "migrate \(old): errno \(errno)")
        }
        outcome.moves.append((from, to))
        outcome.report.renamed.append("\(old) -> \(new)")
        try? AtomicFile.syncDirectory(dir, .full)
    }

    @discardableResult
    private static func setAside(_ name: String, _ dir: URL, _ outcome: inout Outcome, now: Date) throws -> String {
        let fm = FileManager.default
        let stamp = Int(now.timeIntervalSince1970)
        var target = "\(name)\(StoreFiles.asideInfix)\(stamp)"
        var n = 1
        while fm.fileExists(atPath: dir.appendingPathComponent(target).path) {
            n += 1
            target = "\(name)\(StoreFiles.asideInfix)\(stamp)-\(n)"
        }
        guard rename(dir.appendingPathComponent(name).path, dir.appendingPathComponent(target).path) == 0 else {
            throw StoreError(.fileSystem, detail: "set aside \(name): errno \(errno)")
        }
        outcome.report.setAside.append("\(name) -> \(target)")
        try? AtomicFile.syncDirectory(dir, .full)
        return target
    }

    /// A snapshot that opens with the key.
    private struct Candidate {
        let meetings: Int64
        let modified: Date

        init?(url: URL, key: SymmetricKey) {
            guard let data = try? Data(contentsOf: url),
                  let (image, size) = try? SnapshotEnvelope.open(data, key: key),
                  let db = try? SQLiteDatabase(image: image, size: size) else { return nil }
            meetings = (try? db.query("SELECT COUNT(*) FROM meetings")[0].int(0)) ?? 0
            modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        }
    }
}

// MARK: Default directory

extension MeetingStore {
    /// The directory holding the store, without creating or moving anything:
    /// `<Application Support>/Vauta`, or the old `<Application Support>/Acta`
    /// when only that one has a store.
    static func locateDefaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: false)
        return locateDirectory(under: base)
    }

    static func locateDirectory(under base: URL) -> URL {
        let new = base.appendingPathComponent(StoreFiles.directory, isDirectory: true)
        let old = base.appendingPathComponent(StoreFiles.Legacy.directory, isDirectory: true)
        if StoreFiles.hasStore(in: new) { return new }
        if StoreFiles.hasStore(in: old) { return old }
        return new
    }

    /// The directory to open for writing, see `moveDirectoryIfNeeded(under:)`.
    static func defaultDirectory() throws -> DirectoryChoice {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: false)
        return try moveDirectoryIfNeeded(under: base)
    }

    /// The directory to open for writing, and what was done to get it.
    struct DirectoryChoice {
        let url: URL
        /// Set when the earlier folder was renamed to `Vauta` now: a failed open puts it back.
        var movedFrom: URL?
        /// Both locks of the directory, taken before the move: the store keeps them.
        var locks: (main: InstanceLock, legacy: InstanceLock)?
    }

    /// If only the old the earlier folder name directory holds a store (or an unfinished erase),
    /// it is renamed to `Vauta` (one atomic `rename(2)`; an empty `Vauta` is
    /// removed first). If that fails, the old directory is used as it is: the
    /// files inside are renamed there.
    ///
    /// Both lock files of the old directory are taken first, so a build of
    /// either name running on it (recording, saving) is never moved from under
    /// its feet: that throws `.alreadyOpen` and changes nothing. The locks
    /// follow the directory and are handed to the store.
    static func moveDirectoryIfNeeded(under base: URL) throws -> DirectoryChoice {
        let new = base.appendingPathComponent(StoreFiles.directory, isDirectory: true)
        let old = base.appendingPathComponent(StoreFiles.Legacy.directory, isDirectory: true)
        let fm = FileManager.default
        func pending() -> Bool { !StoreFiles.hasStore(in: new) && StoreFiles.hasStoreOrEraseMarker(in: old) }
        guard pending() else { return DirectoryChoice(url: locateDirectory(under: base)) }
        let locks: (main: InstanceLock, legacy: InstanceLock)
        do {
            locks = (try InstanceLock(old.appendingPathComponent(StoreFiles.lock)),
                     try InstanceLock(old.appendingPathComponent(StoreFiles.Legacy.lock)))
        } catch let error as StoreError where error.code == .fileSystem && !fm.fileExists(atPath: old.path) {
            // Another instance moved it in the meantime: its new place is locked as usual.
            return DirectoryChoice(url: locateDirectory(under: base))
        }
        // Checked again under the locks: another instance may have moved it already.
        guard pending() else { return DirectoryChoice(url: locateDirectory(under: base)) }
        // rmdir only removes an empty directory.
        if fm.fileExists(atPath: new.path) { rmdir(new.path) }
        if !fm.fileExists(atPath: new.path), rename(old.path, new.path) == 0 {
            try? AtomicFile.syncDirectory(base, .full)
            return DirectoryChoice(url: new, movedFrom: old, locks: locks)
        }
        return DirectoryChoice(url: old, locks: locks)
    }

    /// Puts `Vauta` back to the earlier folder name after a failed first open (best effort).
    static func undoDirectoryMove(_ choice: DirectoryChoice) {
        guard let old = choice.movedFrom, !FileManager.default.fileExists(atPath: old.path) else { return }
        if rename(choice.url.path, old.path) == 0 {
            try? AtomicFile.syncDirectory(old.deletingLastPathComponent(), .full)
        }
    }
}
