// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation
import Testing
@testable import VautaCore

/// Waits until the folder's Time Machine exclusion is `excluded`. The system's setter can apply a change a moment after it
/// returns when the whole suite runs at once (seen for one change in a few thousand), so a test that changes it through
/// the system waits for it rather than reading it at once; the app only ever excludes, and never relies on the moment.
func backupExclusion(of url: URL, settlesAt excluded: Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(10)
    while BackupExclusion.isExcluded(url) != excluded {
        guard ContinuousClock.now < deadline else { return false }
        try await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Time Machine's exclusion of the model folders is read from the attribute the system's setter writes on the folder, never
/// from a cache of resource values.
@Suite struct BackupExclusionTests {
    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vauta-exclusion-\(UUID().uuidString)/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func setExcluded(_ url: URL, _ excluded: Bool) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try url.setResourceValues(values)
    }

    @Test func theAttributeIsTheOneTheSystemWrites() async throws {
        let url = try folder("models")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(!BackupExclusion.isExcluded(url))
        try BackupExclusion.exclude(url)
        #expect(try await backupExclusion(of: url, settlesAt: true))
        #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // Taken off through another URL for the same folder, as a rename or a restore would.
        try setExcluded(URL(fileURLWithPath: url.path), false)
        #expect(try await backupExclusion(of: url, settlesAt: false))
        #expect(!BackupExclusion.isExcluded(url.appendingPathComponent("missing")))
    }

    @Test func everyChangeIsSeenWhileOtherFoldersChange() async throws {
        let unsettled = try await withThrowingTaskGroup(of: Int.self) { group in
            for task in 0..<8 {
                group.addTask {
                    let url = try folder("task-\(task)")
                    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    var unsettled = 0
                    for i in 0..<50 {
                        let excluded = i.isMultiple(of: 2)
                        try setExcluded(URL(fileURLWithPath: url.path), excluded)
                        if try await !backupExclusion(of: url, settlesAt: excluded) { unsettled += 1 }
                    }
                    return unsettled
                }
            }
            return try await group.reduce(0, +)
        }
        #expect(unsettled == 0)
    }
}
