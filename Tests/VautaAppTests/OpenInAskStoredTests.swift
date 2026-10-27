// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CryptoKit
import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

private final class StoredKey: DatabaseKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    func existingKey() throws -> SymmetricKey? { lock.withLock { key } }
    func createKey() throws -> SymmetricKey { lock.withLock { let k = SymmetricKey(size: .bits256); key = k; return k } }
    func remove() throws { lock.withLock { key = nil } }
    func replace(with key: SymmetricKey) throws { lock.withLock { self.key = key } }
}

/// Open in Ask shows a stored live answer: a claim whose sources are gone is never shown as verified.
@Suite("Live answers: Open in Ask")
@MainActor
struct OpenInAskStoredTests {
    @Test func aClaimWhoseSourcesAreGoneIsDroppedAndTheProseIsRebuilt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-ask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: StoredKey())
        let meeting = try await store.startMeeting(at: Date())
        let segment = try await store.append(Segment(channel: .others, start: 12, end: 15, text: "We keep the budget as it is", isFinal: true), to: meeting)
        let ask = AskModel(store: store)
        let content = AutoAnswerContent(answer: "Budget kept. Ana signed it.", claims: [
            .init(text: "Budget kept.", cites: [.init(kind: .thisMeeting, segmentID: segment, meetingID: meeting, t: 12)]),
            .init(text: "Ana signed it.", cites: [.init(kind: .pastMeeting, segmentID: 99_999, meetingID: 99, t: 5, title: "Gone", date: 0)]),
        ])
        await ask.show(stored: content, question: "Did we keep the budget?", thisMeeting: meeting)
        let answer = try #require(ask.answer)
        #expect(answer.claims.map(\.text) == ["Budget kept."] && answer.claims.allSatisfy { $0.verified && !$0.citations.isEmpty })
        #expect(answer.answer == "Budget kept.", "what the dropped claim said does not stay in the prose")
    }

    @Test func whenNoClaimKeepsASourceTheAnswerIsNotShownAsVerified() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-ask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: StoredKey())
        let meeting = try await store.startMeeting(at: Date())
        let ask = AskModel(store: store)
        let content = AutoAnswerContent(answer: "Ana signed it.", claims: [
            .init(text: "Ana signed it.", cites: [.init(kind: .pastMeeting, segmentID: 99_999, meetingID: 99, t: 5, title: "Gone", date: 0)])])
        await ask.show(stored: content, question: "Who signed?", thisMeeting: meeting)
        let answer = try #require(ask.answer)
        #expect(answer.kind != .verified && answer.claims.isEmpty && !answer.answer.contains("Ana"))
        #expect(!ask.showsStored, "no claim is left, so the footer \"found during the recording\" does not apply")
    }

    @Test func aDocumentCitationOfARemovedSourceIsNotShownAsVerified() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-ask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try MeetingStore(directory: dir, keyStore: StoredKey())
        let meeting = try await store.startMeeting(at: Date())
        let ask = AskModel(store: store)
        let cite = AutoAnswerContent.Cite(kind: .document, fileName: "a.pdf", locator: "p. 1", sourceID: 4_242, relPath: "a.pdf", passageID: 1, quote: "q",
                                          key: "k", format: DocumentFormat.pdf.rawValue, place: .page(1))
        let content = AutoAnswerContent(answer: "From the file.", claims: [.init(text: "From the file.", cites: [cite])])
        await ask.show(stored: content, question: "What does it say?", thisMeeting: meeting)
        let answer = try #require(ask.answer)
        #expect(answer.claims.isEmpty && answer.kind != .verified && !ask.showsStored)
    }
}
