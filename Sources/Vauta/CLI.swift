// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import Foundation

// Command-line tools. Without a command, Vauta starts as a menu-bar app.
// Output is English only (it is meant for support and scripts).
//
// No command of the normal binary captures audio: any process can run
// `open -n -a Vauta --args …` and would use Vauta's microphone and
// system-audio permissions. The capturing `spike` command only exists in the
// diagnostics build, compiled separately with VAUTA_DIAGNOSTICS, which is
// NEVER signed or installed (scripts/ build without it). Build it OUTSIDE the
// project so the capturing binary never ends up next to the code:
//
//   swift build -c release --arch arm64 --scratch-path /tmp/vauta-diagnostics -Xswiftc -DVAUTA_DIAGNOSTICS
//
// Transcribed text is NOT printed by default, only counts: the Terminal keeps
// its scrollback on disk (Saved Application State, Time Machine), outside the
// encrypted store. `--show-text` prints it to stderr after a warning; when the
// output isn't a terminal (redirected, another tool) it also needs
// `--i-understand`. Never with real meetings. Audio is never written to disk:
// there is no option to dump it.

let usage = """
    Usage: Vauta <command> [options]

    Commands:
      doctor                              Check this Mac: speech languages, store, model server, permissions
      status [--locale <id>]              Speech model status and the processes playing or recording audio
      languages                           Transcription languages and whether their models are installed
      install-speech-assets [--locale <id>]
                                          Download the speech model of a language from Apple (once)
      install-dictation-assets [--locale <id>]
                                          Download the dictation model of a language (custom vocabulary)
      transcribe-file <audio> [--locale <id>] [--vocab "a,b"] [--show-text [--i-understand]]
                                          Transcribe an audio file (needs no permissions)
      store-stats                         Size and counts of the existing store (read-only)
      speaker-models                      Verify (SHA-256) and load the bundled speaker-separation models
      diarize <audio> [--rttm <out>] [--threshold <n>] [--live-agreement]
                                          Separate the speakers of an audio file on this Mac and print RTTM (no text,
                                          no audio is written); --threshold is the clustering cut (default 0.70)
      minutes-file <transcript.json> --out <minutes.json> [--locale <id>]
                                          Evaluation: write the minutes of a PUBLIC transcript with Apple's on-device
                                          model and save the items with their citations (never use it on a real meeting)
      cert-pin <cert.pem>                 SPKI pin of a certificate (for Settings › Models)
      server-check <config.json> [--ask-key]
                                          Test a model server configuration with sample text
      help, --help                        Show this help
      version, --version                  Show the version

    --locale takes a BCP-47 language such as en-US or es-ES; the default is
    the language chosen in Vauta, else the first supported language of your
    preferred languages.
    --show-text prints transcribed text to stderr, with a warning; without a
    terminal it also needs --i-understand.
    """

