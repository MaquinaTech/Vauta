// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta

/// A recording dropped on the Meetings window is imported: one audio or video file, nothing else.
@Suite("Meetings: dropping a recording to import it")
struct DropImportTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    @Test func oneAudioOrVideoFileIsTaken() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try file("call.m4a", in: dir), video = try file("call.mov", in: dir), wave = try file("call.wav", in: dir)
        #expect(RecordingImportModel.importable([audio]) == audio)
        #expect(RecordingImportModel.importable([video]) == video)
        #expect(RecordingImportModel.importable([wave]) == wave)
    }

    @Test func anythingElseIsRefused() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = try file("a.m4a", in: dir), other = try file("b.m4a", in: dir), notes = try file("notes.txt", in: dir)
        #expect(RecordingImportModel.importable([audio, other]) == nil, "one recording at a time, as the open panel")
        #expect(RecordingImportModel.importable([notes]) == nil)
        #expect(RecordingImportModel.importable([dir]) == nil, "a folder")
        #expect(RecordingImportModel.importable([]) == nil)
        #expect(RecordingImportModel.importable([URL(string: "https://example.invalid/call.m4a")!]) == nil, "only a file on this Mac")
    }
}
