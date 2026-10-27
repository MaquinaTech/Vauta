// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import Vauta
@testable import VautaCore

/// `Vauta mlx-selftest` is a hidden release check: it parses, it is not in the usage and it prints no content.
@Suite("CLI: mlx-selftest")
struct SelfTestCommandTests {
    @Test func theCommandIsKnownAndParsesItsFlag() throws {
        #expect(LaunchMode.parse(["mlx-selftest"]) == .cli(["mlx-selftest"]))
        let invocation = try CommandInvocation(parsing: ["mlx-selftest", "--model"])
        #expect(invocation.command == "mlx-selftest" && invocation.has("--model") && invocation.positional.isEmpty)
        #expect(throws: CommandInvocation.ParseError.self) { try CommandInvocation(parsing: ["mlx-selftest", "--content"]) }
    }

    @Test func itIsNotListedInTheUsage() {
        #expect(!usage.contains("mlx-selftest") && !usage.contains("selftest"))
    }

    @Test func theExitCodesAreTheDocumentedOnes() {
        #expect(SearchModelSelfTest.ExitCode.pass == 0 && SearchModelSelfTest.ExitCode.fail == 1)
        #expect(SearchModelSelfTest.ExitCode.unsupported == 2 && SearchModelSelfTest.ExitCode.modelMissing == 3)
    }

    @Test func withoutTheModelItReportsExitThreeAndPrintsOnlyCountsAndNames() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: empty) }
        let result = await SearchModelSelfTest.run(includeModel: true, store: SearchModelStore(root: empty))
        // On a Mac without a supported GPU the kernels are skipped (2); otherwise the model is what is missing (3).
        #expect(result.exitCode == SearchModelSelfTest.ExitCode.unsupported || result.exitCode == SearchModelSelfTest.ExitCode.modelMissing)
        let text = result.lines.joined(separator: "\n")
        #expect(text.hasPrefix("mlx-selftest:") && !text.contains(empty.path))
    }

    @Test func goldensMadeByTheAppsOwnEncoderNeverPassInAReleaseBuild() {
        typealias T = SearchModelSelfTest
        #expect(T.goldenVerdict(worst: 0.9999, reference: false, releaseBuild: true).pass == false, "fp16 agreeing with fp32 proves nothing about a shared mistake")
        #expect(T.goldenVerdict(worst: 0.9999, reference: false, releaseBuild: false).pass, "a debug build can still compare with its own goldens")
        #expect(T.goldenVerdict(worst: 0.9999, reference: true, releaseBuild: true).pass)
        #expect(T.goldenVerdict(worst: 0.99, reference: true, releaseBuild: false).pass == false, "below 0.999 fails everywhere")
        #expect(T.goldenVerdict(worst: 0.9999, reference: false, releaseBuild: true).message.contains("make-goldens.py"))
    }
}
