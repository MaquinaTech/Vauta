// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import SQLite3
import Testing
@testable import VautaCore

/// The parsers of what comes from outside Vauta's code, fed mutated input (`Fuzz`): a model server's stream, and the
/// store's journal and image formats (which a crafted backup reaches once its password is known). Each ends in a value or an
/// error, never a crash or a hang, and keeps its limits. A failure names the seed and the iteration to reproduce it.
@Suite struct ParserFuzzTests {
    // MARK: A model server's stream

    private static let streams: [Data] = [
        Data("""
            data: {"choices":[{"delta":{"content":"Hello"}}]}

            data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}

            event: message
            data: {"choices":[{"delta":{"content":" world"},
            data: "finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":3,"prompt_tokens_details":{"cached_tokens":4}}}

            : keep-alive
            id: 7
            data: [DONE]

            """.utf8),
        Data(#"{"choices":[{"message":{"content":"Hi there"},"finish_reason":"length"}],"usage":{"prompt_tokens":5},"timings":{"cache_n":3}}"#.utf8),
        Data("event: error\ndata: {\"error\":{\"message\":\"overloaded\",\"code\":503}}\n\n".utf8),
    ]

    /// Feeds `data` as a stream of lines, as `LLMClient` does, and returns the parser, or nil when it threw.
    private static func parse(_ data: Data, maxContent: Int = 4096) -> ChatStreamParser? {
        var parser = ChatStreamParser(maxContentBytes: maxContent, maxPendingBytes: 4096)
        do {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
                guard try parser.consume(String(line)) else { break }
            }
            try parser.finish()
            return parser
        } catch {
            return nil
        }
    }

    @Test func aMutatedServerStreamEndsInAnAnswerOrAnErrorWithinItsLimits() async throws {
        let (parsed, overLimit, seconds) = try await offPool { () -> (Int, [Int], TimeInterval) in
            var rng = SeededGenerator(seed: 2026)
            var (parsed, overLimit) = (0, [Int]())
            let start = Date()
            for i in 0..<Fuzz.iterations {
                guard let parser = Self.parse(Fuzz.mutate(Self.streams[i % Self.streams.count], &rng)) else { continue }
                parsed += 1
                if parser.content.utf8.count >= parser.maxContentBytes { overLimit.append(i) }
            }
            return (parsed, overLimit, Date().timeIntervalSince(start))
        }
        #expect(parsed > 0, "some mutations still parse (the fuzzer reaches the handlers)")
        #expect(overLimit.isEmpty, "seed 2026, iterations \(overLimit.prefix(5)): content past its limit")
        #expect(seconds < 60, "no input made it hang")
    }

