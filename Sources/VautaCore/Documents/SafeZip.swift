// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Compression
import Foundation

/// A strict reader of the ZIP files that Office documents are. It trusts nothing in the archive.
///
/// - Only the central directory is read (found from the end-of-central-directory record); each local header is checked
///   against it and a mismatch rejects the file.
/// - Stored and deflate entries only. ZIP64, encrypted entries, other methods, more than 5,000 entries, names with `..`,
///   a leading `/` or a NUL are rejected.
/// - Only the entries a format needs are read, by exact name, never "every entry" and never nested archives.
/// - Decompression is streamed with an output cap of the declared size plus one byte; an entry that exceeds its
///   declared size, a ratio above 200:1, an entry above 64 MB or more than 200 MB in total for the file are rejected.
/// - The CRC-32 of each entry is checked.
public struct SafeZip: Sendable {
    public struct Limits: Sendable {
        public var maxEntries = 5_000
        public var maxEntryBytes = 64 << 20
        public var maxTotalBytes = 200 << 20
        public var maxRatio = 200
        public init() {}
    }

    struct Entry: Sendable {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc: UInt32
        let compressed: Int
        let size: Int
        let localOffset: Int
    }

    private let data: Data
    private let entries: [Entry]
    private let limits: Limits
    private let counter = Counter()

