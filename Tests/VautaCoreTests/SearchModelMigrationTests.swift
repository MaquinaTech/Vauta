// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import VautaCore

/// Apple's on-device embeddings were removed: their stored vectors go, the others stay.
@Suite("Search model: removing Apple's embeddings")
struct AppleEmbeddingsRemovalTests {
    @Test func migration24DropsOnlyTheAppleChunks() throws {
        let db = try SQLiteDatabase(image: nil, size: 0)
        try Schema.migrate(db, upTo: 23)
        try db.query("INSERT INTO meetings(id, started_at, ended_at, title) VALUES (1, 0, 1, 'm')")
        for (i, model) in ["apple-nl:com.apple.nl.embedding.latin", "nomic-embed-text", "embeddinggemma-2@914f7f89/r1", "apple-nl:other"].enumerated() {
            try db.query("INSERT INTO chunks(meeting_id, start, end, model, dims, scale, emb, text_key) VALUES (1, ?, ?, ?, 2, 1.0, x'0102', '')",
                         [.real(Double(i)), .real(Double(i) + 1), .text(model)])
        }
        #expect(try Schema.migrate(db))
        let models = try db.query("SELECT model FROM chunks ORDER BY start").map { $0.string(0) }
        #expect(models == ["nomic-embed-text", "embeddinggemma-2@914f7f89/r1"])
        #expect(try Schema.version(of: db) == Schema.currentVersion)
    }

    @Test func theDocumentsIndexDropsAppleVectorsOnceWithoutASchemaChange() async throws {
        let fx = try IndexFixture()
        try await fx.add("a.txt", text: "Alpha\nA passage about launch plans.")
        try await fx.add("b.txt", text: "Beta\nA passage about hiring plans.")
        let apple = EmbeddingSpace(model: "apple-nl:com.apple.nl.embedding.latin", dimensions: 4)
        let other = EmbeddingSpace(model: "nomic-embed-text", dimensions: 4)
        let todo = try await fx.index.passagesNeedingVectors(space: apple, limit: 10)
        #expect(todo.count == 2)
        let q = try #require(VectorIndex.quantize([1, 0, 0, 0]))
        try await fx.index.storeVectors([(id: todo[0].id, q: q.q, scale: q.scale)], space: apple)
        try await fx.index.storeVectors([(id: todo[1].id, q: q.q, scale: q.scale)], space: other)
        #expect(try await fx.index.vectorCount() == 2)
        // An image written before this change has no flag.
        try await fx.index.deleteMetaForTest("apple_nl_dropped")
        try await fx.index.save()
        let key = DocumentIndex.derivedKey(from: .init(data: Data(repeating: 7, count: 32)))
        let reopened = try DocumentIndex(directory: fx.dir.url, key: key)
        #expect(try await reopened.vectorCount() == 1, "only the Apple vector went")
        #expect(try await reopened.passagesNeedingVectors(model: other.model, limit: 5).map(\.id) == [todo[0].id])
        #expect(await reopened.metaForTest("apple_nl_dropped") == "1")
        #expect(try await reopened.totalPassages() == 2, "no rebuild: the passages are untouched")
        // Once: with the flag set, a vector of that name written later is not touched again.
        try await reopened.storeVectors([(id: todo[0].id, q: q.q, scale: q.scale)], space: apple)
        try await reopened.save()
        let again = try DocumentIndex(directory: fx.dir.url, key: key)
        #expect(try await again.vectorCount() == 2)
    }
}

extension DocumentIndex {
    func deleteMetaForTest(_ key: String) throws {
        try db.query("DELETE FROM meta WHERE k = ?", [.text(key)])
        dirty = true
    }

    func metaForTest(_ key: String) -> String? { meta(key) }
}
