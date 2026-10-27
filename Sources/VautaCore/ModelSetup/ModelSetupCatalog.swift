// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

// The guided model setup recommends only models the project evaluated (blind
// benchmark, see docs/MODEL_SERVERS.md): Qwen3.5-9B (79/100) and Qwen3.8-27B (85/100).
//
// Identifiers and commands were checked against the official sources on 2026-10-07:
//  - Ollama library: https://ollama.com/library/qwen3.5 (tag `9b`, 6.6 GB) and
//    https://ollama.com/library/qwen3.8 (tag `27b`, 18 GB). `ollama pull <name>:<tag>`.
//  - LM Studio model catalog: https://lmstudio.ai/models/qwen3.5 (`lms get qwen/qwen3.5-9b`, 7.00 GB) and
//    https://lmstudio.ai/models/qwen3.8 (`qwen/qwen3.8-27b`, 16.10 GB). CLI syntax:
//    https://lmstudio.ai/docs/cli (`lms get`, `lms load --context-length`, `lms server start`).
//    The catalog does not publish MLX 4-bit keys, so the commands carry no quantization suffix:
//    LM Studio picks the build for this Mac and the guide tells the user to prefer MLX 4-bit.
//  - Context length in Ollama: https://docs.ollama.com/context-length (slider in the app's settings;
//    default by GPU memory: 4k below 24 GiB, 32k from 24 to 48 GiB, 256k from 48 GiB; on a Mac the GPU
//    gets only part of the RAM, so the guide always asks for the 32k setting).
//  - Bundle identifiers: Homebrew casks `lm-studio` (ai.elementlabs.lmstudio) and `ollama-app`
//    (com.electron.ollama; the cask also names com.ollama.ollama, its launchd label, tried as a fallback),
//    https://formulae.brew.sh/api/cask/<token>.json.
//    The guide also looks for the app by name in /Applications and ~/Applications, in case a bundle
//    identifier changes.

/// A model server app the guide can set up.
public enum LocalModelApp: String, CaseIterable, Sendable, Identifiable {
    case lmStudio
    case ollama

    public var id: String { rawValue }

    public var displayName: String { serverKind.displayName }

    public var serverKind: ServerKind {
        switch self {
        case .lmStudio: .lmStudio
        case .ollama: .ollama
        }
    }

    /// Bundle identifiers for the LaunchServices lookup, most current first.
    public var bundleIdentifiers: [String] {
        switch self {
        case .lmStudio: ["ai.elementlabs.lmstudio"]
        case .ollama: ["com.electron.ollama", "com.ollama.ollama"]
        }
    }

    /// File name of the app bundle, for the fallback lookup in the Applications folders.
    public var bundleFileName: String {
        switch self {
        case .lmStudio: "LM Studio.app"
        case .ollama: "Ollama.app"
        }
    }

    /// The official site where the app is downloaded (opened in the browser; Vauta downloads nothing).
    public var websiteURL: URL {
        switch self {
        case .lmStudio: URL(string: "https://lmstudio.ai")!
        case .ollama: URL(string: "https://ollama.com/download")!
        }
    }

    public var host: String { websiteURL.host() ?? "" }

    /// Command that starts the server, or nil when the app serves on its own.
    public var startServerCommand: String? {
        switch self {
        case .lmStudio: "lms server start"
        case .ollama: nil
        }
    }

    /// Folders searched when the bundle identifier lookup finds nothing.
    public static func applicationFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appending(path: "Applications", directoryHint: .isDirectory)]
    }
}

/// How to get a model into an app: the exact command, or the term to search for in the app's model browser.
public enum ModelInstall: Equatable, Sendable {
    case command(String)
    case searchTerm(String)
}

/// How to raise a model's context to the size Vauta needs.
public enum ContextFix: Equatable, Sendable {
    /// A command to run in Terminal.
    case command(String)
    /// A setting in the app (Ollama: Settings → Context length).
    case appSetting
}

