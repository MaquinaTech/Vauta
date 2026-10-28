// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing

/// Vauta never makes a cloud service download a file (`DocumentIndexer.isNotOnThisMac`): a document opened for viewing is handed to its
/// app only after `isNotOnThisMac` said it is on this Mac. This scans the app for code that opens a document without it.
@Suite("Online-only documents are never opened")
struct CloudPlaceholderScanTests {
    @Test func everyDocumentOpenedForViewingIsCheckedFirst() throws {
        let files = try NetworkAuditSourceScanTests.sourceFiles().filter { $0.path.hasPrefix("Sources/Vauta/") }
        let opening = files.filter { $0.text.contains("openForViewing(") }
        #expect(opening.count >= 2, "the scan must actually see the code that opens documents")
        let unchecked = opening.filter { !$0.text.contains("isNotOnThisMac(") }.map(\.path)
        #expect(unchecked.isEmpty, "Opens a document without checking that it is on this Mac:\n\(unchecked.joined(separator: "\n"))")
        // The brief's file links go through the same guarded open as the meeting's materials.
        let brief = try #require(files.first { $0.path.hasSuffix("MeetingsModel+Brief.swift") })
        #expect(!brief.text.contains("NSWorkspace.shared.open("))
    }
}
