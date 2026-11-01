// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation

public struct SearchModelProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case tokenizer, weights }
    public var phase: Phase
    public var received: Int
    public var total: Int
}

/// Downloads the search model, only the files and byte ranges of the pinned `SearchModelSpec`, only through `AuditedSession`
/// (purpose `modelDownload`) and only after the person clicked Download.
///
/// Flow: resolve each file at huggingface.co (a 302 that is validated, never followed) and fetch it from the CDN host it
/// names, which must be on the allowlist. The tokenizer is one GET. The text tower is 17 Range requests of 32 MiB, each
/// answered with exactly 206, the exact `Content-Range` and the exact length, hashed as it arrives and checked against its
/// pinned block hash before the next one starts. A resumed download keeps the longest verified prefix. When all blocks are in,
/// the 413 tensors and the assembled file are verified; any failure deletes the partial file. The signed CDN URL lives in
/// memory only and its query string is never logged.
actor SearchModelDownloader {
    private let session: AuditedSession
    private let store: SearchModelStore
    private let spec: SearchModelSpec
    private let appBuild: String
    private var cdn: [String: URL] = [:]

    /// Free space kept beyond the download itself.
    static let headroom = 256 << 20

    init(session: AuditedSession, store: SearchModelStore, appBuild: String = SearchModelDownloader.currentBuild) {
        self.session = session
        self.store = store
        self.spec = store.spec
        self.appBuild = appBuild
    }

    static var currentBuild: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev"
    }

    /// The User-Agent of the downloads from Hugging Face: the app's name only. The system's default would also name the build,
    /// the version of macOS's network stack and of Darwin, which the download doesn't need.
    static let userAgent = "Vauta"

    /// A session for the download: ephemeral, no cache, cookies or credentials, system proxies honoured, default TLS trust.
    static func makeSession(protocolClasses: [AnyClass]? = nil, log: NetworkActivityLog = .shared) -> AuditedSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpAdditionalHeaders = ["User-Agent": userAgent]
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCredentialStorage = nil
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 6 * 3600
        if let protocolClasses { c.protocolClasses = protocolClasses }
        return AuditedSession(configuration: c, log: log)
    }

    /// Downloads and installs. `beforeBlock` is awaited before each request (the controller holds it while a recording runs).
    /// Throws `CancellationError` when the task is cancelled; the verified prefix stays in `staging/` for a resume.
    func run(source: String = "download", tokenizerOnly: Bool = false, progress: @escaping @Sendable (SearchModelProgress) -> Void,
             beforeBlock: @Sendable () async throws -> Void = {}) async throws {
        try preflight()
        try store.createStaging()
        do {
            try await fetchTokenizer(progress: progress, beforeBlock: beforeBlock)
            if !tokenizerOnly {
                try await fetchWeights(progress: progress, beforeBlock: beforeBlock)
            }
            guard FileManager.default.fileExists(atPath: store.stagedWeights.path) else { return }
            try Task.checkCancellation()
            let record = SearchModelInstallRecord(revision: spec.revision, assembledSHA256: spec.assembledSHA256,
                                                  tokenizerSHA256: spec.tokenizerSHA256, source: source, installedAt: Date(),
                                                  appBuild: appBuild, verifiedByBuild: appBuild)
            try store.install(record)
        } catch let error as SearchModelError {
            throw error
        } catch {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            let mapped = Self.map(error)
            // A write that ran out of space: what is still missing, not zero.
            if case .diskFull(let needed) = mapped, needed == 0 {
                throw SearchModelError.diskFull(needed: Self.stillNeeded(spec: spec, stagedBytes: store.bytesOnDisk()))
            }
            throw mapped
        }
    }

    /// The free space a download still needs: the whole download and the headroom, less what is already in `staging/`.
    static func stillNeeded(spec: SearchModelSpec, stagedBytes: Int) -> Int {
        max(headroom, spec.downloadSize + headroom - stagedBytes)
    }

    /// Free space for what is still missing: a resumed download counts the verified prefix it already holds.
    func preflight() throws {
        if let free = store.availableCapacity() {
            let needed = Self.stillNeeded(spec: spec, stagedBytes: store.bytesOnDisk())
            if free < needed { throw SearchModelError.diskFull(needed: needed) }
        }
    }

    // MARK: Resolving

    private enum File { case tokenizer, weights }

    private func name(_ f: File) -> String { f == .tokenizer ? spec.tokenizerFile : spec.sourceFile }

    /// Asks huggingface.co where a file is. A 404 means the revision is gone; the redirect must go to an allowed CDN host and, when
    /// the response says which commit, size and hash the file has, they must be the pinned ones.
    private func resolve(_ file: File, refresh: Bool = false) async throws -> URL {
        if !refresh, let url = cdn[name(file)] { return url }
        cdn[name(file)] = nil
        let resolveURL = URL(string: "https://\(SearchModelDestinations.host)\(spec.resolvePath(name(file)))")!
        guard SearchModelDestinations.isAllowedResolve(resolveURL, spec: spec) else {
            await session.refuse(resolveURL, method: "GET", purpose: .modelDownload, reason: .pathNotAllowed)
            throw SearchModelError.hostNotAllowed
        }
        var request = URLRequest(url: resolveURL, timeoutInterval: 60)
        request.httpMethod = "GET"
        // One byte at most if a server ever answered with the file instead of redirecting.
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let response: HTTPURLResponse
        do {
            response = try await session.stream(request, purpose: .modelDownload, accept: { (300..<400).contains($0.statusCode) }, sink: { _ in })
        } catch AuditedStreamError.refused(let r) {
            throw r.statusCode == 404 ? SearchModelError.revisionGone : (r.statusCode >= 500 || r.statusCode == 429 ? .offline : .unexpectedResponse)
        }
        guard let location = response.value(forHTTPHeaderField: "Location"), let target = URL(string: location, relativeTo: resolveURL)?.absoluteURL
        else { throw SearchModelError.unexpectedResponse }
        guard SearchModelDestinations.isAllowedCDN(target) else {
            await session.refuse(target, method: "GET", purpose: .modelDownload, reason: .destinationNotAllowed)
            throw SearchModelError.hostNotAllowed
        }
        if let commit = response.value(forHTTPHeaderField: "X-Repo-Commit"), commit != spec.revision { throw SearchModelError.mismatch }
        let expectedSize = file == .tokenizer ? spec.tokenizerSize : spec.sourceSize
        let expectedHash = file == .tokenizer ? spec.tokenizerSHA256 : spec.sourceSHA256
        if let etag = response.value(forHTTPHeaderField: "X-Linked-Etag"),
           etag.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "W/", with: "") != expectedHash { throw SearchModelError.mismatch }
        if let size = response.value(forHTTPHeaderField: "X-Linked-Size"), Int(size) != expectedSize { throw SearchModelError.mismatch }
        cdn[name(file)] = target
        return target
    }

    /// The answer is the file's own bytes: a compressed body (which the request did not ask for) would have another length than the pinned one.
    static func isUncompressed(_ response: HTTPURLResponse) -> Bool {
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.trimmingCharacters(in: .whitespaces).lowercased() ?? "identity"
        return encoding.isEmpty || encoding == "identity"
    }

    // MARK: Tokenizer

    private func fetchTokenizer(progress: @escaping @Sendable (SearchModelProgress) -> Void, beforeBlock: @Sendable () async throws -> Void) async throws {
        let spec = self.spec
        if (try? SearchModelVerifier.verifyTokenizer(file: store.stagedTokenizer, spec: spec)) != nil {
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
            // The bytes as stored: a compressed answer would make its length differ from the pinned one.
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let size = spec.tokenizerSize
            do {
                _ = try await session.stream(request, purpose: .modelDownload, accept: { r in
                    r.statusCode == 200 && Self.isUncompressed(r) && (r.expectedContentLength < 0 || Int(r.expectedContentLength) == size)
                }, sink: { try sink.write($0) })
            } catch AuditedStreamError.refused(let r) {
                if (r.statusCode == 403 || r.statusCode == 410), !refreshed { refreshed = true; continue }
                throw r.statusCode == 403 || r.statusCode == 410 ? SearchModelError.offline : .unexpectedResponse
            }
            guard sink.received == size, sink.hexDigest() == spec.tokenizerSHA256 else {
                try? fm.removeItem(at: store.stagedTokenizerPart)
                throw SearchModelError.mismatch
            }
            sink.close()
            try? fm.removeItem(at: store.stagedTokenizer)
            try fm.moveItem(at: store.stagedTokenizerPart, to: store.stagedTokenizer)
            return
        }
    }

    // MARK: Weights

    private func fetchWeights(progress: @escaping @Sendable (SearchModelProgress) -> Void, beforeBlock: @Sendable () async throws -> Void) async throws {
        let spec = self.spec
        let fm = FileManager.default
        // An assembled file that was imported earlier and verified.
        if fm.fileExists(atPath: store.stagedWeights.path) {
            if (try? SearchModelVerifier.fullVerify(file: store.stagedWeights, spec: spec)) != nil { return }
            try? fm.removeItem(at: store.stagedWeights)
        }
        let part = store.stagedWeightsPart
        let header = spec.headerBytes()
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        var good = try Self.resume(part: part, spec: spec)
        // Per block: the signed link may be looked up again once after it expired (403/410) and once after a block that did not
        // match. Both are reset when a block is in, so a slow download can renew the link again later.
        var retriedMismatch = false
        var renewedLink = false
        var lookUpAgain = false
        while good < spec.blocks.count {
            try await beforeBlock()
            try Task.checkCancellation()
            let n = spec.blockLength(good)
            let from = spec.blockSourceOffset(good)
            let url = try await resolve(.weights, refresh: lookUpAgain)
            lookUpAgain = false
            let done = spec.tokenizerSize + good * spec.blockSize
            let sink = try BlockSink(url: part, offset: header.count + good * spec.blockSize, limit: n) { got in
                progress(.init(phase: .weights, received: done + got, total: spec.downloadSize))
            }
            defer { sink.close() }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "GET"
            request.setValue("bytes=\(from)-\(from + n - 1)", forHTTPHeaderField: "Range")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let wantRange = "bytes \(from)-\(from + n - 1)/\(spec.sourceSize)"
            do {
                _ = try await session.stream(request, purpose: .modelDownload, accept: { r in
                    r.statusCode == 206 && Self.isUncompressed(r) && r.value(forHTTPHeaderField: "Content-Range") == wantRange
                        && (r.expectedContentLength < 0 || Int(r.expectedContentLength) == n)
                }, sink: { try sink.write($0) })
            } catch AuditedStreamError.refused(let r) {
                if (r.statusCode == 403 || r.statusCode == 410), !renewedLink { renewedLink = true; lookUpAgain = true; continue }
                throw r.statusCode == 403 || r.statusCode == 410 ? SearchModelError.offline : .unexpectedResponse
            }
            guard sink.received == n else { throw SearchModelError.unexpectedResponse }
            if sink.hexDigest() == spec.blocks[good] {
                good += 1
                retriedMismatch = false
                renewedLink = false
                continue
            }
            // A block that does not match: keep the verified prefix, look the file up again and fetch it once more.
            sink.close()
            try Self.truncate(part: part, to: header.count + good * spec.blockSize)
            if retriedMismatch {
                try? fm.removeItem(at: part)
                throw SearchModelError.mismatch
            }
            retriedMismatch = true
            lookUpAgain = true
        }
        let fh = try FileHandle(forUpdating: part)
        do {
            try fh.synchronize()
            try SearchModelVerifier.fullVerify(handle: fh, spec: spec)
            try fh.close()
        } catch {
            try? fh.close()
            try? fm.removeItem(at: part)
            throw error is CancellationError ? error : SearchModelError.mismatch
        }
        try? fm.removeItem(at: store.stagedWeights)
        try fm.moveItem(at: part, to: store.stagedWeights)
    }

    /// Keeps the longest verified prefix of a partial file (header exact, then each block against its hash) and returns how many
    /// blocks it holds. A file with another header is emptied and given the header.
    static func resume(part: URL, spec: SearchModelSpec) throws -> Int {
        let header = spec.headerBytes()
        let fh = try FileHandle(forUpdating: part)
        defer { try? fh.close() }
        let good = try SearchModelVerifier.verifiedBlocks(partial: fh, spec: spec)
        if good == 0 {
            try fh.truncate(atOffset: 0)
            try fh.seek(toOffset: 0)
            try fh.write(contentsOf: header)
        } else {
            try fh.truncate(atOffset: UInt64(header.count + min(good * spec.blockSize, spec.spanSize)))
        }
        return good
    }

    static func truncate(part: URL, to length: Int) throws {
        let fh = try FileHandle(forUpdating: part)
        defer { try? fh.close() }
        try fh.truncate(atOffset: UInt64(length))
    }

    static func map(_ error: Error) -> SearchModelError {
        if let e = error as? SearchModelError { return e }
        if let u = error as? URLError {
            switch u.code {
            case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return .offline
            default: return .offline
            }
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return .diskFull(needed: 0) }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return .diskFull(needed: 0) }
        return .ioError
    }
}

/// Writes a response body to a file at an offset while hashing it. Called from the URL session's delegate queue only.
final class BlockSink: @unchecked Sendable {
    private let fh: FileHandle
    private let limit: Int
    private var hasher = SHA256()
    private var closed = false
    private let report: @Sendable (Int) -> Void
    private(set) var received = 0

    init(url: URL, offset: Int, limit: Int, report: @escaping @Sendable (Int) -> Void) throws {
        fh = try FileHandle(forWritingTo: url)
        self.limit = limit
        self.report = report
        try fh.seek(toOffset: UInt64(offset))
    }

    func write(_ data: Data) throws {
        guard received + data.count <= limit else { throw SearchModelError.unexpectedResponse }
        try fh.write(contentsOf: data)
        hasher.update(data: data)
        received += data.count
        report(received)
    }

    func hexDigest() -> String {
        let copy = hasher
        return hex(copy.finalize())
    }

    func close() {
        guard !closed else { return }
        closed = true
        try? fh.close()
    }
}
