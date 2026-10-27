// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Storage: candidate entities and named speakers")
struct CandidateEntitiesSpeakersTests {
    @Test func peopleNamedOnTheSpeakersReachTheModelFirstButSuggestionsDoNot() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let m = try await SpeakerMeeting.make(store)
        let ana = try await store.saveEntity(EntityDraft(kind: .person, name: "Ana Named"))
        let bruno = try await store.saveEntity(EntityDraft(kind: .person, name: "Bruno Profile"))
        let carla = try await store.saveEntity(EntityDraft(kind: .person, name: "Carla Suggested"))
        try await m.finalize(extra: [SpeakerDraft(channel: .others, ordinal: 3, entityID: bruno, source: .suggested, confidence: 0.9),
                                     SpeakerDraft(channel: .others, ordinal: 4, entityID: carla, source: .suggested, confidence: 0.5)])
        _ = try await store.assignSpeaker(try await m.speaker(.others, 1).id, toEntity: ana)
        // More confirmed people, seen more recently, that would fill a small window.
        for index in 0..<8 { _ = try await store.saveEntity(EntityDraft(kind: .person, name: "Filler \(index)")) }
        let me = try await store.selfEntity()
        let picked = Set(try await store.candidateEntities(m.meeting, limit: 3).map(\.id))
        #expect(picked == [ana, bruno, me], "the named speakers and the user come first; the suggestion stays out")
        #expect(Set(try await store.candidateEntities(m.meeting, limit: 200).map(\.id)).contains(carla), "a confirmed person is still a candidate, just not first")
    }
}
