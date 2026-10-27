// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import VautaCore
import AVFoundation
import EventKit
import Foundation

/// `Vauta doctor`: one read-only report for support. Never opens or creates
/// the store or a key, never captures audio, and only talks to the model
/// server the user configured (a model list, no meeting content).
func doctor() async -> Int32 {
    var problems = 0
    func line(_ ok: Bool?, _ text: String) {
        let mark = switch ok { case true?: "✓"; case false?: "✗"; case nil: "·" }
        if ok == false { problems += 1 }
        print("  \(mark) \(text)")
    }

    print("\(versionString) — doctor")
    print("\nThis Mac")
    let os = ProcessInfo.processInfo.operatingSystemVersion
    var machine = utsname()
    uname(&machine)
    let arch = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    line(os.majorVersion >= 26, "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(arch)")

    print("\nTranscription")
    let catalog = await SpeechLanguages.catalog()
    if catalog.languages.isEmpty {
        line(false, "On-device speech recognition isn’t available.")
    } else if let language = UserDefaults.standard.string(forKey: Preferences.Keys.transcriptionLanguage)
                .flatMap(catalog.language(matching:)) ?? catalog.defaultLanguage() {
        let installed = language.isInstalled
        line(installed, "Recording language \(language.id): \(installed ? "model installed" : "model not installed — run: Vauta install-speech-assets --locale \(language.id)")")
        let ready = catalog.languages.filter(\.isInstalled).map(\.id)
        line(nil, "Languages ready: \(ready.isEmpty ? "none" : ready.joined(separator: ", ")) (of \(catalog.languages.count) supported)")
    }

    print("\nSpeaker separation")
    let separate = UserDefaults.standard.object(forKey: Preferences.Keys.separateSpeakers) as? Bool ?? true
    do {
        let models = try DiarizationModels.verified()
        _ = try models.makeSegmenter()
        _ = try models.makeEmbedder()
        line(true, "Speaker models verified and loaded · the setting is \(separate ? "on" : "off")")
    } catch {
        line(false, "\(error) Meetings are recorded without separate speakers.")
    }

    print("\nStore")
    line(nil, MeetingStore.existsAtDefaultLocation
         ? "Encrypted store found (not opened)."
         : "No encrypted store here. Run this from inside Vauta.app to check the app’s own store.")

    print("\nModel server")
    do {
        if let config = try LLMServerConfig.load() {
            line(nil, "Configured: \(config.baseURL) (\(config.mode.rawValue))")
            let bearer = try? ServerCredentials.readBearer()
            switch await reachability(config, bearer: bearer ?? nil) {
            case .success(let models):
                let missing = LLMRole.allCases.map(config.model).filter { !$0.isEmpty && !models.contains($0) }
                line(true, "Reachable · \(models.count) models listed")
                if !missing.isEmpty { line(false, "Not listed by the server: \(missing.joined(separator: ", "))") }
            case .failure(let error):
                line(false, "Not reachable: \(error.localizedDescription)")
            }
        } else {
            line(nil, "Not configured (minutes use Apple Intelligence when available).")
        }
    } catch {
        line(false, "The configuration couldn’t be read: \(error.localizedDescription)")
    }

    print("\nSearch model (optional, EmbeddingGemma 2)")
    let search = SearchModelSelfTest.describe()
    line(search.ok, search.text)

    print("\nPermissions (as granted to this binary)")
    let mic = AVCaptureDevice.authorizationStatus(for: .audio)
    line(mic == .authorized ? true : mic == .notDetermined ? nil : false, "Microphone: \(describe(mic))")
    line(nil, "System audio recording: can’t be read from the command line; see System Settings › Privacy & Security › Screen & System Audio Recording.")
    let calendar = EKEventStore.authorizationStatus(for: .event)
    line(nil, "Calendar (optional): \(calendar == .fullAccess ? "full access" : calendar == .notDetermined ? "not asked" : "no access")")

    print(problems == 0 ? "\nNo problems found." : "\n\(problems) problem(s) found.")
    return problems == 0 ? 0 : 1
}

private func describe(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized: "allowed"
    case .denied: "denied — allow Vauta in System Settings › Privacy & Security › Microphone"
    case .restricted: "restricted by a profile"
    case .notDetermined: "not asked yet (asked at the first recording)"
    @unknown default: "unknown"
    }
}

/// The server's model list, within 10 s.
private func reachability(_ config: LLMServerConfig, bearer: String?) async -> Result<[String], Error> {
    let client = LLMClient(config: config, bearer: { bearer })
    return await withTaskGroup(of: Result<[String], Error>?.self) { group in
        group.addTask {
            do { return .success(try await client.allModels(purpose: .connectionTest)) } catch { return .failure(error) }
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(10))
            return Task.isCancelled ? nil : .failure(URLError(.timedOut))
        }
        defer { group.cancelAll() }
        while let next = await group.next() {
            if let next { return next }
        }
        return .failure(URLError(.timedOut))
    }
}

/// `Vauta server-check`: tests a server configuration file (the same JSON
/// Settings › Models imports) with sample text; never sends anything from
/// meetings. The key, if needed, is typed without echo (`--ask-key`): never
/// in arguments or shell history.
func serverCheck(configPath: String, askKey: Bool) async throws -> Int32 {
    let config = try JSONDecoder().decode(LLMServerConfig.self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
    // Embeddings are checked when the file names an embedding model; Settings requires the name only when search
    // by meaning runs on the server.
    _ = try config.validated(embeddingsOnServer: !config.embeddingModel.isEmpty)
    let key = askKey ? readSecret("Server key (not shown): ") : nil
    let client = LLMClient(config: config, bearer: { key })
    let models = try await client.allModels(purpose: .connectionTest)
    print("Server: \(config.baseURL) · \(models.count) models: \(models.joined(separator: ", "))")
    let missing = [config.fastModel, config.deepModel, config.embeddingModel].filter { !$0.isEmpty && !models.contains($0) }
    guard missing.isEmpty else {
        printError("Not listed by the server: \(missing.joined(separator: ", "))")
        return 1
    }
    for (role, name) in [(LLMRole.fast, config.fastModel), (.deep, config.deepModel)] where !name.isEmpty {
        let t0 = Date()
        let r = try await client.chat([.user("Reply with the single word: ready")], ChatOptions(model: role, maxTokens: 300, purpose: .connectionTest))
        print(String(format: "%@ model (%@): “%@” · %d tokens in %.1f s", role == .fast ? "Fast" : "Main", name,
                     String(r.content.prefix(40)), r.completionTokens, Date().timeIntervalSince(t0)))
    }
    if !config.embeddingModel.isEmpty {
        let v = try await client.embed(["embedding test"])
        print("Embeddings (\(config.embeddingModel)): OK (\(v.first?.count ?? 0) dimensions)")
    }
    print("OK: the server answers with the configured models.")
    return 0
}
