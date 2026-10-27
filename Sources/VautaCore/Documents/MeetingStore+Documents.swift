// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// A folder or file the person added as a knowledge source.
public struct DocumentSource: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case folder, file }

    public let id: Int64
    public var kind: Kind
    public var displayName: String
    /// The last known path, for display and for "Locate…". Never used to open the source: the bookmark is.
    public var path: String
    /// The app-scoped, read-only security-scoped bookmark.
    public var bookmark: Data
    public var volumeUUID: String?
    public var paused: Bool
    /// Set when the source is a single file attached to one meeting as its material.
    public var attachedMeetingID: Int64?
    public var addedAt: Date
    /// The folder holds notes the person exported from Notes. The documents are read like any other; the brief labels their excerpts
    /// "Note".
    public var isNotesExport: Bool

    public init(id: Int64, kind: Kind, displayName: String, path: String, bookmark: Data = Data(), volumeUUID: String? = nil, paused: Bool = false,
                attachedMeetingID: Int64? = nil, addedAt: Date = .now, isNotesExport: Bool = false) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.path = path
        self.bookmark = bookmark
        self.volumeUUID = volumeUUID
        self.paused = paused
        self.attachedMeetingID = attachedMeetingID
        self.addedAt = addedAt
        self.isNotesExport = isNotesExport
    }
}

/// What the person chose to read (the index itself is a separate image: see `DocumentIndex`).
extension MeetingStore {
    static let documentSourceColumns = "id, kind, display_name, path, bookmark, volume_uuid, paused, attached_meeting_id, added_at, is_notes_export"

    private static func documentSource(_ r: Row) -> DocumentSource? {
        guard let kind = DocumentSource.Kind(rawValue: r.string(1)) else { return nil }
        return DocumentSource(id: r.int(0), kind: kind, displayName: r.string(2), path: r.string(3), bookmark: r.data(4), volumeUUID: r.optionalString(5),
                              paused: r.int(6) != 0, attachedMeetingID: r.optionalInt(7), addedAt: Date(timeIntervalSince1970: r.double(8)),
                              isNotesExport: r.int(9) != 0)
    }

    /// Every source, oldest first, including the ones attached to a meeting.
    public func documentSources() throws -> [DocumentSource] {
        try db.query("SELECT \(Self.documentSourceColumns) FROM doc_sources ORDER BY added_at, id").compactMap(Self.documentSource)
    }

    public func documentSource(_ id: Int64) throws -> DocumentSource? {
        try db.query("SELECT \(Self.documentSourceColumns) FROM doc_sources WHERE id = ?", [.integer(id)]).first.flatMap(Self.documentSource)
    }

    /// Adds a source. At most `DocumentLimits.maxSources` library sources.
    @discardableResult
    public func addDocumentSource(kind: DocumentSource.Kind, displayName: String, path: String, bookmark: Data, volumeUUID: String?,
                                  attachedMeeting: Int64? = nil, at date: Date = .now) async throws -> DocumentSource {
        let library = try db.query("SELECT COUNT(*) FROM doc_sources WHERE attached_meeting_id IS NULL")[0].int(0)
        if attachedMeeting == nil, library >= DocumentLimits.maxSources { throw StoreError("Too many document sources.") }
        try run("""
            INSERT INTO doc_sources(kind, display_name, path, bookmark, volume_uuid, paused, attached_meeting_id, added_at)
            VALUES (?, ?, ?, ?, ?, 0, ?, ?)
            """, [.text(kind.rawValue), .text(displayName), .text(path), .blob(bookmark), volumeUUID.map { .text($0) },
                  attachedMeeting.map { .integer($0) }, .real(date.timeIntervalSince1970)])
        let id = db.lastInsertRowID
        try await commitEdit()
        guard let source = try documentSource(id) else { throw StoreError("The source was not saved.") }
        return source
    }

