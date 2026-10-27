// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

public struct LanguageModelProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case tokenizer, downloading, finishing, checking }
    public var phase: Phase
    /// Bytes transferred so far (tokenizer and language tower).
    public var received: Int
    public var total: Int
}

/// Downloads the language model: only the files and byte ranges of the pinned `LanguageModelSpec`, only through
/// `AuditedSession` (purpose `languageModelDownload`) and only after the person asked for it.
///
/// It follows `SearchModelDownloader` (a 302 that is validated and never followed, the CDN host allowlist, `identity`
/// encoding, exactly 206 with the exact `Content-Range` and length, a signed URL kept in memory and resolved again on 403/410)
/// with one difference: the 15 GB language tower of Google's file is not stored. Each 64 MiB Range block is held in memory,
/// hashed as it arrives, compared with its pinned hash, and only then handed to `StreamingQuantizer`, which writes the 4-bit
/// file (about 4.2 GB). A block that does not match is fetched once more; a second mismatch deletes everything. A resumed run
/// restarts at the block that holds the first byte not yet consumed (`progress.json`).
actor LanguageModelDownloader {
    private let session: AuditedSession
    private let store: LanguageModelStore
    private let spec: LanguageModelSpec
    private let appBuild: String
    private var cdn: [String: URL] = [:]

    init(session: AuditedSession, store: LanguageModelStore, appBuild: String = LanguageModelStore.currentBuild) {
        self.session = session
        self.store = store
        self.spec = store.spec
        self.appBuild = appBuild
    }

    func run(source: String = "download", progress: @escaping @Sendable (LanguageModelProgress) -> Void,
             beforeBlock: @escaping @Sendable () async throws -> Void = {}) async throws {
        try preflight()
        try store.createStaging()
        do {
            try await fetchTokenizer(progress: progress, beforeBlock: beforeBlock)
            try await fetchWeights(progress: progress, beforeBlock: beforeBlock)
            try Task.checkCancellation()
            let record = LanguageModelInstallRecord(revision: spec.revision, assembledSHA256: spec.assembledSHA256,
                                                    tokenizerSHA256: spec.tokenizerSHA256, source: source, installedAt: Date(),
                                                    appBuild: appBuild, verifiedByBuild: appBuild)
            try store.install(record)
        } catch let error as IntegratedModelError {
            throw error
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            let mapped = Self.map(error)
            if case .diskFull(let needed) = mapped, needed == 0 {
                throw IntegratedModelError.diskFull(needed: store.stillNeeded(stagedBytes: store.stagingBytes()))
            }
            throw mapped
        }
    }

    func preflight() throws { try store.checkRoomToInstall() }

    // MARK: Resolving

    private enum File { case tokenizer, weights }
    private func name(_ f: File) -> String { f == .tokenizer ? spec.tokenizerFile : spec.sourceFile }

    private func resolve(_ file: File, refresh: Bool = false) async throws -> URL {
        if !refresh, let url = cdn[name(file)] { return url }
        cdn[name(file)] = nil
        let resolveURL = URL(string: "https://\(SearchModelDestinations.host)\(spec.resolvePath(name(file)))")!
        guard Self.isAllowedResolve(resolveURL, spec: spec) else {
            await session.refuse(resolveURL, method: "GET", purpose: .languageModelDownload, reason: .pathNotAllowed)
            throw IntegratedModelError.hostNotAllowed
        }
        var request = URLRequest(url: resolveURL, timeoutInterval: 60)
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let response: HTTPURLResponse
        do {
            response = try await session.stream(request, purpose: .languageModelDownload, accept: { (300..<400).contains($0.statusCode) }, sink: { _ in })
        } catch AuditedStreamError.refused(let r) {
            throw r.statusCode == 404 ? IntegratedModelError.revisionGone : (r.statusCode >= 500 || r.statusCode == 429 ? .offline : .unexpectedResponse)
        }
        guard let location = response.value(forHTTPHeaderField: "Location"), let target = URL(string: location, relativeTo: resolveURL)?.absoluteURL
        else { throw IntegratedModelError.unexpectedResponse }
        guard SearchModelDestinations.isAllowedCDN(target) else {
            await session.refuse(target, method: "GET", purpose: .languageModelDownload, reason: .destinationNotAllowed)
            throw IntegratedModelError.hostNotAllowed
        }
        // The three provenance headers are checked when Hugging Face sends them, and are not required: like the search model's
        // downloader, a response without them is accepted, because they are advisory (the commit is already in the pinned URL) and
        // nothing depends on them for integrity. Every block of the tower is compared with its pinned SHA-256 before it is used, the
        // assembled file with its own, so a source that lied or said nothing cannot get a wrong byte installed.
        if let commit = response.value(forHTTPHeaderField: "X-Repo-Commit"), commit != spec.revision { throw IntegratedModelError.mismatch }
        let expectedSize = file == .tokenizer ? spec.tokenizerSize : spec.sourceSize
        let expectedHash = file == .tokenizer ? spec.tokenizerSHA256 : spec.sourceSHA256
        if let etag = response.value(forHTTPHeaderField: "X-Linked-Etag"),
           etag.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "W/", with: "") != expectedHash { throw IntegratedModelError.mismatch }
        if let size = response.value(forHTTPHeaderField: "X-Linked-Size"), Int(size) != expectedSize { throw IntegratedModelError.mismatch }
        cdn[name(file)] = target
        return target
    }

    /// A request to Hugging Face: https, port 443, no user info, and exactly the path of one of the two files of `spec`.
    static func isAllowedResolve(_ url: URL, spec: LanguageModelSpec) -> Bool {
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.host(percentEncoded: false)?.lowercased() == SearchModelDestinations.host else { return false }
        let path = url.path(percentEncoded: true)
        return path == spec.resolvePath(spec.sourceFile) || path == spec.resolvePath(spec.tokenizerFile)
    }

    // MARK: Tokenizer

    private func fetchTokenizer(progress: @escaping @Sendable (LanguageModelProgress) -> Void, beforeBlock: @escaping @Sendable () async throws -> Void) async throws {
        let spec = self.spec
        if (try? LanguageModelVerifier.verifyTokenizer(file: store.stagedTokenizer, spec: spec)) != nil {
            progress(.init(phase: .tokenizer, received: spec.tokenizerSize, total: spec.downloadSize))
            return
        }
        let fm = FileManager.default
        var refreshed = false
        while true {
            try await beforeBlock()
            try Task.checkCancellation()
            let url = try await resolve(.tokenizer, refresh: refreshed)
            fm.createFile(atPath: store.stagedTokenizerPart.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let sink = try BlockSink(url: store.stagedTokenizerPart, offset: 0, limit: spec.tokenizerSize) { n in
                progress(.init(phase: .tokenizer, received: n, total: spec.downloadSize))
            }
            defer { sink.close() }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "GET"
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let size = spec.tokenizerSize
            do {
                _ = try await session.stream(request, purpose: .languageModelDownload, accept: { r in
                    r.statusCode == 200 && SearchModelDownloader.isUncompressed(r) && (r.expectedContentLength < 0 || Int(r.expectedContentLength) == size)
                }, sink: { try sink.write($0) })
            } catch AuditedStreamError.refused(let r) {
                if (r.statusCode == 403 || r.statusCode == 410), !refreshed { refreshed = true; continue }
                throw r.statusCode == 403 || r.statusCode == 410 ? IntegratedModelError.offline : .unexpectedResponse
            }
            guard sink.received == size, sink.hexDigest() == spec.tokenizerSHA256 else {
                try? fm.removeItem(at: store.stagedTokenizerPart)
                throw IntegratedModelError.mismatch
            }
            sink.close()
            try? fm.removeItem(at: store.stagedTokenizer)
            try fm.moveItem(at: store.stagedTokenizerPart, to: store.stagedTokenizer)
            return
        }
    }

    // MARK: Language tower

    private func fetchWeights(progress: @escaping @Sendable (LanguageModelProgress) -> Void, beforeBlock: @escaping @Sendable () async throws -> Void) async throws {
        let spec = self.spec
        let fm = FileManager.default
        // An assembled file that was imported earlier and verified.
        if fm.fileExists(atPath: store.stagedWeights.path) {
            if (try? LanguageModelVerifier.fullVerify(file: store.stagedWeights, spec: spec)) != nil { return }
            try? fm.removeItem(at: store.stagedWeights)
        }
        let part = store.stagedWeightsPart
        var journal = (try? Data(contentsOf: store.stagedJournal)).flatMap { try? JSONDecoder().decode(StreamingQuantizer.Journal.self, from: $0) }
        let partSize = (try? fm.attributesOfItem(atPath: part.path)[.size]) as? Int
        if partSize != spec.assembledSize { journal = nil }
        let quantizer = try StreamingQuantizer(spec: spec, output: part, fresh: journal == nil)
        // Completed tensors in the partial file are checked again (about 4 s); a damaged one moves the restart back to its source bytes.
        if let given = journal {
            // The read-back hashes about a gigabyte or more of tensors: it waits for a recording like a block does.
            try await beforeBlock()
            progress(.init(phase: .checking, received: spec.tokenizerSize + min(given.resumeOffset, spec.spanSize), total: spec.downloadSize))
            journal = quantizer.resume(from: given)
        }
        // A journal at the end of the tower (repair of a file that only needs checking) has nothing left to fetch.
        let firstBlock = (journal?.resumeOffset ?? 0) >= spec.spanSize ? spec.blocks.count : (journal?.resumeOffset ?? 0) / spec.blockSize
        let sink = PendingFeed(quantizer: quantizer)
        let blockCount = spec.blocks.count
        // Up to `Self.parallelBlocks` Range requests are in flight at once (one connection is slow on many networks); the blocks
        // are consumed strictly in order, each only after its own hash matched.
        var inflight: [Int: Task<Data, Error>] = [:]
        var nextToStart = firstBlock
        func startMore() {
            while nextToStart < blockCount, inflight.count < Self.parallelBlocks {
                let index = nextToStart
                inflight[index] = Task { try await self.downloadBlock(index, progress: progress, beforeBlock: beforeBlock) }
                nextToStart += 1
            }
        }
        startMore()
        var block = firstBlock
        do {
            while block < blockCount {
                try Task.checkCancellation()
                guard let task = inflight.removeValue(forKey: block) else { throw IntegratedModelError.unexpectedResponse }
                startMore()
                let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                // The previous block was quantised while this one downloaded; this one is quantised while the next ones download.
                try await sink.wait()
                try store.saveJournal(quantizer.journal)
                let skip = block == firstBlock ? max(0, (journal?.resumeOffset ?? 0) - block * spec.blockSize) : 0
                sink.start(data, skip: skip)
                block += 1
            }
        } catch {
            inflight.values.forEach { $0.cancel() }
            // Whatever the reason, the background quantiser stops and is awaited before this returns, so a run started right after
            // (Resume) never has two writers on the partial file.
            sink.cancel()
            try? await sink.wait()
            if case IntegratedModelError.mismatch = error {
                try? fm.removeItem(at: part)
                try? fm.removeItem(at: store.stagedJournal)
            }
            throw error
        }
        try await sink.wait()
        // The whole-file check that follows reads the 4 GB file again: not during a recording.
        try await beforeBlock()
        progress(.init(phase: .finishing, received: spec.downloadSize, total: spec.downloadSize))
        do {
            try quantizer.finish()
        } catch {
            try? fm.removeItem(at: part)
            try? fm.removeItem(at: store.stagedJournal)
            throw error is CancellationError ? error : IntegratedModelError.mismatch
        }
        try? fm.removeItem(at: store.stagedWeights)
        try fm.moveItem(at: part, to: store.stagedWeights)
        try? fm.removeItem(at: store.stagedJournal)
    }

    static let parallelBlocks = 3

    /// One Range block, in memory, with its hash checked: fetched again once after a mismatch (and after a 403 or 410, resolving the
    /// address again); a second mismatch is an error.
    private func downloadBlock(_ index: Int, progress: @escaping @Sendable (LanguageModelProgress) -> Void,
                               beforeBlock: @escaping @Sendable () async throws -> Void) async throws -> Data {
        let spec = self.spec
        var retriedMismatch = false
        var renewedLink = false
        var lookUpAgain = false
        while true {
            try await beforeBlock()
            try Task.checkCancellation()
            let n = spec.blockLength(index)
            let from = spec.blockSourceOffset(index)
            let url = try await resolve(.weights, refresh: lookUpAgain)
            lookUpAgain = false
            let buffer = BlockBuffer(limit: n) { _ in }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "GET"
            request.setValue("bytes=\(from)-\(from + n - 1)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let wantRange = "bytes \(from)-\(from + n - 1)/\(spec.sourceSize)"
            do {
                _ = try await session.stream(request, purpose: .languageModelDownload, accept: { r in
                    r.statusCode == 206 && SearchModelDownloader.isUncompressed(r) && r.value(forHTTPHeaderField: "Content-Range") == wantRange
                        && (r.expectedContentLength < 0 || Int(r.expectedContentLength) == n)
                }, sink: { try buffer.write($0) })
            } catch AuditedStreamError.refused(let r) {
                if (r.statusCode == 403 || r.statusCode == 410), !renewedLink { renewedLink = true; lookUpAgain = true; continue }
                throw r.statusCode == 403 || r.statusCode == 410 ? IntegratedModelError.offline : .unexpectedResponse
            }
            guard buffer.received == n else { throw IntegratedModelError.unexpectedResponse }
            if buffer.hexDigest() == spec.blocks[index] {
                progress(.init(phase: .downloading, received: spec.tokenizerSize + min((index + 1) * spec.blockSize, spec.spanSize), total: spec.downloadSize))
                return buffer.data
            }
            if retriedMismatch { throw IntegratedModelError.mismatch }
            retriedMismatch = true
            lookUpAgain = true
        }
    }

    static func map(_ error: Error) -> IntegratedModelError {
        if let e = error as? IntegratedModelError { return e }
        if error is URLError { return .offline }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return .diskFull(needed: 0) }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return .diskFull(needed: 0) }
        return .ioError
    }
}

