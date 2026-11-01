// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing

/// `scripts/install-app.sh`, the step of install.sh that puts the new app in place: whatever fails, a working app is left where
/// the installed one was. The apps are folders with a marker file, and `cp` and `codesign` are simulated on the PATH.
@Suite("Packaging: the app is put in place without a moment of no app")
struct InstallAppScriptTests {
    final class Place {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-install-\(UUID().uuidString)", isDirectory: true)
        var new: URL { root.appendingPathComponent("build/Vauta.app") }
        var applications: URL { root.appendingPathComponent("Applications") }
        var installed: URL { applications.appendingPathComponent("Vauta.app") }
        var staging: URL { applications.appendingPathComponent(".Vauta.app.staging") }
        var previous: URL { applications.appendingPathComponent(".Vauta.app.previous") }
        var shims: URL { root.appendingPathComponent("shims") }

        init() throws {
            try Self.app(at: new, version: "new")
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        static func app(at url: URL, version: String) throws {
            let bin = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try version.write(to: bin.appendingPathComponent("Vauta"), atomically: true, encoding: .utf8)
        }

        func version(_ url: URL) -> String? {
            try? String(contentsOf: url.appendingPathComponent("Contents/MacOS/Vauta"), encoding: .utf8)
        }

        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

        func shim(_ name: String, _ body: String) throws {
            let url = shims.appendingPathComponent(name)
            try ("#!/bin/bash\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        /// Runs the script with the shims first on the PATH (`codesign` passes unless a test says otherwise).
        func install() throws -> (status: Int32, output: String) {
            if !exists(shims.appendingPathComponent("codesign")) { try shim("codesign", "exit 0") }
            let script = PackagingTests.root.appendingPathComponent("scripts/install-app.sh").path
            return try PreflightScriptTests.spawn(["/bin/bash", script, new.path, installed.path],
                                                  environment: ["PATH": shims.path + ":/usr/bin:/bin", "HOME": root.path])
        }
    }

    @Test func aNewAppIsPutInPlaceAndNothingIsLeftBeside() throws {
        let place = try Place()
        #expect(try place.install().status == 0)
        #expect(place.version(place.installed) == "new")
        try FileManager.default.removeItem(at: place.new)
        try Place.app(at: place.new, version: "newer")
        let again = try place.install()
        #expect(again.status == 0 && place.version(place.installed) == "newer", "\(again.output)")
        #expect(!place.exists(place.staging) && !place.exists(place.previous), "no copy is left beside the installed app")
    }

    @Test func aCopyThatFailsHalfwayLeavesTheInstalledAppAsItWas() throws {
        let place = try Place()
        try Place.app(at: place.installed, version: "old")
        // The disk fills up in the middle of the copy: part of the bundle is written, then cp fails.
        try place.shim("cp", "mkdir -p \"$3/Contents\"; echo partial > \"$3/Contents/half\"; exit 1")
        let run = try place.install()
        #expect(run.status != 0 && run.output.contains("The installed app was not changed"), "\(run.output)")
        #expect(place.version(place.installed) == "old")
        #expect(!place.exists(place.staging), "the half copy is removed")
    }

    @Test func aCopyThatDoesNotVerifyIsNeverInstalled() throws {
        let place = try Place()
        try Place.app(at: place.installed, version: "old")
        try place.shim("codesign", "exit 1")
        let run = try place.install()
        #expect(run.status != 0 && place.version(place.installed) == "old" && !place.exists(place.staging), "\(run.output)")
    }

    @Test func aRunCutBetweenTheTwoRenamesIsFinishedByTheNextOne() throws {
        let place = try Place()
        // The previous run set the installed app aside and stopped before the new one was in place.
        try Place.app(at: place.previous, version: "old")
        try place.shim("codesign", "exit 1")
        let failed = try place.install()
        #expect(failed.status != 0 && place.version(place.installed) == "old", "the app set aside is put back even when this run fails: \(failed.output)")
        try FileManager.default.removeItem(at: place.shims.appendingPathComponent("codesign"))
        #expect(try place.install().status == 0 && place.version(place.installed) == "new" && !place.exists(place.previous))
    }

    @Test func installUsesIt() throws {
        let install = try String(contentsOf: PackagingTests.root.appendingPathComponent("scripts/install.sh"), encoding: .utf8)
        #expect(install.contains("scripts/install-app.sh build/Vauta.app ~/Applications/Vauta.app"))
        #expect(!install.contains("rm -rf ~/Applications/Vauta.app"), "never a moment with no app")
    }
}
