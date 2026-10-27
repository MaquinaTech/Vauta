// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

/// The file-system work of the indexer. It touches the person's disks (a USB drive, a network share that may hang), so it never
/// runs on the actor: each call goes to a thread of its own with a deadline, and a call that does not return ends as "no answer".
struct FileProbe: Sendable {
    /// nil: the file is gone. Sizes and dates are read fresh from the file system.
    var stat: @Sendable (URL) -> (size: Int64, mtime: Double)? = { DocumentIndexer.stat($0) }
    /// Whether the file's bytes are in the cloud only (nil: they are here).
    var notOnThisMac: @Sendable (URL) -> DocumentSkipReason? = { DocumentScanner.notOnThisMac($0) }
    var hash: @Sendable (URL, Int64) -> String? = { DocumentIndexer.hash($0, size: $1) }
    var isLocalVolume: @Sendable (URL) -> Bool = { url in
        (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) ?? true
    }
    /// Lists a source's files.
    var scan: @Sendable (URL, DocumentSource.Kind) async -> DocumentScanner.Result = { root, kind in
        // On a thread that cannot make a File Provider download anything (listing a placeholder folder would fetch it).
        (try? await runOnDedicatedThread { DocumentScanner.scan(root, kind: kind) }) ?? DocumentScanner.Result()
    }
}

/// What asking a file for its size and date came to.
enum StatOutcome: Sendable, Equatable {
    case found(size: Int64, mtime: Double)
    case gone
    /// The disk did not answer in time (a hung network share).
    case noAnswer
}

extension DocumentIndexer {
    /// The longest a listing of one source may take.
    static let scanDeadline: TimeInterval = 600

    /// Derived from the documents key, so the key that seals the image is not also used as an HMAC key.
    func markerKey() async -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: await index.key, salt: Data(), info: Data(CrashMarker.keyLabel.utf8), outputByteCount: 32)
    }

    func setProbe(_ probe: FileProbe) { self.probe = probe }
    func setIODeadline(_ seconds: TimeInterval) { ioDeadline = seconds }

    func statFile(_ url: URL) async -> StatOutcome {
        let stat = probe.stat
        do {
            let answer = try await withDeadline(seconds: ioDeadline) { try await runOnDedicatedThread { stat(url) } }
            guard let answer else { return .gone }
            return .found(size: answer.size, mtime: answer.mtime)
        } catch {
            return .noAnswer
        }
    }

    /// Asked right before a file is opened: nil when the bytes are on this Mac (or the disk did not answer, which the stat reports).
    func offlineReason(_ url: URL) async -> DocumentSkipReason? {
        let check = probe.notOnThisMac
        return (try? await withDeadline(seconds: ioDeadline, { try await runOnDedicatedThread { check(url) } })) ?? nil
    }

    /// nil when the file is large, unreadable, or the disk did not answer in time (the file is then read as a changed one).
    func hashFile(_ url: URL, size: Int64) async -> String? {
        let hash = probe.hash
        return (try? await withDeadline(seconds: ioDeadline * 4, { try await runOnDedicatedThread { hash(url, size) } })) ?? nil
    }

    func volumeIsLocal(_ url: URL) async -> Bool {
        let check = probe.isLocalVolume
        // A volume that does not answer is treated as a network one.
        return (try? await withDeadline(seconds: ioDeadline, { try await runOnDedicatedThread { check(url) } })) ?? false
    }

    /// nil when the listing took too long.
    func scanFolder(_ root: URL, kind: DocumentSource.Kind) async -> DocumentScanner.Result? {
        let scan = probe.scan
        return try? await withDeadline(seconds: Self.scanDeadline) { await scan(root, kind) }
    }

    /// The source did not answer: it is shown as not connected (its files stay waiting) until the next scan finds it again.
    func markUnresponsive(_ id: Int64) {
        guard sources[id] != nil else { return }
        resolved[id] = nil
        unreachable[id] = .disconnected
        watchers[id]?.stop()
        watchers[id] = nil
        publish(force: true)
    }

    /// The source still exists and no erase or restore has happened since `epoch`: the writes of a long operation are still wanted.
    func isCurrent(_ id: Int64, _ epoch: Int) -> Bool { epoch == self.epoch && sources[id] != nil }

    /// Creates or resets a file's row, unless the source was removed (or the store replaced) in the meantime.
    @discardableResult
    func queueFile(_ id: Int64, epoch: Int, _ scanned: ScannedDocumentFile, format: DocumentFormat) async -> Int64? {
        guard isCurrent(id, epoch) else { return nil }
        return try? await index.markPending(source: id, scanned: scanned, format: format)
    }

    /// Characters in the index, kept between files (a SUM over every file once per file is wasted work). Read again from the index
    /// every 100 files and after anything that removes files.
    func indexedCharacters() async -> Int {
        if let cached = charTotal, charReads < 100 {
            charReads += 1
            return cached
        }
        charReads = 0
        let total = (try? await index.totalCharacters()) ?? 0
        charTotal = total
        return total
    }

    func forgetCharacterTotal() { charTotal = nil }
}
