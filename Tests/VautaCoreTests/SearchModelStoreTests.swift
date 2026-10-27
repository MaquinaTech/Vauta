// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
import VautaMLX
@testable import VautaCore

@Suite("Search model: pinned manifest")
struct SearchModelManifestTests {
    private func fixtureJSON(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/SearchModel/\(name)")
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func theSourceTableEqualsTheDerivedManifest() throws {
        let m = try fixtureJSON("text_manifest.json")
        let spec = SearchModelSpec.pinned
        #expect(spec.repository == m["repo"] as? String && spec.revision == m["revision"] as? String)
        #expect(spec.sourceSize == m["source_size"] as? Int && spec.sourceSHA256 == m["source_sha256"] as? String)
        #expect(spec.spanStart == m["span_start"] as? Int && spec.spanEnd == m["span_end"] as? Int && spec.blockSize == m["block_size"] as? Int)
        #expect(spec.assembledSize == m["assembled_size"] as? Int && spec.assembledSHA256 == m["assembled_sha256"] as? String)
        #expect(spec.blocks == m["blocks"] as? [String])
        let tensors = try #require(m["tensors"] as? [[String: Any]])
        #expect(spec.tensors.count == 413 && tensors.count == 413)
        for (t, j) in zip(spec.tensors, tensors) {
            #expect(t.name == j["name"] as? String && t.dtype == j["dtype"] as? String && t.shape == j["shape"] as? [Int])
            #expect(t.offset == j["offset"] as? Int && t.size == j["size"] as? Int && t.sha256 == j["sha256"] as? String)
        }
    }

    @Test func theTableIsConsistentAndTheHeaderIsTheGoldenOne() {
        let spec = SearchModelSpec.pinned
        #expect(spec.isConsistent)
        #expect(spec.blocks.count == 17 && spec.spanSize == 542_005_296 && spec.assembledSize == 542_050_256)
        #expect(spec.tokenizerSize == 32_170_510 && spec.downloadSize == 574_175_806)
        let header = spec.headerBytes()
        #expect(header.count == 44_960 && spec.headerSize == 44_960)
        #expect(SyntheticModel.sha(header) == "b72380822dcf025d280003fdeb790fb2d19505043425b37a074bddbd7f932542")
        #expect(spec.assembledSize == header.count + spec.spanSize)
        #expect(spec.spanEnd - spec.spanStart == spec.spanSize && spec.blockLength(16) == spec.spanSize - 16 * spec.blockSize)
        #expect(spec.resolvePath("model.safetensors") == "/google/embeddinggemma-2/resolve/914f7f89142e33e77833254d9c9b90c3cef7303b/model.safetensors")
    }

    @Test func theHeaderParsesAsASafetensorsHeader() throws {
        // Only the header: the parser checks offsets against the file size, so a stand-in of the right size is not needed; the
        // header is parsed with a zero-filled body as large as the data it describes would be too big for a test, so the parser
        // is shown the real header with its offsets checked against a sparse file.
        let header = SearchModelSpec.pinned.headerBytes()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-sparse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.safetensors")
        try header.write(to: url)
        let fh = try FileHandle(forWritingTo: url)
        try fh.truncate(atOffset: UInt64(SearchModelSpec.pinned.assembledSize))   // sparse: no disk is used
        try fh.close()
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let entries = try SafetensorsFile.parseHeader(data)
        #expect(entries.count == 413)
        #expect(entries["embed_tokens.weight"]?.shape == [262_144, 512])
    }

    @Test func promptsAndDimensionsAreTheRecipe() throws {
        let m = try fixtureJSON("config_sentence_transformers.json")
        let prompts = try #require(m["prompts"] as? [String: String])
        #expect(SearchModelManifest.queryPrompt == prompts["query"] && SearchModelManifest.queryPrompt == prompts["Retrieval-query"])
        #expect(SearchModelManifest.documentPrompt == prompts["document"] && SearchModelManifest.documentPrompt == prompts["Retrieval-document"])
        #expect(SearchModelManifest.dimensions == 256 && SearchModelManifest.maxSequence == 512)
        #expect(SearchModelManifest.spaceModel == "embeddinggemma-2@914f7f89/r1")
        #expect(SemanticRanker.isSearchModelSpace(SearchModelManifest.spaceModel))
    }

    @Test func aSyntheticSpecIsConsistentToo() {
        #expect(SyntheticModel().spec.isConsistent)
    }
}

@Suite("Search model: store, verification and import")
struct SearchModelStoreTests {
    @Test func theStoreLivesNextToButNotInsideTheStoreDirectory() {
        let fixture = ModelFixture(spec: SyntheticModel().spec)
        defer { fixture.cleanup() }
        let store = fixture.store
        #expect(store.root.lastPathComponent == "Vauta Models")
        #expect(store.installDirectory.path.hasSuffix("Vauta Models/embeddinggemma-2/abcdef01"))
        #expect(store.stagingDirectory.deletingLastPathComponent() == store.installDirectory.deletingLastPathComponent())
        let real = SearchModelStore()
        #expect(real.root.lastPathComponent == "Vauta Models" && !real.root.path.contains("/Vauta/"))
    }