/// A model the guide can recommend.
public struct LocalModel: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    /// Score out of 100 in the project's blind evaluation of minutes.
    public let score: Int
    /// Lower-case tokens that all appear in a server's model identifier for this family and size.
    let matchTokens: [String]
    private let lmStudioKey: String
    private let ollamaTag: String
    private let lmStudioGB: Double
    private let ollamaGB: Double

    public static let qwen35_9B = LocalModel(id: "qwen3.5-9b", displayName: "Qwen3.5-9B", score: 79,
                                             matchTokens: ["qwen3.5", "9b"], lmStudioKey: "qwen/qwen3.5-9b",
                                             ollamaTag: "qwen3.5:9b", lmStudioGB: 7.0, ollamaGB: 6.6)
    public static let qwen38_27B = LocalModel(id: "qwen3.8-27b", displayName: "Qwen3.8-27B", score: 85,
                                              matchTokens: ["qwen3.8", "27b"], lmStudioKey: "qwen/qwen3.8-27b",
                                              ollamaTag: "qwen3.8:27b", lmStudioGB: 16.1, ollamaGB: 18)

    /// The identifier the app uses for this model (`lms load`, `ollama run`).
    public func identifier(for app: LocalModelApp) -> String {
        app == .lmStudio ? lmStudioKey : ollamaTag
    }

    /// Both apps publish this model, so the guide shows exact commands; if one ever stops
    /// publishing it, return `.searchTerm` for that app instead of a guessed command.
    public func install(for app: LocalModelApp) -> ModelInstall {
        switch app {
        case .lmStudio: .command("lms get \(lmStudioKey)")
        case .ollama: .command("ollama pull \(ollamaTag)")
        }
    }

    /// Download size in gigabytes (10^9 bytes), as the app's catalog lists it.
    public func downloadGB(for app: LocalModelApp) -> Double {
        app == .lmStudio ? lmStudioGB : ollamaGB
    }

    /// `loadedID` is the identifier a server reported for this model while it is loaded with too little
    /// context: LM Studio must unload it first, because loading it again adds a second copy.
    public func contextFix(for app: LocalModelApp, tokens: Int = ModelSetupGuide.requiredContext,
                           loadedID: String? = nil) -> ContextFix {
        switch app {
        case .lmStudio:
            if let loadedID {
                let id = Self.shellQuoted(loadedID)
                return .command("lms unload \(id) && lms load \(id) --context-length \(tokens)")
            }
            return .command("lms load \(lmStudioKey) --context-length \(tokens)")
        case .ollama:
            return .appSetting
        }
    }

    /// Server-reported identifiers go into a command the user pastes in Terminal: quote anything unusual.
    static func shellQuoted(_ value: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:@-")
        if !value.isEmpty && value.unicodeScalars.allSatisfy(plain.contains) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Whether a model identifier reported by a server is this model: `qwen/qwen3.5-9b`,
    /// `qwen3.5:9b`, `mlx-community/Qwen3.5-9B-4bit`, case-insensitively.
    public func matches(modelID: String) -> Bool {
        let name = modelID.lowercased()
        return matchTokens.allSatisfy { Self.containsToken($0, in: name) }
    }

    /// The token must not be glued to other letters, digits or a decimal point, so `9b` does not match `19b`.
    private static func containsToken(_ token: String, in name: String) -> Bool {
        var search = name.startIndex..<name.endIndex
        while let found = name.range(of: token, range: search) {
            let before = found.lowerBound > name.startIndex ? name[name.index(before: found.lowerBound)] : nil
            let after = found.upperBound < name.endIndex ? name[found.upperBound] : nil
            let beforeOK = before.map { !$0.isLetter && !$0.isNumber && $0 != "." } ?? true
            let afterOK = after.map { !$0.isLetter && !$0.isNumber } ?? true
            if beforeOK && afterOK { return true }
            search = found.upperBound..<name.endIndex
        }
        return false
    }
}

/// What the guide recommends for a Mac.
public struct ModelRecommendation: Equatable, Sendable {
    public enum Tier: Equatable, Sendable {
        /// Below 16 GB: no local model is recommended.
        case belowMinimum
        /// 16–31 GB: Qwen3.5-9B for both roles.
        case standard
        /// 32 GB or more: Qwen3.8-27B as the main model and Qwen3.5-9B as the fast model.
        case large
    }

    public static let gibibyte: UInt64 = 1 << 30

    public let tier: Tier
    /// Minutes and Ask; nil below 16 GB.
    public let main: LocalModel?
    /// Live notes; nil when the main model also takes this role (`standard`, or "one model only").
    public let fast: LocalModel?

    /// Pure function of the physical memory (`ProcessInfo.physicalMemory`).
    public init(physicalMemory: UInt64) {
        switch physicalMemory {
        case ..<(16 * Self.gibibyte):
            tier = .belowMinimum; main = nil; fast = nil
        case ..<(32 * Self.gibibyte):
            tier = .standard; main = .qwen35_9B; fast = nil
        default:
            tier = .large; main = .qwen38_27B; fast = .qwen35_9B
        }
    }

    public var hasRecommendation: Bool { main != nil }

    /// The models to download: the main one, plus the fast one unless the user chose a single model.
    public func models(includeFast: Bool = true) -> [LocalModel] {
        [main, includeFast ? fast : nil].compactMap { $0 }
    }

    /// Every model the guide accepts when it finds one on a server, best first.
    public var acceptable: [LocalModel] { [main, fast].compactMap { $0 } }

    public func downloadGB(for app: LocalModelApp, includeFast: Bool = true) -> Double {
        models(includeFast: includeFast).reduce(0) { $0 + $1.downloadGB(for: app) }
    }
}

/// Free disk space for the downloads.
public enum DiskSpace {
    /// Left free after the downloads, for macOS and the model's working files.
    public static let headroomBytes: Int64 = 5_000_000_000

    /// Free space (counting what macOS can purge) on the volume of `url`; nil when unknown.
    public static func availableBytes(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    public static func requiredBytes(downloadGB: Double) -> Int64 {
        Int64(downloadGB * 1_000_000_000) + headroomBytes
    }

    /// True when the space is known and not enough for the download plus the headroom.
    public static func isShort(downloadGB: Double, available: Int64?) -> Bool {
        guard let available else { return false }
        return available < requiredBytes(downloadGB: downloadGB)
    }
}

public enum ModelSetupGuide {
    /// The context Vauta needs from the chat models (its default; small models below it truncate long meetings).
    public static let requiredContext = LLMServerConfig.defaultContext
}
