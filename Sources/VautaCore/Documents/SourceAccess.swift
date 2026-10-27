// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What opening a source's bookmark gave.
public enum SourceResolution: Sendable, Equatable {
    /// The source is there. `renewed` is a fresh bookmark when the old one was stale (save it).
    case resolved(url: URL, renewed: Data?)
    /// The drive it was on is not connected. Its index is kept and searchable.
    case disconnected
    /// Moved or deleted: the person can locate it.
    case notFound
    /// macOS no longer lets Vauta in.
    case noPermission
}

/// Access to the folders and files the person added, through the App Sandbox's security-scoped bookmarks.
///
/// Bookmarks are app-scoped and read-only: Vauta can never write to a source. Every read happens between `begin` and
/// `end` on the source's own URL (a folder's scope covers what is inside it). Tests supply their own.
public protocol SourceAccessing: Sendable {
    func makeBookmark(for url: URL) throws -> (data: Data, volumeUUID: String?)
    func resolve(_ source: DocumentSource) -> SourceResolution
    /// Starts reading inside the source's scope. Returns whether a matching `end` is needed.
    func begin(_ url: URL) -> Bool
    func end(_ url: URL)
}

public extension SourceAccessing {
    /// Runs `body` inside the source's scope.
    func withAccess<T>(_ url: URL, _ body: () async throws -> T) async rethrows -> T {
        let started = begin(url)
        defer { if started { end(url) } }
        return try await body()
    }
}

/// The real thing: app-scoped, read-only security-scoped bookmarks.
public struct SecurityScopedAccess: SourceAccessing {
    public init() {}

    /// The volume's identity is kept in the bookmark, so a drive that is not connected is told apart from a folder that moved.
    static let bookmarkKeys: Set<URLResourceKey> = [.volumeUUIDStringKey, .volumeNameKey, .volumeIsRemovableKey]

    public func makeBookmark(for url: URL) throws -> (data: Data, volumeUUID: String?) {
        let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                        includingResourceValuesForKeys: Self.bookmarkKeys, relativeTo: nil)
        return (data, try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
    }

    public func resolve(_ source: DocumentSource) -> SourceResolution {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: source.bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            guard stale else { return .resolved(url: url, renewed: nil) }
            // A stale bookmark still works; it is renewed while access is open so the next launch resolves it directly.
            let started = url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            let renewed = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: Self.bookmarkKeys, relativeTo: nil)
            return .resolved(url: url, renewed: renewed)
        } catch {
            if let uuid = source.volumeUUID, !Self.mountedVolumeUUIDs().contains(uuid) { return .disconnected }
            let code = (error as NSError).code
            if code == NSFileReadNoPermissionError { return .noPermission }
            return .notFound
        }
    }

    public func begin(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func end(_ url: URL) { url.stopAccessingSecurityScopedResource() }

    static func mountedVolumeUUIDs() -> Set<String> {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []) ?? []
        return Set(urls.compactMap { try? $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString })
    }
}

/// Which folders and files may be added.
public enum DocumentSourceRules {
    public enum Verdict: Equatable, Sendable {
        case ok
        /// The same path, or a folder already added contains it.
        case alreadyIncluded(in: String)
        /// The new folder contains sources that were added before; adding it would read their files twice.
        case containsExisting(String)
        /// Vauta's own data (its container) can't be a source.
        case ownData
        case unsupportedFile
    }

    /// `ownData`: the folders that hold Vauta's store and the app's container.
    public static func check(_ url: URL, isDirectory: Bool, existing: [DocumentSource], ownData: [URL]) -> Verdict {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        for own in ownData {
            let ownPath = own.standardizedFileURL.resolvingSymlinksInPath().path
            if path == ownPath || path.hasPrefix(ownPath + "/") || ownPath.hasPrefix(path + "/") { return .ownData }
        }
        if !isDirectory, DocumentFormat.format(forExtension: url.pathExtension) == nil { return .unsupportedFile }
        for source in existing where source.attachedMeetingID == nil {
            let other = URL(fileURLWithPath: source.path).standardizedFileURL.resolvingSymlinksInPath().path
            if path == other || (source.kind == .folder && path.hasPrefix(other + "/")) { return .alreadyIncluded(in: source.displayName) }
            if isDirectory, other.hasPrefix(path + "/") { return .containsExisting(source.displayName) }
        }
        return .ok
    }
}
