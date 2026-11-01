// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing

/// Checks the app bundle inputs (Info.plist, icon, build settings) and the CI helper scripts.
/// Everything runs against the repository checkout or a temporary directory.
@Suite("Packaging")
struct PackagingTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func infoPlistDeclaresIconAndEnglishDevelopmentRegion() throws {
        let plist = try Self.infoPlist()
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")
        #expect(plist["CFBundleDevelopmentRegion"] as? String == "en")
        #expect(plist["CFBundleExecutable"] as? String == "Vauta")
        #expect(plist["LSMinimumSystemVersion"] as? String == "26.0")
        // build-app.sh falls back to these when git cannot provide a version.
        let version = try #require(plist["CFBundleShortVersionString"] as? String)
        #expect(version.wholeMatch(of: /[0-9]+(\.[0-9]+){0,2}/) != nil)
        #expect(Int(try #require(plist["CFBundleVersion"] as? String)) != nil)
    }

    /// Existing installs keep their sandbox container and Keychain items only while the
    /// default bundle ID stays the same.
    @Test func defaultBundleIdentifierIsUnchanged() throws {
        #expect(try Self.infoPlist()["CFBundleIdentifier"] as? String == "local.vauta.app")
        let config = try String(contentsOf: Self.root.appendingPathComponent("scripts/config.sh"), encoding: .utf8)
        #expect(config.contains(#"VAUTA_BUNDLE_ID="${VAUTA_BUNDLE_ID:-local.vauta.app}""#))
    }

    @Test func iconFileIsAValidIcnsWithAllSizes() throws {
        let data = try Data(contentsOf: Self.root.appendingPathComponent("Resources/AppIcon.icns"))
        #expect(data.prefix(4) == Data("icns".utf8))
        func bigEndian(_ offset: Int) -> Int {
            data[data.startIndex + offset..<data.startIndex + offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        #expect(bigEndian(4) == data.count)
        var types: Set<String> = []
        var offset = 8
        while offset + 8 <= data.count {
            let length = bigEndian(offset + 4)
            try #require(length >= 8)
            types.insert(String(decoding: data[data.startIndex + offset..<data.startIndex + offset + 4], as: UTF8.self))
            offset += length
        }
        // 16, 32, 64, 128, 256, 512 and 1024 px images.
        #expect(types.isSuperset(of: ["ic04", "ic11", "ic05", "ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10"]))
    }

    // MARK: - scripts/check-strings.sh

    @Test func stringsCheckAcceptsMatchingTranslations() throws {
        let dir = try Fixture()
        try dir.write("en.lproj/Localizable.strings", #""Saved %@ to %@" = "Saved %1$@ to %2$@";"# + "\n" + #""%lld meetings" = "%lld meetings";"#)
        try dir.write("es.lproj/Localizable.strings", #""Saved %@ to %@" = "Guardado en %2$@: %1$@";"# + "\n" + #""%lld meetings" = "%lld reuniones";"#)
        try dir.write("en.lproj/Localizable.stringsdict", Self.stringsdict(other: "%lld meetings", extra: "<key>one</key><string>%lld meeting</string>"))
        try dir.write("es.lproj/Localizable.stringsdict", Self.stringsdict(other: "%lld reuniones", extra: "<key>one</key><string>Una reunión</string>"))
        try dir.write("ja.lproj/Localizable.strings", #""Saved %@ to %@" = "%2$@ に %1$@ を保存";"# + "\n" + #""%lld meetings" = "%lld 件";"#)
        try dir.write("ja.lproj/Localizable.stringsdict", Self.stringsdict(other: "%lld 件", extra: ""))
        let result = try Self.run("scripts/check-strings.sh", [dir.url.path])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("OK: 4 localized files"))
    }

    @Test func stringsCheckRejectsMissingKeysAndChangedSpecifiers() throws {
        let dir = try Fixture()
        try dir.write("en.lproj/Localizable.strings", #""A" = "A %@";"# + "\n" + #""B" = "%lld items";"# + "\n" + #""C" = "C";"#)
        try dir.write("fr.lproj/Localizable.strings", #""A" = "A";"# + "\n" + #""B" = "%d éléments";"# + "\n" + #""D" = "D";"#)
        try dir.write("en.lproj/InfoPlist.strings", #""NSMicrophoneUsageDescription" = "Mic";"#)
        let result = try Self.run("scripts/check-strings.sh", [dir.url.path])
        #expect(result.status == 1)
        #expect(result.output.contains("missing key: C"))
        #expect(result.output.contains("extra key: D"))
        #expect(result.output.contains(#"format mismatch in "A""#))
        #expect(result.output.contains(#"format mismatch in "B""#))
        #expect(result.output.contains("missing \(dir.url.path)/fr.lproj/InfoPlist.strings"))
    }

    @Test func stringsCheckRejectsBrokenPluralRules() throws {
        let dir = try Fixture()
        try dir.write("en.lproj/Localizable.stringsdict", Self.stringsdict(other: "%lld meetings", extra: ""))
        try dir.write("de.lproj/Localizable.stringsdict", Self.stringsdict(other: "%@ Besprechungen", valueType: "d", extra: ""))
        let result = try Self.run("scripts/check-strings.sh", [dir.url.path])
        #expect(result.status == 1)
        #expect(result.output.contains("NSStringFormatValueTypeKey must stay 'lld'"))
        #expect(result.output.contains("format mismatch in %lld meetings > count > other"))
    }

    @Test func stringsCheckPassesWithoutLocalizations() throws {
        let dir = try Fixture()
        let result = try Self.run("scripts/check-strings.sh", [dir.url.path])
        #expect(result.status == 0)
        #expect(result.output.contains("No translations to check yet."))
    }

    // MARK: - scripts/check-headers.sh

    @Test func headerCheckWarnModeNeverFails() throws {
        let result = try Self.run("scripts/check-headers.sh", ["--warn"])
        #expect(result.status == 0, "\(result.output)")
        #expect(try Self.run("scripts/check-headers.sh", ["--bogus"]).status == 2)
    }

    @Test func headerCheckStrictModeFailsExactlyWhenFilesLackTheHeader() throws {
        let warn = try Self.run("scripts/check-headers.sh", ["--warn"])
        let strict = try Self.run("scripts/check-headers.sh", [])
        let missing = warn.output.contains("Missing SPDX header:")
        #expect(strict.status == (missing ? 1 : 0), "\(strict.output)")
        // The new packaging files always carry the header.
        #expect(!warn.output.contains("scripts/check-headers.sh\n"))
        #expect(!warn.output.contains("PackagingTests.swift"))
    }

    // MARK: - scripts/check-shell-vars.sh

    /// macOS's bash 3.2 reads a byte that is not ASCII right after a name as part of it: "$latest…" stopped the update.sh
    /// of 0.9.3 on an unbound variable. The same name in braces passes, and so does a variable followed by ASCII.
    @Test func shellVariableCheckFailsOnAVariableRightBeforeAnEllipsis() throws {
        let fixture = try Fixture()
        try fixture.write("bad.sh", "#!/bin/bash\nlatest=1\necho \"Verifying $latest\u{2026}\"\n")
        try fixture.write("good.sh", "#!/bin/bash\nlatest=1\necho \"Verifying ${latest}\u{2026}, then $latest and done\"\n")
        let failed = try Self.run("scripts/check-shell-vars.sh", [fixture.url.appendingPathComponent("bad.sh").path])
        #expect(failed.status == 1 && failed.output.contains("bad.sh:3:"), "the line is shown: \(failed.output)")
        let passed = try Self.run("scripts/check-shell-vars.sh", [fixture.url.appendingPathComponent("good.sh").path])
        #expect(passed.status == 0, "\(passed.output)")
    }

    @Test func vautasShellScriptsPassTheVariableCheck() throws {
        let result = try Self.run("scripts/check-shell-vars.sh", [])
        #expect(result.status == 0, "\(result.output)")
        #expect(result.output.contains("OK: "))
    }

    // MARK: - Helpers

    static func stringsdict(other: String, valueType: String = "lld", extra: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>%lld meetings</key><dict>
          <key>NSStringLocalizedFormatKey</key><string>%#@count@</string>
          <key>count</key><dict>
            <key>NSStringFormatSpecTypeKey</key><string>NSStringPluralRuleType</string>
            <key>NSStringFormatValueTypeKey</key><string>\(valueType)</string>
            \(extra)
            <key>other</key><string>\(other)</string>
          </dict>
        </dict></dict></plist>
        """
    }

    struct Fixture: ~Copyable {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-packaging-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        func write(_ path: String, _ contents: String) throws {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
        }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    /// Runs a script with posix_spawn and POSIX_SPAWN_CLOEXEC_DEFAULT: the child gets no copy of any
    /// descriptor of this process. `Process` lets a child hold the other tests' store lock files
    /// (flock is per open file description) until it execs, which on a busy machine failed unrelated
    /// Storage tests with "already open in another instance".
    static func run(_ script: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
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
        let argv = ["/bin/bash", root.appendingPathComponent(script).path] + arguments
        var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cArguments.forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, "/bin/bash", &actions, &attributes, cArguments, environ)
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
