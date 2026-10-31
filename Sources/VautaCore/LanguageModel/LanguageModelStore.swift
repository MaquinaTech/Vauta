// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
internal import VautaMLX

/// What `installed.json` records about an install. Frozen format: new keys are optional.
public struct LanguageModelInstallRecord: Codable, Sendable, Equatable {
    public var revision: String
    public var assembledSHA256: String
    public var tokenizerSHA256: String
    /// "download" or "import".
    public var source: String
    public var installedAt: Date
    public var appBuild: String
    public var verifiedByBuild: String?

    public init(revision: String, assembledSHA256: String, tokenizerSHA256: String, source: String, installedAt: Date, appBuild: String,
                verifiedByBuild: String? = nil) {
        self.revision = revision
        self.assembledSHA256 = assembledSHA256
        self.tokenizerSHA256 = tokenizerSHA256
        self.source = source
        self.installedAt = installedAt
        self.appBuild = appBuild
        self.verifiedByBuild = verifiedByBuild
    }
}

/// Where the language model lives: `<Application Support>/Vauta Models/gemma-4-e4b-it/<revision>/` (next to the search model, never
/// inside the store directory `Vauta/`), with `staging/` beside it while a download or import is in progress. Directories are
/// 0700, files 0600, Spotlight is told to skip it and it is excluded from backups.
public struct LanguageModelStore: Sendable {
    public enum Disk: Sendable, Equatable {
        case empty
        case partial
        case installed(LanguageModelInstallRecord)
    }

    public let root: URL
    public let spec: LanguageModelSpec

    public static var currentBuild: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev" }

    public static let folderName = "Vauta Models"
    public static let modelFolder = "gemma-4-e4b-it"