extension LanguageModelStore {
    func saveJournal(_ journal: StreamingQuantizer.Journal) throws {
        try JSONEncoder().encode(journal).write(to: stagedJournal, options: .atomic)
    }
}

/// One Range block in memory, hashed as it arrives. Written from the URL session's delegate queue only.
final class BlockBuffer: @unchecked Sendable {
    private(set) var data = Data()
    private var hasher = SHA256()
    private let limit: Int
    private let report: @Sendable (Int) -> Void
    var received: Int { data.count }

    init(limit: Int, report: @escaping @Sendable (Int) -> Void) {
        self.limit = limit
        self.report = report
        data.reserveCapacity(limit)
    }

    func write(_ chunk: Data) throws {
        guard data.count + chunk.count <= limit else { throw IntegratedModelError.unexpectedResponse }
        data.append(chunk)
        hasher.update(data: chunk)
        report(data.count)
    }

    func hexDigest() -> String {
        let copy = hasher
        return hex(copy.finalize())
    }
}

/// Runs `StreamingQuantizer.feed` for one verified block in the background while the next block downloads. At most one at a time.
final class PendingFeed: @unchecked Sendable {
    private let quantizer: StreamingQuantizer
    private var task: Task<Void, Error>?

    init(quantizer: StreamingQuantizer) { self.quantizer = quantizer }

    func start(_ data: Data, skip: Int) {
        let q = quantizer
        task = Task.detached(priority: .utility) {
            try data.withUnsafeBytes { raw in
                try q.feed(UnsafeRawBufferPointer(rebasing: raw[skip...]))
            }
        }
    }

    func cancel() { quantizer.cancel() }

    func wait() async throws {
        guard let t = task else { return }
        task = nil
        try await t.value
    }
}
