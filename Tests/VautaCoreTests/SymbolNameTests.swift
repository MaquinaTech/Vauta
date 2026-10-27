// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import Testing

/// An SF Symbol that does not exist draws an empty icon slot (and misaligns what is next to it), so every symbol name
/// written in the app's code must resolve on the Mac that builds it.
@Suite("SF Symbol names")
struct SymbolNameTests {
    @Test func everySymbolNamedInTheSourcesExists() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Vauta")
        let pattern = try NSRegularExpression(pattern: #"(?:systemName|systemImage|systemSymbolName|symbol):\s*"([a-z0-9]+(?:\.[a-z0-9]+)*)""#)
        var names: [String: String] = [:]
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { names[String(text[range])] = url.lastPathComponent }
            }
        }
        #expect(names.count > 20, "the scan found the symbols")
        for (name, file) in names.sorted(by: { $0.key < $1.key }) {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(file): no symbol called \(name)")
        }
    }
}