func runCLI(_ arguments: [String]) async -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    if arguments.contains("--dump") {
        printError("--dump isn’t available: Vauta never saves audio.")
        return 2
    }
    let invocation: CommandInvocation
    do {
        invocation = try CommandInvocation(parsing: arguments)
    } catch {
        switch error {
        case .missingCommand: break
        case .missingValue(let option): printError("\(option) needs a value.")
        case .unknownOption(let option): printError("Unknown option: \(option)")
        }
        print(usage)
        return 2
    }
    do {
        switch invocation.command {
        case _ where invocation.has("--help"), "help":
            print(usage)
        case "version":
            print(versionString)
        case "doctor":
            return await doctor()
        case "status":
            let locale = try await speechLocale(invocation)
            print("Speech model (\(locale.identifier(.bcp47))): \(await SpeechAssets.status(locale))")
            print("Dictation model (\(locale.identifier(.bcp47))): \(await SpeechAssets.dictationStatus(locale))")
            print("Audio processes (● playing · 🎙 using the microphone):")
            for p in AudioProcessDiagnostics.processes().sorted(by: { $0.bundleID < $1.bundleID }) {
                let family = p.family.map { " — \($0.displayName)" } ?? ""
                print("  \(p.isRunningOutput ? "●" : "○")\(p.isRunningInput ? " 🎙" : "  ") \(p.bundleID.isEmpty ? "(no bundle ID)" : p.bundleID) [pid \(p.pid)]\(family)")
            }
            let presence = MeetingPresence.currentState()
            print("Meeting app using the microphone: \(presence.family?.displayName ?? "none")")
        case "languages":
            printLanguages(await SpeechLanguages.catalog())
        case "install-speech-assets", "install-dictation-assets":
            let dictation = invocation.command == "install-dictation-assets"
            let locale = try await speechLocale(invocation, engine: dictation ? .dictation : .speech)
            let id = locale.identifier(.bcp47)
            print("Downloading the \(dictation ? "dictation" : "speech") model for \(id) from Apple (only once)…")
            try await SpeechLanguages.install(locale, engine: dictation ? .dictation : .speech) { p in
                print(String(format: "  %3.0f %%", p * 100))
            }
            print("Status: \(await SpeechLanguages.status(locale, engine: dictation ? .dictation : .speech))")
        case "transcribe-file":
            guard let path = invocation.positional.first else { throw Usage() }
            let vocabulary = invocation.vocabulary
            let locale = try await speechLocale(invocation, engine: vocabulary.isEmpty ? nil : .dictation)
            let showText = try textOutputAllowed(invocation)
            let t0 = Date()
            let finals = try await transcribeFile(URL(fileURLWithPath: path), locale: locale, vocabulary: vocabulary).filter(\.isFinal)
            if showText {
                for s in finals { printError("[\(ElapsedTime.clock(Int(s.start)))] \(s.text)") }
            }
            print(String(format: "%d segments · %d characters · %.2f s",
                         finals.count, finals.reduce(0) { $0 + $1.text.count }, Date().timeIntervalSince(t0)))
        case "server-check":
            guard let path = invocation.positional.first else { throw Usage() }
            return try await serverCheck(configPath: path, askKey: invocation.has("--ask-key"))
        case "cert-pin":
            // No network: SPKI pin (SHA-256, base64) of a PEM certificate, for Settings › Models.
            guard let path = invocation.positional.first else { throw Usage() }
            guard let pin = LLMClient.spkiPin(pem: try String(contentsOfFile: path, encoding: .utf8)) else {
                printError("Not a PEM certificate with an EC (P-256/384/521) or RSA key.")
                return 1
            }
            print(pin)
        case "minutes-file":
            return try await minutesFile(invocation)
        case "mlx-selftest":
            // Hidden from the usage on purpose: a support and release check (see docs/SEARCH_MODEL.md).
            return await mlxSelfTest(invocation)
        case "llm-selftest":
            // Hidden from the usage on purpose: a support and release check (see docs/LANGUAGE_MODEL.md).
            return await llmSelfTest(invocation)
        case "llm-eval":
            return await llmEval(invocation)
        case "llm-install":
            return await llmInstall(invocation)
        case "embed-loop":
            // Hidden: embeds a PUBLIC transcript over and over for the concurrency measurements (see docs/LANGUAGE_MODEL.md).
            return await embedLoop(invocation)
        case "speaker-models":
            // Offline, no audio: the bundled models against their pinned checksums, then a load of each.
            do {
                let models = try DiarizationModels.verified()
                _ = try models.makeSegmenter()
                _ = try models.makeEmbedder()
                print("Speaker models verified and loaded (\(DiarizationModels.segmentationModelID), \(DiarizationModels.embeddingModelID)).")
            } catch {
                printError("Speaker models: \(error)")
                return 1
            }
        case "diarize":
            // Evaluation tool: the same engine as a meeting, offline, over one file. It prints who speaks when (RTTM),
            // never text, and writes no audio. The only file it can write is the RTTM named with --rttm.
            guard let path = invocation.positional.first else { throw Usage() }
            var config = DiarizationConfig()
            if let value = invocation.values["--threshold"] {
                guard let threshold = Float(value), threshold > 0, threshold < 2 else {
                    printError("--threshold takes a number above 0 and below 2 (the default is \(config.finalThreshold)).")
                    return 2
                }
                config.finalThreshold = threshold
            }
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                // The packaged app is sandboxed and can't open arbitrary paths: run a build from source.
                printError("Can't read \(path). The sandboxed app can only open files you pick; run .build/release/Vauta from a source build.")
                return 1
            }
            let t0 = Date()
            let result: Diarization
            if invocation.has("--live-agreement") {
                // Evaluation of the live labels: the windows go through the live tracker as in a meeting.
                let run = try await OfflineDiarization.analyze(url: url, config: config)
                let live = LiveAgreement.measure(records: run.records, totalSamples: run.totalSamples, config: config)
                printError(String(format: "live agreement %.1f%% · %d live labels · %d final speakers · %d labelled of %d speaker-frames",
                                  live.agreement * 100, live.liveLabels, live.finalSpeakers, live.labelledFrames, live.speechFrames))
                result = Reconstruction.diarize(records: run.records, totalSamples: run.totalSamples, config: config)
            } else {
                result = try await OfflineDiarization.diarize(url: url, config: config)
            }
            let rttm = Reconstruction.rttm(result.turns, fileID: url.deletingPathExtension().lastPathComponent)
            if let out = invocation.values["--rttm"] {
                try rttm.write(toFile: out, atomically: true, encoding: .utf8)
            } else {
                print(rttm, terminator: "")
            }
            printError(String(format: "%d speakers · %d turns · %.1f s", result.speakerCount, result.turns.count, Date().timeIntervalSince(t0)))
        #if VAUTA_DIAGNOSTICS
        case "speaker-centroids":
            return try await speakerCentroids(invocation)
        #endif
        case "store-stats":
            let store = try MeetingStore(createIfMissing: false)
            let stats = try await store.stats()
            print("\(store.fileURL.lastPathComponent): \(stats.fileBytes) bytes · journal: \(stats.journalBytes) bytes · \(stats.meetings) meetings · \(stats.segments) segments · \((try? await store.unembeddableChunkCount()) ?? 0) chunks the search model could not read")
        #if VAUTA_DIAGNOSTICS
        case "render-ui":
            return await RenderUI.run(invocation)
        case "translate-bench":
            return await TranslateBench.run(invocation)
        case "spike":
            let locale = try await speechLocale(invocation)
            try await spike(locale: locale, seconds: invocation.positional.compactMap(Double.init).first ?? 120,
                            scope: invocation.has("--all-audio") ? .allSystem : .auto,
                            showText: try textOutputAllowed(invocation))
        #endif
        default:
            printError("Unknown command: \(invocation.command)")
            throw Usage()
        }
        return 0
    } catch is Usage {
        print(usage)
        return 2
    } catch {
        printError("Error: \(error.localizedDescription)")
        if let suggestion = (error as? LocalizedError)?.recoverySuggestion { printError(suggestion) }
        return 1
    }
}

