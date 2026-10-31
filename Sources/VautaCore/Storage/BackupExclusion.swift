// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import Foundation

/// Time Machine's exclusion of a folder Vauta keeps models in: set with the system's API (`isExcludedFromBackup`), and read
/// from the attribute that API writes on the folder itself, never from a cache of resource values (one that predates a change
/// made through another URL). When the Mac is busy the setter may write the attribute a moment after it returns; the app only
/// ever excludes, and nothing depends on that moment (tests that change it wait for it).
enum BackupExclusion {
    /// The extended attribute of an item Time Machine skips wherever it is moved (a "sticky" exclusion).
    static let attribute = "com.apple.metadata:com_apple_backup_excludeItem"

    static func exclude(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func isExcluded(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return getxattr(path, attribute, nil, 0, 0, 0) >= 0
        }
    }
}