    public init(spec: LanguageModelSpec = .pinned, applicationSupport: URL? = nil) {
        self.spec = spec
        let base = applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = base.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// A store rooted exactly at `root` (tests, tools and the evaluation commands).
    public init(root: URL, spec: LanguageModelSpec = .pinned) {
        self.root = root
        self.spec = spec
    }

    var modelParent: URL { root.appendingPathComponent(Self.modelFolder, isDirectory: true) }
    public var installDirectory: URL { modelParent.appendingPathComponent(spec.revisionFolder, isDirectory: true) }
    public var stagingDirectory: URL { modelParent.appendingPathComponent("staging", isDirectory: true) }
    public var weightsURL: URL { installDirectory.appendingPathComponent(LanguageModelManifest.assembledFile) }
    public var tokenizerURL: URL { installDirectory.appendingPathComponent(spec.tokenizerFile) }
    var recordURL: URL { installDirectory.appendingPathComponent("installed.json") }
    var stagedWeights: URL { stagingDirectory.appendingPathComponent("model.safetensors") }
    var stagedWeightsPart: URL { stagingDirectory.appendingPathComponent("model.safetensors.partial") }
    var stagedJournal: URL { stagingDirectory.appendingPathComponent("progress.json") }
    var stagedTokenizer: URL { stagingDirectory.appendingPathComponent("tokenizer.json") }
    var stagedTokenizerPart: URL { stagingDirectory.appendingPathComponent("tokenizer.json.part") }
    /// Present while the staging area holds the installed model that is being repaired (so a paused repair is still one after a relaunch,
    /// and discarding it is known to delete the model).
    var stagedRepairMarker: URL { stagingDirectory.appendingPathComponent("repair.marker") }
    var stagingIsRepair: Bool { FileManager.default.fileExists(atPath: stagedRepairMarker.path) }

    private static var directoryAttributes: [FileAttributeKey: Any] { [.posixPermissions: 0o700] }

    public func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: modelParent, withIntermediateDirectories: true, attributes: Self.directoryAttributes)
        let marker = root.appendingPathComponent(".metadata_never_index")
        if !fm.fileExists(atPath: marker.path) { fm.createFile(atPath: marker.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        try excludeFromBackup()
    }

    func excludeFromBackup() throws {
        var url = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    /// Read from the disk each time, as `SearchModelStore.isExcludedFromBackup` is: a URL keeps the resource values it read.
    public var isExcludedFromBackup: Bool {
        var url = root
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    func createStaging() throws {
        try prepare()
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: Self.directoryAttributes)
    }

    public func discardStaging() { try? FileManager.default.removeItem(at: stagingDirectory) }

    public func disk() -> Disk {
        if let data = try? Data(contentsOf: recordURL), let record = try? Self.decoder.decode(LanguageModelInstallRecord.self, from: data),
           record.revision == spec.revision, FileManager.default.fileExists(atPath: weightsURL.path),
           FileManager.default.fileExists(atPath: tokenizerURL.path) {
            return .installed(record)
        }
        return FileManager.default.fileExists(atPath: stagingDirectory.path) ? .partial : .empty
    }

    func install(_ record: LanguageModelInstallRecord) throws {
        let fm = FileManager.default
        let recordFile = stagingDirectory.appendingPathComponent("installed.json")
        try Self.encoder.encode(record).write(to: recordFile, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordFile.path)
        try? fm.removeItem(at: stagedJournal)
        if fm.fileExists(atPath: installDirectory.path) { try fm.removeItem(at: installDirectory) }
        try fm.moveItem(at: stagingDirectory, to: installDirectory)
        try? excludeFromBackup()
    }

    func updateRecord(_ record: LanguageModelInstallRecord) throws {
        try Self.encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    /// Space the language model's own folder takes (installed files and staging). Not the search model beside it, and the space
    /// allocated on disk: the `.partial` file is created at its full length and fills as the download goes, so its logical size
    /// says nothing about what is written.
    public func bytesOnDisk() -> Int { Self.allocatedBytes(in: modelParent) }

    /// What `staging/` holds now (allocated, see `bytesOnDisk`).
    func stagingBytes() -> Int { Self.allocatedBytes(in: stagingDirectory) }

    static func allocatedBytes(in directory: URL) -> Int {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? v.fileSize ?? 0
        }
        return total
    }

    /// Free space an install needs when `staging/` holds what it holds, or `diskFull` with what is really missing.
    func checkRoomToInstall() throws {
        let needed = stillNeeded(stagedBytes: stagingBytes())
        if let free = availableCapacity(), free < needed { throw IntegratedModelError.diskFull(needed: needed) }
    }

    /// Tests: pretend the volume has this much free space.
    var capacityOverride: (@Sendable () -> Int?)?

    @discardableResult
    public func delete() -> Int {
        let before = bytesOnDisk()
        try? FileManager.default.removeItem(at: modelParent)
        return before - bytesOnDisk()
    }

    public func availableCapacity() -> Int? {
        if let capacityOverride { return capacityOverride() }
        var probe = root
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe = probe.deletingLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int($0) }
    }

    /// Free space an install still needs: the assembled file, the tokenizer and 512 MiB of headroom, less what staging holds.
    public static let headroom = 512 << 20
    public func stillNeeded(stagedBytes: Int) -> Int { max(Self.headroom, spec.installedSize + Self.headroom - stagedBytes) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Why this Mac cannot run the integrated language model (typed, so Settings can say it in the person's language).
public enum LanguageModelUnsupported: Sendable, Equatable {
    /// Less than 16 GB of memory (the installed memory in whole GB).
    case memory(installedGB: Int)
    /// No supported Apple silicon GPU.
    case gpu
    /// The GPU can use less than 8 GB of memory.
    case workingSet
    /// The kernel self-test failed on this Mac.
    case selfTestFailed
}

/// Whether this Mac may run the integrated language model: 16 GiB of memory or more, and an Apple silicon GPU.
public enum LanguageModelGate {
    public static var gpuSupported: Bool { MLXRuntime.isSupported }

    public static let minimumMemory: UInt64 = 16 << 30

    /// nil when the Mac qualifies; otherwise the reason.
    public static func unsupported(memory: UInt64 = ProcessInfo.processInfo.physicalMemory, gpuSupported: Bool) -> LanguageModelUnsupported? {
        if memory < minimumMemory { return .memory(installedGB: Int((Double(memory) / Double(1 << 30)).rounded())) }
        if !gpuSupported { return .gpu }
        return nil
    }

    /// The same as English text (logs and the command line).
    public static func refusal(memory: UInt64 = ProcessInfo.processInfo.physicalMemory, gpuSupported: Bool) -> String? {
        switch unsupported(memory: memory, gpuSupported: gpuSupported) {
        case nil: nil
        case .memory?: "This Mac has less than 16 GB of memory."
        case .gpu?, .workingSet?, .selfTestFailed?: "This Mac has no supported Apple silicon GPU."
        }
    }
}
