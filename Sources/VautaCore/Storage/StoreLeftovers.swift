// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Encrypted copies of the store that the migration from the earlier version kept instead of
/// deleting, so they would not stay invisible on disk:
///
/// - files set aside next to the store (`vauta.db.enc.legacy-<time>`, when both
///   the old and the new names held a store);
/// - a store left in the earlier version's folder, next to the `Vauta` one in use.
///
/// They are encrypted with the key of the live store, so deleting them is plain
/// file removal: the key and the live store are never touched.
public struct StoreLeftover: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// A file set aside inside the store's folder.
        case setAside
        /// The earlier version's folder (the whole folder is one item).
        case oldFolder
    }

    public let kind: Kind
    public let url: URL
    /// Size of the file, or of the data files inside the old folder.
    public let bytes: Int64
    /// When it was set aside (from its name), or the folder's last change.
    public let date: Date?

    public var id: String { url.path }
}

public struct StoreLeftovers: Sendable, Equatable {
    public var items: [StoreLeftover] = []

    public var isEmpty: Bool { items.isEmpty }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    public var setAsideCount: Int { items.filter { $0.kind == .setAside }.count }
    public var hasOldFolder: Bool { items.contains { $0.kind == .oldFolder } }
    /// When the last copy set aside reaches the retention and is deleted automatically (nil when none is set aside).
    public var lastAutomaticDeletion: Date? {
        items.filter { $0.kind == .setAside }.compactMap(\.date).max()
            .map { $0.addingTimeInterval(Double(MeetingStore.retentionDays) * 86_400) }
    }
    /// What "Show in Finder" selects: the files themselves.
    public var urls: [URL] { items.map(\.url) }
}

extension StoreFiles {
    /// Unix time in the name of a set-aside file (`….legacy-1760000000` or `….legacy-1760000000-2`).
    static func asideDate(_ name: String) -> Date? {
        guard let range = name.range(of: asideInfix) else { return nil }
        let digits = name[range.upperBound...].prefix { $0.isNumber }
        return TimeInterval(digits).map(Date.init(timeIntervalSince1970:))
    }

    /// Every file name a Vauta or earlier-version store folder can hold. Anything else in an
    /// old folder is not ours to delete.
    static func isStoreFile(_ name: String) -> Bool {
        dataNames.contains(name) || isAside(name) || isTemporary(name)
            || [lock, Legacy.lock, eraseMarker, Legacy.eraseMarker].contains(name)
    }
}

extension MeetingStore {
    /// The earlier version's folder next to the live `Vauta` one, when it still holds a store.
    /// nil if the live store is itself in a folder with another name (tests, overrides)
    /// or the old folder is the one in use.
    var oldFolder: URL? {
        guard directory.lastPathComponent == StoreFiles.directory else { return nil }
        let old = directory.deletingLastPathComponent().appendingPathComponent(StoreFiles.Legacy.directory, isDirectory: true)
        return StoreFiles.hasStore(in: old) ? old : nil
    }

    /// Looks for encrypted copies the migration left behind. Reads names and sizes only.
    public func leftovers() -> StoreLeftovers {
        let fm = FileManager.default
        var found = StoreLeftovers()
        for name in ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? []).sorted() where StoreFiles.isAside(name) {
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path), attributes[.type] as? FileAttributeType == .typeRegular else { continue }
            found.items.append(StoreLeftover(kind: .setAside, url: url, bytes: Int64(attributes[.size] as? Int ?? 0),
                                             date: StoreFiles.asideDate(name) ?? attributes[.modificationDate] as? Date))
        }
        if let old = oldFolder {
            var bytes: Int64 = 0
            var newest: Date?
            for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where StoreFiles.isStoreFile(name) {
                guard let attributes = try? fm.attributesOfItem(atPath: old.appendingPathComponent(name).path) else { continue }
                bytes += Int64(attributes[.size] as? Int ?? 0)
                if let modified = attributes[.modificationDate] as? Date, modified > newest ?? .distantPast { newest = modified }
            }
            found.items.append(StoreLeftover(kind: .oldFolder, url: old, bytes: bytes, date: newest))
        }
        return found
    }

    /// Deletes every leftover found by `leftovers()`; returns how many items went.
    /// Needs the live store on disk (never deletes the only copy). The key is not
    /// touched. Only store files are removed; the old folder is removed too when
    /// nothing else is left in it.
    @discardableResult
    public func deleteLeftovers() -> Int {
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        var removed = 0
        for item in leftovers().items {
            switch item.kind {
            case .setAside:
                if unlink(item.url.path) == 0 { removed += 1 }
            case .oldFolder:
                if removeOldFolder(item.url) { removed += 1 }
            }
        }
        return removed
    }

    /// Retention for set-aside copies: the ones set aside more than `retentionDays`
    /// ago go. They are a safety net for the migration, not an archive. The old
    /// folder is only ever deleted by the user (or by "Erase everything").
    @discardableResult
    func purgeExpiredSetAside(now: Date = .now) -> Int {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
        var removed = 0
        for item in leftovers().items where item.kind == .setAside {
            if let date = item.date, date < cutoff, unlink(item.url.path) == 0 { removed += 1 }
        }
        return removed
    }

    /// "Erase everything" also removes a store left in the old folder.
    func eraseOldFolder() {
        if let old = oldFolder { _ = removeOldFolder(old) }
    }

    private func removeOldFolder(_ old: URL) -> Bool {
        let fm = FileManager.default
        // An old-named build still running on that folder holds one of its locks:
        // its store is in use, not a leftover, so it stays.
        guard let locks = try? [InstanceLock(old.appendingPathComponent(StoreFiles.lock)),
                                InstanceLock(old.appendingPathComponent(StoreFiles.Legacy.lock))] else { return false }
        var failed = false
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where StoreFiles.isStoreFile(name) {
            if unlink(old.appendingPathComponent(name).path) != 0 && errno != ENOENT { failed = true }
        }
        // rmdir only removes an empty folder: anything that is not ours stays.
        _ = rmdir(old.path)
        withExtendedLifetime(locks) {}
        return !failed
    }
}
