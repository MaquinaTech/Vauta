// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Storage: voice profiles and speaker export")
struct StorageVoiceProfileTests {
    private let consent = Date(timeIntervalSince1970: 1_700_000_000)

    private func person(_ store: MeetingStore, _ name: String) async throws -> Int64 {
        try await store.saveEntity(EntityDraft(kind: .person, name: name))
    }

    private func vector(_ seed: UInt8, count: Int = 128) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: Int($0) &* 31 &+ Int(seed)) }) }

    @Test func addingNeedsAPersonAModelAndAnEmbedding() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let ana = try await person(store, "Ana")
        let project = try await store.saveEntity(EntityDraft(kind: .project, name: "Atlas"))
        await #expect(throws: KnowledgeError.entityGone) { try await store.addVoiceProfile(entityID: project, modelID: "m1", embedding: vector(1), consentRecordedAt: consent) }
        await #expect(throws: KnowledgeError.entityGone) { try await store.addVoiceProfile(entityID: 12_345, modelID: "m1", embedding: vector(1), consentRecordedAt: consent) }
        await #expect(throws: StoreError.self) { try await store.addVoiceProfile(entityID: ana, modelID: "  ", embedding: vector(1), consentRecordedAt: consent) }
        await #expect(throws: StoreError.self) { try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: Data(), consentRecordedAt: consent) }
        await #expect(throws: StoreError.self) {
            try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: Data(count: MeetingStore.maxVoiceEmbeddingBytes + 1), consentRecordedAt: consent)
        }
        await #expect(throws: StoreError.self) { try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: vector(1), consentRecordedAt: .now + 3_600) }
        #expect(try await store.rowCount("voice_profiles") == 0)
        let id = try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: vector(1), consentRecordedAt: consent)
        let profile = try #require(try await store.voiceProfiles(entityID: ana).first)
        #expect(profile.id == id && profile.modelID == "m1" && profile.consentRecordedAt == consent && profile.sourceMeetingID == nil)
    }

    @Test func aProfileOfAnotherModelIsNeverMatched() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let ana = try await person(store, "Ana")
        try await store.addVoiceProfile(entityID: ana, modelID: "wespeaker-1", embedding: vector(1), consentRecordedAt: consent)
        try await store.addVoiceProfile(entityID: ana, modelID: "wespeaker-2", embedding: vector(2), consentRecordedAt: consent)
        #expect(try await store.voiceProfileEmbeddings(modelID: "wespeaker-1").map(\.embedding) == [vector(1)])
        #expect(try await store.voiceProfileEmbeddings(modelID: "wespeaker-2").map(\.embedding) == [vector(2)])
        #expect(try await store.voiceProfileEmbeddings(modelID: "wespeaker-3").isEmpty)
        #expect(try await store.voiceProfileEmbeddings(modelID: "Wespeaker-1").isEmpty, "the model ID is compared exactly")
        #expect(try await store.voiceProfiles().count == 2, "unusable profiles still list, so the user can delete them")
    }

    @Test func aPersonKeepsAtMostTenAndOtherModelsGoFirst() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let ana = try await person(store, "Ana"), luis = try await person(store, "Luis")
        try await store.addVoiceProfile(entityID: luis, modelID: "m1", embedding: vector(99), consentRecordedAt: consent)
        for seed in 0..<3 { try await store.addVoiceProfile(entityID: ana, modelID: "old", embedding: vector(UInt8(seed)), consentRecordedAt: consent) }
        for seed in 0..<9 { try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: vector(UInt8(10 + seed)), consentRecordedAt: consent) }
        let anas = try await store.voiceProfiles(entityID: ana)
        #expect(anas.count == 10)
        #expect(anas.filter { $0.modelID == "old" }.count == 1, "the new model's profiles pushed the old model's out first")
        try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: vector(40), consentRecordedAt: consent)
        let after = try await store.voiceProfiles(entityID: ana)
        #expect(after.count == 10 && after.allSatisfy { $0.modelID == "m1" })
        #expect(try await store.voiceProfiles(entityID: luis).count == 1, "the cap is per person")
    }

    @Test func deletingIsPerPersonOrAllAndLeavesNothingOnDisk() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        let ana = try await person(store!, "Ana"), luis = try await person(store!, "Luis")
        let secret = Data((0..<48).map { UInt8(($0 * 13 + 5) % 251) })
        try await store!.addVoiceProfile(entityID: ana, modelID: "m1", embedding: secret, consentRecordedAt: consent)
        try await store!.addVoiceProfile(entityID: ana, modelID: "m1", embedding: vector(2), consentRecordedAt: consent)
        let keep = try await store!.addVoiceProfile(entityID: luis, modelID: "m1", embedding: vector(3), consentRecordedAt: consent)
        #expect(try await store!.plainImage().range(of: secret) != nil)
        #expect(try await store!.deleteVoiceProfiles(entityID: ana) == 2)
        #expect(try await store!.deleteVoiceProfiles(entityID: ana) == 0)
        #expect(try await store!.voiceProfiles().map(\.id) == [keep])
        #expect(try await store!.plainImage().range(of: secret) == nil, "the freed pages are zeroed")
        #expect(try await store!.deleteVoiceProfile(keep))
        try await store!.addVoiceProfile(entityID: luis, modelID: "m1", embedding: vector(4), consentRecordedAt: consent)
        #expect(try await store!.deleteAllVoiceProfiles() == 1)
        #expect(try await store!.rowCount("voice_profiles") == 0)
        #expect(!fx.exists(fx.journalURL), "the delete is already in a snapshot, which replaces the journal")
        store = nil
        #expect(try await fx.open().rowCount("voice_profiles") == 0)
    }

    @Test func deletingAMeetingKeepsTheProfileButForgetsTheMeeting() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana")
        try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: vector(1), consentRecordedAt: consent, sourceMeetingID: m.meeting)
        try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: vector(2), consentRecordedAt: consent, sourceMeetingID: 31_337)
        #expect(try await store.voiceProfiles(entityID: ana).map(\.sourceMeetingID).contains(31_337) == false)
        try await store.deleteMeeting(m.meeting)
        #expect(try await store.voiceProfiles(entityID: ana).allSatisfy { $0.sourceMeetingID == nil })
    }

    // MARK: Export

    @Test func jsonGainsSpeakersOnlyWhenTheMeetingHasThemAndNeverEmbeddings() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await person(store, "Ana")
        try await m.finalize()
        try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        let print = vector(77, count: 96)
        try await store.addVoiceProfile(entityID: ana, modelID: "m1", embedding: print, consentRecordedAt: consent, sourceMeetingID: m.meeting)

        let export = try #require(try await store.meetingExport(m.meeting))
        #expect(export.speakers.map(\.label) == ["Me", "Speaker 1", "Speaker 2"])
        let options = ExportRendererTests.options
        let json = try MeetingExportJSON.encode(export, options: options)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let speakers = try #require(object["speakers"] as? [[String: Any]])
        #expect(speakers.count == 3)
        #expect(speakers[1]["name"] as? String == "Ana" && speakers[1]["channel"] as? String == "others" && speakers[1]["talkSeconds"] as? Double == 2)
        #expect(speakers[0]["name"] is NSNull && speakers[2]["name"] is NSNull)
        let lines = try #require(object["transcript"] as? [[String: Any]])
        #expect(lines[1]["speakerId"] as? Int64 == export.speakers[1].id)
        #expect(lines[2]["overlap"] as? Bool == true && lines[2]["confidence"] as? Double == 0.7)
        #expect(lines[0]["speaker"] as? String == "Me", "the existing keys keep their meaning")
        #expect(lines[1]["name"] is NSNull, "the channel-level name is unchanged")

        // No format carries a voice fingerprint, in any encoding.
        let encodings = [print.base64EncodedString(), print.map { String(format: "%02x", $0) }.joined(), "embedding", "voice", "m1"]
        var outputs = [json]
        for format in MeetingExportFormat.allCases { if let text = format.render(export, options: options) { outputs.append(text) } }
        for text in outputs { for needle in encodings { #expect(!text.contains(needle), "\(needle.prefix(12))") } }
        #expect(!json.contains("consent"))

        // The other formats keep today's output.
        var plain = export
        plain.speakers = []
        for i in plain.transcript.indices { plain.transcript[i].speaker = nil }
        for format in MeetingExportFormat.allCases where format != .json && format != .pdf {
            #expect(format.render(export, options: options) == format.render(plain, options: options), "\(format)")
        }
    }

    @Test func speakersAreListedWhenTheTranscriptIsEmpty() throws {
        var export = MeetingExport(title: "t", startedAt: ExportRendererTests.date(2026, 10, 6, 8))
        export.speakers = [.init(id: 4, channel: .others, label: "Speaker 1", name: nil, talkSeconds: 1.23456)]
        let json = try MeetingExportJSON.encode(export, options: ExportRendererTests.options)
        #expect(json.contains("\"talkSeconds\" : 1.235") && json.contains("\"label\" : \"Speaker 1\""))
        export.speakers = []
        #expect(!(try MeetingExportJSON.encode(export, options: ExportRendererTests.options)).contains("speakers"))
    }

    @Test func speakersAreNotExportedWithoutTheTranscript() throws {
        var export = MeetingExport(title: "t", startedAt: ExportRendererTests.date(2026, 10, 6, 8))
        export.speakers = [.init(id: 4, channel: .others, label: "Speaker 1", name: "Ana", talkSeconds: 1.2)]
        var options = ExportRendererTests.options
        options.includeTranscript = false
        let json = try MeetingExportJSON.encode(export, options: options)
        #expect(!json.contains("speakers") && !json.contains("Ana"))
    }

    @Test func voiceModelsNeverPrintTheirBytes() {
        let e = VoiceProfileEmbedding(profileID: 3, entityID: 4, embedding: Data([1, 2, 3]))
        #expect(!"\(e)".contains("1, 2") && !String(reflecting: e).contains("[1"))
    }
}