    /// Running total of what was decompressed from this archive.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        func add(_ n: Int, limit: Int) -> Bool {
            lock.lock(); defer { lock.unlock() }
            total += n
            return total <= limit
        }
    }

    /// Opens the archive's directory. Throws a `DocumentExtractionError` (never anything with file content).
    public init(data: Data, limits: Limits = Limits()) throws {
        self.data = data
        self.limits = limits
        entries = try Self.readDirectory(data, limits: limits)
    }

    /// The names of the entries (for deciding what kind of Office file it is).
    public var names: [String] { entries.map(\.name) }

    public func contains(_ name: String) -> Bool { entries.contains { $0.name == name } }

    /// The uncompressed bytes of the entry `name`, or nil when there is no such entry.
    public func read(_ name: String, maxBytes: Int? = nil) throws -> Data? {
        let matches = entries.filter { $0.name == name }
        guard !matches.isEmpty else { return nil }
        // Two entries with one name: which one an Office reader would use is ambiguous, so none is read.
        guard matches.count == 1, let entry = matches.first else { throw DocumentExtractionError(.unreadable) }
        guard entry.flags & 1 == 0 else { throw DocumentExtractionError(.passwordProtected) }
        let cap = min(maxBytes ?? limits.maxEntryBytes, limits.maxEntryBytes)
        guard entry.size <= cap else { throw DocumentExtractionError(.tooLarge) }
        if entry.compressed > 0, entry.size / max(entry.compressed, 1) > limits.maxRatio, entry.size > 4096 {
            throw DocumentExtractionError(.unreadable)
        }
        guard counter.add(entry.size, limit: limits.maxTotalBytes) else { throw DocumentExtractionError(.tooLarge) }
        let payload = try payloadRange(of: entry)
        let out: Data
        switch entry.method {
        case 0:
            guard entry.compressed == entry.size else { throw DocumentExtractionError(.unreadable) }
            out = data.subdata(in: payload)
        case 8:
            out = try Self.inflate(data.subdata(in: payload), expected: entry.size)
        default:
            throw DocumentExtractionError(.unreadable)
        }
        guard out.count == entry.size, Self.crc32(out) == entry.crc else { throw DocumentExtractionError(.unreadable) }
        return out
    }

    // MARK: Directory

    private static func u16(_ d: Data, _ at: Int) -> UInt16 {
        UInt16(d[d.startIndex + at]) | UInt16(d[d.startIndex + at + 1]) << 8
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(u16(d, at)) | UInt32(u16(d, at + 2)) << 16
    }

    private static func readDirectory(_ data: Data, limits: Limits) throws -> [Entry] {
        let bad = DocumentExtractionError(.unreadable)
        guard data.count >= 22 else { throw bad }
        // The end-of-central-directory record is in the last 64 KB plus the 22 bytes of the record itself.
        let lowest = max(0, data.count - 22 - 65_535)
        var eocd = -1
        var i = data.count - 22
        while i >= lowest {
            if u32(data, i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw bad }
        let diskNumber = u16(data, eocd + 4), directoryDisk = u16(data, eocd + 6)
        let onDisk = Int(u16(data, eocd + 8)), total = Int(u16(data, eocd + 10))
        let directorySize = Int(u32(data, eocd + 12)), directoryOffset = Int(u32(data, eocd + 16))
        // ZIP64: the 16- and 32-bit fields are saturated, or a ZIP64 locator sits before the record. No Office file under
        // the size limits needs it.
        if total == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF { throw bad }
        if eocd >= 20, u32(data, eocd - 20) == 0x0706_4B50 { throw bad }
        guard diskNumber == 0, directoryDisk == 0, onDisk == total, total <= limits.maxEntries, total > 0,
              directoryOffset >= 0, directorySize >= 0, directoryOffset + directorySize <= eocd else { throw bad }
        var out: [Entry] = []
        out.reserveCapacity(total)
        var p = directoryOffset
        let end = directoryOffset + directorySize
        for _ in 0..<total {
            guard p + 46 <= end, u32(data, p) == 0x0201_4B50 else { throw bad }
            let flags = u16(data, p + 8), method = u16(data, p + 10)
            let crc = u32(data, p + 16)
            let compressed = Int(u32(data, p + 20)), size = Int(u32(data, p + 24))
            let nameLength = Int(u16(data, p + 28)), extra = Int(u16(data, p + 30)), comment = Int(u16(data, p + 32))
            let offset = Int(u32(data, p + 42))
            guard compressed != 0xFFFF_FFFF, size != 0xFFFF_FFFF, offset != 0xFFFF_FFFF,
                  p + 46 + nameLength + extra + comment <= end else { throw bad }
            let nameBytes = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLength))
            guard let name = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1),
                  isSafeName(name) else { throw bad }
            out.append(Entry(name: name, method: method, flags: flags, crc: crc, compressed: compressed, size: size, localOffset: offset))
            p += 46 + nameLength + extra + comment
        }
        return out
    }

    /// No `..` component, no leading `/`, no NUL, no backslash tricks.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\0"), !name.contains("\\") else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// Checks the local header against the central one and returns where the entry's bytes are.
    private func payloadRange(of entry: Entry) throws -> Range<Int> {
        let bad = DocumentExtractionError(.unreadable)
        let p = entry.localOffset
        guard p >= 0, p + 30 <= data.count, Self.u32(data, p) == 0x0403_4B50 else { throw bad }
        let method = Self.u16(data, p + 8)
        let nameLength = Int(Self.u16(data, p + 26)), extra = Int(Self.u16(data, p + 28))
        let start = p + 30 + nameLength + extra
        guard method == entry.method, p + 30 + nameLength <= data.count,
              start >= 0, start + entry.compressed <= data.count else { throw bad }
        let nameBytes = data.subdata(in: (data.startIndex + p + 30)..<(data.startIndex + p + 30 + nameLength))
        guard let name = String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1),
              name == entry.name else { throw bad }
        return (data.startIndex + start)..<(data.startIndex + start + entry.compressed)
    }

    // MARK: Inflate

    /// Raw DEFLATE (what `COMPRESSION_ZLIB` decodes), streamed, stopping one byte past `expected`.
    static func inflate(_ input: Data, expected: Int) throws -> Data {
        let bad = DocumentExtractionError(.unreadable)
        if expected == 0 { return Data() }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw bad }
        defer { compression_stream_destroy(&stream) }
        let bufferSize = 64 << 10
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var out = Data()
        out.reserveCapacity(min(expected, 8 << 20))
        return try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { throw bad }
            stream.src_ptr = base
            stream.src_size = raw.count
            while true {
                let status: compression_status = buffer.withUnsafeMutableBufferPointer { dst in
                    stream.dst_ptr = dst.baseAddress!
                    stream.dst_size = bufferSize
                    return compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let produced = bufferSize - stream.dst_size
                if produced > 0 {
                    // One byte past the declared size is enough to know the entry lies.
                    if out.count + produced > expected { throw bad }
                    out.append(contentsOf: buffer[0..<produced])
                }
                switch status {
                case COMPRESSION_STATUS_OK:
                    // No output and nothing left to read: a truncated stream, which would loop forever.
                    if produced == 0, stream.src_size == 0 { throw bad }
                    continue
                case COMPRESSION_STATUS_END: return out
                default: throw bad
                }
            }
        }
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}