struct Usage: Error {}

/// "Vauta 0.2.0 (123)", or a development build outside an app bundle.
var versionString: String {
    let info = Bundle.main.infoDictionary ?? [:]
    guard let version = info["CFBundleShortVersionString"] as? String else { return "Vauta (development build)" }
    let build = info["CFBundleVersion"] as? String
    return build.map { "Vauta \(version) (\($0))" } ?? "Vauta \(version)"
}

/// The language of a speech command: `--locale`, else the app's chosen
/// language (when run from inside Vauta.app), else the user's default.
/// With `engine`, that engine must support it.
func speechLocale(_ invocation: CommandInvocation, engine: SpeechEngineKind? = nil) async throws -> Locale {
    let catalog = await SpeechLanguages.catalog()
    let requested = invocation.values["--locale"] ?? UserDefaults.standard.string(forKey: Preferences.Keys.transcriptionLanguage)
    let language = requested.map { catalog.language(matching: $0) } ?? catalog.defaultLanguage()
    guard let language else {
        throw catalog.languages.isEmpty ? CaptureError(.speechUnavailable)
            : CaptureError(.localeUnsupported, localeIdentifier: requested ?? SpeechLanguages.fallbackIdentifier)
    }
    if let engine, !language.engines.contains(engine) {
        throw CaptureError(.localeUnsupported, localeIdentifier: language.id)
    }
    return language.locale
}

func printLanguages(_ catalog: SpeechLanguageCatalog) {
    let fallback = catalog.defaultLanguage()?.id
    for language in catalog.languages {
        let engines = language.engines.map { language.installed.contains($0) ? "\($0.rawValue) (installed)" : $0.rawValue }
        print("  \(language.id == fallback ? "*" : " ") \(language.id.padding(toLength: 10, withPad: " ", startingAt: 0)) \(engines.joined(separator: ", "))")
    }
    print("  * default language")
}

struct TextOutputRefused: LocalizedError {
    var errorDescription: String? {
        "--show-text without a terminal: the text would end up in a file or another tool’s log. Add --i-understand if you really want that."
    }
}

/// `--show-text`: warns on stderr and, when the output isn't a terminal, requires `--i-understand`.
func textOutputAllowed(_ invocation: CommandInvocation) throws -> Bool {
    guard invocation.has("--show-text") else { return false }
    printError("WARNING: the text will be shown in clear; the terminal and any tool or log capturing this output will keep it outside the encrypted store. Don’t use it with real meetings. When done: Cmd-K and close the window.")
    if isatty(STDERR_FILENO) == 0 && !invocation.has("--i-understand") { throw TextOutputRefused() }
    return true
}

/// Reads a secret from the terminal without echo (nil without a terminal or if cancelled).
func readSecret(_ prompt: String) -> String? {
    var buffer = [CChar](repeating: 0, count: 1024)
    defer { _ = buffer.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) } }
    guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) != nil else { return nil }
    let length = buffer.firstIndex(of: 0) ?? buffer.count
    let value = String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
}

/// What `--ask-key` says when nothing was typed at its prompt: nothing is sent, so the server cannot answer "rejected the key".
let noKeyTyped = "No key was typed, so nothing was sent. Copy the key, run the command again and paste it at the prompt (it is not shown)."

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
