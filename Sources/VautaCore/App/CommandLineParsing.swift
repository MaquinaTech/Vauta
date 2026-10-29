// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// How the process was launched: as the menu-bar app or as a command.
public enum LaunchMode: Equatable, Sendable {
    case app
    /// The arguments after the executable path, starting with the command.
    case cli([String])

    /// Commands and flags that switch to command mode when they come first.
    public static let commandWords: Set<String> = [
        "help", "--help", "-h", "version", "--version",
        "doctor", "status", "languages",
        "install-speech-assets", "install-dictation-assets", "transcribe-file",
        "store-stats", "cert-pin", "server-check", "speaker-models", "diarize", "minutes-file", "spike", "mlx-selftest",
    ]

    /// Classifies the process arguments (without the executable path).
    ///
    /// - A known command as the first argument: command mode.
    /// - Any other first argument that is a word (no leading `-`): command
    ///   mode too, so a mistyped command prints the usage instead of
    ///   launching the app with its permissions.
    /// - Otherwise the app: no arguments, Launch Services' `-psn_…`, or
    ///   user-defaults overrides such as `-AppleLanguages (en)` or
    ///   `-NSShowAllViews YES`.
    public static func parse(_ arguments: [String]) -> LaunchMode {
        let args = arguments.filter { !$0.hasPrefix("-psn_") }
        guard let first = args.first else { return .app }
        if commandWords.contains(first) || !first.hasPrefix("-") { return .cli(args) }
        return .app
    }
}

/// A parsed command line: `<command> [positional…] [--option value] [--flag]`.
public struct CommandInvocation: Equatable, Sendable {
    public enum ParseError: Error, Equatable, Sendable {
        case missingCommand
        case missingValue(String)
        case unknownOption(String)
    }

    /// Options that take a value (`--locale es-ES` or `--locale=es-ES`).
    #if VAUTA_DIAGNOSTICS
    // `render-ui` and `translate-bench` (diagnostics build only) also take --lang, --appearance, --scale, --only,
    // --from, --to, --count, --wpm and --strategy.
    public static let valueOptions: Set<String> = ["--locale", "--vocab", "--rttm", "--out", "--threshold", "--goldens", "--tasks", "--providers", "--sets", "--questions", "--seed", "--sampler", "--max-items", "--quiet-wait", "--repeat", "--with-embeddings", "--embedding-purpose", "--purpose", "--transcript", "--seconds", "--passes", "--batch", "--arms", "--guard", "--decided", "--sensitivity", "--sources", "--sentences", "--documents", "--search-model", "--retrieval-arms", "--retrieval-sets", "--controls", "--sweep", "--live-tau", "--split", "--max-queries", "--brief-fixtures", "--brief-arms", "--brief-split", "--brief-minutes-apple", "--brief-minutes-integrated", "--actions-fixtures", "--actions-arms", "--actions-minutes-apple", "--actions-minutes-integrated", "--links-arms", "--links-minutes-apple", "--links-minutes-integrated", "--links-series", "--links-fixtures", "--links-split", "--extraction", "--meetings", "--replay-from", "--summary", "--harness", "--open-questions", "--ask", "--notes", "--live", "--ask-windows", "--output-language", "--notepad", "--cross-questions", "--server", "--variants", "--lang", "--appearance", "--scale", "--only",
                                                  "--from", "--to", "--count", "--wpm", "--strategy"]
    #else
    public static let valueOptions: Set<String> = ["--locale", "--vocab", "--rttm", "--threshold", "--out", "--goldens", "--tasks", "--providers", "--sets", "--questions", "--seed", "--sampler", "--only", "--max-items", "--quiet-wait", "--repeat", "--with-embeddings", "--embedding-purpose", "--purpose", "--transcript", "--seconds", "--passes", "--batch", "--arms", "--guard", "--decided", "--sensitivity", "--sources", "--sentences", "--documents", "--search-model", "--retrieval-arms", "--retrieval-sets", "--controls", "--sweep", "--live-tau", "--split", "--max-queries", "--brief-fixtures", "--brief-arms", "--brief-split", "--brief-minutes-apple", "--brief-minutes-integrated", "--actions-fixtures", "--actions-arms", "--actions-minutes-apple", "--actions-minutes-integrated", "--links-arms", "--links-minutes-apple", "--links-minutes-integrated", "--links-series", "--links-fixtures", "--links-split", "--extraction", "--meetings", "--replay-from", "--summary", "--harness", "--open-questions", "--ask", "--notes", "--live", "--ask-windows", "--output-language", "--notepad", "--cross-questions", "--server", "--variants"]
    #endif
    /// Options without a value.
    public static let flagOptions: Set<String> = ["--show-text", "--i-understand", "--ask-key", "--all-audio", "--live-agreement", "--help", "--model", "--download", "--long", "--print-context", "--warm", "--replay-realtime", "--renumber-final", "--after-meeting", "--no-embedding-cache", "--cold-model", "--no-check", "--keep-answered-aloud", "--detect-only", "--no-detection", "--closing-probe", "--replay-live", "--realtime", "--actions-name-speakers"]

    public var command: String
    public var positional: [String] = []
    public var values: [String: String] = [:]
    public var flags: Set<String> = []

    public init(command: String, positional: [String] = [], values: [String: String] = [:], flags: Set<String> = []) {
        self.command = command
        self.positional = positional
        self.values = values
        self.flags = flags
    }

    public init(parsing arguments: [String]) throws(ParseError) {
        guard let first = arguments.first else { throw .missingCommand }
        // `-h`, `--help` and `--version` are commands of their own.
        switch first {
        case "-h", "--help": command = "help"
        case "--version": command = "version"
        default: command = first
        }
        var rest = arguments.dropFirst()[...]
        while let arg = rest.popFirst() {
            guard arg.hasPrefix("--"), arg.count > 2 else {
                positional.append(arg)
                continue
            }
            if let equals = arg.firstIndex(of: "=") {
                let name = String(arg[..<equals])
                guard Self.valueOptions.contains(name) else { throw .unknownOption(name) }
                values[name] = String(arg[arg.index(after: equals)...])
            } else if Self.valueOptions.contains(arg) {
                guard let value = rest.popFirst(), !value.hasPrefix("--") else { throw .missingValue(arg) }
                values[arg] = value
            } else if Self.flagOptions.contains(arg) {
                flags.insert(arg)
            } else {
                throw .unknownOption(arg)
            }
        }
    }

    public func has(_ flag: String) -> Bool { flags.contains(flag) }

    /// `--vocab "a, b,c"` as a clean list.
    public var vocabulary: [String] {
        (values["--vocab"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