    @Test func preparingExcludesFromBackupAndSpotlightAndIsRepeatable() throws {
        let fixture = ModelFixture(spec: SyntheticModel().spec)
        defer { fixture.cleanup() }
        try fixture.store.prepare()
        #expect(fixture.store.isExcludedFromBackup)
        // A rename can drop the attribute: preparing again sets it again.
        var url = fixture.store.root
        var values = URLResourceValues()
        values.isExcludedFromBackup = false
        try url.setResourceValues(values)
        #expect(!fixture.store.isExcludedFromBackup)
        try fixture.store.prepare()
        #expect(fixture.store.isExcludedFromBackup)
        let mode = try FileManager.default.attributesOfItem(atPath: fixture.store.modelParent.path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
        #expect(FileManager.default.fileExists(atPath: fixture.store.root.appendingPathComponent(".metadata_never_index").path))
    }

    @Test func aStagingFolderMeansPartialAndAnInstallRecordMeansInstalled() throws {
        let model = SyntheticModel()
        let fixture = ModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        #expect(fixture.store.disk() == .empty)
        try fixture.store.createStaging()
        #expect(fixture.store.disk() == .partial)
        try model.assembled.write(to: fixture.store.stagedWeights)
        try model.tokenizer.write(to: fixture.store.stagedTokenizer)
        try fixture.store.install(SearchModelInstallRecord(revision: model.spec.revision, assembledSHA256: "x", tokenizerSHA256: "y", source: "import",
                                                           installedAt: Date(), appBuild: "1"))
        guard case .installed(let record) = fixture.store.disk() else { Issue.record("not installed"); return }
        #expect(record.source == "import" && fixture.store.isExcludedFromBackup)
        #expect(fixture.store.bytesOnDisk() >= model.assembled.count + model.tokenizer.count)
    }

    @Test func deletingRemovesEveryFileAndReportsTheFreedSpace() throws {
        let model = SyntheticModel()
        let fixture = ModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        try fixture.store.createStaging()
        try model.assembled.write(to: fixture.store.stagedWeights)
        try model.tokenizer.write(to: fixture.store.stagedTokenizer)
        try fixture.store.install(SearchModelInstallRecord(revision: model.spec.revision, assembledSHA256: "x", tokenizerSHA256: "y", source: "download",
                                                           installedAt: Date(), appBuild: "1"))
        let freed = fixture.store.delete()
        #expect(freed >= model.assembled.count)
        #expect(fixture.store.disk() == .empty && fixture.store.bytesOnDisk() == 0)
    }

    @Test func quickCheckAndFullVerifyCatchEveryChange() throws {
        let model = SyntheticModel()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("m.safetensors")
        try model.assembled.write(to: file)
        #expect(SearchModelVerifier.quickCheck(file: file, spec: model.spec))
        try SearchModelVerifier.fullVerify(file: file, spec: model.spec)
        // A flipped byte in the data: the quick check (size and header) passes, the full verification does not.
        var data = model.assembled
        data[data.count - 5] ^= 1
        try data.write(to: file)
        #expect(SearchModelVerifier.quickCheck(file: file, spec: model.spec))
        #expect(throws: SearchModelError.mismatch) { try SearchModelVerifier.fullVerify(file: file, spec: model.spec) }
        // A flipped byte in the header, a truncated file, an appended byte.
        data = model.assembled
        data[20] ^= 1
        try data.write(to: file)
        #expect(!SearchModelVerifier.quickCheck(file: file, spec: model.spec))
        try model.assembled.dropLast().write(to: file)
        #expect(!SearchModelVerifier.quickCheck(file: file, spec: model.spec))
        #expect(throws: SearchModelError.mismatch) { try SearchModelVerifier.fullVerify(file: file, spec: model.spec) }
        try (model.assembled + Data([0])).write(to: file)
        #expect(throws: SearchModelError.mismatch) { try SearchModelVerifier.fullVerify(file: file, spec: model.spec) }
        #expect(!SearchModelVerifier.quickCheck(file: dir.appendingPathComponent("missing"), spec: model.spec))
    }

    // MARK: Import

    private func files(_ model: SyntheticModel, in dir: URL) throws -> (source: URL, assembled: URL, tokenizer: URL) {
        let s = dir.appendingPathComponent("original.safetensors"), a = dir.appendingPathComponent("text.safetensors"), t = dir.appendingPathComponent("tokenizer.json")
        try model.source.write(to: s)
        try model.assembled.write(to: a)
        try model.tokenizer.write(to: t)
        return (s, a, t)
    }

    @Test func theOriginalFileAndTheTokenizerInstallTheModel() async throws {
        let model = SyntheticModel()
        let fixture = ModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let f = try files(model, in: fixture.root)
        let outcome = try await SearchModelImporter.importFiles([f.source, f.tokenizer], store: fixture.store, appBuild: "t")
        #expect(outcome == .installed)
        #expect(try Data(contentsOf: fixture.store.weightsURL) == model.assembled)
        guard case .installed(let record) = fixture.store.disk() else { Issue.record("not installed"); return }
        #expect(record.source == "import")
    }

    @Test func theAssembledFileCanComeFirstAndTheTokenizerLater() async throws {
        let model = SyntheticModel()
        let fixture = ModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let f = try files(model, in: fixture.root)
        #expect(try await SearchModelImporter.importFiles([f.assembled], store: fixture.store) == .needsTokenizer)
        #expect(fixture.store.disk() == .partial)
        #expect(try await SearchModelImporter.importFiles([f.tokenizer], store: fixture.store) == .installed)
    }

    @Test func aWrongSizeOrAWrongHashIsRefusedAndInstallsNothing() async throws {
        let model = SyntheticModel()
        let fixture = ModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let f = try files(model, in: fixture.root)
        let other = fixture.root.appendingPathComponent("other.bin")
        try Data(count: 123).write(to: other)
        await #expect(throws: SearchModelError.importWrongFile) { try await SearchModelImporter.importFiles([other], store: fixture.store) }
        // The right size with another content.
        var bad = model.source
        bad[bad.count / 2] ^= 1
        try bad.write(to: f.source)
        await #expect(throws: SearchModelError.mismatch) { try await SearchModelImporter.importFiles([f.source, f.tokenizer], store: fixture.store) }
        var badTokenizer = model.tokenizer
        badTokenizer[0] ^= 1
        try badTokenizer.write(to: f.tokenizer)
        await #expect(throws: SearchModelError.mismatch) { try await SearchModelImporter.importFiles([f.tokenizer], store: fixture.store) }
        guard case .installed = fixture.store.disk() else { return }
        Issue.record("nothing should have been installed")
    }

    @Test func aSymbolicLinkIsFollowedLikeInTheHuggingFaceCache() async throws {
        let model = SyntheticModel()
        let fixture = ModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        // snapshots/<revision>/model.safetensors -> ../../blobs/<sha>
        let blobs = fixture.root.appendingPathComponent("hub/models--x/blobs", isDirectory: true)
        let snapshot = fixture.root.appendingPathComponent("hub/models--x/snapshots/rev", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try model.source.write(to: blobs.appendingPathComponent("aaa"))
        try model.tokenizer.write(to: blobs.appendingPathComponent("bbb"))
        let link = snapshot.appendingPathComponent("model.safetensors"), tokenizerLink = snapshot.appendingPathComponent("tokenizer.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../blobs/aaa")
        try FileManager.default.createSymbolicLink(atPath: tokenizerLink.path, withDestinationPath: "../../blobs/bbb")
        #expect(try await SearchModelImporter.importFiles([link, tokenizerLink], store: fixture.store) == .installed)
    }

    @Test func importingNeverTouchesTheNetwork() async throws {
        let log = NetworkActivityLog()
        let model = SyntheticModel()
        let fixture = ModelFixture(spec: model.spec)
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let f = try files(model, in: fixture.root)
        _ = try await SearchModelImporter.importFiles([f.source, f.tokenizer], store: fixture.store)
        #expect(await log.snapshot().isEmpty)
    }
}