    /// Marks (or unmarks) a folder as holding notes exported from Notes. Nothing is read from Notes itself.
    public func setDocumentSourceNotesExport(_ id: Int64, _ isNotes: Bool) async throws {
        try run("UPDATE doc_sources SET is_notes_export = ? WHERE id = ?", [.integer(isNotes ? 1 : 0), .integer(id)])
        try await commitEdit()
    }

    public func setDocumentSourcePaused(_ id: Int64, _ paused: Bool) async throws {
        try run("UPDATE doc_sources SET paused = ? WHERE id = ?", [.integer(paused ? 1 : 0), .integer(id)])
        try await commitEdit()
    }

    /// After a stale bookmark was renewed, or the person located a moved source.
    public func updateDocumentSource(_ id: Int64, bookmark: Data, path: String, displayName: String? = nil, volumeUUID: String?) async throws {
        try run("UPDATE doc_sources SET bookmark = ?, path = ?, display_name = coalesce(?, display_name), volume_uuid = coalesce(?, volume_uuid) WHERE id = ?",
                [.blob(bookmark), .text(path), displayName.map { .text($0) }, volumeUUID.map { .text($0) }, .integer(id)])
        try await commitEdit()
    }

    /// Removes the source and its bookmark (the index of its files is deleted by the caller).
    public func removeDocumentSource(_ id: Int64) async throws {
        try transaction {
            try run("DELETE FROM doc_sources WHERE id = ?", [.integer(id)])
            // The stored answers lose the claims that cited the removed source.
            try purgeDanglingQuestionCites()
        }
        try await commitEdit()
    }

    // MARK: Meetings' materials

    public func setMeetingsDeletedHandler(_ handler: (@Sendable () -> Void)?) { meetingsDeletedHandler = handler }

    /// The sources attached to a meeting (single files) and the library files linked to it.
    public func meetingMaterials(_ meetingID: Int64) throws -> (attached: [DocumentSource], linked: [(source: Int64, relPath: String)]) {
        let attached = try db.query("SELECT \(Self.documentSourceColumns) FROM doc_sources WHERE attached_meeting_id = ? ORDER BY added_at, id",
                                    [.integer(meetingID)]).compactMap(Self.documentSource)
        let linked = try db.query("SELECT source_id, rel_path FROM meeting_materials WHERE meeting_id = ? ORDER BY rel_path", [.integer(meetingID)])
            .map { (source: $0.int(0), relPath: $0.string(1)) }
        return (attached, linked)
    }

    /// Where Ask looks for a meeting's materials.
    public func materialsFilter(_ meetingID: Int64) throws -> DocumentFilter? {
        let materials = try meetingMaterials(meetingID)
        let entries = materials.attached.map { DocumentFilter.Entry(source: $0.id) } + materials.linked.map { DocumentFilter.Entry(source: $0.source, relPath: $0.relPath) }
        return entries.isEmpty ? nil : DocumentFilter(entries)
    }

    public func linkMaterial(meeting: Int64, source: Int64, relPath: String) async throws {
        try run("INSERT OR IGNORE INTO meeting_materials(meeting_id, source_id, rel_path) VALUES (?, ?, ?)", [.integer(meeting), .integer(source), .text(relPath)])
        try await commitEdit()
    }

    public func unlinkMaterial(meeting: Int64, source: Int64, relPath: String) async throws {
        try run("DELETE FROM meeting_materials WHERE meeting_id = ? AND source_id = ? AND rel_path = ?", [.integer(meeting), .integer(source), .text(relPath)])
        try await commitEdit()
    }

    // MARK: The documents image

    /// The key of the documents image: derived from the store's, so erasing everything (which rotates it) destroys the
    /// index too.
    public func documentsKey() -> SymmetricKey { DocumentIndex.derivedKey(from: key) }

    /// The folder the store and the documents image live in.
    public nonisolated var storeDirectory: URL { file.deletingLastPathComponent() }

    /// How many sources the store holds (the restore sheet says they will be indexed again).
    public func documentSourceCount() throws -> Int { Int(try db.query("SELECT COUNT(*) FROM doc_sources WHERE attached_meeting_id IS NULL")[0].int(0)) }
}
