// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

#if VAUTA_DIAGNOSTICS
import VautaCore
import AppKit
import Foundation

// `Vauta render-ui <out-dir> [--lang <code>] [--appearance light|dark|both] [--scale 2] [--only <prefix,...>]`
//
// Renders the main views with invented sample meetings to PNG files, so the
// interface can be reviewed without launching the app (and README screenshots
// can be regenerated). Diagnostics build only; run it through
// scripts/render-ui.sh, which builds the app bundle it needs (the interface
// language comes from the bundle's .lproj folders).
//
// It uses a temporary encrypted store with an in-memory key: no real store, no
// Keychain item, no network, no permission prompt, no audio.

enum RenderUI {
    /// The only bundle ID the command runs under, so it can never share a
    /// container, Keychain item or preferences with a real install. Renders that
    /// run side by side use their own copy of the bundle with a suffix
    /// ("local.vauta.snapshots.es-dark"), so none sees another's preferences.
    static let bundleID = "local.vauta.snapshots"

    private static var isSnapshotBundle: Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        return id == bundleID || id.hasPrefix(bundleID + ".")
    }

    /// Interface languages with a localization folder (the script renders each).
    static let languages = ["en", "es", "fr", "de", "it", "pt-BR", "ja", "ko", "zh-Hans"]
    private static let regions = ["en": "en_US", "es": "es_ES", "fr": "fr_FR", "de": "de_DE", "it": "it_IT",
                                  "pt-BR": "pt_BR", "ja": "ja_JP", "ko": "ko_KR", "zh-Hans": "zh_CN"]

    @MainActor
    static func run(_ invocation: CommandInvocation) async -> Int32 {
        guard let outPath = invocation.positional.first else {
            printError("Usage: Vauta render-ui <out-dir> [--lang <code>] [--appearance light|dark|both] [--scale 2] [--only <prefix,...>]")
            return 2
        }
        let language = invocation.values["--lang"] ?? "en"
        guard languages.contains(language) else {
            printError("Unknown --lang \(language). Available: \(languages.joined(separator: ", ")).")
            return 2
        }
        let appearances: [String]
        switch invocation.values["--appearance"] ?? "both" {
        case "light": appearances = ["light"]
        case "dark": appearances = ["dark"]
        case "both": appearances = ["light", "dark"]
        default:
            printError("--appearance takes light, dark or both.")
            return 2
        }
        let scale = invocation.values["--scale"].flatMap(Double.init) ?? 2
        guard (1...4).contains(scale) else {
            printError("--scale takes a number from 1 to 4.")
            return 2
        }
        // Scene name prefixes to render (for example "guide,settings-models"); all scenes when absent.
        let prefixes = invocation.values["--only"]?.split(separator: ",").map(String.init) ?? []
        let scenes = prefixes.isEmpty ? SnapshotScenes.all : SnapshotScenes.all.filter { scene in prefixes.contains { scene.name.hasPrefix($0) } }
        guard !scenes.isEmpty else {
            printError("--only matches no scene.")
            return 2
        }
        guard isSnapshotBundle, let domain = Bundle.main.bundleIdentifier else {
            printError("render-ui only runs inside the snapshot app bundle (bundle ID \(bundleID)). Use scripts/render-ui.sh.")
            return 1
        }
        if let relaunch = relaunchArguments(for: language) {
            // The language is read once, when the process starts: run again with it.
            execv(CommandLine.arguments[0], relaunch.map { strdup($0) } + [nil])
            printError("Couldn’t restart for the \(language) interface language.")
            return 1
        }
        guard Bundle.main.preferredLocalizations.first == language else {
            printError("The bundle has no \(language) localization (it uses \(Bundle.main.preferredLocalizations.first ?? "none")).")
            return 1
        }

        let out = URL(fileURLWithPath: outPath, isDirectory: true)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-snapshots-\(UUID().uuidString)", isDirectory: true)
        // Every render starts from no preferences at all, whatever an earlier one left.
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer {
            try? FileManager.default.removeItem(at: work)
            UserDefaults.standard.removePersistentDomain(forName: domain)
        }
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            // The spelling checker underlines words in text fields at a moment of its own:
            // keep it off so every render of a scene is the same.
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["NSAllowContinuousSpellChecking"] = false
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            // Let the run loop finish launching so the first window already draws as in the frontmost app.
            await SnapshotHost.warmUp()
            // Every scene is rendered at the same simulated moment (a Monday, 10:00), whatever day this runs on.
            AppClock.fix(at: SampleWorld.snapshotNow)
            defer { AppClock.fix(at: nil) }
            let world = try await SampleWorld.make(language: language, directory: work.appendingPathComponent("Vauta", isDirectory: true))
            let fixture = SnapshotFixture(language: language, world: world)
            defer { fixture.cleanUp() }
            var written = 0
            var layoutProblems: [String] = []
            for appearance in appearances {
                let options = SnapshotHost.Options(dark: appearance == "dark", scale: scale, defaults: fixture.appDefaults)
                for scene in scenes {
                    let prepared = await scene.make(fixture)
                    if let alert = prepared.alert {
                        guard let png = await SnapshotHost.renderAlert(alert, options: options) else {
                            printError("Couldn’t render \(scene.name).")
                            return 1
                        }
                        try png.write(to: out.appendingPathComponent("\(scene.name)-\(language)-\(appearance).png"), options: .atomic)
                        written += 1
                        continue
                    }
                    guard let png = await SnapshotHost.render(prepared.view, size: scene.size, fitHeight: scene.fitHeight, fitWidth: scene.fitWidth,
                                                              chrome: scene.chrome(prepared.title), options: options, ready: prepared.ready,
                                                              after: prepared.after, verify: prepared.verify)
                    else {
                        printError("Couldn’t render \(scene.name).")
                        return 1
                    }
                    let file = out.appendingPathComponent("\(scene.name)-\(language)-\(appearance).png")
                    try png.write(to: file, options: .atomic)
                    written += 1
                    if let problem = SnapshotHost.lastLayoutProblem {
                        layoutProblems.append("\(scene.name) (\(language), \(appearance)): \(problem)")
                        SnapshotHost.lastLayoutProblem = nil
                    }
                }
            }
            print("\(written) images in \(out.path)")
            if !layoutProblems.isEmpty {
                for problem in layoutProblems { printError("Layout check failed: \(problem).") }
                return 1
            }
            return 0
        } catch {
            printError("Error: \(error.localizedDescription)")
            return 1
        }
    }

    /// The arguments to run again with the interface language set, or nil when it already is.
    private static func relaunchArguments(for language: String) -> [String]? {
        if Bundle.main.preferredLocalizations.first == language { return nil }
        if ProcessInfo.processInfo.environment["VAUTA_RENDER_RELAUNCHED"] != nil { return nil }
        setenv("VAUTA_RENDER_RELAUNCHED", "1", 1)
        return CommandLine.arguments + ["-AppleLanguages", "(\(language))", "-AppleLocale", regions[language] ?? "en_US"]
    }
}
#endif
