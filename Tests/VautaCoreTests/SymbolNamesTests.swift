// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import AppKit
import Foundation
import Testing

@Suite("Interface: SF Symbols exist")
struct SymbolNamesTests {
    /// Every symbol name written in the menu-bar panel and the captions panel exists on this system:
    /// a name that doesn't leaves an empty icon (it once left the menu-bar item blank).
    @Test func everySymbolInThePanelsExists() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Vauta/App")
        var names: Set<String> = []
        for folder in ["Panel", "Translation"] {
            let directory = root.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
                for line in try String(contentsOf: file, encoding: .utf8).split(separator: "\n") {
                    guard line.contains("systemName:") || line.contains("systemImage:") || line.contains("symbol:")
                            || line.contains("iconButton(") || line.contains("symbol =") else { continue }
                    for match in line.matches(of: /"([a-z0-9]+(?:\.[a-z0-9]+)*)"/) { names.insert(String(match.1)) }
                }
            }
        }
        #expect(names.count > 15, "the scan found only \(names.count) names")
        for name in names.sorted() {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name) is not an SF Symbol")
        }
    }
}
