// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing

/// The sanitizers workflow skips the suites that run a model on the GPU (`GPU_SUITES` in `.github/workflows/sanitizers.yml`).
/// The list is written by hand, so this keeps it honest: every suite marked `.gpuExclusive` is skipped (a new one is not run
/// under the sanitizers by accident), and every name in it is a suite of the tests (a renamed one does not start running).
@Suite("CI: the sanitizers skip exactly the GPU suites")
struct SanitizerWorkflowTests {
    static let root = NetworkAuditSourceScanTests.packageRoot()

    /// The suite names in `GPU_SUITES`.
    static func skipped() throws -> Set<String> {
        let workflow = try String(contentsOf: root.appending(path: ".github/workflows/sanitizers.yml"), encoding: .utf8)
        let line = try #require(workflow.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("GPU_SUITES:") })
        let value = line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        return Set(value.split(separator: "|").map(String.init))
    }

    /// Every suite type of the test sources, and whether its `@Suite` attribute has `.gpuExclusive`.
    static func suites() throws -> [String: Bool] {
        // The traits up to the declaration that follows them, never into the next `@Suite(`; other attributes may come between.
        let pattern = try NSRegularExpression(pattern: #"@Suite\(((?:(?!@Suite\().)*?)\)\s*(?:@\w+(?:\([^)]*\))?\s*)*"#
                                                  + #"(?:(?:public|internal|private|fileprivate|final)\s+)*(?:struct|class|enum|actor)\s+(\w+)"#,
                                              options: .dotMatchesLineSeparators)
        var out: [String: Bool] = [:]
        let tests = root.appending(path: "Tests")
        let walker = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = NetworkAuditSourceScanTests.code(try String(contentsOf: url, encoding: .utf8))
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let traits = Range(match.range(at: 1), in: text), let name = Range(match.range(at: 2), in: text) else { continue }
                out[String(text[name])] = text[traits].contains(".gpuExclusive")
            }
        }
        return out
    }

    @Test func everyGPUSuiteIsSkippedAndEverySkippedNameIsASuite() throws {
        let skipped = try Self.skipped()
        let suites = try Self.suites()
        #expect(suites.count > 100, "the scan found \(suites.count) suites: the pattern no longer matches how suites are declared")
        let gpu = Set(suites.filter { $0.value }.keys)
        #expect(!gpu.isEmpty)
        #expect(gpu.subtracting(skipped).isEmpty, "marked .gpuExclusive but run under the sanitizers: \(gpu.subtracting(skipped).sorted())")
        #expect(skipped.subtracting(suites.keys).isEmpty, "in GPU_SUITES but not a suite: \(skipped.subtracting(suites.keys).sorted())")
    }
}
