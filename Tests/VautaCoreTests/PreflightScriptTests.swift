// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing

/// `scripts/preflight.sh`, which install.sh and update.sh run before a build: each missing piece stops with what to do, a valid Mac
/// passes unchanged, and the build's jobs follow the memory. The Mac is simulated with commands on the PATH that print what it would.
@Suite("Packaging: the preflight of a build")
struct PreflightScriptTests {
    struct Mac {
        var arch = "arm64"
        var macOS = "27.2"
        var commandLineTools = true
        var sdk = "27.2"
        var swift = "swift-driver version: 1.168.6 Apple Swift version 6.4.2 (swiftlang-6.4.2.1.9 clang-2100.4.1.1)"
        var freeKB = 50 * 1024 * 1024
        var memory: UInt64 = 24 << 30
    }

    /// Runs the script on a simulated Mac; `environment` adds variables.
    static func run(_ mac: Mac, environment: [String: String] = [:]) throws -> (status: Int32, output: String) {
        let shims = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shims) }
        func shim(_ name: String, _ body: String) throws {
            let url = shims.appendingPathComponent(name)
            try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try shim("uname", "echo \(mac.arch)")
        try shim("sw_vers", "echo \(mac.macOS)")
        try shim("xcode-select", mac.commandLineTools ? "echo /Library/Developer/CommandLineTools" : "exit 2")
        try shim("xcrun", "echo \(mac.sdk)")
        try shim("swift", "echo '\(mac.swift)'")
        try shim("df", "echo 'Filesystem 1024-blocks Used Available Capacity'; echo '/dev/disk3s1 239362496 1 \(mac.freeKB) 1%'")
        try shim("sysctl", "echo \(mac.memory)")
        var env = ["PATH": shims.path + ":/usr/bin:/bin", "HOME": NSHomeDirectory()]
        env.merge(environment) { _, new in new }
        return try spawn(["/bin/bash", PackagingTests.root.appendingPathComponent("scripts/preflight.sh").path], environment: env)
    }

    @Test func aMacThatCanBuildPassesWithTheJobsOfItsMemory() throws {
        let ok = try Self.run(Mac())
        #expect(ok.status == 0 && ok.output.contains("Ready to build Vauta (VAUTA_JOBS=3)"), "\(ok.output)")
        #expect(try Self.run(Mac(memory: 8 << 30)).output.contains("VAUTA_JOBS=2"))
        #expect(try Self.run(Mac(memory: 16 << 30)).output.contains("VAUTA_JOBS=3"))
        let big = try Self.run(Mac(memory: 64 << 30))
        #expect(big.status == 0 && !big.output.contains("VAUTA_JOBS"), "more memory: Swift's own default")
        #expect(try Self.run(Mac(memory: 8 << 30), environment: ["VAUTA_JOBS": "5"]).output.contains("VAUTA_JOBS=5"), "a value set is kept")
        #expect(try Self.run(Mac(swift: "Apple Swift version 7.0 (swiftlang-7.0)")).status == 0)
    }

    @Test(arguments: [
        (Mac(arch: "x86_64"), "Apple silicon"),
        (Mac(macOS: "15.6"), "macOS 26 or later"),
        (Mac(commandLineTools: false), "xcode-select --install"),
        (Mac(sdk: "26.4"), "macOS 27 SDK"),
        (Mac(swift: "Apple Swift version 6.3 (swiftlang-6.3)"), "Swift 6.4 or later"),
        (Mac(swift: "command not found"), "Swift 6.4 or later"),
        (Mac(freeKB: 3 * 1024 * 1024), "8 GB free"),
    ])
    func eachMissingPieceStopsWithWhatToDo(mac: Mac, says: String) throws {
        let result = try Self.run(mac)
        #expect(result.status == 1 && result.output.contains("ERROR:") && result.output.contains(says), "\(result.output)")
    }

    @Test func theChecksCanBeSkipped() throws {
        let skipped = try Self.run(Mac(arch: "x86_64", memory: 8 << 30), environment: ["VAUTA_SKIP_PREFLIGHT": "1"])
        #expect(skipped.status == 0 && skipped.output.contains("VAUTA_JOBS=2"), "skipped, the jobs still follow the memory")
    }

    @Test func installAndUpdateRunItBeforeTheBuild() throws {
        let install = try String(contentsOf: PackagingTests.root.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
        let update = try String(contentsOf: PackagingTests.root.appendingPathComponent("scripts/update.sh"), encoding: .utf8)
        let build = try String(contentsOf: PackagingTests.root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        for script in [install, update] { #expect(script.contains("source scripts/preflight.sh") && script.contains("vauta_preflight || exit 1")) }
        let preflight = try #require(install.range(of: "vauta_preflight || exit 1")), built = try #require(install.range(of: "./scripts/build-app.sh"))
        #expect(preflight.lowerBound < built.lowerBound)
        // Before update.sh checks out a release, which may predate the preflight.
        let checked = try #require(update.range(of: "vauta_preflight || exit 1")), checkout = try #require(update.range(of: "checkout --quiet"))
        #expect(checked.lowerBound < checkout.lowerBound)
        #expect(build.contains("${VAUTA_JOBS:+-j \"$VAUTA_JOBS\"}"))
    }

    /// The app is built from the reviewed pins only: the dependency check runs first, and nothing is resolved anew.
    @Test func theBuildUsesTheReviewedPinsOnly() throws {
        let build = try String(contentsOf: PackagingTests.root.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
        let check = try #require(build.range(of: "\nscripts/check-dependencies.sh\n")), swift = try #require(build.range(of: "\nswift build "))
        #expect(check.lowerBound < swift.lowerBound)
        #expect(build.contains("SWIFT_ARGS=(-c release --arch arm64 --force-resolved-versions "))
    }

    /// posix_spawn with an environment of its own and no descriptor of this process (see `PackagingTests.run`).
    static func spawn(_ argv: [String], environment: [String: String]) throws -> (status: Int32, output: String) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw CocoaError(.fileReadUnknown) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArguments.forEach { free($0) }; cEnvironment.forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, argv[0], &actions, &attributes, cArguments, cEnvironment)
        close(fds[1])
        guard code == 0 else {
            close(fds[0])
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        let output = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true).readDataToEndOfFile()
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        let exit = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return (exit, String(decoding: output, as: UTF8.self))
    }
}
