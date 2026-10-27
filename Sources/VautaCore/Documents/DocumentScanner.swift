// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Lists the files of a source that Vauta reads, with what is known without opening them.
///
/// Never followed: symbolic links and Finder aliases, packages (`.app`, `.photoslibrary`), hidden files, Office lock files
/// (`~$…`), `.git`, `node_modules`, `.Trash`. Depth is capped at 16 and a folder at 20,000 files. Files in iCloud that are not
/// on this Mac are listed as skipped: Vauta never starts a download. The same goes for files that another cloud service keeps online only
/// (dataless files of a File Provider) and for Google Drive shortcuts (`.gdoc`, `.gsheet`…), which are never opened.
public enum DocumentScanner {
    public struct Result: Sendable, Equatable {
        public var files: [ScannedDocumentFile] = []
        /// The folder has more files than Vauta reads.
        public var truncated = false
        /// The source folder itself is a placeholder of a cloud service: it was not listed, and the one entry in `files` says so.
        public var rootNotOnThisMac = false
    }

    private static let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey, .isDirectoryKey, .fileSizeKey,
                                                 .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]

    public static func scan(_ root: URL, kind: DocumentSource.Kind) -> Result { scan(root, kind: kind, isDataless: isDataless) }

    static func scan(_ root: URL, kind: DocumentSource.Kind, isDataless: (URL) -> Bool) -> Result {
        var result = Result()
        switch kind {
        case .file:
            if let file = describe(root, relPath: root.lastPathComponent, isDataless: isDataless) { result.files.append(file) }
        case .folder:
            let basePath = root.standardizedFileURL.path
            // The folder itself may be a placeholder: listing it would make the provider fetch its contents.
            if isDataless(root) {
                result.rootNotOnThisMac = true
                result.files.append(ScannedDocumentFile(relPath: root.lastPathComponent + "/", size: 0, mtime: 0, format: nil, skip: .cloudNotDownloaded))
                return result
            }
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else { return result }
            for case let url as URL in walker {
                if Task.isCancelled { break }
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true || values?.isAliasFile == true { if values?.isDirectory == true { walker.skipDescendants() }; continue }
                if values?.isDirectory == true {
                    // A folder the cloud service has not downloaded: listing it would make the provider fetch its contents.
                    // It is kept as a skipped entry (never listed) so the person is told that part of the source was not read.
                    if isDataless(url) {
                        walker.skipDescendants()
                        var relPath = url.standardizedFileURL.path
                        if relPath.hasPrefix(basePath + "/") { relPath.removeFirst(basePath.count + 1) }
                        relPath += "/"
                        if result.files.count < DocumentLimits.maxFilesPerSource {
                            result.files.append(ScannedDocumentFile(relPath: relPath, size: 0, mtime: 0, format: nil, skip: .cloudNotDownloaded))
                        }
                        continue
                    }
                    if name == "node_modules" || name == ".git" || name == ".Trash" || walker.level > DocumentLimits.maxDepth { walker.skipDescendants() }
                    continue
                }
                guard values?.isRegularFile == true, !name.hasPrefix("~$") else { continue }
                var relPath = url.standardizedFileURL.path
                if relPath.hasPrefix(basePath + "/") { relPath.removeFirst(basePath.count + 1) }
                guard let file = describe(url, relPath: relPath, values: values, isDataless: isDataless) else { continue }
                if result.files.count >= DocumentLimits.maxFilesPerSource { result.truncated = true; break }
                result.files.append(file)
            }
        }
        return result
    }

    /// nil for a file Vauta does not read at all (an unknown extension is not listed, so it is never counted as skipped).
    static func describe(_ url: URL, relPath: String, values: URLResourceValues? = nil, isDataless: (URL) -> Bool = DocumentScanner.isDataless) -> ScannedDocumentFile? {
        let ext = url.pathExtension.lowercased()
        let values = values ?? (try? url.resourceValues(forKeys: Set(keys)))
        let size = Int64(values?.fileSize ?? 0)
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let identity = (attributes?[.systemNumber] as? NSNumber).flatMap { dev in (attributes?[.systemFileNumber] as? NSNumber).map { "\(dev):\($0)" } }
        if let format = DocumentFormat.format(forExtension: ext) {
            var skip: DocumentSkipReason?
            if let status = values?.ubiquitousItemDownloadingStatus, status != .current { skip = .iCloudNotDownloaded }
            else if isDataless(url) { skip = .cloudNotDownloaded }
            else if size > DocumentLimits.maxBytes(for: format) { skip = .tooLarge }
            return ScannedDocumentFile(relPath: relPath, size: size, mtime: mtime, fileID: identity, format: format, skip: skip)
        }
        if DocumentFormat.googleDriveExtensions.contains(ext) {
            // Never opened: the file holds a link, and following it would contact an online service.
            return ScannedDocumentFile(relPath: relPath, size: size, mtime: mtime, fileID: identity, format: nil, skip: .googleDriveShortcut)
        }
        if DocumentFormat.exportAsPDFExtensions.contains(ext) {
            return ScannedDocumentFile(relPath: relPath, size: size, mtime: mtime, fileID: identity, format: nil, skip: .exportAsPDF)
        }
        return nil
    }

    /// `SF_DATALESS` (sys/stat.h): the file system lists the file but its bytes are in the cloud. A File Provider (iCloud Drive, Google
    /// Drive, Dropbox, OneDrive) downloads them the moment the file is read, so a dataless file is never opened: `lstat` only reads the
    /// directory entry and downloads nothing.
    static let datalessFlag: UInt32 = 0x4000_0000

    /// Why a file cannot be read now without a download, or nil when its bytes are on this Mac. Asked again right before a file is
    /// hashed, read or recognized: macOS can turn a downloaded file into a placeholder after it was listed.
    static func notOnThisMac(_ url: URL, isDataless: (URL) -> Bool = DocumentScanner.isDataless) -> DocumentSkipReason? {
        if let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus, status != .current {
            return .iCloudNotDownloaded
        }
        return isDataless(url) ? .cloudNotDownloaded : nil
    }

    static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_flags & datalessFlag != 0
    }

    /// The first 16 bytes (hex) of the SHA-256 of a file, read in chunks: to tell a touched file from a changed one and to
    /// follow a rename. nil when the file cannot be read.
    public static func contentHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256Hasher()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
            // End of file is an empty read (or none).
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(chunk)
        }
        return hasher.finish()
    }
}

import CryptoKit

struct SHA256Hasher {
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    func finish() -> String { hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined() }
}

extension DocumentScanner {
    /// Whether a folder scan would list a file at this relative path: no hidden component, nothing under `node_modules`, `.git`
    /// or `.Trash`, no package (a folder with an extension such as `.app`) and not deeper than the depth limit.
    public static func listsRelativePath(_ relPath: String) -> Bool {
        let parts = relPath.split(separator: "/").map(String.init)
        guard let name = parts.last, !name.hasPrefix("."), !name.hasPrefix("~$") else { return false }
        let folders = parts.dropLast()
        // `walker.level` counts the folders above the file; the scan stops going down past the depth limit.
        guard folders.count <= DocumentLimits.maxDepth else { return false }
        for folder in folders {
            if folder.hasPrefix(".") || folder == "node_modules" || folder == "Trash" || (folder as NSString).pathExtension.count > 0 { return false }
        }
        return true
    }
}