    @Test func aServerStreamCannotOverflowTheStackOrTheMemory() throws {
        let deep = String(repeating: "[", count: 3_000)
        #expect(Self.parse(Data("data: \(deep)\n\n".utf8)) != nil, "a nesting no JSON parser takes is not an object: skipped")
        #expect(Self.parse(Data(deep.utf8)) == nil, "nor a body")
        let flood = (0..<2_000).map { _ in #"data: {"choices":[{"delta":{"content":"0123456789"}}]}"# }.joined(separator: "\n")
        #expect(Self.parse(Data(flood.utf8)) == nil, "content past its limit is refused")
        let unended = "data: {\"choices\":\n" + String(repeating: "data: 0123456789\n", count: 1_000)
        #expect(Self.parse(Data(unended.utf8)) == nil, "an event that never ends is refused at its limit")
    }

    // MARK: The journal

    private static func randomOps(_ rng: inout SeededGenerator) -> [JournalOp] {
        (0..<Int.random(in: 0...4, using: &rng)).map { _ in
            JournalOp(sql: ["INSERT INTO t VALUES (?, ?)", "UPDATE t SET a = ? WHERE id = ?", "DELETE FROM t", "SELECT 'ñ, 日本'"]
                        .randomElement(using: &rng)!,
                      params: (0..<Int.random(in: 0...5, using: &rng)).map { _ -> SQLiteValue? in
                switch Int.random(in: 0..<6, using: &rng) {
                case 0: nil
                case 1: .integer(Int64.random(in: .min ... .max, using: &rng))
                case 2: .real(Double.random(in: -1e9...1e9, using: &rng))
                case 3: .text(String((0..<Int.random(in: 0...12, using: &rng)).map { _ in "aé語 \n'".randomElement(using: &rng)! }))
                case 4: .blob(Data((0..<Int.random(in: 0...16, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }))
                default: .ids((0..<Int.random(in: 0...6, using: &rng)).map { _ in Int64.random(in: 1...1_000_000, using: &rng) })
                }
            })
        }
    }

    private static func encoded(_ ops: [JournalOp]) -> Data { copy(Journal.encode(ops)) }

    /// The bytes of a buffer, copied while it is alive (its deinit zeroes them, and ARC may release it right after `bytes`).
    private static func copy(_ buffer: SecretBuffer) -> Data { withExtendedLifetime(buffer) { Data(buffer.bytes) } }

    @Test func journalOperationsReadBackExactly() {
        var rng = SeededGenerator(seed: 11)
        for i in 0..<1_000 {
            let ops = Self.randomOps(&rng)
            let back = try? Journal.decode(Self.encoded(ops))
            #expect(back == ops, "seed 11, iteration \(i)")
            if back != ops { return }
        }
    }

    @Test func aMutatedJournalRecordEndsInOperationsOrAnError() async throws {
        let unstable = try await offPool { () -> [Int] in
            var rng = SeededGenerator(seed: 12)
            var unstable: [Int] = []
            for i in 0..<Fuzz.iterations {
                let data = Fuzz.mutate(Self.encoded(Self.randomOps(&rng)), &rng)
                // Whatever reads must write back to the same bytes: nothing is read that the format can't say.
                guard let ops = try? Journal.decode(data) else { continue }
                if Self.encoded(ops) != data { unstable.append(i) }
            }
            return unstable
        }
        #expect(unstable.isEmpty, "seed 12, iterations \(unstable.prefix(5))")
    }

    // MARK: The store image

    @Test func aMutatedImageEndsInAnImageOrAnErrorWithinItsLimits() async throws {
        let (opened, seconds) = try await offPool { () -> (Int, TimeInterval) in
            var rng = SeededGenerator(seed: 13)
            var image = Data("SQLite format 3\0".utf8)
            image.append(Data((0..<4_000).map { UInt8(truncatingIfNeeded: $0 * 31) }))
            // Random bytes pack as LZ4 literals, which an edit mostly leaves readable: the fuzzer reaches the copy.
            let noise = Data((0..<4_000).map { _ in UInt8.random(in: 0...255, using: &rng) })
            let seeds = try [image, noise, Data(repeating: 7, count: 2_048)].map { seed in
                try seed.withUnsafeBytes { Self.copy(try SnapshotEnvelope.pack($0)) }
            }
            var opened = 0
            let start = Date()
            for i in 0..<Fuzz.iterations {
                guard let image = try? SnapshotEnvelope.unpack(Fuzz.mutate(seeds[i % seeds.count], &rng), maxSize: 1 << 20) else { continue }
                precondition(image.1 <= 1 << 20)
                sqlite3_free(image.0)
                opened += 1
            }
            return (opened, Date().timeIntervalSince(start))
        }
        #expect(opened > 0)
        #expect(seconds < 60)
    }

    // MARK: The settings in a backup

    @Test func aMutatedSettingsPayloadKeepsOnlyAllowedSettingsOfTheirType() async throws {
        let rejected = try await offPool { () -> [Int] in
            guard let seed = BackupPreferences(values: [
                "transcriptionLanguage": .string("es-ES"), "copyProtection": .bool(true), "autoStopMinutes": .int(10),
                "recordHotKey": .data(Data(#"{"keyCode":15,"modifiers":6144}"#.utf8)), "notAllowed": .string("x"),
            ]).encoded() else { return [-1] }
            var rng = SeededGenerator(seed: 14)
            var rejected: [Int] = []
            for i in 0..<Fuzz.iterations {
                let read = BackupPreferences(decoding: Fuzz.mutate(seed, &rng))
                // What is read is what the allow-list accepts, each with its type and size: filtering it again keeps it all.
                if BackupPreferences(values: read.values).values != read.values { rejected.append(i) }
            }
            return rejected
        }
        #expect(rejected.isEmpty, "seed 14, iterations \(rejected.prefix(5))")
    }

    @Test func anImageDeclaringMoreThanAnIntCanHoldIsRefused() {
        for declared: UInt64 in [UInt64(Int.max) + 1, .max] {
            var plain = Data()
            withUnsafeBytes(of: declared.littleEndian) { plain.append(contentsOf: $0) }
            plain.append(1)
            plain.append(Data(repeating: 0, count: 64))
            #expect(throws: StoreError.self) { try SnapshotEnvelope.unpack(plain) }
        }
    }
}
