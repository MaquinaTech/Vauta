// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// What `installed.json` records about an install. Frozen format: new keys are optional.
public struct SearchModelInstallRecord: Codable, Sendable, Equatable {
    public var revision: String
    public var assembledSHA256: String
    public var tokenizerSHA256: String
    /// "download" or "import".
    public var source: String
    public var installedAt: Date
    public var appBuild: String
    /// The build that last ran the full verification (the full check runs again when the build changes).
    public var verifiedByBuild: String?

    public init(revision: String, assembledSHA256: String, tokenizerSHA256: String, source: String, installedAt: Date,
                appBuild: String, verifiedByBuild: String? = nil) {
        self.revision = revision
        self.assembledSHA256 = assembledSHA256
        self.tokenizerSHA256 = tokenizerSHA256
        self.source = source
        self.installedAt = installedAt
        self.appBuild = appBuild
        self.verifiedByBuild = verifiedByBuild
    }
}

/// Where the search model lives and what is on disk: `<Application Support>/Vauta Models/embeddinggemma-2/<revision>/`, with
/// `staging/` as a sibling while a download or import is in progress. It is deliberately outside the store directory (`Vauta/`),
/// which the move from the earlier version and Erase Everything treat as theirs. Directories are 0700, files 0600, Spotlight is told to
/// skip it and it is excluded from backups.
public struct SearchModelStore: Sendable {
    public enum Disk: Sendable, Equatable {
        case empty
        /// An interrupted download or import is waiting in `staging/`.
        case partial
        case installed(SearchModelInstallRecord)
    }

    public let root: URL
    public let spec: SearchModelSpec

    public static let folderName = "Vauta Models"
    public static let modelFolder = "embeddinggemma-2"

    /// The default location, in the app's Application Support (inside the container when sandboxed).
    public init(spec: SearchModelSpec = .pinned, applicationSupport: URL? = nil) {
        self.spec = spec
        let base = applicationSupport ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = base.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// A store rooted exactly at `root` (tests and tools).
    public init(root: URL, spec: SearchModelSpec = .pinned) {
        self.root = root
        self.spec = spec
    }

    var modelParent: URL { root.appendingPathComponent(Self.modelFolder, isDirectory: true) }
    public var installDirectory: URL { modelParent.appendingPathComponent(spec.revisionFolder, isDirectory: true) }
    public var stagingDirectory: URL { modelParent.appendingPathComponent("staging", isDirectory: true) }
    public var weightsURL: URL { installDirectory.appendingPathComponent(SearchModelManifest.assembledFile) }
    public var tokenizerURL: URL { installDirectory.appendingPathComponent(spec.tokenizerFile) }
    var recordURL: URL { installDirectory.appendingPathComponent("installed.json") }
    var stagedWeights: URL { stagingDirectory.appendingPathComponent("model.safetensors") }
    var stagedWeightsPart: URL { stagingDirectory.appendingPathComponent("model.safetensors.part") }
    var stagedTokenizer: URL { stagingDirectory.appendingPathComponent("tokenizer.json") }
    var stagedTokenizerPart: URL { stagingDirectory.appendingPathComponent("tokenizer.json.part") }

    private static var directoryAttributes: [FileAttributeKey: Any] { [.posixPermissions: 0o700] }

    /// Creates the folders (0700), tells Spotlight to skip them and excludes them from backups. Safe to call often: a rename
    /// can drop the backup attribute, so the controller calls it at every start.
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

    public var isExcludedFromBackup: Bool {
        (try? root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true
    }

    func createStaging() throws {
        try prepare()
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true, attributes: Self.directoryAttributes)
    }

    public func discardStaging() { try? FileManager.default.removeItem(at: stagingDirectory) }

    /// What is on disk, without verifying it.
    public func disk() -> Disk {
        if let data = try? Data(contentsOf: recordURL), let record = try? Self.decoder.decode(SearchModelInstallRecord.self, from: data),
           record.revision == spec.revision, FileManager.default.fileExists(atPath: weightsURL.path),
           FileManager.default.fileExists(atPath: tokenizerURL.path) {
            return .installed(record)
        }
        return FileManager.default.fileExists(atPath: stagingDirectory.path) ? .partial : .empty
    }

    /// Moves the verified staging folder into place and writes the record. The previous install of the same revision (a
    /// reinstall) is replaced.
    func install(_ record: SearchModelInstallRecord) throws {
        let fm = FileManager.default
        let recordFile = stagingDirectory.appendingPathComponent("installed.json")
        try Self.encoder.encode(record).write(to: recordFile, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordFile.path)
        if fm.fileExists(atPath: installDirectory.path) { try fm.removeItem(at: installDirectory) }
        try fm.moveItem(at: stagingDirectory, to: installDirectory)
        try? excludeFromBackup()
    }

    func updateRecord(_ record: SearchModelInstallRecord) throws {
        try Self.encoder.encode(record).write(to: recordURL, options: .atomic)
    }

    /// Bytes on disk (installed files and any staging).
    public func bytesOnDisk() -> Int {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if v?.isRegularFile == true { total += v?.fileSize ?? 0 }
        }
        return total
    }

    /// Removes the model and any staging. Returns the bytes freed.
    @discardableResult
    public func delete() -> Int {
        let before = bytesOnDisk()
        try? FileManager.default.removeItem(at: modelParent)
        return before - bytesOnDisk()
    }

    /// Free space for the volume of the store (important-usage capacity), or nil when unknown.
    public func availableCapacity() -> Int? {
        // The nearest folder that exists (the store's own folder is created on first use).
        var probe = root
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe = probe.deletingLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage.map { Int($0) }
    }

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
