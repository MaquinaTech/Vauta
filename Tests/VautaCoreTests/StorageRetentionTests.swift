// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("Storage deletion, retention and recovery")
struct StorageRetentionTests {
    private let day: TimeInterval = 86_400

    private func record(_ store: MeetingStore, at date: Date = .now, _ text: String) async throws -> Int64 {
        let id = try await store.startMeeting(at: date)
        try await store.append(segment(.me, 0, text), to: id)
        try await store.endMeeting(id, at: date + 60)
        return id
    }

    @Test func deleteLeavesNoTraceInMemoryOrOnDisk() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        let kept = try await record(store!, "la reunión que se queda")
        let gone = "zzborradoxq"
        let other = try await record(store!, "Esto contiene \(gone) y nada más")
        #expect(try await store!.imageContains(gone))
        try await store!.deleteMeeting(other)
        #expect(try await !store!.imageContains(gone), "no trace in the database or the FTS index")
        store = nil
        store = try fx.open()
        #expect(try await !store!.imageContains(gone))
        #expect(try await store!.meetings().map(\.id) == [kept])
    }

    @Test func deleteWhileRecordingDefersCompaction() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let word = "zzdiferidoxq"
        let past = try await record(store, "Algo \(word) que borrar")
        let live = try await store.startMeeting(at: .now)
        try await store.deleteMeeting(past)
        #expect(try await !store.meetings().contains { $0.id == past })
        #expect(await store.compactionPendingForTests())
        try await store.endMeeting(live, at: .now)
        #expect(await !store.compactionPendingForTests())
        #expect(try await !store.imageContains(word))

        await store.forceCompactionPendingForTests()
        try await store.flush()
        #expect(await !store.compactionPendingForTests(), "a pending compaction is retried on the next save")
    }

    @Test func purgeDeletesExpiredMeetingsButNeverTheActiveOne() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let recent = try await record(store, "reciente")
        let word = "zzcaducadaxq"
        let old = try await record(store, at: .now - Double(MeetingStore.retentionDays + 1) * day, "Reunión \(word) antigua")
        let oldActive = try await store.startMeeting(at: .now - Double(MeetingStore.retentionDays + 5) * day)
        try await store.append(segment(.me, 0, "sigue grabando"), to: oldActive)
        #expect(try await store.purgeExpired() == 1)
        let ids = try await store.meetings().map(\.id)
        #expect(!ids.contains(old) && ids.contains(oldActive) && ids.contains(recent))
        try await store.endMeeting(oldActive, at: .now)
        #expect(try await !store.imageContains(word))
    }

    /// Two-speed retention: at `retentionDays` the transcript goes and the
    /// minutes, tasks and mentions stay; a meeting without minutes keeps its
    /// text for a grace period (flagged for distillation); at the knowledge
    /// retention the whole meeting goes.
    @Test func twoSpeedRetentionPurgesRawTextAndKeepsKnowledge() async throws {
        let fx = StoreFixture()
        var store: MeetingStore! = try fx.open(knowledgeDays: 365)
        let kobaltix = try await store.saveEntity(EntityDraft(kind: .project, name: "Kobaltix"))
        let raw = Double(MeetingStore.retentionDays)
        let old = try await record(store, at: .now - (raw + 1) * day, "El zzpurgaxq de la reunión antigua con Kobaltix")
        try await store.saveCard(MeetingCard(summary: "Revisión del contrato", topics: ["contrato"]), of: old)
        let oldTask = try await store.addTask(old, text: "Revisar el contrato", segmentID: nil)
        let noCard = try await record(store, at: .now - (raw + 2) * day, "Reunión sin acta zzsinactaxq")
        let expired = try await record(store, at: .now - (raw + Double(MeetingStore.distillGraceDays) + 1) * day, "zzbrutoxq texto en bruto")
        #expect(try await store.purgeExpired() > 0)

        #expect(try await store.segments(of: old).isEmpty)
        #expect(try await store.card(old)?.summary == "Revisión del contrato")
        #expect(try await store.tasks(old).contains { $0.id == oldTask })
        #expect(try await store.search("zzpurgaxq").isEmpty)
        #expect(try await !store.imageContains("zzpurgaxq"), "secure-delete FTS + VACUUM leave no trace")
        let surfaces = try await store.refs(kobaltix).filter { $0.meeting.id == old }
        #expect(!surfaces.isEmpty && surfaces.allSatisfy { $0.surface == "Kobaltix" && $0.context == nil })
        // Within the grace period a meeting without minutes keeps its text.
        #expect(try await store.segments(of: noCard).count == 1)
        #expect(try await store.meetingsNeedingDistill().contains(noCard))
        // Past it, the text goes even without minutes; the meeting itself stays.
        #expect(try await store.meeting(expired)?.id == expired, "the meeting itself is kept")
        #expect(try await store.segments(of: expired).isEmpty)
        #expect(try await !store.imageContains("zzbrutoxq"))
        #expect(try await !store.meetingsNeedingDistill().contains(expired))

        try await store.flush()
        store = nil
        store = try fx.open(recover: true, knowledgeDays: 365)
        #expect(try await store.meetings().contains { $0.id == old }, "a purged meeting is not treated as empty on reopen")
        try await store.purgeExpired(now: .now + Double(MeetingStore.distillGraceDays + 1) * day)
        #expect(try await store.segments(of: noCard).isEmpty, "after the grace period the text goes even without minutes")
        try await store.purgeExpired(now: .now + 300 * day)
        #expect(try await !store.meetings().contains { $0.id == old }, "at the knowledge retention the whole meeting goes")
        await store.setKnowledgeRetention(days: MeetingStore.retentionDays)
        let both = try await record(store, at: .now - (raw + 5) * day, "Todo se borra a la vez")
        try await store.purgeExpired()
        #expect(try await !store.meetings().contains { $0.id == both }, "with equal retentions everything goes at once")
    }

    @Test func retentionAlsoRunsAtOpen() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        let recent = try await record(store!, "reciente")
        let old = try await record(store!, at: .now - Double(MeetingStore.retentionDays + 2) * day, "antigua")
        store = nil
        store = try fx.open(recover: true)
        let ids = try await store!.meetings().map(\.id)
        #expect(!ids.contains(old) && ids.contains(recent))
    }

    @Test func recoveryClosesOpenMeetingsAndRemovesOnlyOwnTemporaries() async throws {
        let fx = StoreFixture()
        var store: MeetingStore? = try fx.open()
        let kept = try await record(store!, "terminada")
        let cut = try await store!.startMeeting(at: .now)
        try await store!.append(segment(.me, 0, "reunión cortada"), to: cut)
        try await store!.saveIfNeeded()
        store = nil   // crash while recording
        let foreign = fx.dir.appendingPathComponent("other-note.txt")
        let orphan = fx.dir.appendingPathComponent(MeetingStore.tempPrefix + "orphan")
        try Data("x".utf8).write(to: foreign)
        try Data("x".utf8).write(to: orphan)
        store = try fx.open(recover: true)
        let list = try await store!.meetings()
        #expect(Set(list.map(\.id)) == [kept, cut])
        #expect(list.allSatisfy { $0.endedAt != nil })
        #expect(!fx.exists(orphan) && fx.exists(foreign))
    }

    @Test func emptyMeetingIsRemovedWhenItEnds() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        let kept = try await store.endMeeting(id, at: .now)
        #expect(!kept, "the caller can tell that nothing was saved")
        #expect(try await store.meeting(id) == nil)
        #expect(await store.activeMeetingID == nil)
    }

    @Test func meetingWithContentIsReportedAsKept() async throws {
        let fx = StoreFixture()
        let store = try fx.open()
        let id = try await store.startMeeting(at: .now)
        try await store.append(Segment(channel: .others, start: 1, end: 2, text: "Hola", isFinal: true), to: id)
        #expect(try await store.endMeeting(id, at: .now))
        #expect(try await store.meeting(id) != nil)
    }
}
