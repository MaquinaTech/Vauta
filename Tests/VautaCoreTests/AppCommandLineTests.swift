// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

@Suite("App: launch mode and command line")
struct AppCommandLineTests {
    @Test(arguments: [
        [String](), ["-psn_0_12345"], ["-AppleLanguages", "(en)"], ["-NSShowAllViews", "YES"],
        ["-AppleLocale", "es_ES"], ["-psn_0_1", "-AppleLanguages", "(fr)"], ["--unknown-flag"],
    ])
    func launchesTheAppWithoutACommand(arguments: [String]) {
        #expect(LaunchMode.parse(arguments) == .app)
    }

    @Test(arguments: ["doctor", "status", "help", "--help", "-h", "--version", "version", "store-stats",
                      "install-speech-assets", "transcribe-file", "server-check", "cert-pin", "languages", "speaker-models", "diarize", "minutes-file", "mlx-selftest"])
    func knownCommandsRunTheCommandLine(command: String) {
        #expect(LaunchMode.parse([command, "x"]) == .cli([command, "x"]))
    }

    /// Every option a command reads is one the parser knows: an option missing from the lists is refused as unknown before the
    /// command runs. The commands of the diagnostics build are left out (they compile, and their options exist, only there).
    @Test func everyOptionTheCommandsReadIsKnownToTheParser() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Vauta")
        let files = try #require(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let valueRead = try Regex(#"values\["(--[a-z0-9-]+)"\]"#), flagRead = try Regex(#"\.has\("(--[a-z0-9-]+)"\)"#)
        var read = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.components(separatedBy: "\n").prefix(5).contains("#if VAUTA_DIAGNOSTICS") { continue }
            for match in text.matches(of: valueRead) {
                let name = String(text[try #require(match.output[1].range)])
                #expect(CommandInvocation.valueOptions.contains(name), "\(file.lastPathComponent) reads \(name)")
                read += 1
            }
            for match in text.matches(of: flagRead) {
                let name = String(text[try #require(match.output[1].range)])
                #expect(CommandInvocation.flagOptions.contains(name), "\(file.lastPathComponent) reads \(name)")
                read += 1
            }
        }
        #expect(read > 50, "the scan found \(read) options: the pattern no longer matches how the commands read them")
    }

    @Test func minutesFileTakesItsOutputPath() throws {
        let invocation = try CommandInvocation(parsing: ["minutes-file", "t.json", "--out", "m.json", "--locale", "en-US"])
        #expect(invocation.positional == ["t.json"])
        #expect(invocation.values["--out"] == "m.json")
    }

    @Test func minutesEvaluationCountsWhatTheModelProposed() {
        let answer = #"Here: {"decisions": [{"text": "a"}, {"text": "b"}], "tasks": [{"text": "c"}], "topics": ["x"]}"#
        #expect(MinutesEvaluation.countProposals(answer) == 3)
        #expect(MinutesEvaluation.countProposals("no json") == 0)
    }

    @Test func launchServicesArgumentIsDroppedBeforeTheCommand() {
        #expect(LaunchMode.parse(["-psn_0_1", "doctor"]) == .cli(["doctor"]))
    }

    @Test func aMistypedCommandPrintsUsageInsteadOfLaunchingTheApp() {
        #expect(LaunchMode.parse(["doctr"]) == .cli(["doctr"]))
    }

    @Test func parsesPositionalValuesAndFlags() throws {
        let invocation = try CommandInvocation(parsing: ["transcribe-file", "talk.m4a", "--locale", "es-ES", "--vocab", "Kobaltix, Nubelia,,",
                                                         "--show-text", "--i-understand"])
        #expect(invocation.command == "transcribe-file")
        #expect(invocation.positional == ["talk.m4a"])
        #expect(invocation.values["--locale"] == "es-ES")
        #expect(invocation.vocabulary == ["Kobaltix", "Nubelia"])
        #expect(invocation.has("--show-text") && invocation.has("--i-understand"))
        #expect(!invocation.has("--ask-key"))
    }

    @Test func acceptsEqualsForm() throws {
        let invocation = try CommandInvocation(parsing: ["status", "--locale=fr-CA"])
        #expect(invocation.values["--locale"] == "fr-CA")
    }

    @Test func helpAndVersionFlagsBecomeCommands() throws {
        #expect(try CommandInvocation(parsing: ["--help"]).command == "help")
        #expect(try CommandInvocation(parsing: ["-h"]).command == "help")
        #expect(try CommandInvocation(parsing: ["--version"]).command == "version")
    }

    @Test func rejectsBadOptions() {
        #expect(throws: CommandInvocation.ParseError.missingValue("--locale")) {
            try CommandInvocation(parsing: ["status", "--locale"])
        }
        #expect(throws: CommandInvocation.ParseError.missingValue("--locale")) {
            try CommandInvocation(parsing: ["status", "--locale", "--show-text"])
        }
        #expect(throws: CommandInvocation.ParseError.unknownOption("--loud")) {
            try CommandInvocation(parsing: ["status", "--loud"])
        }
        #expect(throws: CommandInvocation.ParseError.unknownOption("--show-text")) {
            try CommandInvocation(parsing: ["status", "--show-text=yes"])
        }
        #expect(throws: CommandInvocation.ParseError.missingCommand) {
            try CommandInvocation(parsing: [])
        }
    }

    @Test func elapsedClock() {
        #expect(ElapsedTime.clock(0) == "00:00")
        #expect(ElapsedTime.clock(65) == "01:05")
        #expect(ElapsedTime.clock(3599) == "59:59")
        #expect(ElapsedTime.clock(3600) == "1:00:00")
        #expect(ElapsedTime.clock(3723) == "1:02:03")
        #expect(ElapsedTime.clock(-5) == "00:00")
        #expect(ElapsedTime.stamp(95) == "1:35")
        #expect(ElapsedTime.stamp(24) == "0:24")
        #expect(ElapsedTime.stamp(754) == "12:34")
        #expect(ElapsedTime.stamp(5412) == "1:30:12")
        #expect(ElapsedTime.stamp(-5) == "0:00")
        #expect(!ElapsedTime.spoken(65).isEmpty)
    }
}
