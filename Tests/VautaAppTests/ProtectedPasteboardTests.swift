// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import Testing
import VautaCore
@testable import Vauta

/// Copied meeting text is marked so clipboard managers skip it. These tests use a private pasteboard, never the general one.
@Suite("Protected pasteboard")
struct ProtectedPasteboardTests {
    @Test func theCopiedItemCarriesTheConcealedAndTransientMarks() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("local.vauta.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(ProtectedPasteboard.copy("Decisions\n- Keep the shell\n", to: board))
        let types = Set((board.types ?? []).map(\.rawValue))
        #expect(types.contains("org.nspasteboard.ConcealedType") && types.contains("org.nspasteboard.TransientType"))
        #expect(types.contains(NSPasteboard.PasteboardType.string.rawValue))
        #expect(board.string(forType: .string) == "Decisions\n- Keep the shell\n")
        #expect(board.pasteboardItems?.count == 1)
    }

    @Test func aSecondCopyReplacesTheFirst() {
        let board = NSPasteboard(name: NSPasteboard.Name("local.vauta.test.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        ProtectedPasteboard.copy("first", to: board)
        ProtectedPasteboard.copy("second", to: board)
        #expect(board.string(forType: .string) == "second" && board.pasteboardItems?.count == 1)
    }

    @Test func copyMinutesUsesTheSameHelper() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Vauta/App/Meetings/MeetingExporter.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("ProtectedPasteboard.copy(text)") && !text.contains("NSPasteboard.general"))
    }
}
